import SwiftData
import SwiftUI

/// Session state, the latest calibration report (with JSON export and parse-again), the band's
/// raw files (shareable) and the last session's log.
struct DiagnosticsView: View {
    @EnvironmentObject private var link: BandLink
    @EnvironmentObject private var model: AppModel
    @Query(sort: \ActivityBlob.ts, order: .reverse) private var blobs: [ActivityBlob]
    @State private var share: ShareItem?
    @State private var exportError: String?

    private var busy: Bool { model.ingestBusy || link.phase.isBusy }

    var body: some View {
        List {
            Section {
                LabeledContent(String(localized: "State"), value: link.phase.label.isEmpty ? String(localized: "Idle") : link.phase.label)
                if let outcome = link.lastOutcome { LabeledContent(String(localized: "Last session"), value: outcome.label) }
            }
            .fbFormRow()

            calibration

            Section {
                if blobs.isEmpty {
                    Text("No files yet. After a sync the band's records are listed here.")
                        .foregroundStyle(.textSecondary)
                } else {
                    Button(String(localized: "Share raw files (\(blobs.count))")) { shareRaw() }
                    ForEach(blobs.prefix(60)) { blob in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(blob.kindLabel).textStyle(.body)
                            Text(verbatim: "\(blob.ts.formatted(date: .abbreviated, time: .shortened)) · \(blob.data.count.formatted(.byteCount(style: .file))) · \(blob.parseStatus)\(blob.parseNote.map { " · \($0)" } ?? "")")
                                .textStyle(.caption)
                                .foregroundStyle(.textSecondary)
                        }
                    }
                }
            } header: {
                Text("The band's files")
            } footer: {
                Text("Raw files can be shared to check the file formats. They contain your health data.")
            }
            .fbFormRow()

            Section {
                if link.log.isEmpty {
                    Text("No session yet.").foregroundStyle(.textSecondary)
                }
                ForEach(Array(link.log.enumerated()), id: \.offset) { entry in
                    Text(verbatim: entry.element).font(.caption.monospaced()).foregroundStyle(.textBody)
                }
            } header: {
                Text("Log")
            }
            .fbFormRow()
        }
        .fbFormStyle()
        .navigationTitle(String(localized: "Diagnostics"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { ActivitySheet(items: $0.urls) }
        .toolbar {
            if !link.log.isEmpty {
                ShareLink(item: link.log.joined(separator: "\n")) {
                    Label(String(localized: "Share log"), systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    /// Phase 0 calibration (plan section 4): the latest per-sync report.
    @ViewBuilder private var calibration: some View {
        Section {
            if let report = model.calibration {
                LabeledContent(String(localized: "Report"), value: report.generatedAt.formatted(date: .abbreviated, time: .shortened))
                if let outcome = report.outcome { LabeledContent(String(localized: "Outcome"), value: outcome) }
                LabeledContent(String(localized: "Files"), value: FBFormat.number(report.files.count))
                if let history = report.history {
                    LabeledContent(String(localized: "Today list"), value: history.todayCount.map(FBFormat.number) ?? String(localized: "No response"))
                    LabeledContent(String(localized: "Past list"), value: history.pastCount.map(FBFormat.number) ?? String(localized: "No response"))
                    LabeledContent(String(localized: "Requested / received / failed"), value: "\(history.requested) / \(history.received) / \(history.failed)")
                    if history.listIncomplete {
                        Text("A file list was missing or malformed. Sync again; available files are still processed.")
                    } else if history.pastCount == 0 {
                        Text("The past list was empty. Some devices report older files in today's list; see the session log for file kinds.")
                    }
                }
                LabeledContent(String(localized: "Checks"), value: ["pass", "warn", "fail", "skip"]
                    .compactMap { k in report.counts[k].map { "\(k) \($0)" } }.joined(separator: " · "))
                ForEach(Array(report.checks.enumerated()), id: \.offset) { _, check in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: FBSpace.xs) {
                            if check.status == .fail {
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.low).accessibilityHidden(true)
                            }
                            Text(verbatim: "\(check.status.rawValue) · \(check.name)\(check.subject.map { " \($0)" } ?? "")")
                                .textStyle(.subhead)
                                .foregroundStyle(.textPrimary)
                        }
                        Text(verbatim: check.detail).textStyle(.caption).foregroundStyle(.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Button(String(localized: "Share report as JSON"), action: exportReport)
            } else {
                Text("No report yet. After a sync, every file and its sanity checks show up here.")
                    .foregroundStyle(.textSecondary)
            }
            Button(busy ? String(localized: "Working…") : String(localized: "Parse all files again")) {
                Task { await model.reparseAll() }
            }
            .disabled(busy)
        } header: {
            Text("Calibration")
        } footer: {
            Text(exportError ?? String(localized: "Parsing again rebuilds sleep, minute data and scores from the stored raw files."))
        }
        .fbFormRow()
    }

    private func exportReport() {
        do {
            if let url = try model.exportCalibration() { share = ShareItem(urls: [url]) }
            exportError = nil
        } catch {
            exportError = String(localized: "Couldn't write the report: \(error.localizedDescription)")
        }
    }

    /// Writes every stored file as <type-subtype-detail-vN>_<id>.bin into a temporary folder.
    private func shareRaw() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("freeband-raw", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = blobs.compactMap { blob -> URL? in
            let url = folder.appendingPathComponent("\(blob.type)-\(blob.subtype)-\(blob.detailType)-v\(blob.version)_\(blob.fileID).bin")
            return (try? blob.data.write(to: url, options: .completeFileProtection)) != nil ? url : nil
        }
        if !urls.isEmpty { share = ShareItem(urls: urls) }
    }
}

/// Version, privacy, the first-run again, and the trademark note.
struct AboutView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("onboarded") private var onboarded = true
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.l) {
                ListCard {
                    ListRow(title: String(localized: "Version"), value: Payload.appVersion, accessory: .none)
                    Button { openURL(model.hubURL.appendingPathComponent("privacy")) } label: {
                        ListRow(title: String(localized: "Privacy"), systemImage: nil)
                    }
                    .buttonStyle(.fbRow)
                    Button { onboarded = false } label: {
                        ListRow(title: String(localized: "Show the first-run steps again"), showsDivider: false)
                    }
                    .buttonStyle(.fbRow)
                }
                Footnote(String(localized: "Freeband is an independent project, not affiliated with Xiaomi. Xiaomi, Mi Band and Mi Fitness are trademarks of Xiaomi Inc."))
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.xl)
        }
        .fbScreen()
        .navigationTitle(String(localized: "About"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
