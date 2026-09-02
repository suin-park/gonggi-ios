import Foundation

/// Runs mesh merge + RGB projection + USDZ export after capture finishes.
enum TexturedMeshReconstruction {
    struct Output {
        let usdzURL: URL
        let reportURL: URL
        let report: TexturedMeshReport
    }

    static func reconstruct(
        sessionId: String,
        meshSnapshots: [MeshAnchorSnapshot],
        keyframes: [CaptureKeyframeRecord],
        peakMemoryEstimateMB: Double
    ) throws -> Output {
        let started = CFAbsoluteTimeGetCurrent()

        let merged = MeshMerger.merge(snapshots: meshSnapshots)
        let keyframeDirectory = try CaptureSessionStore.keyframesDirectory(sessionId: sessionId)
        let projection = try TextureProjector.project(
            mesh: merged,
            keyframes: keyframes,
            keyframeDirectory: keyframeDirectory
        )

        let usdzURL = try CaptureSessionStore.texturedSpaceUSDZURL(sessionId: sessionId)
        try TexturedMeshExporter.exportUSDZ(mesh: projection.mesh, to: usdzURL)

        let outputSize = (try? FileManager.default.attributesOfItem(atPath: usdzURL.path)[.size] as? NSNumber)?
            .int64Value ?? 0

        let report = TexturedMeshReport(
            vertexCount: projection.mesh.vertexCount,
            triangleCount: projection.mesh.triangleCount,
            keyframeCount: keyframes.count,
            texturedVertexCount: projection.texturedVertexCount,
            texturedCoveragePercent: projection.texturedCoveragePercent,
            reconstructionTimeSec: CFAbsoluteTimeGetCurrent() - started,
            outputByteSize: outputSize,
            peakMemoryEstimateMB: peakMemoryEstimateMB,
            usdzFileName: CaptureSessionStore.texturedSpaceUSDZFileName,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )

        let reportURL = try CaptureSessionStore.texturedSpaceReportURL(sessionId: sessionId)
        try TexturedMeshExporter.writeReport(report, to: reportURL)

        return Output(usdzURL: usdzURL, reportURL: reportURL, report: report)
    }
}
