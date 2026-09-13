import Foundation
import OSLog

/// Shared eligibility + Astra plan preparation for 3D expansion.
/// Used by Space Detail「3D 공간으로 확장」and Record「기존 공간에서 시작」.
/// Astra is optional — callers may fall back to `AdvancedCaptureGuidePlan.defaultP1Plan`.
enum ThreeDExpansionSupport {
    enum PrepareConfig {
        /// Soft UX threshold (show recovery affordances).
        static let softTimeoutSec: TimeInterval = 30
        /// Hard stop for foreground prepare polling (no 5-minute waits).
        static let hardTimeoutSec: TimeInterval = 60
        /// In-flight older than this → stale (force re-analyze once).
        static let staleInFlightSec: TimeInterval = 60
        static let pollIntervalSec: TimeInterval = 1.5
    }

    private static let log = Logger(subsystem: "com.whik.gonggi", category: "3DExpansion")

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

    @MainActor
    static func is3DAlreadyComplete(
        sessionKey: String,
        store: AdvancedCaptureAnalysisStore = .shared
    ) -> Bool {
        store.record(sessionId: sessionKey)?.canOpenGaussianViewer == true
    }

    /// Spaces that can start / continue 3D expansion (360 ready, 3D not finished).
    @MainActor
    static func isEligibleFor3DExpansion(
        _ space: SpaceRecord,
        store: AdvancedCaptureAnalysisStore = .shared
    ) -> Bool {
        guard hasExpandable360Source(space) else { return false }
        return !is3DAlreadyComplete(sessionKey: sessionKey(for: space), store: store)
    }

    @MainActor
    static func expandableSpaces(
        from spaces: [SpaceRecord],
        store: AdvancedCaptureAnalysisStore = .shared
    ) -> [SpaceRecord] {
        spaces
            .filter { isEligibleFor3DExpansion($0, store: store) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    /// Reject empty / incomplete plans so callers fall back to Astra re-analysis or default plan.
    static func isUsableGuidePlan(_ plan: AdvancedCaptureGuidePlan) -> Bool {
        guard !plan.segments.isEmpty else { return false }
        return plan.segments.contains {
            !$0.instructionKo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Cached plan when analysis already ready and usable — otherwise nil.
    @MainActor
    static func cachedGuidePlan(
        sessionId: String,
        store: AdvancedCaptureAnalysisStore = .shared
    ) -> AdvancedCaptureGuidePlan? {
        guard let record = store.record(sessionId: sessionId) else {
            log.info("cachedGuidePlan[\(sessionId, privacy: .public)]: no record")
            return nil
        }
        guard record.status == .ready else {
            log.info("cachedGuidePlan[\(sessionId, privacy: .public)]: status=\(record.status.rawValue, privacy: .public)")
            return nil
        }
        guard let plan = record.guidePlan, isUsableGuidePlan(plan) else {
            log.info("cachedGuidePlan[\(sessionId, privacy: .public)]: ready but plan missing/unusable")
            return nil
        }
        log.info("cachedGuidePlan[\(sessionId, privacy: .public)]: hit segments=\(plan.segments.count)")
        return AdvancedCaptureCopy.sanitize(plan)
    }

    @MainActor
    private static func isStaleInFlight(
        _ record: AdvancedCaptureAnalysisRecord,
        now: Date = Date()
    ) -> Bool {
        guard record.status.isInFlight else { return false }
        let age = now.timeIntervalSince(record.updatedAt)
        let sinceCreate = now.timeIntervalSince(record.createdAt)
        return age >= PrepareConfig.staleInFlightSec || sinceCreate >= PrepareConfig.staleInFlightSec
    }

    /// Start analysis only when needed.
    /// Automatic force for failed/unusable/stale is applied by `prepareGuidePlan` (once per session).
    /// Pass `force: true` only for explicit retry / one-shot recovery.
    @MainActor
    @discardableResult
    static func startOrReuseAnalysis(
        sessionId: String,
        useMock: Bool,
        force: Bool = false,
        store: AdvancedCaptureAnalysisStore = .shared
    ) async -> Result<AdvancedCaptureAnalysisRecord, AdvancedCaptureError> {
        AdvancedCaptureAnalysisRuntime.shared.configure(useMock: useMock)
        let existing = store.record(sessionId: sessionId)
        // Failed jobs always need an explicit re-kick; stale/unusable ready is handled once in prepareGuidePlan.
        let shouldForce = force || existing?.status == .failed
        log.info(
            "startOrReuseAnalysis[\(sessionId, privacy: .public)]: existing=\(existing?.status.rawValue ?? "nil", privacy: .public) force=\(shouldForce)"
        )
        return await AdvancedCaptureAnalysisRuntime.shared.startAnalysis(
            sessionId: sessionId,
            force: shouldForce
        )
    }

    /// Resolve a guide plan with hard timeout. Never mutates LatLong.
    /// On timeout / invalid ready returns failure so UI can retry or use `defaultP1Plan`.
    /// Automatic force re-analysis is capped at **one** per prepare call.
    @MainActor
    static func prepareGuidePlan(
        sessionId: String,
        useMock: Bool,
        allowOneStaleForce: Bool = true,
        hardTimeoutSec: TimeInterval = PrepareConfig.hardTimeoutSec,
        pollIntervalSec: TimeInterval = PrepareConfig.pollIntervalSec
    ) async -> Result<AdvancedCaptureGuidePlan, AdvancedCaptureError> {
        let started = Date()
        log.info("prepareGuidePlan[\(sessionId, privacy: .public)]: begin")

        if let cached = cachedGuidePlan(sessionId: sessionId) {
            log.info("prepareGuidePlan[\(sessionId, privacy: .public)]: using cache")
            return .success(cached)
        }

        var didForceOnce = false

        func forceOnceIfAllowed(reason: String) async -> Result<AdvancedCaptureGuidePlan, AdvancedCaptureError>? {
            guard allowOneStaleForce, !didForceOnce else {
                log.info("prepareGuidePlan[\(sessionId, privacy: .public)]: skip force (\(reason)) alreadyUsed=\(didForceOnce)")
                return nil
            }
            didForceOnce = true
            log.info("prepareGuidePlan[\(sessionId, privacy: .public)]: force once — \(reason, privacy: .public)")
            let forced = await startOrReuseAnalysis(sessionId: sessionId, useMock: useMock, force: true)
            if case .failure(let error) = forced {
                return .failure(error)
            }
            if let ready = cachedGuidePlan(sessionId: sessionId) {
                return .success(ready)
            }
            return nil
        }

        // Decide whether first start should force (stale / unusable ready / failed).
        let existing = AdvancedCaptureAnalysisStore.shared.record(sessionId: sessionId)
        let unusableReady = existing?.status == .ready
            && (existing?.guidePlan.map(isUsableGuidePlan) != true)
        let needsInitialForce = existing?.status == .failed
            || unusableReady
            || (existing.map { isStaleInFlight($0) } ?? false)

        if needsInitialForce {
            if let outcome = await forceOnceIfAllowed(reason: "initial stale/unusable/failed") {
                return outcome
            }
            // Fall through to poll loop — do not treat ready-without-plan as terminal yet.
        }

        let start = await startOrReuseAnalysis(sessionId: sessionId, useMock: useMock, force: false)
        switch start {
        case .failure(let error):
            log.error("prepareGuidePlan[\(sessionId, privacy: .public)]: start failed \(error.userMessage, privacy: .public)")
            return .failure(error)
        case .success(let record):
            log.info("prepareGuidePlan[\(sessionId, privacy: .public)]: start ok status=\(record.status.rawValue, privacy: .public) jobId=\(record.jobId, privacy: .public)")
        }

        if let ready = cachedGuidePlan(sessionId: sessionId) {
            return .success(ready)
        }

        // ready-without-plan: force at most once, then keep polling until hard timeout.
        if let record = AdvancedCaptureAnalysisStore.shared.record(sessionId: sessionId),
           record.status == .ready,
           cachedGuidePlan(sessionId: sessionId) == nil
        {
            if let outcome = await forceOnceIfAllowed(reason: "ready without usable plan") {
                return outcome
            }
        }

        while Date().timeIntervalSince(started) < hardTimeoutSec {
            if Task.isCancelled {
                log.info("prepareGuidePlan[\(sessionId, privacy: .public)]: cancelled")
                return .failure(.unknown("cancelled"))
            }

            await AdvancedCaptureAnalysisRuntime.shared.syncActiveOnce()

            if let plan = cachedGuidePlan(sessionId: sessionId) {
                log.info("prepareGuidePlan[\(sessionId, privacy: .public)]: ready after poll \(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public)s")
                return .success(plan)
            }

            if let record = AdvancedCaptureAnalysisStore.shared.record(sessionId: sessionId) {
                log.info(
                    "prepareGuidePlan[\(sessionId, privacy: .public)]: poll status=\(record.status.rawValue, privacy: .public) hasPlan=\(record.guidePlan != nil) elapsed=\(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public)s"
                )

                if record.status == .failed {
                    return .failure(.server(record.lastErrorMessage ?? record.lastErrorCode ?? "analyze_failed"))
                }

                if record.status == .ready, cachedGuidePlan(sessionId: sessionId) == nil {
                    // One force attempt, then continue polling (plan may arrive on a later fetch).
                    if let outcome = await forceOnceIfAllowed(reason: "ready+nil mid-poll") {
                        return outcome
                    }
                }

                if isStaleInFlight(record) {
                    if let outcome = await forceOnceIfAllowed(reason: "stale in-flight") {
                        return outcome
                    }
                    // Force budget exhausted while still stale — stop looping; UI → recovery/default.
                    log.error("prepareGuidePlan[\(sessionId, privacy: .public)]: stale after single force")
                    return .failure(.timedOut)
                }
            }

            try? await Task.sleep(nanoseconds: UInt64(pollIntervalSec * 1_000_000_000))
        }

        // Hard timeout: distinguish ready-without-plan vs still in-flight.
        if let record = AdvancedCaptureAnalysisStore.shared.record(sessionId: sessionId),
           record.status == .ready,
           cachedGuidePlan(sessionId: sessionId) == nil
        {
            log.error("prepareGuidePlan[\(sessionId, privacy: .public)]: hard timeout with ready but no usable plan")
            return .failure(.notReady)
        }
        log.error("prepareGuidePlan[\(sessionId, privacy: .public)]: hard timeout \(hardTimeoutSec)s")
        return .failure(.timedOut)
    }
}
