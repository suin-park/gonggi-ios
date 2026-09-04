//
//  OpenCVPanoramaReconstructor.hpp
//  Phase 2B/2C: feature match + ARKit prior + BA + spherical stitch.
//  Does NOT use cv::Stitcher high-level API as the default path.
//
//  Build 24: two-pass memory-bounded architecture
//    A) analysis on proxy images only
//    B) streaming full-res warp → feed → release (≤1 resident warped frame)
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
    /// Analysis / matching proxy long-edge (Build 24: 1200–1600; never keep full-res N).
    float matchLongEdge = 1400.f;
    float maxVisualCorrectionDeg = 12.f;
    float minInlierRatio = 0.25f;
    int minInliers = 16;
    /// Exposure gain estimation long-edge (proxy-only).
    float exposureAnalysisLongEdge = 640.f;
    /// Seam finder analysis long-edge (proxy-only).
    float seamAnalysisLongEdge = 640.f;
    /// Soft phys_footprint budgets (MB). Build 23 jetsam ≈ 3072MB — stay far below.
    /// preferred <1000; warn ~1200; hard degradation ≤1500.
    double memoryWarnMB = 1200.0;
    double memoryCriticalMB = 1500.0;
    /// MultiBand bands — stability default 3 (was 5).
    int blendBands = 3;
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
    std::string exposureMode = "Gain";
    std::string seamFinder = "GraphCutColorGrad";
    std::string blender = "MultiBand";
    /// Build 24 architecture tag.
    std::string memoryArchitecture = "two_pass_streaming";
    int maxLoadedFullResCount = 0;
    int maxWarpedResidentCount = 0;
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
    int blendBandsUsed = 3;
};

/// Returns true on success and writes JPEG to config.outputPath.
/// Never throws across this boundary — all C++/OpenCV exceptions become structured failure.
bool GonggiOpenCVStitchPanorama(
    const std::vector<GonggiOpenCVFrameInput> &frames,
    const GonggiOpenCVStitchConfig &config,
    GonggiOpenCVStitchMetrics &metrics
);
