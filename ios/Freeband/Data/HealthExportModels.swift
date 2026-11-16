import Foundation
import SwiftData

/// Durable write-ahead ledger. It deliberately survives deletion of band observations.
@Model
final class HealthExportLedgerRow {
    @Attribute(.unique) var identifier: String = ""
    var namespace: UUID = UUID()
    var kind: String = ""
    var start: Date = Date()
    var fingerprint: String = ""
    var version: Int = 1
    var state: String = "savePending"

    init(_ entry: HealthExportEntry) { update(entry) }
    func update(_ entry: HealthExportEntry) {
        identifier = entry.identifier; namespace = entry.namespace; kind = entry.kind.rawValue
        start = entry.start; fingerprint = entry.fingerprint; version = entry.version; state = entry.state.rawValue
    }
    var entry: HealthExportEntry? {
        guard let kind = HealthExportKind(rawValue: kind), let state = HealthExportEntry.State(rawValue: state) else { return nil }
        return HealthExportEntry(identifier: identifier, namespace: namespace, kind: kind, start: start,
                                 fingerprint: fingerprint, version: version, state: state)
    }
}

@Model
final class HealthExportSettings {
    var enabled: Bool = false
    var lastSuccess: Date?
    /// Following a local deletion, older data is never automatically re-exported, even if the band is re-added.
    var suppressBefore: Date?
    init() { }
}
