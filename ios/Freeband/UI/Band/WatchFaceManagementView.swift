import SwiftUI
import UniformTypeIdentifiers
import CoreFoundation
import CoreGraphics
import UIKit

struct WatchFaceManagementView: View {
    let band: Band

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var link: BandLink
    @State private var deleteCandidate: WatchFace?
    @State private var showingDeleteConfirmation = false
    @State private var didAutoLoad = false
    @State private var showingImporter = false
    @State private var importedFace: ImportedWatchFace?
    @State private var importedPreview: MiWatchFacePreview?
    @State private var showingInstallConfirmation = false
    @State private var importError: String?

    private var isBusy: Bool { link.phase.isBusy }
    private var isInstalling: Bool {
        if case .watchFaceInstall = link.purpose { return isBusy }
        return false
    }
    private var isLoading: Bool { isBusy && (link.purpose == .watchFaces || isInstalling) }

    var body: some View {
        List {
            Section {
                if isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(isInstalling
                             ? String(localized: "Installing watch face…")
                             : String(localized: "Loading watch faces…"))
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
                Button {
                    showingImporter = true
                } label: {
                    Label(String(localized: "Choose .bin watch-face file"), systemImage: "square.and.arrow.down")
                }
                .disabled(isBusy)

                if let importedFace {
                    VStack(alignment: .leading, spacing: 10) {
                        if let preview = importedPreview, let previewImage = makePreviewImage(preview) {
                            Image(uiImage: previewImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 190)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            Label(String(localized: "Preview unavailable"), systemImage: "photo")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text(importedFace.name)
                            .font(.headline)
                        Text("ID: \(importedFace.id)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text("\(String(localized: "Mi Band 8 watch-face file")) · \(importedFace.data.count) bayt")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "Install and activate")) {
                            showingInstallConfirmation = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.08, green: 0.29, blue: 0.58))
                        .foregroundStyle(.white)
                        .disabled(isBusy)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text(String(localized: "Import a watch face"))
            } footer: {
                Text(String(localized: "Only Mi Band 8 binary watch faces with both the normal and always-on styles are accepted. Keep the band charged and close Mi Fitness during installation."))
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
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [UTType(filenameExtension: "bin") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            do {
                let urls = try result.get()
                guard let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                importedFace = try MiWatchFaceUpload.parseFile(data)
                importedPreview = MiWatchFacePreview.decode(data)
            } catch {
                importedFace = nil
                importedPreview = nil
                importError = error.localizedDescription
            }
        }
        .confirmationDialog(
            String(localized: "Install and activate this watch face?"),
            isPresented: $showingInstallConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Install"), role: .destructive) {
                guard let face = importedFace else { return }
                model.start(band, .watchFaceInstall(id: face.id, name: face.name, data: face.data))
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This writes a binary watch-face file to your Mi Band 8 and then activates it. An incompatible file may cause problems with the band."))
        }
        .alert(String(localized: "Couldn't open watch-face file"), isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
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

    private func makePreviewImage(_ preview: MiWatchFacePreview) -> UIImage? {
        let bytes = [UInt8](preview.rgba)
        guard bytes.count == preview.width * preview.height * 4,
              let providerData = bytes.withUnsafeBufferPointer({
                  CFDataCreate(kCFAllocatorDefault, $0.baseAddress, $0.count)
              }),
              let provider = CGDataProvider(data: providerData),
              let image = CGImage(width: preview.width, height: preview.height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: preview.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image)
    }

    private func refresh() {
        model.start(band, .watchFaces)
    }
}
