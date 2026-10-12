import Foundation

/// Copy for the 매장 screens. Short sentences; no technology names.
enum StoreShelfCopy {
    static let sectionTitle = "매장"
    static let recordTitle = "매대 기록하기"
    static let recordLine = "매대를 비추면 제품과 위치를 함께 기록해요"
    static let findTitle = "제품 찾기"
    static let findLine = "제품을 비추면 기록된 진열 위치를 안내해요"

    static let noStoreTitle = "아직 기록한 매장이 없어요"
    static let noStoreLine = "먼저 매대를 기록해 주세요."
    static let noWorldMapLine = "이 매장은 아직 매대를 기록하지 않았어요. 먼저 매대를 기록해 주세요."
    static let recognitionUnavailable = "제품 인식은 아직 준비 중이에요. 지금은 기록한 위치를 다시 불러오는 시험만 할 수 있어요."
    static let testMarkerNotice = "시험용 표시예요. 실제 제품 위치가 아니에요."
    static let relocalizeHint = "저장할 때 비춘 매대 쪽으로 천천히 카메라를 움직여 주세요."
    static let saveNeedsMoreScan = "매대 주변을 조금 더 천천히 비춘 뒤 저장해 주세요."
}

/// A store the user created on this device.
struct StoreRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var createdAt: Date
}

/// A manually placed test marker. It stands in for a product position in the prototype and is never presented as a
/// recognised product. `transform` is the column-major 4x4 of its ARAnchor in the saved map's world frame.
struct StoreTestMarker: Codable, Equatable, Identifiable, Sendable {
    static let anchorNamePrefix = "gonggi.store.marker."

    var id: String
    var label: String
    var transform: [Float]
    var createdAt: Date

    var anchorName: String { Self.anchorNamePrefix + id }

    static func markerId(fromAnchorName name: String?) -> String? {
        guard let name, name.hasPrefix(anchorNamePrefix) else { return nil }
        let id = String(name.dropFirst(anchorNamePrefix.count))
        return id.isEmpty ? nil : id
    }
}

/// What was stored with a saved world map (the map itself is a separate file).
struct StoreWorldMapInfo: Codable, Equatable, Sendable {
    var savedAt: Date
    var byteCount: Int
    var mappingStatus: String
    var markerCount: Int
    var extent: [Float]
    var center: [Float]
    var deviceModel: String?
}

/// Outcome of one restore attempt: a diagnostic record, not shelf data.
struct StoreRestoreAttempt: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var startedAt: Date
    /// `restored`, `failed_timeout`, `cancelled`
    var outcome: String
    var secondsToRelocalize: Double?
    var markersExpected: Int
    var markersPresentAfterRestore: Int
    var trackingReasonsSeen: [String]
    /// What the tester saw against a known real-world spot: "within_2cm", "within_5cm", "within_10cm", "over_10cm", "not_checked".
    var observedOffset: String
    var note: String?
}
