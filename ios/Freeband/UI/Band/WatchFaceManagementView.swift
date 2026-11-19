import SwiftUI

struct WatchFaceManagementView: View {
    let band: Band

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var link: BandLink
    @State private var deleteCandidate: WatchFace?
    @State private var showingDeleteConfirmation = false
    @State private var didAutoLoad = false

    private var isBusy: Bool { link.phase.isBusy }
    private var isLoading: Bool { isBusy && link.purpose == .watchFaces }

    var body: some View {
        List {
            Section {
                if isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(String(localized: "Loading watch faces…"))
                    }
                }

                if link.watchFaces.isEmpty && !isLoading {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "No watch faces loaded"))
                            .font(.headline)
                        Text(String(localized: "Tap refresh to read the watch faces installed on your band."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if case .failed = link.phase {
                            Text(link.phase.label)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(link.watchFaces) { face in
                        faceRow(face)
                    }
                }
            } header: {
                Text(String(localized: "Installed on the band"))
            } footer: {
                Text(String(localized: "Close Mi Fitness before managing watch faces. Only custom inactive faces can be deleted."))
            }

            Section {
                Label(String(localized: "Custom watch-face file upload is not available yet for the Mi Band 8 transport."), systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "Watch faces"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(Text(String(localized: "Refresh watch faces")))
                .disabled(isBusy)
            }
        }
        .task {
            guard !didAutoLoad else { return }
            didAutoLoad = true
            if link.watchFaces.isEmpty && !isBusy { refresh() }
        }
        .confirmationDialog(
            String(localized: "Delete this watch face?"),
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                guard let face = deleteCandidate else { return }
                model.start(band, .watchFaceDelete(face.id))
                deleteCandidate = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                deleteCandidate = nil
            }
        } message: {
            Text(deleteCandidate?.name ?? "")
        }
    }

    @ViewBuilder
    private func faceRow(_ face: WatchFace) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(face.name)
                        .font(.body.weight(.medium))
                    Text("ID: \(face.id)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if face.isActive {
                    Label(String(localized: "Active"), systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }

            if !face.isActive || face.canDelete {
                HStack {
                    if !face.isActive {
                        Button(String(localized: "Set as active")) {
                            model.start(band, .watchFaceSet(face.id))
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                    }
                    if face.canDelete && !face.isActive {
                        Spacer()
                        Button(role: .destructive) {
                            deleteCandidate = face
                            showingDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(Text(String(localized: "Delete watch face")))
                        .disabled(isBusy)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func refresh() {
        model.start(band, .watchFaces)
    }
}
