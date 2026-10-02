import Foundation

/// The smallest record that can tell WHY the box and the object disagree: where each tap went, what the floor probe said,
/// where the estimate landed, and (once a second) where the camera, the box, the floor under the box and the AR anchor
/// are. With it a screen recording becomes explainable: a box offset that is constant in the world = placement geometry; a
/// box (or anchor) that moves relative to the floor = AR world drift; neither of the two = drag/size maths.
/// Written to Documents/ObjectPlacementTraces/ and shared from the sizing panel; also embedded in object.json when a
/// capture follows. Contains no photos and no account data.
struct ObjectPlacementTrace: Codable, Equatable {
    struct Event: Codable, Equatable {
        var tSec: Double
        var kind: String
        var values: [String: Double]
        var text: [String: String]
    }

    var schema = 2
    var appBuild: String
    var device: String
    /// Wall-clock time of the first event (epoch ms). Every event time `tSec` is ARFrame time (the camera's own clock) since
    /// that moment, so camera, anchor, guide and user actions share ONE time base; add `startedAtEpochMs` to match a recording.
    var startedAtEpochMs: Double = 0
    var events: [Event] = []
    /// Newest events are dropped once the cap is reached except `sample`s, which are thinned: the file stays small.
    static let maxEvents = 1500

    mutating func add(_ t: Double, _ kind: String, _ values: [String: Double] = [:], _ text: [String: String] = [:]) {
        if events.count >= Self.maxEvents {
            // keep the beginning (placement) and the most recent samples
            if kind == "sample" { events.removeAll(where: { $0.kind == "sample" }, limit: 1) }
            else if events.count >= Self.maxEvents + 100 { return }
        }
        events.append(Event(tSec: (t * 1000).rounded() / 1000, kind: kind, values: values, text: text))
    }

    static func currentAppBuild() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    /// Writes the trace as JSON under Documents/ObjectPlacementTraces and returns the file.
    @discardableResult
    func write(name: String? = nil) throws -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ObjectPlacementTraces", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        let url = dir.appendingPathComponent(name ?? "placement_\(f.string(from: Date())).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(self).write(to: url, options: [.atomic])
        return url
    }
}

private extension Array {
    /// Removes the first `limit` elements that satisfy the predicate.
    mutating func removeAll(where shouldRemove: (Element) -> Bool, limit: Int) {
        var removed = 0
        var i = 0
        while i < count, removed < limit {
            if shouldRemove(self[i]) { remove(at: i); removed += 1 } else { i += 1 }
        }
    }
}
