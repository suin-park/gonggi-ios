import Foundation
import SwiftUI
import CoreGraphics

@MainActor
final class SpaceCleanupSession: ObservableObject {
    static let pollIntervalNanoseconds: UInt64 = 3_000_000_000
    static let maxPollDurationNanoseconds: UInt64 = 180_000_000_000 // 3 minutes

    @Published var mode: SpaceCleanupMode?
    @Published var points: [SpaceCleanupSelectionPoint] = []
    @Published var job: SpaceCleanupJobDTO?
    @Published var isSubmitting = false
    @Published var errorMessage: String?
    @Published var consentAccepted = false
    @Published private(set) var isActive = false
    @Published private(set) var poleWarningActive = false
    @Published private(set) var isPolling = false
    @Published var maskOverlayReady = false
    @Published var removalTargetText = ""

    private var client: any SpaceCleanupServing = SpaceCleanupAPIClient()
    private(set) var spaceId: String = ""
    private(set) var sourceRevisionId: String = ""
    var onAccepted: ((String?) -> Void)?

    private var pollTask: Task<Void, Never>?
    private var pollVisible = false
    private var pollStartedAt: Date?
    /// Test-only overrides (production leaves nil).
    var pollIntervalNanosecondsOverride: UInt64?
    var maxPollDurationNanosecondsOverride: UInt64?

    func configure(client: any SpaceCleanupServing) {
        self.client = client
    }

    func begin(spaceId: String, sourceRevisionId: String) {
        cancelPolling()
        self.spaceId = spaceId
        self.sourceRevisionId = sourceRevisionId
        mode = nil
        points = []
        job = nil
        errorMessage = nil
        consentAccepted = false
        isActive = false
        poleWarningActive = false
        maskOverlayReady = false
        removalTargetText = ""
    }

    func activateSelectedMode(spaceId: String, sourceRevisionId: String, consentAccepted: Bool) {
        begin(spaceId: spaceId, sourceRevisionId: sourceRevisionId)
        self.consentAccepted = consentAccepted
        mode = .selectedObjects
        isActive = true
        pollVisible = true
    }

    func deactivate() {
        cancelPolling()
        pollVisible = false
        isActive = false
        points = []
        job = nil
        errorMessage = nil
        poleWarningActive = false
        maskOverlayReady = false
        removalTargetText = ""
    }

    func onSelectionUIAppear() {
        pollVisible = true
        resumePollingIfNeeded()
    }

    func onSelectionUIDisappear() {
        pollVisible = false
        cancelPolling()
    }

    func onScenePhaseActive() {
        guard pollVisible else { return }
        resumePollingIfNeeded()
    }

    func onScenePhaseBackground() {
        cancelPolling()
    }

    func selectMode(_ mode: SpaceCleanupMode) {
        self.mode = mode
        points = []
        job = nil
        errorMessage = nil
        maskOverlayReady = false
        removalTargetText = ""
        cancelPolling()
    }

    /// Canonical equirect point — screen coords are optional auxiliaries only.
    func addPoint(
        u: Double,
        v: Double,
        yaw: Double,
        pitch: Double,
        direction: SpaceCleanupDirection,
        screen: CGPoint? = nil
    ) {
        poleWarningActive = v < 0.08 || v > 0.92 || abs(pitch) > (75 * .pi / 180)
        let screenX: Double? = screen.map { Double($0.x) }
        let screenY: Double? = screen.map { Double($0.y) }
        let point = SpaceCleanupSelectionPoint(
            id: "selection-\(points.count + 1)",
            u: Self.wrapU(u),
            v: min(1, max(0, v)),
            yaw: yaw,
            pitch: pitch,
            direction: direction,
            screenX: screenX,
            screenY: screenY
        )
        points.append(point)
    }

    func addCenterAim(
        yawDeg: Float,
        pitchDeg: Float,
        screen: CGPoint? = nil
    ) {
        let uv = VRSphereEquirectBridge.textureUVFromEquirectDegrees(
            yawDeg: yawDeg,
            pitchDeg: pitchDeg
        )
        let dir = SpaceLinkMath.lookDirection(yawDeg: yawDeg, pitchDeg: pitchDeg)
        addPoint(
            u: Double(uv.u),
            v: Double(uv.v),
            yaw: Double(yawDeg) * .pi / 180,
            pitch: Double(pitchDeg) * .pi / 180,
            direction: SpaceCleanupDirection(
                x: Double(dir.x),
                y: Double(dir.y),
                z: Double(dir.z)
            ),
            screen: screen
        )
    }

    func undoLast() {
        guard !points.isEmpty else { return }
        points.removeLast()
        if points.isEmpty { poleWarningActive = false }
    }

    func removePoint(id: String) {
        points.removeAll { $0.id == id }
        // Re-number for display stability
        for i in points.indices {
            points[i].id = "selection-\(i + 1)"
        }
        if points.isEmpty { poleWarningActive = false }
    }

    /// Clear selection and abandon current detect job — next submit gets a new idempotency intent.
    func resetForReselect() {
        cancelPolling()
        points.removeAll()
        job = nil
        poleWarningActive = false
        maskOverlayReady = false
        removalTargetText = ""
        errorMessage = nil
        isSubmitting = false
    }

    var canSubmitSelected: Bool { !points.isEmpty && job == nil && !isSubmitting }
    var canConfirm: Bool {
        guard let job, job.isAwaitingConfirmation else { return false }
        guard !(job.detectedObjects ?? []).isEmpty else { return false }
        let trimmed = removalTargetText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !isSubmitting
    }

    var detectedPolygons: [[SpaceCleanupUvPoint]] {
        (job?.detectedObjects ?? []).map(\.polygon)
    }

    func markMaskOverlayReady(_ ready: Bool) {
        maskOverlayReady = ready
    }

    func submitAllFurniture() async {
        guard consentAccepted else {
            errorMessage = "AI 이용 동의가 필요합니다."
            return
        }
        await create(mode: .allFurniture, points: nil)
        if let resultId = job?.placementResultId {
            onAccepted?(resultId)
        }
    }

    func submitSelected() async {
        guard consentAccepted else {
            errorMessage = "AI 이용 동의가 필요합니다."
            return
        }
        guard canSubmitSelected else {
            errorMessage = "가구를 하나 이상 선택해 주세요."
            return
        }
        maskOverlayReady = false
        await create(mode: .selectedObjects, points: points)
        startPollingIfNeeded()
    }

    /// Confirm detected masks, then hand off to 보관함 immediately (no VR edit polling).
    func confirmMasks() async {
        guard canConfirm, let jobId = job?.id else {
            errorMessage = "마스크를 확인한 뒤에만 정리할 수 있어요."
            return
        }
        guard job?.detectedObjects?.isEmpty == false else {
            errorMessage = "감지된 가구가 없어 확인할 수 없어요."
            return
        }
        let label = removalTargetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            errorMessage = "무엇을 제거할지 입력해 주세요."
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            job = try await client.confirmJob(id: jobId, removalTarget: label)
            // Curtain-style async handoff: leave VR; locker polls PROCESSING.
            cancelPolling()
            let resultId = job?.placementResultId
            isActive = false
            onAccepted?(resultId)
        } catch let error as SpaceCleanupAPIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = SpaceCleanupAPIError.offline.userMessage
        }
    }

    private func create(mode: SpaceCleanupMode, points: [SpaceCleanupSelectionPoint]?) async {
        isSubmitting = true
        defer { isSubmitting = false }
        errorMessage = nil
        let request = SpaceCleanupCreateRequest(
            spaceId: spaceId,
            sourceRevisionId: sourceRevisionId,
            mode: mode,
            points: points,
            aiConsentAccepted: true
        )
        let key = "cleanup-\(spaceId)-\(sourceRevisionId)-\(mode.rawValue)-\(UUID().uuidString)"
        do {
            job = try await client.createJob(request: request, idempotencyKey: key)
        } catch let error as SpaceCleanupAPIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = SpaceCleanupAPIError.offline.userMessage
        }
    }

    private func startPollingIfNeeded() {
        guard pollVisible else { return }
        guard let status = job?.status,
              ["QUEUED", "DETECTING", "PROCESSING"].contains(status)
        else {
            cancelPolling()
            return
        }
        guard pollTask == nil else { return }
        pollStartedAt = Date()
        isPolling = true
        let jobId = job?.id
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.pollIntervalNanosecondsOverride ?? Self.pollIntervalNanoseconds)
                guard !Task.isCancelled else { return }
                guard self.pollVisible else {
                    self.cancelPolling()
                    return
                }
                let maxNs = self.maxPollDurationNanosecondsOverride ?? Self.maxPollDurationNanoseconds
                if let started = self.pollStartedAt,
                   Date().timeIntervalSince(started) > Double(maxNs) / 1e9 {
                    self.errorMessage = "작업이 너무 오래 걸려 중단되었습니다. 다시 시도해 주세요."
                    self.cancelPolling()
                    return
                }
                guard let id = jobId ?? self.job?.id else {
                    self.cancelPolling()
                    return
                }
                do {
                    let fresh = try await self.client.fetchJob(id: id)
                    self.job = fresh
                    if fresh.isAwaitingConfirmation || fresh.isCompleted || fresh.isFailed {
                        self.cancelPolling()
                        if fresh.isCompleted {
                            self.onAccepted?(fresh.placementResultId)
                        }
                        if fresh.isFailed {
                            self.errorMessage = fresh.failureMessageSafe
                                ?? SpaceCleanupAPIError.server(status: 500).userMessage
                        }
                        return
                    }
                } catch let error as SpaceCleanupAPIError {
                    self.errorMessage = error.userMessage
                    self.cancelPolling()
                    return
                } catch {
                    self.errorMessage = SpaceCleanupAPIError.offline.userMessage
                    self.cancelPolling()
                    return
                }
            }
        }
    }

    private func resumePollingIfNeeded() {
        guard pollVisible, job?.isInFlight == true else { return }
        startPollingIfNeeded()
    }

    func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    static func wrapU(_ u: Double) -> Double {
        var x = u.truncatingRemainder(dividingBy: 1)
        if x < 0 { x += 1 }
        return x
    }

    static func canonicalJSONObject(for point: SpaceCleanupSelectionPoint) -> [String: Any] {
        [
            "u": point.u,
            "v": point.v,
            "yaw": point.yaw,
            "pitch": point.pitch,
            "direction": [
                "x": point.direction.x,
                "y": point.direction.y,
                "z": point.direction.z,
            ],
        ]
    }
}

#if DEBUG
actor SpaceCleanupMockClient: SpaceCleanupServing {
    nonisolated(unsafe) var createCalls = 0
    nonisolated(unsafe) var confirmCalls = 0
    nonisolated(unsafe) var fetchCalls = 0
    nonisolated(unsafe) var editWouldHaveBeenCalled = false
    /// Simulate DETECTING → AWAITING_CONFIRMATION across fetch polls.
    nonisolated(unsafe) var detectPollsBeforeReady = 1
    private var jobs: [String: SpaceCleanupJobDTO] = [:]
    private var detectCounters: [String: Int] = [:]

    func createJob(request: SpaceCleanupCreateRequest, idempotencyKey: String) async throws -> SpaceCleanupJobDTO {
        createCalls += 1
        guard request.aiConsentAccepted else { throw SpaceCleanupAPIError.consentRequired }
        let id = "cleanup-job-\(createCalls)"
        let status: String
        var detected: [SpaceCleanupDetectedObject]?
        var maskPreviewUrl: String?
        if request.mode == .selectedObjects {
            if detectPollsBeforeReady <= 0 {
                status = "AWAITING_CONFIRMATION"
                let pts = request.points ?? []
                detected = [
                    SpaceCleanupDetectedObject(
                        selectionIds: pts.map(\.id),
                        label: "sofa",
                        polygon: pts.map { SpaceCleanupUvPoint(u: $0.u, v: $0.v) }
                            + pts.map { SpaceCleanupUvPoint(u: Self.wrap($0.u + 0.02), v: $0.v + 0.02) },
                        confidence: 0.9,
                        needsConfirmation: true,
                        warnings: []
                    ),
                ]
                maskPreviewUrl = "https://example.com/mask-preview.png"
            } else {
                status = "DETECTING"
                detectCounters[id] = 0
                detected = nil
            }
        } else {
            status = "QUEUED"
        }
        let job = SpaceCleanupJobDTO(
            id: id,
            status: status,
            mode: request.mode,
            spaceId: request.spaceId,
            sourceRevisionId: request.sourceRevisionId,
            resultRevisionId: nil,
            progress: status == "DETECTING" ? 10 : 40,
            selectionPoints: request.points,
            detectedObjects: detected,
            failureCode: nil,
            failureMessageSafe: nil,
            outsideMaskDiff: nil,
            placementResultId: "pr-cleanup-\(createCalls)",
            maskPreviewUrl: maskPreviewUrl,
            createdAt: nil,
            updatedAt: nil
        )
        jobs[id] = job
        return job
    }

    func fetchJob(id: String) async throws -> SpaceCleanupJobDTO {
        fetchCalls += 1
        guard var job = jobs[id] else { throw SpaceCleanupAPIError.notFound }
        if job.status == "DETECTING" {
            let count = (detectCounters[id] ?? 0) + 1
            detectCounters[id] = count
            if count >= detectPollsBeforeReady {
                let pts = job.selectionPoints ?? []
                job.status = "AWAITING_CONFIRMATION"
                job.progress = 40
                job.detectedObjects = [
                    SpaceCleanupDetectedObject(
                        selectionIds: pts.map(\.id),
                        label: "sofa",
                        polygon: pts.map { SpaceCleanupUvPoint(u: $0.u, v: $0.v) }
                            + pts.map { SpaceCleanupUvPoint(u: Self.wrap($0.u + 0.02), v: $0.v + 0.02) },
                        confidence: 0.9,
                        needsConfirmation: true,
                        warnings: []
                    ),
                ]
                job.maskPreviewUrl = "https://example.com/mask-preview.png"
                jobs[id] = job
            }
        } else if job.status == "PROCESSING" {
            job.status = "COMPLETED"
            job.resultRevisionId = "rev-cleanup-\(id)"
            jobs[id] = job
        }
        return job
    }

    nonisolated(unsafe) var lastConfirmRemovalTarget: String?

    func confirmJob(id: String, removalTarget: String) async throws -> SpaceCleanupJobDTO {
        confirmCalls += 1
        lastConfirmRemovalTarget = removalTarget
        editWouldHaveBeenCalled = true
        guard var job = jobs[id] else { throw SpaceCleanupAPIError.notFound }
        guard job.isAwaitingConfirmation, !(job.detectedObjects ?? []).isEmpty else {
            throw SpaceCleanupAPIError.server(status: 409)
        }
        let trimmed = removalTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpaceCleanupAPIError.server(status: 400) }
        job.status = "PROCESSING"
        jobs[id] = job
        return job
    }

    func retryJob(id: String) async throws -> SpaceCleanupJobDTO {
        guard var job = jobs[id] else { throw SpaceCleanupAPIError.notFound }
        job.status = "QUEUED"
        job.failureCode = nil
        jobs[id] = job
        return job
    }

    private static func wrap(_ u: Double) -> Double {
        var x = u.truncatingRemainder(dividingBy: 1)
        if x < 0 { x += 1 }
        return x
    }
}
#endif
