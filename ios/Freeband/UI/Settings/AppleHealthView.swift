import HealthKit
import SwiftUI
import UIKit

struct AppleHealthView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View { AppleHealthDetails(service: model.healthExport) }
}

private struct AppleHealthDetails: View {
    @ObservedObject var service: HealthExportService
    @State private var confirming = false
    var body: some View {
        Form {
            Section {
                Text("Freeband can write eligible band steps, heart rate and sleep stages to Apple Health. It never reads Apple Health.")
                Text("Turning on exports eligible history stored on this phone and later syncs while Freeband is open. Corrections can update or remove entries Freeband previously wrote.")
                Text("Use one exporting iPhone per band. Reinstalling or using another phone can create duplicates. Health-side deletions cannot be detected.")
                Text("Deleting Freeband data or removing a band does not delete Health entries. Older history on this phone will not be exported again.")
            }.fbFormRow()
            Section {
                if !service.available {
                    Text("Apple Health is unavailable on this device or with demo data.")
                } else {
                    LabeledContent(String(localized: "Steps"), value: permission(.steps))
                    LabeledContent(String(localized: "Heart rate"), value: permission(.heartRate))
                    LabeledContent(String(localized: "Sleep stages"), value: permission(.sleep))
                    if let last = service.lastSuccess {
                        LabeledContent(String(localized: "Last successful sync"), value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    if service.busy { Text("Syncing…") }
                    if service.enabled && !service.busy && service.status == nil { Text("Ready to sync") }
                    if let status = service.status { Text(status) }
                    if service.enabled {
                        Button(String(localized: "Sync now")) { service.schedule() }.disabled(service.busy)
                        Button(String(localized: "Turn off Apple Health"), role: .destructive) { service.disable() }
                    } else {
                        Button(String(localized: "Turn on Apple Health")) { confirming = true }
                    }
                    Button(String(localized: "Open app settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    Text("Change write access in the Health app under your profile, Apps, Freeband.")
                }
            } header: { Text("Write access") }.fbFormRow()
        }
        .fbFormStyle()
        .navigationTitle(String(localized: "Apple Health"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { service.refresh() }
        .confirmationDialog(String(localized: "Turn on Apple Health export?"), isPresented: $confirming, titleVisibility: .visible) {
            Button(String(localized: "Continue")) { Task { await service.enable() } }
        } message: {
            Text("Freeband writes eligible history and may update or remove its own entries when band data changes. Re-enabling resumes pending corrections.")
        }
    }
    private func permission(_ kind: HealthExportKind) -> String {
        switch service.permissions[kind] {
        case .sharingAuthorized: String(localized: "Allowed to write")
        case .sharingDenied: String(localized: "Write access denied")
        default: String(localized: "Not requested")
        }
    }
}
