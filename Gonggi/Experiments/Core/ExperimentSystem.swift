import Foundation
import CoreMedia
import Darwin

/// 센서 실험용 시스템 값 읽기 (메모리, 열 상태, 시계, 기기 정보).
enum ExpSys {
    /// AVFoundation PTS가 쓰는 host time clock (초).
    static func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    /// `ARFrame.timestamp`가 쓰는 시계(systemUptime, 초).
    static func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

    /// host clock - systemUptime. 두 시계가 같은 기준이면 거의 0이고 시간이 지나도 변하지 않는다. 가정이 아니라 측정한다.
    static func clockDelta() -> Double { hostNow() - uptime() }

    static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }

    static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static var thermal: String { thermalName(ProcessInfo.processInfo.thermalState) }

    /// serious 이상이면 검사를 끝낸다.
    static var thermalIsSevere: Bool {
        let s = ProcessInfo.processInfo.thermalState
        return s == .serious || s == .critical
    }

    static var machine: String {
        var u = utsname()
        uname(&u)
        return withUnsafePointer(to: &u.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    static func fourCC(_ v: FourCharCode) -> String {
        let bytes = [UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return String(bytes: bytes, encoding: .ascii) ?? String(v) }
        return String(v)
    }

    static var appVersionLine: String { GonggiBuildInfo.versionLine }
}

/// Optional -> JSON 안전 값.
func expNN(_ x: Any?) -> Any { x ?? NSNull() }

/// JSON으로 쓸 수 없는 값(NaN, Inf)을 null로 바꾼다.
func expJSONSafe(_ v: Any) -> Any {
    switch v {
    case let d as Double: return d.isFinite ? d : NSNull()
    case let f as Float: return f.isFinite ? Double(f) : NSNull()
    case let a as [Any]: return a.map(expJSONSafe)
    case let m as [String: Any]: return m.mapValues(expJSONSafe)
    default: return v
    }
}

/// 여러 스레드에서 쌓는 이벤트 목록 (중단, 오류).
final class ExpEvents: @unchecked Sendable {
    struct Item {
        let hostTime: Double
        let source: String
        let kind: String
        let detail: String
    }

    private let lock = NSLock()
    private var items: [Item] = []

    func add(source: String, kind: String, detail: String = "") {
        lock.lock()
        items.append(Item(hostTime: ExpSys.hostNow(), source: source, kind: kind, detail: detail))
        if items.count > 500 { items.removeFirst(items.count - 500) }
        lock.unlock()
    }

    var all: [Item] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    func count(source: String? = nil, kinds: Set<String>? = nil, from: Double = -.infinity, to: Double = .infinity) -> Int {
        all.filter {
            (source == nil || $0.source == source) && (kinds == nil || kinds!.contains($0.kind)) && $0.hostTime >= from && $0.hostTime <= to
        }.count
    }
}
