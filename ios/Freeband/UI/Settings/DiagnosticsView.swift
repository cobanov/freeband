import SwiftData
import SwiftUI

/// Session state, the latest calibration report (with JSON export and parse-again), the band's
/// raw files (shareable) and the last session's log.
struct DiagnosticsView: View {
    @EnvironmentObject private var link: BandLink
    @State private var askingBind = false
    @State private var logLines: [String] = []
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
                if logLines.isEmpty {
                    Text("No session yet.").foregroundStyle(.textSecondary)
                }
                ForEach(Array(logLines.enumerated()), id: \.offset) { entry in
                    Text(verbatim: entry.element).font(.caption.monospaced()).foregroundStyle(.textBody)
                }
            } header: {
                Text("Log")
            }
            .fbFormRow()
        }
        .fbFormStyle()
        .navigationTitle(String(localized: "Diagnostics"))
        .onAppear { logLines = link.log.lines }
        .onReceive(link.log.$lines) { logLines = $0 }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { ActivitySheet(items: $0.urls) }
        .toolbar {
            if !logLines.isEmpty {
                ShareLink(item: logLines.joined(separator: "\n")) {
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
            Button(String(localized: "Probe the band")) { model.probeSelectedBand() }
                .disabled(link.phase.isBusy)
            Button(String(localized: "Ask the band how it pairs")) { askingBind = true }
                .disabled(link.phase.isBusy)
                .confirmationDialog(String(localized: "Ask the band how it pairs?"), isPresented: $askingBind, titleVisibility: .visible) {
                    Button(String(localized: "Ask")) { model.probeBindSelectedBand() }
                    Button(String(localized: "Cancel"), role: .cancel) {}
                } message: {
                    Text("Freeband sends the first step of pairing and stops. The answer shows in the log. On a band that is already paired this has not been tried: it should only be refused, but the band may show a pairing screen.")
                }
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
                    Button { openURL(AppModel.siteURL.appendingPathComponent("privacy")) } label: {
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
