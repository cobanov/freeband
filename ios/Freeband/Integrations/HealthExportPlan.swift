import Foundation

// This file contains no HealthKit calls. In particular, a missing source value is only
// evidence of deletion when its entire reconciliation scope was successfully rebuilt.
enum HealthExportKind: String, Codable, CaseIterable {
    case steps, heartRate, restingHeartRate, oxygen, sleep
}

struct HealthExportSample: Codable, Equatable {
    let namespace: UUID
    let kind: HealthExportKind
    let start: Date
    let end: Date
    /// Count, beats per minute, or a Freeband StageKind raw value for sleep.
    let value: Int

    /// The namespace is random; neither a MAC address nor a local SwiftData ID leaves the app.
    var identifier: String {
        let timestamp = Int64(start.timeIntervalSince1970.rounded())
        return "freeband.v1.\(namespace.uuidString.lowercased()).\(kind.rawValue).\(timestamp)"
    }

    var fingerprint: String {
        "\(Int64(start.timeIntervalSince1970.rounded())):\(Int64(end.timeIntervalSince1970.rounded())):\(value)"
    }
}

struct HealthExportEntry: Codable, Equatable {
    let identifier: String
    let namespace: UUID
    let kind: HealthExportKind
    let start: Date
    var fingerprint: String
    var version: Int
    var state: State

    enum State: String, Codable { case savePending, saved, deletePending, deleted, suppressed }
}

struct HealthExportScope {
    let namespace: UUID
    let kind: HealthExportKind
    let start: Date
    let end: Date
    /// Set only after all inputs for this scope have been parsed and committed successfully.
    let authoritative: Bool

    func contains(_ entry: HealthExportEntry) -> Bool {
        namespace == entry.namespace && kind == entry.kind && start <= entry.start && entry.start < end
    }
}

enum HealthExportChange: Equatable {
    case save(HealthExportSample, version: Int)
    case delete(identifier: String, kind: HealthExportKind)
}

enum HealthExportPlanner {
    /// A caller persists each returned ledger mutation before issuing the corresponding operation.
    /// Duplicate identifiers and overlapping scopes are rejected rather than guessed at.
    enum PlanError: Error { case duplicateIdentifier, overlappingScopes, versionOverflow }

    static func reconcile(samples: [HealthExportSample], entries: [HealthExportEntry],
                          scopes: [HealthExportScope]) throws -> (entries: [HealthExportEntry], changes: [HealthExportChange]) {
        guard Set(samples.map(\.identifier)).count == samples.count,
              Set(entries.map(\.identifier)).count == entries.count else { throw PlanError.duplicateIdentifier }
        for (index, scope) in scopes.enumerated() {
            for other in scopes.dropFirst(index + 1) where scope.namespace == other.namespace && scope.kind == other.kind {
                if scope.start < other.end && other.start < scope.end { throw PlanError.overlappingScopes }
            }
        }
        var byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.identifier, $0) })
        var changes: [HealthExportChange] = []
        for sample in samples.sorted(by: { $0.identifier < $1.identifier }) {
            let id = sample.identifier
            if var entry = byID[id] {
                if entry.state == .suppressed { continue }
                if entry.fingerprint != sample.fingerprint || entry.state == .deleted || entry.state == .deletePending {
                    guard entry.version < Int.max else { throw PlanError.versionOverflow }
                    entry.version += 1
                    entry.fingerprint = sample.fingerprint
                    entry.state = .savePending
                }
                if entry.state == .savePending { changes.append(.save(sample, version: entry.version)) }
                byID[id] = entry
            } else {
                byID[id] = HealthExportEntry(identifier: id, namespace: sample.namespace, kind: sample.kind,
                                             start: sample.start, fingerprint: sample.fingerprint,
                                             version: 1, state: .savePending)
                changes.append(.save(sample, version: 1))
            }
        }
        let desired = Set(samples.map(\.identifier))
        for id in byID.keys.sorted() {
            guard var entry = byID[id], !desired.contains(id), entry.state != .deleted, entry.state != .suppressed,
                  scopes.contains(where: { $0.authoritative && $0.contains(entry) }) else { continue }
            entry.state = .deletePending
            byID[id] = entry
            changes.append(.delete(identifier: id, kind: entry.kind))
        }
        return (byID.values.sorted { $0.identifier < $1.identifier }, changes)
    }
}
