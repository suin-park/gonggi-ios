import Foundation

/// Selects reconstruction engine. Production always Legacy.
enum PanoramaEngineSelection: String, CaseIterable, Equatable, Sendable {
    case legacy
    case openCV
    /// Legacy user-facing output + OpenCV A/B artifacts (same keyframes).
    case abCompare

    static var productionDefault: PanoramaEngineSelection { .legacy }

    /// Release: Legacy unless `Quick360Config.testFlightABCompareEnabled` (TestFlight A/B).
    /// DEBUG: optional `debugOverride`.
    static func resolved() -> PanoramaEngineSelection {
        #if DEBUG
        return debugOverride ?? .legacy
        #else
        if Quick360Config.testFlightABCompareEnabled {
            return .abCompare
        }
        return .legacy
        #endif
    }

    #if DEBUG
    /// DEBUG-only override (tests / future debug panel).
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

        // Phase 2+: prefer in-memory rgba; else copy JPEG written by OpenCV bridge.
        if let rgba = openCV.rgba, openCV.width > 0, openCV.height > 0, openCV.success {
            try PanoramaExporter.writeJPEG(
                rgba: rgba,
                width: openCV.width,
                height: openCV.height,
                to: dir.appendingPathComponent(PanoramaABPaths.openCVPanorama)
            )
        } else if openCV.success,
                  let url = openCV.panoramaURL,
                  FileManager.default.fileExists(atPath: url.path) {
            let dest = dir.appendingPathComponent(PanoramaABPaths.openCVPanorama)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
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
