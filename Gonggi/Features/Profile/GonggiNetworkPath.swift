import Network
import Foundation

/// Lightweight path check for cellular-upload gating.
enum GonggiNetworkPath {
    /// true when the default path is constrained / expensive (typically cellular).
    static func isExpensiveOrConstrained() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "gonggi.network.path")
            var resumed = false
            let finish: (Bool) -> Void = { value in
                queue.async {
                    guard !resumed else { return }
                    resumed = true
                    monitor.cancel()
                    continuation.resume(returning: value)
                }
            }
            monitor.pathUpdateHandler = { path in
                finish(path.isExpensive || path.isConstrained)
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1.5) {
                finish(false)
            }
        }
    }
}
