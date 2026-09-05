import Foundation
import UIKit

/// Orchestrates: validate 10 photos → upload → poll → download → VR (no LatLong preview).
@MainActor
final class SpaceGenerationCoordinator: ObservableObject {
    @Published private(set) var state: SpaceRecordState = .idle
    @Published private(set) var localLatLongURL: URL?
    @Published private(set) var jobId: String?
    @Published private(set) var sessionId: String?

    private var api: SpaceRecordAPIClienting?
    private var sourceFiles: [(direction: String, fileURL: URL)] = []
    private var pollTask: Task<Void, Never>?
    private var generationStarted = false
    private let maxWaitSec: TimeInterval = 180

    private static let persistenceKey = "gonggi.spaceRecord.active"

    init(api: SpaceRecordAPIClienting? = nil) {
        self.api = api
    }

    func configure(useMock: Bool) {
        if api == nil {
            api = useMock ? MockSpaceRecordAPIClient() : LockerSpaceRecordAPIClient()
        }
    }

    deinit {
        pollTask?.cancel()
    }

    /// Start generation after DirectionCapture completes (exactly once).
    func start(from result: DirectionCaptureResult) {
        guard !generationStarted else { return }
        generationStarted = true
        state = .preparing
        localLatLongURL = nil

        let validation = Self.validateCaptureFiles(result: result)
        switch validation {
        case .failure:
            state = .failed(.captureIncomplete)
            generationStarted = false
            return
        case .success(let files):
            sourceFiles = files
            sessionId = result.sessionId
            persist()
            Task { await self.uploadAndPoll(regenerate: false) }
        }
    }

    func retryGenerate() {
        guard !sourceFiles.isEmpty, let sessionId else {
            state = .failed(.captureIncomplete)
            return
        }
        pollTask?.cancel()
        generationStarted = true
        state = .preparing
        localLatLongURL = nil
        _ = sessionId
        Task { await self.uploadAndPoll(regenerate: true) }
    }

    func resetForRecapture() {
        pollTask?.cancel()
        pollTask = nil
        generationStarted = false
        sourceFiles = []
        jobId = nil
        sessionId = nil
        localLatLongURL = nil
        state = .idle
        UserDefaults.standard.removeObject(forKey: Self.persistenceKey)
    }

    func resumeIfNeeded() {
        guard case .idle = state else { return }
        guard let data = UserDefaults.standard.data(forKey: Self.persistenceKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobId = obj["jobId"] as? String,
              let sessionId = obj["sessionId"] as? String
        else { return }
        self.jobId = jobId
        self.sessionId = sessionId
        generationStarted = true
        state = .generating
        Task { await self.pollUntilDone(jobId: jobId, startedAt: Date()) }
    }

    // MARK: - Validation

    static func validateCaptureFiles(
        result: DirectionCaptureResult
    ) -> Result<[(direction: String, fileURL: URL)], SpaceRecordFailure> {
        var files: [(direction: String, fileURL: URL)] = []
        var seen = Set<String>()
        let dir = result.directoryURL

        for name in DirectionName.captureOrder {
            if seen.contains(name.rawValue) {
                return .failure(.captureIncomplete)
            }
            seen.insert(name.rawValue)
            let url = dir.appendingPathComponent(name.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .failure(.captureIncomplete)
            }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber,
                  size.intValue > 0
            else {
                return .failure(.captureIncomplete)
            }
            // Prefer readable file over in-memory only
            files.append((direction: name.rawValue, fileURL: url))
        }

        guard files.count == 10 else { return .failure(.captureIncomplete) }
        return .success(files)
    }

    /// Test helper: count of times generation pipeline entered uploading.
    private(set) var uploadStartCount = 0

    // MARK: - Pipeline

    private func uploadAndPoll(regenerate: Bool) async {
        guard let api else {
            state = .failed(.network)
            generationStarted = false
            return
        }
        state = .uploading
        uploadStartCount += 1
        do {
            let response: SpaceRecordCreateResponse
            if regenerate {
                response = try await api.regenerate(sessionId: sessionId ?? "", imageFiles: sourceFiles)
            } else {
                response = try await api.create(sessionId: sessionId ?? "", imageFiles: sourceFiles)
            }
            jobId = response.jobId
            sessionId = response.sessionId
            persist()

            if response.status == "completed" {
                state = .loadingResult
            }
            state = .generating
            await pollUntilDone(jobId: response.jobId, startedAt: Date())
        } catch SpaceRecordClientError.captureIncomplete {
            state = .failed(.captureIncomplete)
            generationStarted = false
        } catch {
            state = .failed(.network)
            generationStarted = false
        }
    }

    private func pollUntilDone(jobId: String, startedAt: Date) async {
        guard let api else { return }
        pollTask?.cancel()
        let intervals: [UInt64] = [
            2_000_000_000, 2_000_000_000, 3_000_000_000, 3_000_000_000, 5_000_000_000
        ]
        var i = 0
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                if Date().timeIntervalSince(startedAt) > maxWaitSec {
                    self.state = .failed(.timeout)
                    self.generationStarted = false
                    return
                }
                do {
                    let status = try await api.fetchStatus(jobId: jobId)
                    if status.status == "failed" {
                        self.state = .failed(.generationFailed)
                        self.generationStarted = false
                        return
                    }
                    if status.status == "completed", let urlString = status.imageUrl {
                        await self.finishWithRemoteURL(urlString, width: status.width, height: status.height)
                        return
                    }
                    self.state = .generating
                } catch {
                    // Transient — keep polling until timeout
                }
                let delay = intervals[min(i, intervals.count - 1)]
                i += 1
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        await pollTask?.value
    }

    private func finishWithRemoteURL(_ urlString: String, width: Int?, height: Int?) async {
        guard let api else { return }
        state = .loadingResult
        guard let remote = URL(string: urlString) else {
            state = .failed(.invalidResult)
            generationStarted = false
            return
        }
        if let width, let height, (width != 2048 || height != 1024) {
            if remote.scheme?.hasPrefix("http") == true {
                state = .failed(.invalidResult)
                generationStarted = false
                return
            }
        }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("gonggi-latlong-\(jobId ?? UUID().uuidString).jpg")
        do {
            try await api.downloadImage(from: remote, to: dest)
            guard let img = UIImage(contentsOfFile: dest.path),
                  let cg = img.cgImage,
                  cg.width > 0, cg.height > 0
            else {
                state = .failed(.invalidResult)
                generationStarted = false
                return
            }
            localLatLongURL = dest
            state = .viewing
            persist()
        } catch {
            state = .failed(.network)
            generationStarted = false
        }
    }

    private func persist() {
        var obj: [String: Any] = [:]
        if let sessionId { obj["sessionId"] = sessionId }
        if let jobId { obj["jobId"] = jobId }
        if let localLatLongURL { obj["localURL"] = localLatLongURL.path }
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            UserDefaults.standard.set(data, forKey: Self.persistenceKey)
        }
    }
}
