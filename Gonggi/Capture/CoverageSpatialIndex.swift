import Foundation
import simd

/// Thread-safe snapshot of `CoverageModelV1` cell states for mesh wireframe lookup on the AR delegate queue.
final class CoverageSpatialIndex {
    private var cellStates: [String: CoverageState] = [:]
    private let lock = NSLock()

    func replace(cells: [String: CoverageCell]) {
        lock.lock()
        cellStates = Dictionary(uniqueKeysWithValues: cells.map { ($0.key, $0.value.state) })
        lock.unlock()
    }

    func reset() {
        lock.lock()
        cellStates = [:]
        lock.unlock()
    }

    func state(at worldPosition: simd_float3) -> CoverageState {
        let cellId = CaptureMath.gridCellId(position: worldPosition)
        lock.lock()
        let state = cellStates[cellId] ?? .unseen
        lock.unlock()
        return state
    }
}

/// Visual classification for LiDAR mesh wireframe — maps coverage state to wireframe bucket.
enum CoverageMeshWireStyle: Equatable {
    case needsCapture
    case captured

    static func bucket(for state: CoverageState) -> CoverageMeshWireStyle {
        state == .good ? .captured : .needsCapture
    }
}
