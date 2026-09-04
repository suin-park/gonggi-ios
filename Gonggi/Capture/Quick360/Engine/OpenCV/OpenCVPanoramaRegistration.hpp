//
//  OpenCVPanoramaRegistration.hpp
//  Build 26: rotation-only pair registration + pose-graph with ARKit prior.
//

#pragma once

#include <opencv2/core.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/stitching/detail/matchers.hpp>
#include <opencv2/stitching/detail/camera.hpp>

#include <string>
#include <vector>

struct GonggiRegPairDebug {
    int src = 0;
    int dst = 0;
    int rawMatches = 0;
    int mutualMatches = 0;
    int inliers = 0;
    double inlierRatio = 0;
    double medianAngularErrorDeg = 0;
    double overlapEstimate = 0;
    double visualDeltaYawDeg = 0;
    double visualDeltaPitchDeg = 0;
    double visualDeltaRollDeg = 0;
    bool accepted = false;
    std::string rejectReason;
};

struct GonggiRegistrationConfig {
    float maxVisualCorrectionDeg = 12.f;
    float minInlierRatio = 0.25f;
    int minInliers = 16;
    double priorAngularGateDeg = 10.0;   // prefilter vs ARKit relative
    double inlierAngularThreshDeg = 3.5; // rotation RANSAC inlier
    int minSpatialBins = 3;              // 3x3 grid coverage
    double priorWeight = 2.0;            // pose-graph ARKit pull
    double rollDamp = 0.08;              // keep roll near ARKit
    int poseGraphIters = 25;
    bool runSecondaryOpenCVBA = false;   // optional; primary is Gonggi graph
};

struct GonggiRegistrationMetrics {
    int acceptedPairCount = 0;
    int rejectedPairCount = 0;
    double medianPairAngularErrorDeg = 0;
    double p90PairAngularErrorDeg = 0;
    double averageCameraCorrectionDeg = 0;
    double maxCameraCorrectionDeg = 0;
    int connectedComponents = 0;
    int poseGraphEdgeCount = 0;
    std::string registrationMode = "rotation_graph_arkit_prior";
    std::string baRole = "secondary_skipped";
    bool poseGraphConverged = false;
};

/// Estimate relative rotations from features + ARKit priors; refine orientations in-place.
/// Also fills OpenCV N×N MatchesInfo for optional secondary BA / seam confidence.
/// Writes pair JSON/JPG and pose_graph_*.json when debugDirectory non-empty.
bool GonggiRunRotationRegistration(
    const std::vector<cv::detail::ImageFeatures> &features,
    const std::vector<cv::Mat> &K_match,
    const std::vector<cv::Mat> &R_arkit_cv, // CV_32F 3x3 OpenCV camera rotations
    const std::vector<cv::Mat> &matchImagesBGR,
    const std::vector<float> &yawDeg,
    const std::vector<float> &pitchDeg,
    const GonggiRegistrationConfig &config,
    const std::string &debugDirectory,
    std::vector<cv::detail::CameraParams> &camerasInOut,
    std::vector<cv::detail::MatchesInfo> &pairwiseNxNOut,
    std::vector<GonggiRegPairDebug> &pairDebugOut,
    GonggiRegistrationMetrics &metricsOut
);

/// iPhone 14 Plus guided-target overlap report (analysis only; does not change layout).
std::string GonggiCaptureOverlapAnalysisJSON();
