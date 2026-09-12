import Foundation

struct RepairTarget: Codable, Equatable, Identifiable {
    var id: String
    var sessionId: String
    var baseRevisionId: String
    var targetYawDeg: Double
    var targetPitchDeg: Double
    var radiusYawDeg: Double
    var radiusPitchDeg: Double
    var createdAt: Date

    static func make(
        sessionId: String,
        baseRevisionId: String,
        targetYawDeg: Double,
        targetPitchDeg: Double
    ) -> RepairTarget {
        RepairTarget(
            id: UUID().uuidString,
            sessionId: sessionId,
            baseRevisionId: baseRevisionId,
            targetYawDeg: targetYawDeg,
            targetPitchDeg: targetPitchDeg,
            radiusYawDeg: Double(VRSphereEquirectBridge.defaultYawRadiusDeg),
            radiusPitchDeg: Double(VRSphereEquirectBridge.defaultPitchRadiusDeg),
            createdAt: Date()
        )
    }
}

struct RepairCaptureMetadataPayload: Codable, Equatable {
    var sessionId: String
    var baseRevisionId: String
    var repairTargetId: String
    var targetYawDeg: Double
    var targetPitchDeg: Double
    var capturedYawDeg: Double
    var capturedElevationDeg: Double
    var yawConvention: String
    var imageWidth: Int?
    var imageHeight: Int?
    var timestamp: String
    var fovSource: String
    var horizontalFOV: Double
    var verticalFOV: Double
    var targetDeltaYawDeg: Double?
    var targetDeltaPitchDeg: Double?
}

struct SpaceRepairJobRecord: Codable, Equatable, Identifiable {
    var id: String { repairJobId }
    var repairJobId: String
    var sessionId: String
    var baseRevisionId: String
    var revisionId: String?
    var target: RepairTarget
    var status: String
    var repairMode: String
    var resultImageURL: String?
    var localLatLongPath: String?
    var createdAt: Date
    var updatedAt: Date
    var errorCode: String?
    /// Server Astra / deterministic summary for card note (optional).
    var userFacingSummaryKo: String? = nil
    var intent: String? = nil

    var isTerminal: Bool {
        status == "completed" || status == "failed"
    }

    var isActive: Bool { !isTerminal }
}

struct SpaceRepairCreateResponse: Equatable {
    var repairJobId: String
    var revisionId: String
    var status: String
}

struct SpaceRepairStatusResponse: Equatable {
    var status: String
    var revisionId: String?
    var imageUrl: String?
    var width: Int?
    var height: Int?
    var errorCode: String?
    var userFacingSummaryKo: String? = nil
    var intent: String? = nil
}

enum RepairIntentHint: String, CaseIterable, Identifiable, Equatable {
    case preserveText = "preserve_text"
    case fixGeometry = "fix_geometry"
    case fillGap = "fill_gap"
    case removeObject = "remove_object"
    case generalRefine = "general_refine"

    var id: String { rawValue }

    var labelKo: String {
        switch self {
        case .preserveText: return "글자 보존"
        case .fixGeometry: return "구조 수정"
        case .fillGap: return "빈 곳 채우기"
        case .removeObject: return "객체 제거"
        case .generalRefine: return "일반 다듬기"
        }
    }
}
