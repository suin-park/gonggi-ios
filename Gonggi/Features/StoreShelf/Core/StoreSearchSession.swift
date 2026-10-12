import Foundation

// State of one 제품 찾기 session: from "nothing recognised" to "this product is locked and guidance runs". Pure Swift.
//
// Why a state machine: recognition runs on every analysed camera frame. Without state the result flips between products
// while the camera moves, the guidance screen would be opened again and again for the same product, and the other
// products seen while walking to the destination would replace the target.

struct ShelfSearchSession: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case image
        case text
        case photo
        case name
        case pick
    }

    enum State: Equatable, Sendable {
        case searching
        /// Several products fit: the person chooses (never forced to the nearest).
        case candidates([ShelfMatchCandidate])
        /// Looked at long enough and nothing registered resembles it.
        case unregistered
        /// One product is the target. Recognition is paused until the person ends it.
        case locked(productId: String, source: Source)
    }

    enum Event: Equatable, Sendable {
        case locked(productId: String, source: Source)
        case candidates
        case unregistered
        case cleared
        case released
    }

    struct Config: Equatable, Sendable {
        var window = 6
        /// Votes the winner needs inside the window...
        var required = 4
        /// ...while the best OTHER decision has at most this many.
        var maxRunnerUp = 1
        /// Frames without any product before stale candidates / "unregistered" are cleared.
        var clearAfterEmptyFrames = 6
        /// After the person ends a guidance, the same product is not locked again for this long (seconds).
        var releaseCooldown: Double = 3
    }

    let config: Config
    private(set) var state: State = .searching
    private var recent: [ShelfMatchOutcome] = []
    private var emptyFrames = 0
    private var cooldownProduct: String?
    private var cooldownUntil: Double = -1
    private(set) var lockCount = 0

    init(config: Config = Config()) {
        self.config = config
    }

    var isLocked: Bool {
        if case .locked = state { return true }
        return false
    }

    var lockedProductId: String? {
        if case .locked(let id, _) = state { return id }
        return nil
    }

    /// Recognition work is skipped while a product is locked.
    var recognitionPaused: Bool { isLocked }

    /// One analysed frame in which a product region was found.
    mutating func ingest(_ outcome: ShelfMatchOutcome, time: Double) -> Event? {
        guard !isLocked else { return nil }
        emptyFrames = 0
        if case .noGallery = outcome { return nil }
        if case .matched(let c) = outcome, c.productId == cooldownProduct, time < cooldownUntil { return nil }
        recent.append(outcome)
        if recent.count > config.window { recent.removeFirst(recent.count - config.window) }

        var counts: [String: Int] = [:]
        for o in recent { counts[o.key, default: 0] += 1 }
        guard let (winnerKey, winnerVotes) = counts.max(by: { $0.value < $1.value }), winnerVotes >= config.required else { return nil }
        let runnerUp = counts.filter { $0.key != winnerKey }.values.max() ?? 0
        guard runnerUp <= config.maxRunnerUp, let winner = recent.last(where: { $0.key == winnerKey }) else { return nil }

        switch winner {
        case .matched(let c):
            state = .locked(productId: c.productId, source: .image)
            lockCount += 1
            recent = []
            return .locked(productId: c.productId, source: .image)
        case .uncertain(let list):
            if state != .candidates(list) {
                state = .candidates(list)
                return .candidates
            }
            return nil
        case .unregistered:
            if state != .unregistered {
                state = .unregistered
                return .unregistered
            }
            return nil
        case .noGallery:
            return nil
        }
    }

    /// One analysed frame without any product region.
    mutating func ingestEmpty() -> Event? {
        guard !isLocked else { return nil }
        emptyFrames += 1
        guard emptyFrames >= config.clearAfterEmptyFrames else { return nil }
        recent = []
        if state != .searching {
            state = .searching
            return .cleared
        }
        return nil
    }

    /// The person (or a text / name / photo search) names the target.
    mutating func lock(productId: String, source: Source) -> Event {
        state = .locked(productId: productId, source: source)
        lockCount += 1
        recent = []
        emptyFrames = 0
        return .locked(productId: productId, source: source)
    }

    /// A one-shot result (a photo): shown immediately, no voting over frames.
    mutating func present(_ outcome: ShelfMatchOutcome, source: Source) -> Event? {
        switch outcome {
        case .matched(let c):
            return lock(productId: c.productId, source: source)
        case .uncertain(let list):
            state = .candidates(list)
            return .candidates
        case .unregistered:
            state = .unregistered
            return .unregistered
        case .noGallery:
            return nil
        }
    }

    /// Text read from the product settles an uncertain image result: only among the listed candidates.
    mutating func settleWithText(productId: String) -> Event? {
        guard case .candidates(let list) = state, list.contains(where: { $0.productId == productId }) else { return nil }
        return lock(productId: productId, source: .text)
    }

    /// "다른 제품 찾기" / end of guidance.
    mutating func release(now: Double) -> Event {
        if let id = lockedProductId {
            cooldownProduct = id
            cooldownUntil = now + config.releaseCooldown
        }
        state = .searching
        recent = []
        emptyFrames = 0
        return .released
    }
}
