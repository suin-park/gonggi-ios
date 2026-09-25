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

/// Decisions + bounded counters + telemetry for one presentation.
struct GaussianViewerSession {
    static let maxAutoRecoveries = 2
    static let downloadStallSeconds: TimeInterval = 30
    static let prepareTimeoutSeconds: TimeInterval = 90
    static let noResponseSeconds: TimeInterval = 25

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
    private(set) var lastPercent: Int?
    var bytesTotal: Int64?
    var profile: [String: Any] = [:]
    var nativeReadyMs: Int?
    private(set) var events: [(t: Int, e: String, d: String?)] = []

    var elapsedMs: Int { Int(Date().timeIntervalSince(openedAt) * 1000) }

    mutating func log(_ e: String, _ d: String? = nil) {
        guard events.count < 60 else { return }
        events.append((elapsedMs, String(e.prefix(80)), d.map { String($0.prefix(160)) }))
    }

    private mutating func enter(_ next: GaussianViewerPhase) {
        guard next != phase else { return }
        phase = next
        phaseEnteredAt = Date()
    }

    mutating func noteBridgeMessage() { lastBridgeMessageAt = Date() }

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
    mutating func noteBackground() { backgrounded += 1 }
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
        if manual || !(phase.isRecovering) { enter(.connecting) }
    }

    /// Periodic watchdog — returns a failure when the current phase is stuck.
    func watchdog(now: Date = Date()) -> GaussianViewerFailure? {
        switch phase {
        case .connecting:
            if lastBridgeMessageAt == nil, now.timeIntervalSince(phaseEnteredAt) > Self.noResponseSeconds {
                return .noResponse
            }
        case .downloading:
            if now.timeIntervalSince(lastProgressAt) > Self.downloadStallSeconds { return .downloadStalled }
        case .preparing, .displaying:
            if now.timeIntervalSince(phaseEnteredAt) > Self.prepareTimeoutSeconds { return .prepareTimeout }
        case .recovering(let reason):
            // Recovery reload whose page never answered.
            if lastBridgeMessageAt == nil, now.timeIntervalSince(phaseEnteredAt) > Self.noResponseSeconds {
                return .recoveryExhausted(reason)
            }
        default:
            break
        }
        return nil
    }

    var outcome: String {
        if case .failed = phase { return "failed" }
        if everDisplayed { return (processTerminated + contextLost) > 0 ? "recovered" : "displayed" }
        return "closed_before_display"
    }

    func telemetryPayload() -> [String: Any] {
        func num(_ k: String) -> Any { (profile[k] as? NSNumber) ?? NSNull() }
        var failureCode: Any = NSNull()
        if case .failed(let f) = phase { failureCode = f.code }
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
