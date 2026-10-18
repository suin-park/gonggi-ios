import Foundation

/// 후면 깊이 검사의 단계. 앞 단계의 성공을 뒤 단계의 증거로 쓰지 않는다.
enum ExpDepthStage: String, CaseIterable {
    case deviceFound        // A. 듀얼 와이드 장치 발견
    case photoDepth         // B. 사진용 깊이 지원
    case streamFormats      // 영상·깊이 호환 포맷 존재
    case outputConnected    // 깊이 출력 연결 성공
    case callbacks          // C. 실제 깊이 콜백 수신

    var title: String {
        switch self {
        case .deviceFound: return "듀얼 와이드 장치 발견"
        case .photoDepth: return "사진용 깊이 지원"
        case .streamFormats: return "영상·깊이 호환 포맷 존재"
        case .outputConnected: return "깊이 출력 연결"
        case .callbacks: return "실제 깊이 콜백 수신"
        }
    }
}

enum ExpStageState: String {
    case yes, no, unknown, notRun

    var label: String {
        switch self {
        case .yes: return "예"
        case .no: return "아니오"
        case .unknown: return "확인 못함"
        case .notRun: return "아직 안 함"
        }
    }
}

/// 미지원 / 설정 실패 / 중단 / 수신 없음을 구분한다.
enum ExpOutcome: Equatable {
    case ok
    case permissionDenied
    case unsupported(String)
    case setupFailed(String)
    case interrupted(String)
    case noData

    var label: String {
        switch self {
        case .ok: return "깊이 수신 확인"
        case .permissionDenied: return "카메라 권한 없음"
        case .unsupported(let r): return "미지원: \(r)"
        case .setupFailed(let r): return "설정 실패: \(r)"
        case .interrupted(let r): return "중단됨: \(r)"
        case .noData: return "수신 없음: 연결은 됐지만 깊이 콜백이 오지 않음"
        }
    }

    var isOK: Bool { self == .ok }
}

/// 실행이 끝난 이유.
enum ExpEndReason: String {
    case completed          // 정해진 시간 완료
    case userStopped
    case thermal
    case backgrounded
    case failed
    case notStarted

    var label: String {
        switch self {
        case .completed: return "정해진 시간 완료"
        case .userStopped: return "사용자가 중지"
        case .thermal: return "기기 온도(serious 이상)로 자동 종료"
        case .backgrounded: return "앱이 백그라운드로 이동해 종료"
        case .failed: return "실패로 종료"
        case .notStarted: return "시작하지 못함"
        }
    }
}

enum ExpDepthClassifier {
    /// 깊이 검사 결과를 한 가지 결과로 나눈다. 콜백이 한 번이라도 왔다면 "수신 확인"이다 (정확도는 별개).
    static func outcome(permissionDenied: Bool,
                        deviceFound: Bool,
                        formatsPresent: Bool,
                        setupError: String?,
                        outputConnected: Bool,
                        interruptions: Int,
                        depthCallbacks: Int) -> ExpOutcome {
        if permissionDenied { return .permissionDenied }
        if !deviceFound { return .unsupported("듀얼 와이드 카메라가 발견되지 않음") }
        if !formatsPresent { return .unsupported("영상과 함께 쓸 수 있는 깊이 포맷이 없음") }
        if let e = setupError { return .setupFailed(e) }
        if !outputConnected { return .setupFailed("깊이 출력 연결이 만들어지지 않음") }
        if depthCallbacks > 0 { return .ok }
        if interruptions > 0 { return .interrupted("세션 중단 \(interruptions)회, 깊이 콜백 없음") }
        return .noData
    }
}

/// RGB-깊이, 포즈-영상 동기화 판정. 공존 성공과는 별도다.
enum ExpSyncVerdict: Equatable {
    case pass(p95Ms: Double, limitMs: Double)
    case fail(p95Ms: Double, limitMs: Double)
    case unknown(String)

    var label: String {
        switch self {
        case .pass(let p, let l): return String(format: "일치(p95 %.1f ms ≤ %.1f ms)", p, l)
        case .fail(let p, let l): return String(format: "불일치(p95 %.1f ms > %.1f ms)", p, l)
        case .unknown(let r): return "판정 불가: \(r)"
        }
    }
}

enum ExpSync {
    /// offsets: 한 스트림의 각 프레임에서 다른 스트림 최근접 프레임까지의 시간차(초).
    /// 한계는 영상 프레임 주기의 절반(잠정 기준). 표본이 적거나 두 시계가 같은 기준인지 확인되지 않으면 판정하지 않는다.
    static func evaluate(offsets: [Double], videoHz: Double?, clockStable: Bool, minSamples: Int = 30) -> ExpSyncVerdict {
        guard clockStable else { return .unknown("두 시계(host clock, systemUptime)의 차이가 안정적이지 않음") }
        guard let hz = videoHz, hz > 1 else { return .unknown("영상 빈도를 알 수 없음") }
        guard offsets.count >= minSamples else { return .unknown("표본 \(offsets.count)개 (<\(minSamples))") }
        let limit = 0.5 / hz
        let p95 = ExpMath.percentile(offsets.map { abs($0) }, 0.95) ?? .infinity
        return p95 <= limit ? .pass(p95Ms: p95 * 1000, limitMs: limit * 1000) : .fail(p95Ms: p95 * 1000, limitMs: limit * 1000)
    }

    /// host clock와 systemUptime의 차이가 검사 중 얼마나 움직였는지 (ms 이내면 같은 기준으로 본다).
    static func isClockStable(deltas: [Double], toleranceS: Double = 0.002) -> Bool {
        guard let lo = deltas.min(), let hi = deltas.max() else { return false }
        return hi - lo <= toleranceS
    }
}

/// 공존 검사 구간(phase) 하나의 측정값.
struct ExpPhaseStats: Equatable {
    var name: String
    var seconds: Double
    var arHz: Double?
    var videoHz: Double?
    var depthHz: Double?
    var arEvents: Int
    var avEvents: Int
}

enum ExpCoexistVerdict: Equatable {
    case coexists
    case failed([String])
    case unknown(String)

    var label: String {
        switch self {
        case .coexists: return "공존 확인(두 스트림이 함께 계속 수신됨)"
        case .failed(let r): return "공존 실패: " + r.joined(separator: "; ")
        case .unknown(let r): return "판정 불가: \(r)"
        }
    }

    var isCoexists: Bool { self == .coexists }
}

enum ExpCoexist {
    /// 기준값(잠정): 함께 도는 구간에서 각 스트림이 단독 구간의 70% 이상, 절대 5Hz 이상, 중단/오류 이벤트 0.
    static let keepRatio = 0.7
    static let minHz = 5.0

    /// aloneAR/aloneAV: 각각 단독으로 돌 때의 구간(없으면 저하 비교는 하지 않고 절대 기준만 본다). both: 두 스트림이 함께 도는 구간.
    static func evaluate(aloneAR: ExpPhaseStats?, aloneAV: ExpPhaseStats?, both: ExpPhaseStats?) -> ExpCoexistVerdict {
        guard let both else { return .unknown("함께 도는 구간이 만들어지지 않음") }
        var reasons: [String] = []
        if both.arEvents > 0 { reasons.append("ARKit 중단/오류 \(both.arEvents)건") }
        if both.avEvents > 0 { reasons.append("AV 세션 중단/오류 \(both.avEvents)건") }
        func check(_ name: String, _ hz: Double?, _ base: Double?) {
            guard let hz, hz >= minHz else { reasons.append("\(name) 수신 없음 또는 \(minHz)Hz 미만"); return }
            if let base, base > 0, hz < base * keepRatio {
                reasons.append(String(format: "%@ 빈도가 단독 대비 %.0f%% (<%.0f%%)", name, hz / base * 100, keepRatio * 100))
            }
        }
        check("ARKit", both.arHz, aloneAR?.arHz)
        check("영상", both.videoHz, aloneAV?.videoHz)
        check("깊이", both.depthHz, aloneAV?.depthHz)
        return reasons.isEmpty ? .coexists : .failed(reasons)
    }
}
