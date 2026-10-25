import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum SpaceImportPhase: Equatable {
    case picking
    case validating
    case uploading
    case finishing
    case failed(String)
    case done
}

@MainActor
final class SpaceImportViewModel: ObservableObject {
    @Published var phase: SpaceImportPhase = .picking
    @Published var titleText: String = ""
    @Published var previewImage: UIImage?
    @Published var pickedVideoURL: URL?
    @Published var pickedPlyURL: URL?
    @Published var pickedPlyName: String?
    @Published var mediaKind: String = "still"

    private let api = SpaceImportAPIClient()
    private let plyApi = MobileGaussianPLYAPIClient()
    private let store = SpaceJobStore.shared

    var statusLine: String? {
        switch phase {
        case .validating: return L("Checking the file…")
        case .uploading: return L("Uploading…")
        case .finishing: return L("Adding the space…")
        case .failed(let m): return m
        default: return nil
        }
    }

    func reset() {
        phase = .picking
        titleText = ""
        previewImage = nil
        pickedVideoURL = nil
        pickedPlyURL = nil
        pickedPlyName = nil
        mediaKind = "still"
    }

    func handlePickedImage(_ image: UIImage) {
        phase = .validating
        guard let validated = SpaceImportMediaValidator.validateStillImage(image) else {
            phase = .failed(
                L("Only 2:1 panorama (LatLong) images can be imported. Choose a file exported as equirectangular from a 360 camera.")
            )
            return
        }
        _ = validated
        previewImage = image
        pickedVideoURL = nil
        pickedPlyURL = nil
        pickedPlyName = nil
        mediaKind = "still"
        phase = .picking
    }

    func handlePickedVideo(url: URL) async {
        phase = .validating
        do {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                phase = .failed(L("Can't read the video"))
                return
            }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let rendered = size.applying(transform)
            let w = Int(abs(rendered.width))
            let h = Int(abs(rendered.height))
            guard w > 0, h > 0, w == h * 2, w >= 1024, w <= 8192 else {
                phase = .failed(
                    L("Only 2:1 panorama (equirectangular) videos can be imported. Choose a video exported in that format from a 360 camera.")
                )
                return
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let cg = try generator.copyCGImage(at: .zero, actualTime: nil)
            let poster = UIImage(cgImage: cg)
            guard SpaceImportMediaValidator.validateStillImage(poster) != nil else {
                phase = .failed(L("Can't make a panorama poster from the video"))
                return
            }
            previewImage = poster
            pickedVideoURL = url
            pickedPlyURL = nil
            pickedPlyName = nil
            mediaKind = "video"
            phase = .picking
        } catch {
            phase = .failed(L("Can't check the video"))
        }
    }

    
    func handlePickedPly(url: URL) {
        phase = .validating
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        guard name.lowercased().hasSuffix(".ply") else {
            phase = .failed(L("Only PLY files can be imported"))
            return
        }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            let size = values.fileSize ?? 0
            guard size > 0 else {
                phase = .failed(L("Can't read the file"))
                return
            }
            if size > MobileGaussianPLYAPIClient.maxFileBytes {
                phase = .failed(MobileGaussianPLYAPIClient.PLYImportError.tooLarge.userMessage)
                return
            }
            pickedPlyURL = url
            pickedPlyName = name
            previewImage = nil
            pickedVideoURL = nil
            mediaKind = "ply"
            phase = .picking
        } catch {
            phase = .failed(L("Can't check the PLY file"))
        }
    }

    /// Returns Gaussian space id when mediaKind == ply; otherwise LatLong session/job id.
    func submit() async -> String? {
        let title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = title.isEmpty ? L("Imported space") : title

        if mediaKind == "ply", let plyURL = pickedPlyURL {
            return await submitPly(fileURL: plyURL, displayName: displayName)
        }
        if mediaKind == "video", let videoURL = pickedVideoURL, let poster = previewImage {
            return await submitVideo(videoURL: videoURL, poster: poster, displayName: displayName)
        }
        guard let image = previewImage,
              let validated = SpaceImportMediaValidator.validateStillImage(image)
        else {
            phase = .failed(L("Choose an image to import"))
            return nil
        }
        phase = .uploading
        do {
            let result = try await api.importStill(
                jpegData: validated.jpeg,
                title: displayName
            )
            phase = .finishing
            let dest = try SpaceLatLongStore.latLongURL(sessionId: result.sessionId)
            try validated.jpeg.write(to: dest, options: .atomic)
            let job = SpaceJobRecord(
                sessionId: result.sessionId,
                jobId: result.jobId,
                createdAt: Date(),
                completedAt: Date(),
                serverStatus: "completed",
                displayName: displayName,
                resultImageURL: result.imageUrl,
                localLatLongPath: dest.path,
                localLatLongSourceURL: result.imageUrl,
                latestRevisionId: result.latestRevisionId ?? "rev-0-base",
                width: result.width,
                height: result.height,
                ownerUserId: {
                    if case .user(let id) = store.boundScope { return id }
                    return nil
                }(),
                sourceKind: "import",
                mediaKind: "still"
            )
            store.upsert(job)
            phase = .done
            return result.jobId
        } catch let err as SpaceImportAPIClient.ImportError {
            phase = .failed(SpaceImportMediaValidator.userMessage(for: err))
            return nil
        } catch {
            phase = .failed(L("Import failed"))
            return nil
        }
    }

    private func submitVideo(videoURL: URL, poster: UIImage, displayName: String) async -> String? {
        guard let validated = SpaceImportMediaValidator.validateStillImage(poster) else {
            phase = .failed(L("The poster image isn't valid"))
            return nil
        }
        phase = .uploading
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: videoURL.path)
            let byteSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
            let ext = videoURL.pathExtension.lowercased()
            let contentType = (ext == "mov") ? "video/quicktime" : "video/mp4"
            let presign = try await api.presignVideo(contentType: contentType, byteSize: byteSize)
            try await api.uploadVideo(
                to: presign.uploadUrl,
                fileURL: videoURL,
                contentType: contentType
            )
            phase = .finishing
            let result = try await api.completeVideoImport(
                sessionId: presign.sessionId,
                videoKey: presign.videoKey,
                contentType: contentType,
                posterJPEG: validated.jpeg,
                title: displayName
            )
            let posterDest = try SpaceLatLongStore.latLongURL(sessionId: result.sessionId)
            try validated.jpeg.write(to: posterDest, options: .atomic)
            let localVideo = try SpaceLatLongStore.videoURL(
                sessionId: result.sessionId,
                pathExtension: ext.isEmpty ? "mp4" : ext
            )
            if FileManager.default.fileExists(atPath: localVideo.path) {
                try? FileManager.default.removeItem(at: localVideo)
            }
            try FileManager.default.copyItem(at: videoURL, to: localVideo)

            let job = SpaceJobRecord(
                sessionId: result.sessionId,
                jobId: result.jobId,
                createdAt: Date(),
                completedAt: Date(),
                serverStatus: "completed",
                displayName: displayName,
                resultImageURL: result.imageUrl,
                localLatLongPath: posterDest.path,
                localLatLongSourceURL: result.imageUrl,
                latestRevisionId: result.latestRevisionId ?? "rev-0-base",
                width: result.width,
                height: result.height,
                ownerUserId: {
                    if case .user(let id) = store.boundScope { return id }
                    return nil
                }(),
                sourceKind: "import",
                mediaKind: "video",
                remoteVideoURL: result.videoUrl,
                localVideoPath: localVideo.path
            )
            store.upsert(job)
            phase = .done
            return result.jobId
        } catch let err as SpaceImportAPIClient.ImportError {
            phase = .failed(SpaceImportMediaValidator.userMessage(for: err))
            return nil
        } catch {
            phase = .failed(L("Video import failed"))
            return nil
        }
    }

    private func submitPly(fileURL: URL, displayName: String) async -> String? {
        phase = .uploading
        do {
            let result = try await plyApi.importPLY(fileURL: fileURL, name: displayName)
            phase = .done
            return "gaussian:" + result.spaceId
        } catch let err as MobileGaussianPLYAPIClient.PLYImportError {
            phase = .failed(err.userMessage)
            return nil
        } catch {
            phase = .failed(L("PLY import failed"))
            return nil
        }
    }
}

struct SpaceImportSheet: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = SpaceImportViewModel()
    @State private var photoItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var showPlyImporter = false
    @Environment(\.dismiss) private var dismiss

    /// LatLong still/video import → session/job id
    var onImported: ((String) -> Void)?
    /// External PLY → Gaussian space id
    var onGaussianImported: ((String) -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                    Text(L("Add a 2:1 panorama (LatLong) image or video exported from a 360 camera as a space."))
                        .font(GonggiTypography.body(15))
                        .foregroundStyle(GonggiColors.textSecondary)

                    TextField(L("Space name (optional)"), text: $model.titleText)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: GonggiSpacing.md) {
                        PhotosPicker(
                            selection: $photoItem,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            labelChip(title: L("Image"), systemImage: "photo")
                        }
                        PhotosPicker(
                            selection: $videoItem,
                            matching: .videos,
                            photoLibrary: .shared()
                        ) {
                            labelChip(title: L("Video"), systemImage: "video")
                        }
                    }


                    Button {
                        showPlyImporter = true
                    } label: {
                        labelChip(title: "3DGS PLY", systemImage: "cube.transparent")
                    }
                    .disabled(model.phase.isBusy)

                    if model.mediaKind == "ply", let plyName = model.pickedPlyName {
                        HStack(spacing: 10) {
                            Image(systemName: "cube.transparent")
                                .font(.system(size: 28))
                                .foregroundStyle(GonggiColors.textSecondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(plyName)
                                    .font(GonggiTypography.body(15))
                                    .lineLimit(2)
                                Text(L("It will be added as a Gaussian splatting space"))
                                    .font(GonggiTypography.caption(13))
                                    .foregroundStyle(GonggiColors.textSecondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GonggiColors.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                    } else if let preview = model.previewImage {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Text(model.mediaKind == "video" ? L("It will be added as a video VR") : L("It will be added as a still panorama"))
                            .font(GonggiTypography.caption(13))
                            .foregroundStyle(GonggiColors.textSecondary)
                    }

                    if let status = model.statusLine {
                        Text(status)
                            .font(GonggiTypography.body(14))
                            .foregroundStyle(
                                model.phase.isFailed ? GonggiColors.warningCritical : GonggiColors.textSecondary
                            )
                    }

                    Button {
                        Task {
                            if let jobId = await model.submit() {
                                if jobId.hasPrefix("gaussian:") {
                                    let spaceId = String(jobId.dropFirst("gaussian:".count))
                                    onGaussianImported?(spaceId)
                                } else {
                                    appState.rebuildSpaces()
                                    onImported?(jobId)
                                }
                                dismiss()
                            }
                        }
                    } label: {
                        Text(L("Import as a space"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        (model.mediaKind == "ply" ? model.pickedPlyURL == nil : model.previewImage == nil)
                            || model.phase.isBusy
                    )
                }
                .padding(GonggiSpacing.lg)
            }
            .background(GonggiAmbientBackground())
            .navigationTitle(L("Import"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Close")) { dismiss() }
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        model.handlePickedImage(image)
                    } else {
                        model.phase = .failed(L("Couldn't load the image"))
                    }
                }
            }
            .onChange(of: videoItem) { _, item in
                guard let item else { return }
                Task {
                    if let movie = try? await item.loadTransferable(type: MovieFile.self) {
                        await model.handlePickedVideo(url: movie.url)
                    } else if let url = try? await item.loadTransferable(type: URL.self) {
                        await model.handlePickedVideo(url: url)
                    } else {
                        model.phase = .failed(L("Couldn't load the video"))
                    }
                }
            }

            .fileImporter(
                isPresented: $showPlyImporter,
                allowedContentTypes: [UTType(filenameExtension: "ply") ?? .data, .item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    model.handlePickedPly(url: url)
                case .failure:
                    model.phase = .failed(L("Couldn't select the PLY file"))
                }
            }
        }
    }

    private func labelChip(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(GonggiTypography.body(15))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(GonggiColors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private extension SpaceImportPhase {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .validating, .uploading, .finishing: return true
        default: return false
        }
    }
}

/// PhotosPicker transferable for a local movie copy.
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("gonggi-import-\(UUID().uuidString).\(received.file.pathExtension)")
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.copyItem(at: received.file, to: temp)
            return MovieFile(url: temp)
        }
    }
}
