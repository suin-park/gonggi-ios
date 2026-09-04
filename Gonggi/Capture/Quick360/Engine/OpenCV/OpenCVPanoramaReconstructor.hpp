//
//  OpenCVPanoramaReconstructor.hpp
//  Phase 2B/2C: feature match + ARKit prior + BA + spherical stitch.
//  Does NOT use cv::Stitcher high-level API as the default path.
//

#pragma once

#include <string>
#include <vector>

struct GonggiOpenCVFrameInput {
    std::string jpegPath;
    // Row-major 3×3 Gonggi roll-free camera→world (StabilizedCameraFrame.rotation).
    float R_gonggi[9];
    float fx, fy, cx, cy;
    int width, height;
    float yawDeg;
    float pitchDeg;
    float translationM; // parallax hint; not used as BA dof
};

struct GonggiOpenCVStitchConfig {
    std::string outputPath;
    int outputWidth = 4096;
    int outputHeight = 2048;
    float firstForwardYawDeg = 0;
    float firstForwardPitchDeg = 0;
    std::string debugDirectory; // optional …/ab/opencv/
    float matchLongEdge = 1400.f;
    float maxVisualCorrectionDeg = 12.f;
    float minInlierRatio = 0.25f;
    int minInliers = 16;
    /// Exposure gain estimation long-edge (Build 23: never full-res feed).
    float exposureAnalysisLongEdge = 768.f;
    /// Seam finder analysis long-edge (Build 23: real downscale).
    float seamAnalysisLongEdge = 800.f;
    /// Soft phys_footprint budgets (MB) for iPhone 14 Plus (~6GB).
    /// Warn: reduce analysis resolution. Critical: more aggressive + fewer blend bands.
    double memoryWarnMB = 1800.0;
    double memoryCriticalMB = 2200.0;
};

struct GonggiOpenCVStitchMetrics {
    bool success = false;
    std::string errorMessage;
    double processingTimeMs = 0;
    double peakMemoryMB = 0;
    int inputKeyframeCount = 0;
    int matchedPairCount = 0;
    int failedPairCount = 0;
    double averageRawMatches = 0;
    double averageFilteredMatches = 0;
    double averageInliers = 0;
    double averageInlierRatio = 0;
    int cameraGraphEdges = 0;
    int connectedComponents = 0;
    bool bundleAdjustmentConverged = false;
    double bundleAdjustmentBeforeError = 0;
    double bundleAdjustmentAfterError = 0;
    int optimizedCameraCount = 0;
    int rejectedCameraCount = 0;
    double averageVisualCorrectionDeg = 0;
    double maxVisualCorrectionDeg = 0;
    double averageOverlap = 0;
    double featureTimeMs = 0;
    double matchingTimeMs = 0;
    double bundleAdjustmentTimeMs = 0;
    double warpTimeMs = 0;
    double exposureTimeMs = 0;
    double seamTimeMs = 0;
    double blendTimeMs = 0;
    double encodeTimeMs = 0;
    double holePercent = 0;
    double zenithHolePercent = 0;
    double nadirHolePercent = 0;
    std::string outputResolution;
    double outputFileSizeMB = 0;
    std::string featureDetector = "AKAZE";
    std::string featureMatcher = "BF_HAMMING_KNN";
    /// Build 23 default: Gain (not BlocksGain) for iPhone memory safety.
    std::string exposureMode = "Gain";
    std::string seamFinder = "GraphCutColorGrad";
    std::string blender = "MultiBand";
    // Memory telemetry (phys_footprint MB)
    double memoryStartMB = 0;
    double memoryAfterLoadMB = 0;
    double memoryAfterFeatureMB = 0;
    double memoryAfterMatchMB = 0;
    double memoryAfterBAMB = 0;
    double memoryAfterWarpMB = 0;
    double memoryBeforeExposureMB = 0;
    double memoryAfterExposureMB = 0;
    double memoryBeforeSeamMB = 0;
    double memoryAfterSeamMB = 0;
    double memoryBeforeBlendMB = 0;
    double memoryAfterBlendMB = 0;
    double memoryAfterEncodeMB = 0;
    float exposureAnalysisLongEdgeUsed = 0;
    float seamAnalysisLongEdgeUsed = 0;
    int blendBandsUsed = 5;
};

/// Returns true on success and writes JPEG to config.outputPath.
/// Never throws across this boundary — all C++/OpenCV exceptions become structured failure.
bool GonggiOpenCVStitchPanorama(
    const std::vector<GonggiOpenCVFrameInput> &frames,
    const GonggiOpenCVStitchConfig &config,
    GonggiOpenCVStitchMetrics &metrics
);
