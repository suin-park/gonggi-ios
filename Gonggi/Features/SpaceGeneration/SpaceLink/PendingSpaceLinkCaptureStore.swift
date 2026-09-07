import Foundation

/// Local pending context for Space Link → capture → finalize (never persisted as linked until success).
@MainActor
final class PendingSpaceLinkCaptureStore: ObservableObject {
    static let shared = PendingSpaceLinkCaptureStore()

    @Published private(set) var pending: PendingSpaceLinkCapture?

    private let defaultsKey = "gonggi.pendingSpaceLinkCapture.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(PendingSpaceLinkCapture.self, from: data) {
            pending = decoded
        }
    }

    func set(_ value: PendingSpaceLinkCapture) {
        pending = value
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    func clear() {
        pending = nil
        defaults.removeObject(forKey: defaultsKey)
    }

    func clearIfMatching(draftHotspotId: String) {
        guard pending?.draftHotspotId == draftHotspotId else { return }
        clear()
    }

    func clearIfMatching(targetSessionId: String) {
        guard pending?.targetSessionId == targetSessionId else { return }
        clear()
    }
}
