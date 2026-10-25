import Foundation

enum SpaceCleanupMode: String, Codable, Sendable, Equatable, CaseIterable {
    case allFurniture = "ALL_FURNITURE"
    case selectedObjects = "SELECTED_OBJECTS"

    var title: String {
        switch self {
        case .allFurniture: return L("Clear all furniture")
        case .selectedObjects: return L("Choose furniture to clear")
        }
    }

    var subtitle: String {
        switch self {
        case .allFurniture:
            return L("Keeps the room's structure and clears movable furniture and everyday items.")
        case .selectedObjects:
            return L("Choose one or more pieces of furniture to remove from the 360° space.")
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
    /// 0...100 from Cloud (locker progress may normalize to 0...1).
    var progress: Int?
    var selectionPoints: [SpaceCleanupSelectionPoint]?
    var detectedObjects: [SpaceCleanupDetectedObject]?
    var failureCode: String?
    var failureMessageSafe: String?
    var outsideMaskDiff: Double?
    var placementResultId: String?
    var maskPreviewUrl: String?
    var createdAt: String?
    var updatedAt: String?

    var isAwaitingConfirmation: Bool { status == "AWAITING_CONFIRMATION" }
    var isCompleted: Bool { status == "COMPLETED" }
    var isFailed: Bool { status == "FAILED" }
    var isInFlight: Bool {
        ["QUEUED", "DETECTING", "PROCESSING"].contains(status)
    }

    /// Normalized 0...1 for ProgressView.
    var progressFraction: Double {
        guard let progress else { return 0.15 }
        if progress <= 1 { return max(0.05, Double(progress)) }
        return min(1, max(0.05, Double(progress) / 100))
    }
}

struct SpaceCleanupCreateRequest: Codable, Sendable {
    var spaceId: String
    var sourceRevisionId: String
    var mode: SpaceCleanupMode
    var points: [SpaceCleanupSelectionPoint]?
    var aiConsentAccepted: Bool
}
