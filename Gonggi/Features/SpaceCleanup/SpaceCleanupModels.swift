import Foundation

enum SpaceCleanupMode: String, Codable, Sendable, Equatable, CaseIterable {
    case allFurniture = "ALL_FURNITURE"
    case selectedObjects = "SELECTED_OBJECTS"

    var title: String {
        switch self {
        case .allFurniture: return "전체 가구 비우기"
        case .selectedObjects: return "가구 선택해서 비우기"
        }
    }

    var subtitle: String {
        switch self {
        case .allFurniture:
            return "공간의 구조는 유지하고 이동 가능한 가구와 생활용품을 비웁니다."
        case .selectedObjects:
            return "360° 공간에서 없애고 싶은 가구를 하나 이상 선택합니다."
        }
    }
}

struct SpaceCleanupDirection: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var z: Double
}

struct SpaceCleanupSelectionPoint: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var u: Double
    var v: Double
    var yaw: Double
    var pitch: Double
    var direction: SpaceCleanupDirection

    /// Screen/pixel are auxiliary only — never treated as canonical.
    var screenX: Double? = nil
    var screenY: Double? = nil
}

struct SpaceCleanupUvPoint: Codable, Sendable, Equatable {
    var u: Double
    var v: Double
}

struct SpaceCleanupDetectedObject: Codable, Sendable, Equatable, Identifiable {
    var selectionIds: [String]
    var label: String
    var polygon: [SpaceCleanupUvPoint]
    var confidence: Double?
    var needsConfirmation: Bool?
    var warnings: [String]?

    var id: String { selectionIds.joined(separator: ",") + ":" + label }
}

struct SpaceCleanupJobDTO: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var status: String
    var mode: SpaceCleanupMode
    var spaceId: String
    var sourceRevisionId: String
    var resultRevisionId: String?
    var progress: Int?
    var selectionPoints: [SpaceCleanupSelectionPoint]?
    var detectedObjects: [SpaceCleanupDetectedObject]?
    var failureCode: String?
    var failureMessageSafe: String?
    var outsideMaskDiff: Double?
    var placementResultId: String?
    var createdAt: String?
    var updatedAt: String?

    var isAwaitingConfirmation: Bool { status == "AWAITING_CONFIRMATION" }
    var isCompleted: Bool { status == "COMPLETED" }
    var isFailed: Bool { status == "FAILED" }
    var isInFlight: Bool {
        ["QUEUED", "DETECTING", "PROCESSING"].contains(status)
    }
}

struct SpaceCleanupCreateRequest: Codable, Sendable {
    var spaceId: String
    var sourceRevisionId: String
    var mode: SpaceCleanupMode
    var points: [SpaceCleanupSelectionPoint]?
    var aiConsentAccepted: Bool
}
