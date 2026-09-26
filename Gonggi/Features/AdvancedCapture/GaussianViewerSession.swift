import Foundation
import UIKit

/// Pure state for one Gaussian viewer presentation (testable without WebKit).
///
/// Phases separate "download finished" from "space displayed": only `ready` (bridge
/// `render_ready`, sent after the package's first valid frame + splats + camera check) hides
/// the loading UI. Recovery is bounded; after `maxAutoRecoveries` the user retries manually.
enum GaussianViewerPhase: Equatable {
    case connecting
    case downloading(percent: Int?)
    case preparing
    case displaying
    case ready
    case recovering(GaussianViewerRecoveryReason)
    case failed(GaussianViewerFailure)

    var isTerminalFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum GaussianViewerRecoveryReason: String, Equatable {
    case webContentProcessTerminated = "process_terminated"
    case webGLContextLost = "webgl_context_lost"
    case renderStalledAfterResume = "render_stalled_after_resume"
    case navigationDidNotStart = "navigation_did_not_start"
}

enum GaussianViewerFailure: Equatable {
    case network
    case downloadStalled
    case prepareTimeout
    case viewNotReady(code: String)
    case recoveryExhausted(GaussianViewerRecoveryReason)
    case noResponse

    var title: String {
        switch self {
        case .network: return "공간 데이터를 받지 못했어요"
        case .downloadStalled: return "다운로드가 멈췄어요"
        case .prepareTimeout: return "공간 준비가 오래 걸리고 있어요"
        case .viewNotReady: return "공간을 표시하지 못했어요"
        case .recoveryExhausted: return "화면을 복구하지 못했어요"
        case .noResponse: return "뷰어가 응답하지 않아요"
        }
    }

    var detail: String {
        switch self {
        case .network: return "네트워크 연결을 확인한 뒤 다시 시도해 주세요."
        case .downloadStalled: return "네트워크가 불안정할 수 있어요. 다시 시도해 주세요."
        case .prepareTimeout: return "기기 메모리가 부족할 수 있어요. 다른 앱을 닫고 다시 시도해 주세요."
        case .viewNotReady: return "다시 시도하면 처음부터 불러와요."
        case .recoveryExhausted: return "기기 메모리가 부족했을 수 있어요. 다시 시도해 주세요."
        case .noResponse: return "다시 시도해 주세요."
        }
    }

    var code: String {
        switch self {
        case .network: return "NETWORK"
        case .downloadStalled: return "DOWNLOAD_STALLED"
        case .prepareTimeout: return "PREPARE_TIMEOUT"
        case .viewNotReady(let code): return "VIEW_NOT_READY_\(code)"
        case .recoveryExhausted(let r): return "RECOVERY_EXHAUSTED_\(r.rawValue)"
        case .noResponse: return "NO_RESPONSE"
        }
    }
}

/// One request to show a Gaussian space. Presenting with `fullScreenCover(item:)` hands the
/// space id to the cover content directly — with `isPresented:` + a separate optional id the first
/// presentation could render with a stale nil id (empty black cover until the next body update).
struct GaussianViewerPresentation: Identifiable, Equatable {
    let id = UUID()
    let spaceId: String
    let requestedAt = Date()
}

/// Decisions + bounded counters + telemetry for one presentation.
struct GaussianViewerSession {
    static let maxAutoRecoveries = 2
    /// No change in the downloaded percent (≈2 MB of a 207 MB PLY) for this long ⇒ stalled.
    static let downloadStallSeconds: TimeInterval = 60
    static let prepareTimeoutSeconds: TimeInterval = 90
    /// Page committed (HTML arrived) but the viewer never reported.
    static let noResponseSeconds: TimeInterval = 25
    /// Viewer script started but never reached a load stage.
    static let noStageSeconds: TimeInterval = 60

    let sessionId = UUID().uuidString
    let openedAt = Date()
    private(set) var phase: GaussianViewerPhase = .connecting
    private(set) var autoRecoveries = 0
    private(set) var manualRetries = 0
    private(set) var loads = 1
    private(set) var processTerminated = 0
    private(set) var contextLost = 0
    private(set) var contextRestored = 0
    private(set) var backgrounded = 0
    private(set) var jsErrors = 0
    private(set) var everDisplayed = false
    private(set) var lastProgressAt = Date()
    private(set) var phaseEnteredAt = Date()
    private(set) var lastBridgeMessageAt: Date?
    /// WebKit committed the viewer document (before this, WebKit's own request timeout applies).
    private(set) var navigationCommittedAt: Date?
    /// Set while the app is in the background: watchdog is paused and elapsed time is shifted.
    private(set) var pausedAt: Date?
    private(set) var backgroundMs = 0
    /// Last JS error code reported before display (kept for the failure record; not a failure itself).
    private(set) var lastSoftErrorCode: String?
    private(set) var lastPercent: Int?
    var bytesTotal: Int64?
    var profile: [String: Any] = [:]
    var nativeReadyMs: Int?
    /// Tap → viewer onAppear (presentation latency).
    var presentToAppearMs: Int?
    private(set) var bridgeFirstSeq: Int?
    private(set) var bridgeGaps = 0
    private(set) var events: [(t: Int, e: String, d: String?)] = []

    var elapsedMs: Int { Int(Date().timeIntervalSince(openedAt) * 1000) }

    mutating func log(_ e: String, _ d: String? = nil, at: Date? = nil) {
        guard events.count < 60 else { return }
        let t = at.map { max(0, Int($0.timeIntervalSince(openedAt) * 1000)) } ?? elapsedMs
        events.append((t, String(e.prefix(80)), d.map { String($0.prefix(160)) }))
    }

    /// First bridge sequence number seen on a page (> 1 ⇒ early messages were lost) and gaps.
    mutating func noteBridgeSequence(first: Int?, gap: (Int, Int)?) {
        if let first, bridgeFirstSeq == nil { bridgeFirstSeq = first }
        if let gap {
            bridgeGaps += 1
            log("bridge_gap", "\(gap.0)->\(gap.1)")
        }
    }

    private mutating func enter(_ next: GaussianViewerPhase) {
        guard next != phase else { return }
        // Downloading percent updates are not UI phase changes worth a timeline entry.
        let sameKind: Bool
        if case .downloading = phase, case .downloading = next { sameKind = true } else { sameKind = false }
        phase = next
        phaseEnteredAt = Date()
        if !sameKind { log("ui", next.logName) }
    }

    mutating func noteBridgeMessage() { lastBridgeMessageAt = Date() }

    mutating func noteNavigationCommitted(at now: Date = Date()) {
        if navigationCommittedAt == nil { navigationCommittedAt = now }
    }

    mutating func noteSoftError(_ code: String) {
        noteBridgeMessage()
        lastSoftErrorCode = String(code.prefix(60))
    }

    /// App went to background: stop judging timeouts (WebKit suspends the page).
    mutating func pause(at now: Date = Date()) {
        guard pausedAt == nil else { return }
        pausedAt = now
        backgrounded += 1
    }

    /// Back to foreground: background time never counts toward any timeout.
    mutating func resume(at now: Date = Date()) {
        guard let start = pausedAt else { return }
        pausedAt = nil
        let gap = max(0, now.timeIntervalSince(start))
        backgroundMs += Int(gap * 1000)
        phaseEnteredAt = phaseEnteredAt.addingTimeInterval(gap)
        lastProgressAt = lastProgressAt.addingTimeInterval(gap)
        navigationCommittedAt = navigationCommittedAt?.addingTimeInterval(gap)
        lastBridgeMessageAt = lastBridgeMessageAt?.addingTimeInterval(gap)
    }

    var isPaused: Bool { pausedAt != nil }

    /// Bridge stage → phase (never regresses from ready; failures stay until retry).
    mutating func applyStage(_ stage: String) {
        noteBridgeMessage()
        if phase == .ready || phase.isTerminalFailure { return }
        if case .recovering = phase, stage != "downloading", stage != "preparing", stage != "displaying" { return }
        switch stage {
        case "downloading": enter(.downloading(percent: lastPercent)); lastProgressAt = Date()
        case "preparing": enter(.preparing)
        case "displaying": enter(.displaying)
        default: break
        }
    }

    mutating func applyProgress(percent: Int) {
        noteBridgeMessage()
        if percent != lastPercent { lastProgressAt = Date() }
        lastPercent = percent
        if case .downloading = phase { enter(.downloading(percent: percent)) }
        else if phase == .connecting { enter(.downloading(percent: percent)) }
    }

    mutating func markReady() {
        noteBridgeMessage()
        if !everDisplayed { nativeReadyMs = elapsedMs }
        everDisplayed = true
        enter(.ready)
    }

    mutating func fail(_ f: GaussianViewerFailure) {
        log("failed", f.code)
        enter(.failed(f))
    }

    /// A recovery trigger: returns true when an automatic recovery should run now.
    mutating func requestRecovery(_ reason: GaussianViewerRecoveryReason) -> Bool {
        switch reason {
        case .webContentProcessTerminated: processTerminated += 1
        case .webGLContextLost: contextLost += 1
        default: break
        }
        log("recovery_requested", reason.rawValue)
        guard autoRecoveries < Self.maxAutoRecoveries else {
            fail(.recoveryExhausted(reason))
            return false
        }
        autoRecoveries += 1
        enter(.recovering(reason))
        return true
    }

    mutating func noteContextRestored() { contextRestored += 1 }
    mutating func noteJSError() { jsErrors += 1 }

    /// A new document load (auto recovery or manual retry).
    mutating func beginReload(manual: Bool) {
        loads += 1
        if manual {
            manualRetries += 1
            autoRecoveries = 0
        }
        lastPercent = nil
        lastProgressAt = Date()
        lastBridgeMessageAt = nil
        navigationCommittedAt = nil
        lastSoftErrorCode = nil
        if manual || !(phase.isRecovering) { enter(.connecting) }
    }

    /// Periodic watchdog — returns a failure when the current phase is stuck.
    /// Paused in background; a download that keeps advancing never times out.
    func watchdog(now: Date = Date()) -> GaussianViewerFailure? {
        if pausedAt != nil { return nil }
        switch phase {
        case .connecting:
            if let noResponse = connectingFailure(now: now) { return noResponse }
        case .downloading:
            if now.timeIntervalSince(lastProgressAt) > Self.downloadStallSeconds { return .downloadStalled }
        case .preparing, .displaying:
            if now.timeIntervalSince(phaseEnteredAt) > Self.prepareTimeoutSeconds { return .prepareTimeout }
        case .recovering(let reason):
            // Recovery reload whose page never answered.
            if connectingFailure(now: now) != nil { return .recoveryExhausted(reason) }
        default:
            break
        }
        return nil
    }

    private func connectingFailure(now: Date) -> GaussianViewerFailure? {
        guard let committed = navigationCommittedAt else { return nil }
        if let last = lastBridgeMessageAt {
            // Script alive but no load stage yet.
            return now.timeIntervalSince(last) > Self.noStageSeconds ? .noResponse : nil
        }
        return now.timeIntervalSince(committed) > Self.noResponseSeconds ? .noResponse : nil
    }

    var outcome: String {
        if case .failed = phase { return "failed" }
        if everDisplayed { return (processTerminated + contextLost) > 0 ? "recovered" : "displayed" }
        return "closed_before_display"
    }

    func telemetryPayload() -> [String: Any] {
        func num(_ k: String) -> Any { (profile[k] as? NSNumber) ?? NSNull() }
        var failureCode: Any = NSNull()
        if case .failed(let f) = phase {
            failureCode = String((lastSoftErrorCode.map { "\(f.code)|\($0)" } ?? f.code).prefix(80))
        }
        let info = Bundle.main.infoDictionary
        return [
            "sessionId": sessionId,
            "appBuild": (info?["CFBundleVersion"] as? String) ?? "",
            "appVersion": (info?["CFBundleShortVersionString"] as? String) ?? "",
            "device": Self.deviceModel(),
            "osVersion": UIDevice.current.systemVersion,
            "bridgeProtocol": (profile["protocol"] as? String) ?? NSNull(),
            "viewerVersion": (profile["viewerVersion"] as? String) ?? NSNull(),
            "outcome": outcome,
            "failureCode": failureCode,
            "plyName": (profile["plyName"] as? String) ?? NSNull(),
            "bytesTotal": (profile["bytesTotal"] as? NSNumber) ?? bytesTotal.map { NSNumber(value: $0) } ?? NSNull(),
            "splats": (profile["splats"] as? NSNumber) ?? NSNull(),
            "timings": [
                "downloadStartMs": num("downloadStartMs"),
                "downloadEndMs": num("downloadEndMs"),
                "parsedMs": num("parsedMs"),
                "gpuUploadStartMs": num("gpuUploadStartMs"),
                "gpuUploadEndMs": num("gpuUploadEndMs"),
                "firstFrameMs": num("firstFrameMs"),
                "readyMs": num("readyMs"),
                "nativeReadyMs": nativeReadyMs.map { NSNumber(value: $0) } ?? NSNull(),
                "presentToAppearMs": presentToAppearMs.map { NSNumber(value: $0) } ?? NSNull(),
                "hiddenMs": num("hiddenMs"),
                "nativeBackgroundMs": backgroundMs + (pausedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0),
                "contentFetchMs": num("contentFetchMs"),
            ],
            "content": [
                "transferSize": num("contentTransferSize"),
                "encodedSize": num("contentEncodedSize"),
            ],
            "canvas": [
                "width": num("canvasWidth"),
                "height": num("canvasHeight"),
                "devicePixelRatio": num("devicePixelRatio"),
                "renderer": (profile["renderer"] as? String) ?? NSNull(),
            ],
            "counters": [
                "loads": loads,
                "webglContextLost": contextLost,
                "webglContextRestored": contextRestored,
                "processTerminated": processTerminated,
                "autoRecoveries": autoRecoveries,
                "manualRetries": manualRetries,
                "backgrounded": backgrounded,
                "jsErrors": jsErrors,
                "bridgeGaps": bridgeGaps,
                "bridgeFirstSeq": bridgeFirstSeq.map { NSNumber(value: $0) } ?? NSNull(),
            ],
            "events": events.map { ev -> [String: Any] in
                var o: [String: Any] = ["t": ev.t, "e": ev.e]
                if let d = ev.d { o["d"] = d }
                return o
            },
        ]
    }

    static func deviceModel() -> String {
        var sys = utsname()
        uname(&sys)
        let mirror = Mirror(reflecting: sys.machine)
        return mirror.children.compactMap { $0.value as? Int8 }.filter { $0 != 0 }
            .map { String(UnicodeScalar(UInt8($0))) }.joined()
    }
}

extension GaussianViewerPhase {
    var logName: String {
        switch self {
        case .connecting: return "connecting"
        case .downloading: return "downloading"
        case .preparing: return "preparing"
        case .displaying: return "displaying"
        case .ready: return "ready"
        case .recovering(let r): return "recovering:\(r.rawValue)"
        case .failed(let f): return "failed:\(f.code)"
        }
    }

    var isRecovering: Bool {
        if case .recovering = self { return true }
        return false
    }
}

/// Fire-and-forget telemetry POST (owner-scoped on the server; no URLs or tokens in body).
enum GaussianViewerTelemetryUploader {
    static func send(spaceId: String, payload: [String: Any]) {
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty,
              JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload)
        else { return }
        let url = AppConfiguration.production.apiBaseURL
            .appendingPathComponent("api/gaussian-spaces/\(spaceId)/viewer-telemetry")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req).resume()
    }
}
