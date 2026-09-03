import Foundation

/// Selects reconstruction engine. Production always Legacy.
enum PanoramaEngineSelection: String, CaseIterable, Equatable, Sendable {
    case legacy
    case openCV
    /// Run Legacy for user output + also invoke OpenCV (stub in Phase 1) for A/B artifacts.
    case abCompare

    static var productionDefault: PanoramaEngineSelection { .legacy }

    /// Release: always legacy. DEBUG: may override via `debugOverride`.
    static func resolved() -> PanoramaEngineSelection {
        #if DEBUG
        return debugOverride ?? .legacy
        #else
        return .legacy
        #endif
    }

    #if DEBUG
    /// DEBUG-only override (no UI in Phase 1 — set from tests / future debug panel).
    static var debugOverride: PanoramaEngineSelection?
    #endif

    func makePrimaryEngine() -> any PanoramaEngineProtocol {
        switch self {
        case .legacy, .abCompare:
            return GonggiLegacyPanoramaEngine()
        case .openCV:
            return OpenCVPanoramaEngine()
        }
    }
}

enum PanoramaABTestWriter {
    /// Writes A/B directory contract. OpenCV may fail (Phase 1 stub) — still writes reports.
    static func write(
        sessionId: String,
        legacy: PanoramaEngineOutput,
        openCV: PanoramaEngineOutput
    ) throws {
        let dir = try PanoramaABPaths.directory(sessionId: sessionId)

        if let rgba = legacy.rgba, legacy.width > 0, legacy.height > 0 {
            try PanoramaExporter.writeJPEG(
                rgba: rgba,
                width: legacy.width,
                height: legacy.height,
                to: dir.appendingPathComponent(PanoramaABPaths.legacyPanorama)
            )
        } else if let url = legacy.panoramaURL,
                  FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.copyItem(
                at: url,
                to: dir.appendingPathComponent(PanoramaABPaths.legacyPanorama)
            )
        }

        // Phase 1: opencv_panorama.jpg may be absent; report still written.
        if let rgba = openCV.rgba, openCV.width > 0, openCV.height > 0, openCV.success {
            try PanoramaExporter.writeJPEG(
                rgba: rgba,
                width: openCV.width,
                height: openCV.height,
                to: dir.appendingPathComponent(PanoramaABPaths.openCVPanorama)
            )
        }

        var legacyReport = legacy.report
        if legacyReport.outputFilePath == nil {
            legacyReport.outputFilePath = dir
                .appendingPathComponent(PanoramaABPaths.legacyPanorama).path
        }
        var openCVReport = openCV.report
        openCVReport.outputFilePath = openCV.success
            ? dir.appendingPathComponent(PanoramaABPaths.openCVPanorama).path
            : nil

        try PanoramaExporter.writeJSON(
            legacyReport,
            to: dir.appendingPathComponent(PanoramaABPaths.legacyReport)
        )
        try PanoramaExporter.writeJSON(
            openCVReport,
            to: dir.appendingPathComponent(PanoramaABPaths.openCVReport)
        )

        let iso = ISO8601DateFormatter().string(from: Date())
        let ab = PanoramaABComparisonReport(
            sessionId: sessionId,
            createdAt: iso,
            legacy: legacyReport,
            openCV: openCVReport,
            notes: openCV.success
                ? nil
                : (openCV.failureReason ?? "OpenCV unavailable; schema reserved for A/B")
        )
        try PanoramaExporter.writeJSON(
            ab,
            to: dir.appendingPathComponent(PanoramaABPaths.abReport)
        )
    }
}
