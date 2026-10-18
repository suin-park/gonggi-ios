import Foundation

/// 실험 화면들 사이에서 카메라 소유권을 하나씩 넘긴다.
/// 앞 검사가 세션을 완전히 멈추고 `release`하기 전에는 다음 검사가 시작되지 않는다.
/// 의도적인 동시 실행은 공존 검사 하나만 허용하며, 그 검사가 소유권을 한 번에 가진다.
@MainActor
final class ExperimentCameraGate {
    static let shared = ExperimentCameraGate()
    private(set) var owner: String?

    /// 최대 `timeout`초 동안 앞 소유자가 놓기를 기다린다. 못 얻으면 false.
    func acquire(_ name: String, timeout: TimeInterval = 4) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while owner != nil && owner != name && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard owner == nil || owner == name else { return false }
        owner = name
        return true
    }

    func release(_ name: String) {
        if owner == name { owner = nil }
    }
}
