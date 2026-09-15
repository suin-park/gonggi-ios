import Foundation
import SwiftUI

@MainActor
final class SpaceCleanupSession: ObservableObject {
    @Published var mode: SpaceCleanupMode?
    @Published var points: [SpaceCleanupSelectionPoint] = []
    @Published var job: SpaceCleanupJobDTO?
    @Published var isSubmitting = false
    @Published var errorMessage: String?
    @Published var consentAccepted = false
    @Published private(set) var isActive = false
    @Published private(set) var poleWarningActive = false

    private var client: any SpaceCleanupServing = SpaceCleanupAPIClient()
    private(set) var spaceId: String = ""
    private(set) var sourceRevisionId: String = ""
    var onAccepted: ((String?) -> Void)?

    func configure(client: any SpaceCleanupServing) {
        self.client = client
    }

    func begin(spaceId: String, sourceRevisionId: String) {
        self.spaceId = spaceId
        self.sourceRevisionId = sourceRevisionId
        mode = nil
        points = []
        job = nil
        errorMessage = nil
        consentAccepted = false
        isActive = false
        poleWarningActive = false
    }

    func activateSelectedMode(spaceId: String, sourceRevisionId: String, consentAccepted: Bool) {
        begin(spaceId: spaceId, sourceRevisionId: sourceRevisionId)
        self.consentAccepted = consentAccepted
        mode = .selectedObjects
        isActive = true
    }

    func deactivate() {
        isActive = false
        points = []
        job = nil
        errorMessage = nil
        poleWarningActive = false
    }

    func selectMode(_ mode: SpaceCleanupMode) {
        self.mode = mode
        points = []
        job = nil
        errorMessage = nil
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
        let point = SpaceCleanupSelectionPoint(
            id: "selection-\(points.count + 1)",
            u: Self.wrapU(u),
            v: min(1, max(0, v)),
            yaw: yaw,
            pitch: pitch,
            direction: direction,
            screenX: screen?.x,
            screenY: screen?.y
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
        if points.isEmpty { poleWarningActive = false }
    }

    func resetPoints() {
        points.removeAll()
        job = nil
        poleWarningActive = false
        errorMessage = nil
    }

    var canSubmitSelected: Bool { !points.isEmpty }
    var canConfirm: Bool {
        guard let job else { return false }
        return job.isAwaitingConfirmation
    }

    /// Detected polygons for overlay — only after DETECTING completes.
    var detectedPolygons: [[SpaceCleanupUvPoint]] {
        (job?.detectedObjects ?? []).map(\.polygon)
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
        // Mask confirmation happens after DETECTING — do not confirm edit yet.
        await create(mode: .selectedObjects, points: points)
    }

    func confirmMasks() async {
        guard canConfirm, let jobId = job?.id else {
            errorMessage = "마스크를 확인한 뒤에만 정리할 수 있어요."
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            job = try await client.confirmJob(id: jobId)
            if job?.isCompleted == true || job?.isInFlight == true {
                onAccepted?(job?.placementResultId)
            }
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

    static func wrapU(_ u: Double) -> Double {
        var x = u.truncatingRemainder(dividingBy: 1)
        if x < 0 { x += 1 }
        return x
    }

    /// Encode canonical point JSON without screen auxiliaries as required fields.
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
    var createCalls = 0
    var confirmCalls = 0
    var editWouldHaveBeenCalled = false
    private var jobs: [String: SpaceCleanupJobDTO] = [:]

    func createJob(request: SpaceCleanupCreateRequest, idempotencyKey: String) async throws -> SpaceCleanupJobDTO {
        createCalls += 1
        guard request.aiConsentAccepted else { throw SpaceCleanupAPIError.consentRequired }
        let id = "cleanup-job-\(createCalls)"
        let status: String
        var detected: [SpaceCleanupDetectedObject]?
        if request.mode == .selectedObjects {
            status = "AWAITING_CONFIRMATION"
            let pts = request.points ?? []
            detected = [
                SpaceCleanupDetectedObject(
                    selectionIds: pts.map(\.id),
                    label: "sofa",
                    polygon: pts.map { SpaceCleanupUvPoint(u: $0.u, v: $0.v) },
                    confidence: 0.9,
                    needsConfirmation: true,
                    warnings: []
                ),
            ]
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
            progress: 10,
            selectionPoints: request.points,
            detectedObjects: detected,
            failureCode: nil,
            failureMessageSafe: nil,
            outsideMaskDiff: nil,
            placementResultId: "pr-cleanup-\(createCalls)",
            createdAt: nil,
            updatedAt: nil
        )
        jobs[id] = job
        return job
    }

    func fetchJob(id: String) async throws -> SpaceCleanupJobDTO {
        guard let job = jobs[id] else { throw SpaceCleanupAPIError.notFound }
        return job
    }

    func confirmJob(id: String) async throws -> SpaceCleanupJobDTO {
        confirmCalls += 1
        editWouldHaveBeenCalled = true
        guard var job = jobs[id] else { throw SpaceCleanupAPIError.notFound }
        job.status = "PROCESSING"
        jobs[id] = job
        job.status = "COMPLETED"
        job.resultRevisionId = "rev-cleanup-\(id)"
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
}
#endif
