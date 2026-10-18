import Foundation

/// 기록하기 → 실험 메뉴의 노출 설정.
///
/// 이 빌드(TestFlight, Release 포함)에서는 켜져 있다. `#if DEBUG`에 묶지 않는다.
/// 정식 배포 빌드에서 끄려면 빌드 설정 `GONGGI_SENSOR_EXPERIMENTS`를 `NO`로 바꾸면 된다
/// (Info.plist `GonggiSensorExperimentsEnabled`로 들어간다). 원격 설정·서버·DB는 쓰지 않는다.
/// 값이 없거나 해석할 수 없으면 꺼진 것으로 본다.
enum SensorExperimentFeature {
    static let infoKey = "GonggiSensorExperimentsEnabled"
    static let envKey = "GONGGI_SENSOR_EXPERIMENTS"

    /// 순수 함수(테스트용). 환경변수가 있으면 그것이 우선한다.
    static func isEnabled(infoValue: Any?, env: String?) -> Bool {
        if let env, let parsed = parse(env) { return parsed }
        if let b = infoValue as? Bool { return b }
        if let n = infoValue as? NSNumber { return n.boolValue }
        if let s = infoValue as? String, let parsed = parse(s) { return parsed }
        return false
    }

    static var isEnabled: Bool {
        isEnabled(
            infoValue: Bundle.main.object(forInfoDictionaryKey: infoKey),
            env: ProcessInfo.processInfo.environment[envKey]
        )
    }

    private static func parse(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "yes", "true", "on": return true
        case "0", "no", "false", "off": return false
        default: return nil
        }
    }
}
