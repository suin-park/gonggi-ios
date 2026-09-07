import Foundation

/// One entry in multipart `captureMetadata` (20 required when present).
struct SpaceCaptureMetadataEntry: Codable, Equatable, Sendable {
    var direction: String
    var capturedYawDeg: Double
    var capturedElevationDeg: Double
    var nominalYawDeg: Double?
    var nominalElevationDeg: Double?
    var captureTimestamp: Double?
    var width: Int?
    var height: Int?
    var rollDeg: Double?
    /// iOS yaw convention: front=0, right turn decreases (unwrapped).
    var yawConvention: String?
    /// Build 60 additive debug (not used by production prompt).
    var closureDeltaDeg: Double?
    var horizontalLevelDeltaDeg: Double?
    var closureGatePassed: Bool?
    /// App CFBundleVersion (e.g. "61") for Build61 scaffold validation forensics.
    var appBuild: String?
    /// Client-requested generation mode when Build61 scaffold opt-in is active.
    var clientGenerationMode: String?
}

enum SpaceCaptureMetadataBuilder {
    /// Builds JSON array for multipart field `captureMetadata`.
    /// Uses photo-request motion poses from `DirectionCaptureReport` (unwrapped yaw).
    static func jsonString(from report: DirectionCaptureReport) throws -> String {
        let entries: [SpaceCaptureMetadataEntry] = report.captures.map { rec in
            let capturedYaw = Double(rec.capturedYawDeg ?? rec.yawDeg)
            let capturedElev = Double(rec.capturedElevationDeg ?? rec.elevationDeg ?? 0)
            return SpaceCaptureMetadataEntry(
                direction: rec.direction.rawValue,
                capturedYawDeg: capturedYaw,
                capturedElevationDeg: capturedElev,
                nominalYawDeg: rec.nominalYaw.map(Double.init),
                nominalElevationDeg: rec.nominalElevation.map(Double.init),
                captureTimestamp: rec.timestamp,
                width: rec.finalPixelWidth,
                height: rec.finalPixelHeight,
                rollDeg: Double(rec.rollDeg),
                yawConvention: "ios_right_turn_negative_unwrapped",
                closureDeltaDeg: rec.closureDeltaDeg.map(Double.init),
                horizontalLevelDeltaDeg: rec.horizontalLevelDeltaDeg.map(Double.init),
                closureGatePassed: rec.closureGatePassed,
                appBuild: GonggiSpaceRecordAIMode.currentAppBuildNumber,
                clientGenerationMode: GonggiSpaceRecordAIMode.createRequestMode
            )
        }
        guard entries.count == DirectionName.requiredCount else {
            throw SpaceRecordClientError.captureIncomplete
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entries)
        guard let s = String(data: data, encoding: .utf8) else {
            throw SpaceRecordClientError.invalidResponse
        }
        return s
    }
}
