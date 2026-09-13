import Foundation

/// Shared eligibility + Astra plan preparation for 3D expansion.
/// Used by Space Detail「3D 공간으로 확장」and Record「기존 공간에서 시작」.
enum ThreeDExpansionSupport {
    static func sessionKey(for space: SpaceRecord) -> String {
        space.sessionId ?? space.id
    }

    /// LatLong / 360 source is ready enough to expand (does not require 3DGS).
    /// Matches PlaceAssetSpacePicker / library openability: ready + local or remote URL (no network probe).
    static func hasExpandable360Source(_ space: SpaceRecord) -> Bool {
        guard space.canOpenExistingVR else { return false }
        let hasLocal = SpaceLatLongStore.isValidLocalFile(at: space.localLatLongPath)
        let hasRemote = !(space.remoteImageURL ?? space.viewerURL?.absoluteString ?? "").isEmpty
        return hasLocal || hasRemote
    }

    static func is3DAlreadyComplete(
        sessionKey: String,
        store: AdvancedCaptureAnalysisStore = .shared
    ) -> Bool {
        store.record(sessionId: sessionKey)?.canOpenGaussianViewer == true
    }

    /// Spaces that can start / continue 3D expansion (360 ready, 3D not finished).
    static func isEligibleFor3DExpansion(
        _ space: SpaceRecord,
        store: AdvancedCaptureAnalysisStore = .shared
    ) -> Bool {
        guard hasExpandable360Source(space) else { return false }
        return !is3DAlreadyComplete(sessionKey: sessionKey(for: space), store: store)
    }

    static func expandableSpaces(
        from spaces: [SpaceRecord],
        store: AdvancedCaptureAnalysisStore = .shared
    ) -> [SpaceRecord] {
        spaces
            .filter { isEligibleFor3DExpansion($0, store: store) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    /// Reject empty / incomplete plans so callers fall back to Astra re-analysis.
    static func isUsableGuidePlan(_ plan: AdvancedCaptureGuidePlan) -> Bool {
        guard !plan.segments.isEmpty else { return false }
        return plan.segments.contains {
            !$0.instructionKo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Cached plan when analysis already ready and usable — otherwise nil (forces re-analyze path).
    static func cachedGuidePlan(
        sessionId: String,
        store: AdvancedCaptureAnalysisStore = .shared
    ) -> AdvancedCaptureGuidePlan? {
        guard let record = store.record(sessionId: sessionId),
              record.status == .ready,
              let plan = record.guidePlan,
              isUsableGuidePlan(plan)
        else { return nil }
        return AdvancedCaptureCopy.sanitize(plan)
    }

    /// Start analysis only when needed; reuse in-flight / ready+usable; force on failed or unusable ready plan.
    @MainActor
    @discardableResult
    static func startOrReuseAnalysis(
        sessionId: String,
        useMock: Bool,
        store: AdvancedCaptureAnalysisStore = .shared
    ) async -> Result<AdvancedCaptureAnalysisRecord, AdvancedCaptureError> {
        AdvancedCaptureAnalysisRuntime.shared.configure(useMock: useMock)
        let existing = store.record(sessionId: sessionId)
        let unusableReady = existing?.status == .ready
            && (existing?.guidePlan.map(isUsableGuidePlan) != true)
        let force = existing?.status == .failed || unusableReady
        return await AdvancedCaptureAnalysisRuntime.shared.startAnalysis(
            sessionId: sessionId,
            force: force
        )
    }

    /// Resolve a guide plan: usable cache → analysis (force if cache invalid) → poll until ready.
    /// Never mutates or deletes existing LatLong assets.
    @MainActor
    static func prepareGuidePlan(
        sessionId: String,
        useMock: Bool,
        timeoutIterations: Int = 120,
        sleepNanoseconds: UInt64 = 2_000_000_000
    ) async -> Result<AdvancedCaptureGuidePlan, AdvancedCaptureError> {
        if let cached = cachedGuidePlan(sessionId: sessionId) {
            return .success(cached)
        }

        let start = await startOrReuseAnalysis(sessionId: sessionId, useMock: useMock)
        if case .failure(let error) = start {
            return .failure(error)
        }

        if let ready = cachedGuidePlan(sessionId: sessionId) {
            return .success(ready)
        }

        for _ in 0..<timeoutIterations {
            if Task.isCancelled {
                return .failure(.unknown("cancelled"))
            }
            await AdvancedCaptureAnalysisRuntime.shared.syncActiveOnce()
            if let plan = cachedGuidePlan(sessionId: sessionId) {
                return .success(plan)
            }
            if let record = AdvancedCaptureAnalysisStore.shared.record(sessionId: sessionId),
               record.status == .failed
            {
                return .failure(.server(record.lastErrorMessage ?? record.lastErrorCode ?? "analyze_failed"))
            }
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
        }
        return .failure(.notReady)
    }
}
