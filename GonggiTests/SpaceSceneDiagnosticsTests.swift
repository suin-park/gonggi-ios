import XCTest
@testable import Gonggi

final class SpaceSceneDiagnosticsTests: XCTestCase {
    func testEncodeOmitsSecretsAndIncludesSchema() throws {
        let emptyScene = SCNHostView.SceneDiagnosticsSnapshot(
            geometry: SpaceSceneDiagnostics.GeometryInfo(
                sphereGeometryType: "SCNSphere",
                sphereRadius: 10,
                sphereSegmentCount: 192,
                sphereLocalScale: [-1, 1, 1],
                sphereWorldTransform: Array(repeating: 0, count: 16),
                sphereParentName: nil,
                cullMode: "front",
                materialLightingModel: "constant",
                contentsTransform: Array(repeating: 0, count: 16),
                wrapS: "repeat",
                wrapT: "clamp",
                insideOutScaleConvention: [-1, 1, 1]
            ),
            camera: SpaceSceneDiagnostics.CameraInfo(
                worldTransform: Array(repeating: 0, count: 16),
                eulerPitchYawRoll: [0, 0, 0],
                lookFinalYawDeg: -48,
                lookFinalPitchDeg: 1,
                fieldOfViewDeg: 70,
                zNear: 0.1,
                zFar: 100,
                viewportWidth: 390,
                viewportHeight: 844,
                projectionTransform: nil
            ),
            hotspots: [],
            placements: []
        )

        let link = SpaceLink.makeDraft(
            sourceSpaceId: "dir-test",
            yawDeg: -48,
            pitchDeg: 2,
            radius: 3
        )
        var linked = link
        linked.status = .linked
        linked.label = "내 방"
        linked.id = "hotspot-local-1"

        let report = SpaceSceneDiagnostics.buildReport(
            sessionId: "dir-test-session",
            baseRevisionId: "rev-0-base",
            displayedTextureURL: URL(fileURLWithPath: "/tmp/Spaces/dir-test/latlong.jpg"),
            localDisplayedLinks: [linked],
            localCachedLinks: [linked],
            serverLinks: [
                SpaceLink(
                    id: "hotspot-local-1",
                    sourceSpaceId: "dir-test",
                    targetSpaceId: "target",
                    yawDeg: -132.16,
                    pitchDeg: 1.9,
                    radius: 3,
                    label: "내 방",
                    externalUrl: nil,
                    labelSize: .medium,
                    status: .linked,
                    targetEntryYawDeg: nil,
                    targetSessionId: nil,
                    targetResultImageURL: nil,
                    targetStatus: "completed",
                    createdAt: Date(),
                    updatedAt: Date()
                ),
            ],
            serverFetchError: nil,
            pendingPoseSaveIds: [],
            linkedPoseCheckpoint: ["hotspot-local-1": (yaw: -48, pitch: 2, radius: 3)],
            placementEntries: [],
            assetMetadata: [:],
            scene: emptyScene,
            notes: ["unit-test"]
        )

        let data = try SpaceSceneDiagnostics.encodePretty(report)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"schemaVersion\" : 1"))
        XCTAssertTrue(json.contains("hotspot-local-1"))
        XCTAssertTrue(json.contains("-48"))
        XCTAssertTrue(json.contains("-132.16") || json.contains("-132.1"))
        // Secrets must not appear.
        XCTAssertFalse(json.lowercased().contains("bearer"))
        XCTAssertFalse(json.contains("shareToken"))
        XCTAssertFalse(json.contains("accessToken"))
        XCTAssertFalse(json.contains("@"))

        let delta = report.hotspots.localVsServerYawDeltaDeg["hotspot-local-1"]
        XCTAssertNotNil(delta)
        XCTAssertEqual(delta!, 84.16, accuracy: 0.5)
    }

    func testBuildInfoHasVersionFields() {
        XCTAssertFalse(GonggiBuildInfo.marketingVersion.isEmpty)
        XCTAssertFalse(GonggiBuildInfo.buildNumber.isEmpty)
        XCTAssertFalse(GonggiBuildInfo.buildSHA.isEmpty)
    }
}
