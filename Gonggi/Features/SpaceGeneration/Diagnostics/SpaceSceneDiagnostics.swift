import CryptoKit
import Foundation
import ImageIO
import SceneKit
import simd
import UIKit

/// Owner VR scene diagnostics for TestFlight share-sheet export.
/// Captures local render state first; server fields are filled separately without mutating local stores.
enum SpaceSceneDiagnostics {
    struct Report: Codable, Sendable {
        var schemaVersion: Int
        var exportedAt: String
        var app: AppInfo
        var space: SpaceInfo
        var panoramaImage: ImageInfo
        var hotspots: HotspotsBlock
        var panoramaGeometry: GeometryInfo
        var camera: CameraInfo
        var placements: [PlacementInfo]
        var notes: [String]
    }

    struct AppInfo: Codable, Sendable {
        var marketingVersion: String
        var buildNumber: String
        var buildSHA: String
    }

    struct SpaceInfo: Codable, Sendable {
        var sessionId: String
        var baseRevisionId: String
        var displayedTexturePathSuffix: String
        var latestRevisionStampId: String?
        var latestRevisionToken: String?
    }

    struct ImageInfo: Codable, Sendable {
        var sourceKind: String
        var pathSuffix: String
        var exists: Bool
        var byteCount: Int?
        var sha256: String?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var uiImageOrientation: String?
        var cgImagePropertyOrientation: Int?
        var decodeOrientationCorrection: String
        var prepareEquirectPassThrough: Bool
    }

    struct HotspotPose: Codable, Sendable {
        var id: String
        var status: String
        var labelPresent: Bool
        var labelSize: String?
        var yawDeg: Float
        var pitchDeg: Float
        var radius: Float
        var hasExternalUrl: Bool
        var hasTargetSpaceId: Bool
        var worldPosition: [Float]?
        var lookDirection: [Float]?
        var hitTestUV: UVHit?
        var updatedAt: String?
    }

    struct UVHit: Codable, Sendable {
        var u: Float
        var v: Float
        var equirectYawDeg: Float
        var equirectPitchDeg: Float
        var hitNodeName: String?
    }

    struct HotspotsBlock: Codable, Sendable {
        var localDisplayed: [HotspotPose]
        var localCache: [HotspotPose]
        var serverFetched: [HotspotPose]?
        var serverFetchError: String?
        var pendingPoseSaveIds: [String]
        var linkedPoseCheckpoint: [String: PoseCheckpoint]
        var localVsServerYawDeltaDeg: [String: Float]
    }

    struct PoseCheckpoint: Codable, Sendable {
        var yawDeg: Float
        var pitchDeg: Float
        var radius: Float
    }

    struct GeometryInfo: Codable, Sendable {
        var sphereGeometryType: String
        var sphereRadius: Float?
        var sphereSegmentCount: Int?
        var sphereLocalScale: [Float]
        var sphereWorldTransform: [Float]
        var sphereParentName: String?
        var cullMode: String?
        var materialLightingModel: String?
        var contentsTransform: [Float]
        var wrapS: String?
        var wrapT: String?
        var insideOutScaleConvention: [Float]
    }

    struct CameraInfo: Codable, Sendable {
        var worldTransform: [Float]
        var eulerPitchYawRoll: [Float]
        var lookFinalYawDeg: Float
        var lookFinalPitchDeg: Float
        var fieldOfViewDeg: Float
        var zNear: Float?
        var zFar: Float?
        var viewportWidth: Float
        var viewportHeight: Float
        var projectionTransform: [Float]?
    }

    struct PlacementInfo: Codable, Sendable {
        var id: String
        var assetId: String
        var entryPosition: [Float]
        var entryRotationY: Float
        var entryUniformScale: Float
        var supportMode: String?
        var supportY: Float?
        var nodeWorldPosition: [Float]?
        var nodeWorldTransform: [Float]?
        var nodeLocalScale: [Float]?
        var contentBaseScaleNormalize: Float?
        var heightCm: Double?
    }

    // MARK: - Build report

    static func buildReport(
        sessionId: String,
        baseRevisionId: String,
        displayedTextureURL: URL,
        localDisplayedLinks: [SpaceLink],
        localCachedLinks: [SpaceLink],
        serverLinks: [SpaceLink]?,
        serverFetchError: String?,
        pendingPoseSaveIds: [String],
        linkedPoseCheckpoint: [String: (yaw: Float, pitch: Float, radius: Float)],
        placementEntries: [VRPlacedAssetEntry],
        assetMetadata: [String: MobileAssetDTO],
        scene: SCNHostView.SceneDiagnosticsSnapshot,
        notes: [String] = []
    ) -> Report {
        let image = inspectImage(at: displayedTextureURL)
        let stamp = SpaceLatLongStore.readRevisionStamp(forImageAt: displayedTextureURL)

        let localDisplayed = localDisplayedLinks.map { link in
            enrich(link: link, scene: scene)
        }
        let localCache = localCachedLinks.map { link in
            HotspotPose(
                id: link.id,
                status: link.status.rawValue,
                labelPresent: !(link.label ?? "").isEmpty,
                labelSize: link.labelSize?.rawValue,
                yawDeg: link.yawDeg,
                pitchDeg: link.pitchDeg,
                radius: link.radius,
                hasExternalUrl: link.externalUrl != nil,
                hasTargetSpaceId: link.targetSpaceId != nil,
                worldPosition: nil,
                lookDirection: nil,
                hitTestUV: nil,
                updatedAt: iso(link.updatedAt)
            )
        }
        let serverMapped = serverLinks?.map { link in
            HotspotPose(
                id: link.id,
                status: link.status.rawValue,
                labelPresent: !(link.label ?? "").isEmpty,
                labelSize: link.labelSize?.rawValue,
                yawDeg: link.yawDeg,
                pitchDeg: link.pitchDeg,
                radius: link.radius,
                hasExternalUrl: link.externalUrl != nil,
                hasTargetSpaceId: link.targetSpaceId != nil,
                worldPosition: nil,
                lookDirection: nil,
                hitTestUV: nil,
                updatedAt: iso(link.updatedAt)
            )
        }

        var yawDeltas: [String: Float] = [:]
        if let serverLinks {
            let byId = Dictionary(uniqueKeysWithValues: serverLinks.map { ($0.id, $0) })
            for local in localDisplayedLinks {
                guard let remote = byId[local.id] else { continue }
                yawDeltas[local.id] = VRSphereEquirectBridge.shortestDeltaDeg(
                    from: remote.yawDeg,
                    to: local.yawDeg
                )
            }
        }

        let checkpoints = linkedPoseCheckpoint.mapValues {
            PoseCheckpoint(yawDeg: $0.yaw, pitchDeg: $0.pitch, radius: $0.radius)
        }

        let placements: [PlacementInfo] = placementEntries.map { entry in
            let meta = assetMetadata[entry.assetId]
            let nodeSnap = scene.placements.first { $0.id == entry.id }
            return PlacementInfo(
                id: entry.id,
                assetId: entry.assetId,
                entryPosition: [entry.position.x, entry.position.y, entry.position.z],
                entryRotationY: entry.rotationY,
                entryUniformScale: entry.uniformScale,
                supportMode: entry.supportMode?.rawValue,
                supportY: entry.supportY,
                nodeWorldPosition: nodeSnap?.worldPosition,
                nodeWorldTransform: nodeSnap?.worldTransform,
                nodeLocalScale: nodeSnap?.localScale,
                contentBaseScaleNormalize: nodeSnap?.contentBaseScale,
                heightCm: meta?.heightCm
            )
        }

        return Report(
            schemaVersion: 1,
            exportedAt: iso(Date()) ?? "",
            app: AppInfo(
                marketingVersion: GonggiBuildInfo.marketingVersion,
                buildNumber: GonggiBuildInfo.buildNumber,
                buildSHA: GonggiBuildInfo.buildSHA
            ),
            space: SpaceInfo(
                sessionId: sessionId,
                baseRevisionId: baseRevisionId,
                displayedTexturePathSuffix: pathSuffix(displayedTextureURL),
                latestRevisionStampId: stamp?.revisionId,
                latestRevisionToken: stamp?.revisionToken
            ),
            panoramaImage: image,
            hotspots: HotspotsBlock(
                localDisplayed: localDisplayed,
                localCache: localCache,
                serverFetched: serverMapped,
                serverFetchError: serverFetchError,
                pendingPoseSaveIds: pendingPoseSaveIds,
                linkedPoseCheckpoint: checkpoints,
                localVsServerYawDeltaDeg: yawDeltas
            ),
            panoramaGeometry: scene.geometry,
            camera: scene.camera,
            placements: placements,
            notes: notes
        )
    }

    static func encodePretty(_ report: Report) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    static func writeTempFile(_ report: Report) throws -> URL {
        let data = try encodePretty(report)
        let name = "gonggi-space-diagnostics-\(report.space.sessionId.prefix(12))-\(Int(Date().timeIntervalSince1970)).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Helpers

    private static func enrich(link: SpaceLink, scene: SCNHostView.SceneDiagnosticsSnapshot) -> HotspotPose {
        let node = scene.hotspots.first { $0.id == link.id }
        let look = SpaceLinkMath.lookDirection(yawDeg: link.yawDeg, pitchDeg: link.pitchDeg)
        return HotspotPose(
            id: link.id,
            status: link.status.rawValue,
            labelPresent: !(link.label ?? "").isEmpty,
            labelSize: link.labelSize?.rawValue,
            yawDeg: link.yawDeg,
            pitchDeg: link.pitchDeg,
            radius: link.radius,
            hasExternalUrl: link.externalUrl != nil,
            hasTargetSpaceId: link.targetSpaceId != nil,
            worldPosition: node?.worldPosition,
            lookDirection: [look.x, look.y, look.z],
            hitTestUV: node?.hitTestUV,
            updatedAt: iso(link.updatedAt)
        )
    }

    private static func inspectImage(at url: URL) -> ImageInfo {
        let path = url.path
        let exists = FileManager.default.fileExists(atPath: path)
        var byteCount: Int?
        var sha: String?
        if exists, let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
            byteCount = data.count
            sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        var uiOri: String?
        var cgOri: Int?
        var width: Int?
        var height: Int?
        if let img = UIImage(contentsOfFile: path) {
            uiOri = orientationName(img.imageOrientation)
            width = img.cgImage?.width
            height = img.cgImage?.height
        }
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let o = props[kCGImagePropertyOrientation] as? Int {
            cgOri = o
        }

        let kind: String
        let last = url.lastPathComponent.lowercased()
        if last == "latlong-latest.jpg" {
            kind = "latlong-latest"
        } else if last == "latlong.jpg" {
            kind = "latlong-base"
        } else if last.contains("repair") {
            kind = "repair-local"
        } else {
            kind = "other-local"
        }

        return ImageInfo(
            sourceKind: kind,
            pathSuffix: pathSuffix(url),
            exists: exists,
            byteCount: byteCount,
            sha256: sha,
            pixelWidth: width,
            pixelHeight: height,
            uiImageOrientation: uiOri,
            cgImagePropertyOrientation: cgOri,
            decodeOrientationCorrection: "UIImage(contentsOfFile:) then prepareEquirectTextureForInsideOut(pass-through); forced .up when prepared",
            prepareEquirectPassThrough: true
        )
    }

    private static func pathSuffix(_ url: URL) -> String {
        let parts = url.pathComponents.suffix(4)
        return parts.joined(separator: "/")
    }

    private static func orientationName(_ o: UIImage.Orientation) -> String {
        switch o {
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        case .upMirrored: return "upMirrored"
        case .downMirrored: return "downMirrored"
        case .leftMirrored: return "leftMirrored"
        case .rightMirrored: return "rightMirrored"
        @unknown default: return "unknown"
        }
    }

    private static func iso(_ date: Date?) -> String? {
        guard let date else { return nil }
        return ISO8601DateFormatter().string(from: date)
    }

    static func matrix16(_ m: simd_float4x4) -> [Float] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w,
        ]
    }

    static func scnMatrix16(_ m: SCNMatrix4) -> [Float] {
        matrix16(simd_float4x4(m))
    }
}
