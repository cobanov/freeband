import AppIntents
import SwiftData
import SwiftUI
import UIKit

/// Up to five signed https endpoints that get each sync's data.
struct WebhooksView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.modelContext) private var context
    @Query(sort: \Webhook.createdAt) private var hooks: [Webhook]
    @State private var newURL = ""
    @State private var urlError: String?

    var body: some View {
        Form {
            Section {
                Text("After every sync Freeband sends that sync's data to these addresses as JSON. Requests are signed; check them with the secret on the receiving side.")
                    .textStyle(.subhead)
                    .foregroundStyle(.textSecondary)
            }
            .fbFormRow()
            ForEach(hooks) { hook in
                Section {
                    Toggle(isOn: Binding(get: { hook.enabled }, set: { hook.enabled = $0; try? context.save() })) {
                        Text(hook.url).lineLimit(2).textStyle(.subhead)
                    }
                    LabeledContent(String(localized: "Secret")) {
                        Button(String(localized: "Copy")) { UIPasteboard.general.string = hook.secret }
                    }
                    if let status = hook.lastStatus, let at = hook.lastAt {
                        LabeledContent(String(localized: "Last delivery"), value: "\(status), \(FBFormat.time(at))")
                    }
                    Button(String(localized: "Send a test")) { Task { await model.ping(hook) } }
                    Button(String(localized: "Delete webhook"), role: .destructive) {
                        context.delete(hook)
                        try? context.save()
                    }
                }
                .fbFormRow()
            }
            Section {
                TextField("https://", text: $newURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(String(localized: "Add webhook")) { add() }
                    .disabled(newURL.isEmpty || hooks.count >= 5)
            } header: {
                Text("New address")
            } footer: {
                Text(urlError ?? String(localized: "Up to 5 addresses, https:// only. The signature format is in the API docs (Web access › Open API docs)."))
            }
            .fbFormRow()
        }
        .fbFormStyle()
        .navigationTitle(String(localized: "Webhooks"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        let trimmed = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https", url.host != nil else {
            urlError = String(localized: "The address must start with https:// and include a domain.")
            return
        }
        context.insert(Webhook(url: url.absoluteString, secret: WebhookSender.newSecret()))
        try? context.save()
        newURL = ""
        urlError = nil
    }
}

/// What Siri and Shortcuts can do with Freeband.
struct ShortcutsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.l) {
                ListCard {
                    ListRow(title: String(localized: "Find band"), subtitle: String(localized: "“Find my band with Freeband”"),
                            systemImage: "dot.radiowaves.left.and.right", accessory: .none)
                    ListRow(title: String(localized: "Send to band"), subtitle: String(localized: "“Send a message to my band with Freeband”"),
                            systemImage: "text.bubble", accessory: .none)
                    ListRow(title: String(localized: "Sync band"), subtitle: String(localized: "“Sync my band with Freeband”"),
                            systemImage: "arrow.triangle.2.circlepath", accessory: .none, showsDivider: false)
                }
                Footnote(String(localized: "Shortcuts open Freeband for a moment: the band only talks to the app while it runs."))
                ShortcutsLink()
                    .shortcutsLinkStyle(.automaticOutline)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.xl)
        }
        .fbScreen()
        .navigationTitle(String(localized: "Shortcuts & Siri"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
