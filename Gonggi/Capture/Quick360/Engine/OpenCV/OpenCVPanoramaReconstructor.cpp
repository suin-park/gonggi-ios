//
//  OpenCVPanoramaReconstructor.cpp
//  Phase 2B/2C reconstruction (detail::* — not cv::Stitcher high-level).
//  Pure C++ (no ObjC) so OpenCV headers are not poisoned by YES/NO macros.
//

#include "OpenCVPanoramaReconstructor.hpp"

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/calib3d.hpp>
#include <opencv2/stitching/detail/matchers.hpp>
#include <opencv2/stitching/detail/camera.hpp>
#include <opencv2/stitching/detail/motion_estimators.hpp>
#include <opencv2/stitching/detail/warpers.hpp>
#include <opencv2/stitching/detail/exposure_compensate.hpp>
#include <opencv2/stitching/detail/seam_finders.hpp>
#include <opencv2/stitching/detail/blenders.hpp>
#include <opencv2/stitching/warpers.hpp>

#include <mach/mach.h>
#include <sys/stat.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <exception>
#include <fstream>
#include <functional>
#include <new>
#include <numeric>
#include <sstream>

using namespace cv;
using namespace cv::detail;

namespace {

constexpr float kPi = 3.14159265358979323846f;

double peakMemoryMB() {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return 0;
    }
    return static_cast<double>(info.phys_footprint) / (1024.0 * 1024.0);
}

double nowMs() {
    using clock = std::chrono::steady_clock;
    return std::chrono::duration<double, std::milli>(clock::now().time_since_epoch()).count();
}

Matx33f gonggiToOpenCVCamera() {
    // Gonggi/ARKit: X right, Y up, −Z forward. OpenCV: X right, Y down, +Z forward.
    return Matx33f(1, 0, 0, 0, -1, 0, 0, 0, -1);
}

Mat rowMajor9ToMat3(const float *r9) {
    Mat R(3, 3, CV_32F);
    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 3; ++c) {
            R.at<float>(r, c) = r9[r * 3 + c];
        }
    }
    return R;
}

Mat gonggiRToOpenCVR(const float *r9_gonggi) {
    Mat Rg = rowMajor9ToMat3(r9_gonggi);
    Mat D;
    Mat(gonggiToOpenCVCamera()).convertTo(D, CV_32F);
    // world = Rg * p_g = Rcv * D * p_g  ⇒  Rcv = Rg * D^{-1} = Rg * D
    return Rg * D;
}

float rotationAngleDeg(const Mat &Ra, const Mat &Rb) {
    Mat Rrel = Ra.t() * Rb;
    float tr = static_cast<float>(trace(Rrel)[0]);
    float c = std::max(-1.f, std::min(1.f, (tr - 1.f) * 0.5f));
    return std::acos(c) * 180.f / kPi;
}

float angularDistanceDeg(float yawA, float pitchA, float yawB, float pitchB) {
    // Unit directions in CaptureBasis-style yaw/pitch.
    float ya = yawA * kPi / 180.f, pa = pitchA * kPi / 180.f;
    float yb = yawB * kPi / 180.f, pb = pitchB * kPi / 180.f;
    float cpa = std::cos(pa), cpb = std::cos(pb);
    Vec3f a(std::sin(ya) * cpa, std::sin(pa), std::cos(ya) * cpa);
    Vec3f b(std::sin(yb) * cpb, std::sin(pb), std::cos(yb) * cpb);
    float d = std::max(-1.f, std::min(1.f, a.dot(b)));
    return std::acos(d) * 180.f / kPi;
}

float estimateHFovDeg(float fx, int width) {
    return 2.f * std::atan(0.5f * width / std::max(fx, 1.f)) * 180.f / kPi;
}

float estimateVFovDeg(float fy, int height) {
    return 2.f * std::atan(0.5f * height / std::max(fy, 1.f)) * 180.f / kPi;
}

float expectedOverlap(float fovDeg, float separationDeg) {
    float o = fovDeg - std::abs(separationDeg);
    return std::max(0.f, o / std::max(fovDeg, 1.f));
}

struct PairCandidate {
    int i, j;
    float angularDeg;
    float overlap;
};

std::vector<PairCandidate> selectPairs(const std::vector<GonggiOpenCVFrameInput> &frames) {
    const int n = static_cast<int>(frames.size());
    std::vector<PairCandidate> pairs;
    if (n < 2) return pairs;

    // Bucket by pitch band for neighbor selection.
    std::vector<int> order(n);
    std::iota(order.begin(), order.end(), 0);
    std::sort(order.begin(), order.end(), [&](int a, int b) {
        if (std::abs(frames[a].pitchDeg - frames[b].pitchDeg) > 8.f) {
            return frames[a].pitchDeg > frames[b].pitchDeg;
        }
        return frames[a].yawDeg < frames[b].yawDeg;
    });

    auto maybeAdd = [&](int i, int j) {
        if (i == j) return;
        if (i > j) std::swap(i, j);
        for (const auto &p : pairs) {
            if (p.i == i && p.j == j) return;
        }
        float ang = angularDistanceDeg(
            frames[i].yawDeg, frames[i].pitchDeg,
            frames[j].yawDeg, frames[j].pitchDeg
        );
        float hfov = 0.5f * (estimateHFovDeg(frames[i].fx, frames[i].width)
            + estimateHFovDeg(frames[j].fx, frames[j].width));
        float ov = expectedOverlap(hfov, ang);
        // Keep geometrically plausible overlaps (≥ ~15%).
        if (ov < 0.15f && ang > 55.f) return;
        pairs.push_back({i, j, ang, ov});
    };

    // Same-ring neighbors + next-neighbors by sorted yaw within pitch bands.
    for (int a = 0; a < n; ++a) {
        std::vector<int> ring;
        for (int b = 0; b < n; ++b) {
            if (std::abs(frames[a].pitchDeg - frames[b].pitchDeg) <= 18.f) {
                ring.push_back(b);
            }
        }
        std::sort(ring.begin(), ring.end(), [&](int x, int y) {
            return frames[x].yawDeg < frames[y].yawDeg;
        });
        for (size_t k = 0; k < ring.size(); ++k) {
            maybeAdd(ring[k], ring[(k + 1) % ring.size()]);
            if (ring.size() > 2) {
                maybeAdd(ring[k], ring[(k + 2) % ring.size()]);
            }
        }
    }

    // Cross-band: horizon ↔ upper/lower, upper/lower ↔ poles.
    for (int i = 0; i < n; ++i) {
        for (int j = i + 1; j < n; ++j) {
            float dp = std::abs(frames[i].pitchDeg - frames[j].pitchDeg);
            float dy = std::abs(frames[i].yawDeg - frames[j].yawDeg);
            if (dy > 180.f) dy = 360.f - dy;
            if (dp >= 25.f && dp <= 55.f && dy <= 40.f) {
                maybeAdd(i, j);
            }
            // Pole-ish frames: |pitch| > 60
            bool poleI = std::abs(frames[i].pitchDeg) > 60.f;
            bool poleJ = std::abs(frames[j].pitchDeg) > 60.f;
            if ((poleI || poleJ) && angularDistanceDeg(
                    frames[i].yawDeg, frames[i].pitchDeg,
                    frames[j].yawDeg, frames[j].pitchDeg) < 70.f) {
                maybeAdd(i, j);
            }
        }
    }

    return pairs;
}

void ensureDir(const std::string &path) {
    if (path.empty()) return;
    std::string cur;
    for (size_t i = 0; i < path.size(); ++i) {
        char ch = path[i];
        cur.push_back(ch);
        if (ch == '/' || i + 1 == path.size()) {
            if (cur == "/" || cur.empty()) continue;
            // Trim trailing slash for mkdir except root.
            std::string dir = cur;
            while (dir.size() > 1 && dir.back() == '/') dir.pop_back();
            ::mkdir(dir.c_str(), 0755);
        }
    }
}

void writeText(const std::string &path, const std::string &text) {
    if (path.empty()) return;
    std::ofstream out(path);
    out << text;
}

std::string metricsToJSON(const GonggiOpenCVStitchMetrics &m) {
    std::ostringstream o;
    o << "{"
      << "\"success\":" << (m.success ? "true" : "false") << ","
      << "\"errorMessage\":\"" << m.errorMessage << "\","
      << "\"inputKeyframeCount\":" << m.inputKeyframeCount << ","
      << "\"matchedPairCount\":" << m.matchedPairCount << ","
      << "\"failedPairCount\":" << m.failedPairCount << ","
      << "\"averageRawMatches\":" << m.averageRawMatches << ","
      << "\"averageFilteredMatches\":" << m.averageFilteredMatches << ","
      << "\"averageInliers\":" << m.averageInliers << ","
      << "\"averageInlierRatio\":" << m.averageInlierRatio << ","
      << "\"cameraGraphEdges\":" << m.cameraGraphEdges << ","
      << "\"connectedComponents\":" << m.connectedComponents << ","
      << "\"bundleAdjustmentConverged\":" << (m.bundleAdjustmentConverged ? "true" : "false") << ","
      << "\"bundleAdjustmentBeforeError\":" << m.bundleAdjustmentBeforeError << ","
      << "\"bundleAdjustmentAfterError\":" << m.bundleAdjustmentAfterError << ","
      << "\"optimizedCameraCount\":" << m.optimizedCameraCount << ","
      << "\"rejectedCameraCount\":" << m.rejectedCameraCount << ","
      << "\"averageVisualCorrectionDeg\":" << m.averageVisualCorrectionDeg << ","
      << "\"maxVisualCorrectionDeg\":" << m.maxVisualCorrectionDeg << ","
      << "\"averageOverlap\":" << m.averageOverlap << ","
      << "\"featureTimeMs\":" << m.featureTimeMs << ","
      << "\"matchingTimeMs\":" << m.matchingTimeMs << ","
      << "\"bundleAdjustmentTimeMs\":" << m.bundleAdjustmentTimeMs << ","
      << "\"warpTimeMs\":" << m.warpTimeMs << ","
      << "\"exposureTimeMs\":" << m.exposureTimeMs << ","
      << "\"seamTimeMs\":" << m.seamTimeMs << ","
      << "\"blendTimeMs\":" << m.blendTimeMs << ","
      << "\"encodeTimeMs\":" << m.encodeTimeMs << ","
      << "\"totalTimeMs\":" << m.processingTimeMs << ","
      << "\"peakMemoryMB\":" << m.peakMemoryMB << ","
      << "\"memoryArchitecture\":\"" << m.memoryArchitecture << "\","
      << "\"maxLoadedFullResCount\":" << m.maxLoadedFullResCount << ","
      << "\"maxWarpedResidentCount\":" << m.maxWarpedResidentCount << ","
      << "\"memoryStartMB\":" << m.memoryStartMB << ","
      << "\"memoryAfterLoadMB\":" << m.memoryAfterLoadMB << ","
      << "\"memoryAfterFeatureMB\":" << m.memoryAfterFeatureMB << ","
      << "\"memoryAfterMatchMB\":" << m.memoryAfterMatchMB << ","
      << "\"memoryAfterBAMB\":" << m.memoryAfterBAMB << ","
      << "\"memoryAfterWarpMB\":" << m.memoryAfterWarpMB << ","
      << "\"memoryBeforeExposureMB\":" << m.memoryBeforeExposureMB << ","
      << "\"memoryAfterExposureMB\":" << m.memoryAfterExposureMB << ","
      << "\"memoryBeforeSeamMB\":" << m.memoryBeforeSeamMB << ","
      << "\"memoryAfterSeamMB\":" << m.memoryAfterSeamMB << ","
      << "\"memoryBeforeBlendMB\":" << m.memoryBeforeBlendMB << ","
      << "\"memoryAfterBlendMB\":" << m.memoryAfterBlendMB << ","
      << "\"memoryAfterEncodeMB\":" << m.memoryAfterEncodeMB << ","
      << "\"exposureAnalysisLongEdgeUsed\":" << m.exposureAnalysisLongEdgeUsed << ","
      << "\"seamAnalysisLongEdgeUsed\":" << m.seamAnalysisLongEdgeUsed << ","
      << "\"blendBandsUsed\":" << m.blendBandsUsed << ","
      << "\"holePercent\":" << m.holePercent << ","
      << "\"zenithHolePercent\":" << m.zenithHolePercent << ","
      << "\"nadirHolePercent\":" << m.nadirHolePercent << ","
      << "\"outputResolution\":\"" << m.outputResolution << "\","
      << "\"outputFileSizeMB\":" << m.outputFileSizeMB << ","
      << "\"featureDetector\":\"" << m.featureDetector << "\","
      << "\"featureMatcher\":\"" << m.featureMatcher << "\","
      << "\"exposureMode\":\"" << m.exposureMode << "\","
      << "\"seamFinder\":\"" << m.seamFinder << "\","
      << "\"blender\":\"" << m.blender << "\""
      << "}";
    return o.str();
}

void noteMemory(GonggiOpenCVStitchMetrics &metrics, double &slot) {
    slot = peakMemoryMB();
    metrics.peakMemoryMB = std::max(metrics.peakMemoryMB, slot);
}

float uniformAnalysisScale(const std::vector<Mat> &imgs, float targetLongEdge) {
    int maxLE = 1;
    for (const auto &m : imgs) {
        if (!m.empty()) {
            maxLE = std::max(maxLE, std::max(m.cols, m.rows));
        }
    }
    return std::min(1.f, targetLongEdge / static_cast<float>(std::max(maxLE, 1)));
}

std::string cameraParamsJSON(const std::vector<CameraParams> &cams) {
    std::ostringstream o;
    o << "{\"cameras\":[";
    for (size_t i = 0; i < cams.size(); ++i) {
        Mat R;
        cams[i].R.convertTo(R, CV_32F);
        o << "{\"index\":" << i
          << ",\"focal\":" << cams[i].focal
          << ",\"ppx\":" << cams[i].ppx
          << ",\"ppy\":" << cams[i].ppy
          << ",\"R\":[";
        for (int r = 0; r < 3; ++r) {
            for (int c = 0; c < 3; ++c) {
                if (r || c) o << ",";
                o << R.at<float>(r, c);
            }
        }
        o << "]}";
        if (i + 1 < cams.size()) o << ",";
    }
    o << "]}";
    return o.str();
}

// Re-center so camera 0 looks at panorama center (first-forward → U≈0.5).
void anchorFirstForward(std::vector<CameraParams> &cameras) {
    if (cameras.empty()) return;
    Mat R0;
    cameras[0].R.convertTo(R0, CV_32F);
    Mat R0inv = R0.inv();
    for (auto &cam : cameras) {
        Mat R;
        cam.R.convertTo(R, CV_32F);
        Mat Rn = R * R0inv;
        Rn.convertTo(cam.R, cam.R.type());
    }
}

/// Jetsam-safe stage checkpoint — flush every major stage immediately.
struct MemoryTrace {
    std::string path;
    void open(const std::string &dir) {
        if (dir.empty()) return;
        ensureDir(dir);
        path = dir + "/memory_trace.jsonl";
        // Truncate previous incomplete run for this session debug dir.
        std::ofstream(path, std::ios::trunc);
    }
    void checkpoint(
        const char *stage,
        int keyframeIndex = -1,
        int loadedFullResCount = 0,
        int warpedResidentCount = 0
    ) {
        if (path.empty()) return;
        std::ostringstream o;
        o << "{"
          << "\"stage\":\"" << stage << "\","
          << "\"timestamp\":" << nowMs() << ","
          << "\"physFootprintMB\":" << peakMemoryMB() << ","
          << "\"keyframeIndex\":" << keyframeIndex << ","
          << "\"loadedFullResCount\":" << loadedFullResCount << ","
          << "\"warpedResidentCount\":" << warpedResidentCount
          << "}\n";
        std::ofstream out(path, std::ios::app);
        out << o.str();
        out.flush();
    }
};

Mat cameraK(const CameraParams &cam) {
    Mat K = Mat::eye(3, 3, CV_32F);
    K.at<float>(0, 0) = static_cast<float>(cam.focal);
    K.at<float>(0, 2) = static_cast<float>(cam.ppx);
    K.at<float>(1, 1) = static_cast<float>(cam.focal * cam.aspect);
    K.at<float>(1, 2) = static_cast<float>(cam.ppy);
    return K;
}

} // namespace

static bool GonggiOpenCVStitchPanoramaImpl(
    const std::vector<GonggiOpenCVFrameInput> &frames,
    const GonggiOpenCVStitchConfig &config,
    GonggiOpenCVStitchMetrics &metrics
) {
    const double tAll = nowMs();
    metrics = GonggiOpenCVStitchMetrics();
    metrics.inputKeyframeCount = static_cast<int>(frames.size());
    noteMemory(metrics, metrics.memoryStartMB);
    metrics.featureDetector = "AKAZE";
    metrics.featureMatcher = "BF_HAMMING_KNN";
    metrics.exposureMode = "Gain";
    metrics.seamFinder = "GraphCutColorGrad";
    metrics.blender = "MultiBand";
    metrics.memoryArchitecture = "two_pass_streaming";
    metrics.blendBandsUsed = config.blendBands;
    metrics.exposureAnalysisLongEdgeUsed = config.exposureAnalysisLongEdge;
    metrics.seamAnalysisLongEdgeUsed = config.seamAnalysisLongEdge;

    MemoryTrace trace;
    trace.open(config.debugDirectory);
    trace.checkpoint("start", -1, 0, 0);

    auto fail = [&](const std::string &msg) {
        metrics.success = false;
        metrics.errorMessage = msg;
        metrics.processingTimeMs = nowMs() - tAll;
        metrics.peakMemoryMB = std::max(metrics.peakMemoryMB, peakMemoryMB());
        if (!config.debugDirectory.empty()) {
            ensureDir(config.debugDirectory);
            writeText(config.debugDirectory + "/metrics.json", metricsToJSON(metrics));
        }
        trace.checkpoint("fail", -1, metrics.maxLoadedFullResCount, metrics.maxWarpedResidentCount);
        return false;
    };

    if (frames.empty()) return fail("empty keyframes");
    if (config.outputWidth <= 0 || config.outputHeight <= 0) return fail("invalid output size");
    if (config.outputWidth != 2 * config.outputHeight) return fail("output must be 2:1");

    ensureDir(config.debugDirectory);
    if (!config.debugDirectory.empty()) {
        ensureDir(config.debugDirectory + "/matches");
        ensureDir(config.debugDirectory + "/warped");
        ensureDir(config.debugDirectory + "/masks");
        ensureDir(config.debugDirectory + "/seams");
    }

    const int n = static_cast<int>(frames.size());

    // =====================================================================
    // PASS A — analysis on proxy only (no fullImages[N], no full-res warped[N])
    // =====================================================================
    std::vector<Mat> matchImages(n), matchGray(n);
    std::vector<float> matchScale(n, 1.f);
    std::vector<Size> nativeSizes(n);
    std::vector<Mat> K_full(n), K_match(n), R0_cv(n);

    for (int i = 0; i < n; ++i) {
        // Load one JPEG, downscale to proxy, release full-res immediately.
        Mat bgr = imread(frames[i].jpegPath, IMREAD_COLOR);
        if (bgr.empty()) {
            return fail("failed to read keyframe: " + frames[i].jpegPath);
        }
        metrics.maxLoadedFullResCount = std::max(metrics.maxLoadedFullResCount, 1);
        nativeSizes[i] = bgr.size();

        Mat K = Mat::eye(3, 3, CV_32F);
        K.at<float>(0, 0) = frames[i].fx;
        K.at<float>(1, 1) = frames[i].fy;
        K.at<float>(0, 2) = frames[i].cx;
        K.at<float>(1, 2) = frames[i].cy;
        float sx = static_cast<float>(bgr.cols) / std::max(frames[i].width, 1);
        float sy = static_cast<float>(bgr.rows) / std::max(frames[i].height, 1);
        K.at<float>(0, 0) *= sx;
        K.at<float>(0, 2) *= sx;
        K.at<float>(1, 1) *= sy;
        K.at<float>(1, 2) *= sy;
        K_full[i] = K.clone();

        const float longEdge = static_cast<float>(std::max(bgr.cols, bgr.rows));
        float scale = std::min(1.f, config.matchLongEdge / std::max(longEdge, 1.f));
        matchScale[i] = scale;
        if (scale < 0.999f) {
            resize(bgr, matchImages[i], Size(), scale, scale, INTER_AREA);
        } else {
            matchImages[i] = bgr.clone();
        }
        bgr.release(); // full-res gone — analysis keeps proxy only

        K_match[i] = K.clone();
        K_match[i].at<float>(0, 0) *= scale;
        K_match[i].at<float>(0, 2) *= scale;
        K_match[i].at<float>(1, 1) *= scale;
        K_match[i].at<float>(1, 2) *= scale;
        R0_cv[i] = gonggiRToOpenCVR(frames[i].R_gonggi);
        cvtColor(matchImages[i], matchGray[i], COLOR_BGR2GRAY);
    }
    noteMemory(metrics, metrics.memoryAfterLoadMB);
    trace.checkpoint("analysisLoad", -1, 0, 0);

    // ---- Features (AKAZE) ----
    const double tFeat0 = nowMs();
    Ptr<AKAZE> akaze = AKAZE::create(AKAZE::DESCRIPTOR_MLDB, 0, 3, 0.001f);
    std::vector<ImageFeatures> features(n);
    for (int i = 0; i < n; ++i) {
        features[i].img_idx = i;
        features[i].img_size = matchImages[i].size();
        akaze->detectAndCompute(matchGray[i], noArray(), features[i].keypoints, features[i].descriptors);
        matchGray[i].release();
    }
    matchGray.clear();
    metrics.featureTimeMs = nowMs() - tFeat0;
    noteMemory(metrics, metrics.memoryAfterFeatureMB);
    trace.checkpoint("features", -1, 0, 0);

    // ---- Pair selection + matching (unchanged logic) ----
    const double tMatch0 = nowMs();
    auto pairCands = selectPairs(frames);
    Ptr<DescriptorMatcher> matcher = BFMatcher::create(NORM_HAMMING, false);

    std::vector<MatchesInfo> pairwise;
    double sumRaw = 0, sumFilt = 0, sumInliers = 0, sumInlierRatio = 0, sumOverlap = 0;
    int matched = 0, failed = 0;

    for (const auto &pc : pairCands) {
        MatchesInfo mi;
        mi.src_img_idx = pc.i;
        mi.dst_img_idx = pc.j;

        if (features[pc.i].descriptors.empty() || features[pc.j].descriptors.empty()) {
            mi.confidence = 0;
            pairwise.push_back(mi);
            failed++;
            continue;
        }

        std::vector<std::vector<DMatch>> knn;
        matcher->knnMatch(features[pc.i].descriptors, features[pc.j].descriptors, knn, 2);
        std::vector<DMatch> good;
        for (const auto &v : knn) {
            if (v.size() >= 2 && v[0].distance < 0.75f * v[1].distance) {
                good.push_back(v[0]);
            }
        }
        std::vector<std::vector<DMatch>> knnBack;
        matcher->knnMatch(features[pc.j].descriptors, features[pc.i].descriptors, knnBack, 2);
        std::vector<DMatch> mutualGood;
        for (const auto &m : good) {
            bool ok = false;
            if (m.trainIdx >= 0 && m.trainIdx < static_cast<int>(knnBack.size())) {
                const auto &back = knnBack[m.trainIdx];
                if (!back.empty() && back[0].trainIdx == m.queryIdx) ok = true;
            }
            if (ok) mutualGood.push_back(m);
        }
        good.swap(mutualGood);
        mi.matches = good;
        int rawCount = static_cast<int>(knn.size());
        int filtCount = static_cast<int>(good.size());

        std::vector<Point2f> pts1, pts2;
        pts1.reserve(good.size());
        pts2.reserve(good.size());
        for (const auto &m : good) {
            pts1.push_back(features[pc.i].keypoints[m.queryIdx].pt);
            pts2.push_back(features[pc.j].keypoints[m.trainIdx].pt);
        }

        Mat inlierMask;
        int inliers = 0;
        Mat H;
        bool geomOK = false;
        if (pts1.size() >= 8) {
            H = findHomography(pts1, pts2, RANSAC, 3.0, inlierMask, 2000, 0.995);
            if (!inlierMask.empty()) {
                inliers = countNonZero(inlierMask);
            }
        }

        float inlierRatio = filtCount > 0 ? static_cast<float>(inliers) / filtCount : 0.f;
        mi.num_inliers = inliers;
        mi.confidence = inlierRatio;

        if (!H.empty() && inliers >= config.minInliers && inlierRatio >= config.minInlierRatio) {
            std::vector<Mat> Rs, Ts, Ns;
            Mat Km64;
            K_match[pc.i].convertTo(Km64, CV_64F);
            int nsols = 0;
            try {
                nsols = decomposeHomographyMat(H, Km64, Rs, Ts, Ns);
            } catch (...) {
                nsols = 0;
            }
            Mat Ri, Rj, Rprior;
            R0_cv[pc.i].convertTo(Ri, CV_64F);
            R0_cv[pc.j].convertTo(Rj, CV_64F);
            Rprior = Ri.t() * Rj;
            double bestAng = 1e9;
            int best = -1;
            for (int s = 0; s < nsols; ++s) {
                double ang = rotationAngleDeg(Mat(Rprior), Rs[s]);
                if (ang < bestAng) {
                    bestAng = ang;
                    best = s;
                }
            }
            if (best >= 0 && bestAng <= config.maxVisualCorrectionDeg * 2.5) {
                mi.H = H;
                mi.confidence = std::max(mi.confidence, 0.55);
                mi.inliers_mask.assign(good.size(), 0);
                if (!inlierMask.empty()) {
                    for (size_t k = 0; k < good.size() && k < static_cast<size_t>(inlierMask.rows); ++k) {
                        mi.inliers_mask[k] = inlierMask.at<uchar>(static_cast<int>(k)) ? 1 : 0;
                    }
                }
                geomOK = true;
            }
        }

        if (!geomOK) {
            failed++;
            mi.confidence = 0;
        } else {
            matched++;
            sumRaw += rawCount;
            sumFilt += filtCount;
            sumInliers += inliers;
            sumInlierRatio += inlierRatio;
            sumOverlap += pc.overlap;
        }
        pairwise.push_back(mi);

        if (!config.debugDirectory.empty()) {
            std::ostringstream name;
            name << config.debugDirectory << "/matches/pair_" << pc.i << "_" << pc.j << ".txt";
            std::ostringstream body;
            body << "angularDeg=" << pc.angularDeg << " overlap=" << pc.overlap
                 << " raw=" << rawCount << " filtered=" << filtCount
                 << " inliers=" << inliers << " ratio=" << inlierRatio
                 << " ok=" << (geomOK ? 1 : 0) << "\n";
            writeText(name.str(), body.str());
        }
    }

    metrics.matchingTimeMs = nowMs() - tMatch0;
    metrics.matchedPairCount = matched;
    metrics.failedPairCount = failed;
    if (matched > 0) {
        metrics.averageRawMatches = sumRaw / matched;
        metrics.averageFilteredMatches = sumFilt / matched;
        metrics.averageInliers = sumInliers / matched;
        metrics.averageInlierRatio = sumInlierRatio / matched;
        metrics.averageOverlap = sumOverlap / matched;
    }
    metrics.cameraGraphEdges = matched;
    noteMemory(metrics, metrics.memoryAfterMatchMB);
    trace.checkpoint("matching", -1, 0, 0);

    // Connected components
    std::vector<int> parent(n);
    std::iota(parent.begin(), parent.end(), 0);
    std::function<int(int)> find = [&](int x) {
        return parent[x] == x ? x : parent[x] = find(parent[x]);
    };
    auto unite = [&](int a, int b) {
        a = find(a); b = find(b);
        if (a != b) parent[b] = a;
    };
    for (const auto &mi : pairwise) {
        if (mi.confidence > 0 && mi.num_inliers >= config.minInliers) {
            unite(mi.src_img_idx, mi.dst_img_idx);
        }
    }
    std::vector<int> roots;
    for (int i = 0; i < n; ++i) roots.push_back(find(i));
    std::sort(roots.begin(), roots.end());
    roots.erase(std::unique(roots.begin(), roots.end()), roots.end());
    metrics.connectedComponents = static_cast<int>(roots.size());

    // ---- Camera init from ARKit prior (full-res intrinsics for final warp) ----
    std::vector<CameraParams> cameras(n);
    std::vector<CameraParams> camerasProxy(n);
    for (int i = 0; i < n; ++i) {
        cameras[i].focal = 0.5f * (K_full[i].at<float>(0, 0) + K_full[i].at<float>(1, 1));
        cameras[i].ppx = K_full[i].at<float>(0, 2);
        cameras[i].ppy = K_full[i].at<float>(1, 2);
        cameras[i].aspect = K_full[i].at<float>(1, 1) / std::max(K_full[i].at<float>(0, 0), 1.f);
        R0_cv[i].convertTo(cameras[i].R, CV_32F);
        cameras[i].t = Mat::zeros(3, 1, CV_32F);

        camerasProxy[i].focal = 0.5f * (K_match[i].at<float>(0, 0) + K_match[i].at<float>(1, 1));
        camerasProxy[i].ppx = K_match[i].at<float>(0, 2);
        camerasProxy[i].ppy = K_match[i].at<float>(1, 2);
        camerasProxy[i].aspect = K_match[i].at<float>(1, 1) / std::max(K_match[i].at<float>(0, 0), 1.f);
        R0_cv[i].convertTo(camerasProxy[i].R, CV_32F);
        camerasProxy[i].t = Mat::zeros(3, 1, CV_32F);
    }
    if (!config.debugDirectory.empty()) {
        writeText(config.debugDirectory + "/camera_before.json", cameraParamsJSON(cameras));
    }

    std::vector<MatchesInfo> baMatches;
    for (const auto &mi : pairwise) {
        if (mi.confidence > 0 && mi.num_inliers >= config.minInliers) {
            baMatches.push_back(mi);
        }
    }

    const double tBA0 = nowMs();
    double errBefore = 0, errAfter = 0;
    bool baOK = false;

    if (n == 1) {
        baOK = true;
        metrics.optimizedCameraCount = 1;
    } else if (!baMatches.empty()) {
        Ptr<BundleAdjusterBase> adjuster = makePtr<BundleAdjusterRay>();
        adjuster->setConfThresh(0.15);
        std::vector<CameraParams> camsBefore = camerasProxy;
        try {
            bool ran = (*adjuster)(features, baMatches, camerasProxy);
            baOK = ran;
            double sumCorr = 0, maxCorr = 0;
            int corrN = 0;
            for (int i = 0; i < n; ++i) {
                Mat Ra, Rb;
                camsBefore[i].R.convertTo(Ra, CV_32F);
                camerasProxy[i].R.convertTo(Rb, CV_32F);
                double ang = rotationAngleDeg(Ra, Rb);
                if (ang > config.maxVisualCorrectionDeg) {
                    camerasProxy[i] = camsBefore[i];
                    metrics.rejectedCameraCount++;
                    ang = 0;
                } else {
                    metrics.optimizedCameraCount++;
                    sumCorr += ang;
                    maxCorr = std::max(maxCorr, ang);
                    corrN++;
                }
                errAfter += ang;
            }
            errBefore = 0;
            if (corrN > 0) {
                metrics.averageVisualCorrectionDeg = sumCorr / corrN;
            }
            metrics.maxVisualCorrectionDeg = maxCorr;
            metrics.bundleAdjustmentBeforeError = errBefore;
            metrics.bundleAdjustmentAfterError = errAfter / std::max(n, 1);
        } catch (const cv::Exception &ex) {
            camerasProxy = camsBefore;
            metrics.errorMessage = std::string("BA exception: ") + ex.what();
            baOK = false;
        }
    } else {
        metrics.optimizedCameraCount = n;
        baOK = true;
        metrics.errorMessage = "no confident visual pairs; using ARKit prior only";
    }
    // Propagate optimized rotations to full-res cameras (intrinsics stay full-res).
    for (int i = 0; i < n; ++i) {
        camerasProxy[i].R.copyTo(cameras[i].R);
    }
    metrics.bundleAdjustmentTimeMs = nowMs() - tBA0;
    metrics.bundleAdjustmentConverged = baOK;
    noteMemory(metrics, metrics.memoryAfterBAMB);
    trace.checkpoint("BA", -1, 0, 0);

    // Features no longer needed after BA.
    features.clear();
    features.shrink_to_fit();
    pairwise.clear();
    baMatches.clear();

    anchorFirstForward(cameras);
    anchorFirstForward(camerasProxy);

    if (!config.debugDirectory.empty()) {
        writeText(config.debugDirectory + "/camera_after.json", cameraParamsJSON(cameras));
        std::ostringstream g;
        g << "{\"edges\":" << metrics.cameraGraphEdges
          << ",\"components\":" << metrics.connectedComponents
          << ",\"nodes\":" << n << "}\n";
        writeText(config.debugDirectory + "/camera_graph.json", g.str());
    }

    // Soft memory budget → analysis resolution / blend bands
    float exposureLE = config.exposureAnalysisLongEdge;
    float seamLE = config.seamAnalysisLongEdge;
    int blendBands = std::max(2, config.blendBands);
    if (metrics.peakMemoryMB >= config.memoryCriticalMB) {
        exposureLE = std::min(exposureLE, 384.f);
        seamLE = std::min(seamLE, 384.f);
        blendBands = 2;
    } else if (metrics.peakMemoryMB >= config.memoryWarnMB) {
        exposureLE = std::min(exposureLE, 512.f);
        seamLE = std::min(seamLE, 512.f);
        blendBands = std::min(blendBands, 3);
    }
    metrics.exposureAnalysisLongEdgeUsed = exposureLE;
    metrics.seamAnalysisLongEdgeUsed = seamLE;
    metrics.blendBandsUsed = blendBands;

    // ---- Proxy warp (matching-scale only) ----
    const double tWarp0 = nowMs();
    std::vector<double> focalsProxy;
    for (int i = 0; i < n; ++i) focalsProxy.push_back(camerasProxy[i].focal);
    std::nth_element(focalsProxy.begin(), focalsProxy.begin() + focalsProxy.size() / 2, focalsProxy.end());
    double proxyWarperScale = focalsProxy[focalsProxy.size() / 2];

    Ptr<WarperCreator> warperCreator = makePtr<cv::SphericalWarper>();
    Ptr<RotationWarper> proxyWarper = warperCreator->create(static_cast<float>(proxyWarperScale));

    std::vector<Point> proxyCorners(n);
    std::vector<Mat> proxyWarped(n), proxyMask(n);
    for (int i = 0; i < n; ++i) {
        Mat K = cameraK(camerasProxy[i]);
        Mat R;
        camerasProxy[i].R.convertTo(R, CV_32F);
        proxyCorners[i] = proxyWarper->warp(
            matchImages[i], K, R, INTER_LINEAR, BORDER_REFLECT, proxyWarped[i]
        );
        Mat mask = Mat::ones(matchImages[i].size(), CV_8U) * 255;
        if (frames[i].translationM > 0.35f) {
            // Scale erode kernel with proxy size
            int k = std::max(3, static_cast<int>(31 * matchScale[i]) | 1);
            erode(mask, mask, getStructuringElement(MORPH_ELLIPSE, Size(k, k)));
        }
        proxyCorners[i] = proxyWarper->warp(
            mask, K, R, INTER_NEAREST, BORDER_CONSTANT, proxyMask[i]
        );
        matchImages[i].release();
    }
    matchImages.clear();
    metrics.warpTimeMs = nowMs() - tWarp0;
    noteMemory(metrics, metrics.memoryAfterWarpMB);
    // maxWarpedResidentCount tracks full-res only (proxy N is analysis-only).
    trace.checkpoint("proxyWarp", -1, 0, 0);

    // ---- Exposure on (further) downscaled proxy — store scalar gains only ----
    metrics.memoryBeforeExposureMB = peakMemoryMB();
    metrics.peakMemoryMB = std::max(metrics.peakMemoryMB, metrics.memoryBeforeExposureMB);
    const double tExp0 = nowMs();
    std::vector<double> exposureGains(n, 1.0);
    {
        const float expScale = uniformAnalysisScale(proxyWarped, exposureLE);
        std::vector<Point> cornersLo(n);
        std::vector<UMat> imgsLo(n), masksLo(n);
        for (int i = 0; i < n; ++i) {
            Mat imgLo, maskLo;
            if (expScale < 0.999f) {
                resize(proxyWarped[i], imgLo, Size(), expScale, expScale, INTER_AREA);
                resize(proxyMask[i], maskLo, Size(), expScale, expScale, INTER_NEAREST);
            } else {
                imgLo = proxyWarped[i];
                maskLo = proxyMask[i];
            }
            cornersLo[i] = Point(
                cvRound(proxyCorners[i].x * expScale),
                cvRound(proxyCorners[i].y * expScale)
            );
            imgLo.copyTo(imgsLo[i]);
            maskLo.copyTo(masksLo[i]);
            if (expScale < 0.999f) {
                imgLo.release();
                maskLo.release();
            }
        }
        Ptr<ExposureCompensator> compensator =
            ExposureCompensator::createDefault(ExposureCompensator::GAIN);
        metrics.exposureMode = "Gain";
        compensator->feed(cornersLo, imgsLo, masksLo);
        if (auto *gc = dynamic_cast<GainCompensator *>(compensator.get())) {
            exposureGains = gc->gains();
        }
        imgsLo.clear();
        masksLo.clear();
    }
    metrics.exposureTimeMs = nowMs() - tExp0;
    noteMemory(metrics, metrics.memoryAfterExposureMB);
    trace.checkpoint("exposureAnalysis", -1, 0, 0);

    // ---- Seam on downscaled proxy — keep low-res seam masks only ----
    metrics.memoryBeforeSeamMB = peakMemoryMB();
    metrics.peakMemoryMB = std::max(metrics.peakMemoryMB, metrics.memoryBeforeSeamMB);
    const double tSeam0 = nowMs();
    std::vector<Mat> seamMasksLo(n);
    std::vector<Size> seamSizes(n);
    {
        const float seamScale = uniformAnalysisScale(proxyWarped, seamLE);
        std::vector<UMat> warpedF(n), masksF(n);
        std::vector<Point> cornersF(n);
        for (int i = 0; i < n; ++i) {
            Mat w8, w32, mLo;
            if (seamScale < 0.999f) {
                resize(proxyWarped[i], w8, Size(), seamScale, seamScale, INTER_AREA);
                resize(proxyMask[i], mLo, Size(), seamScale, seamScale, INTER_NEAREST);
            } else {
                w8 = proxyWarped[i];
                mLo = proxyMask[i];
            }
            w8.convertTo(w32, CV_32F);
            w32.copyTo(warpedF[i]);
            mLo.copyTo(masksF[i]);
            cornersF[i] = Point(
                cvRound(proxyCorners[i].x * seamScale),
                cvRound(proxyCorners[i].y * seamScale)
            );
            if (seamScale < 0.999f) {
                w8.release();
                w32.release();
                mLo.release();
            }
            // Free proxy warped as soon as copied into seam buffers.
            proxyWarped[i].release();
        }
        Ptr<SeamFinder> seamFinder;
        try {
            seamFinder = makePtr<GraphCutSeamFinder>(GraphCutSeamFinderBase::COST_COLOR_GRAD);
            metrics.seamFinder = "GraphCutColorGrad";
        } catch (...) {
            seamFinder = makePtr<DpSeamFinder>(DpSeamFinder::COLOR_GRAD);
            metrics.seamFinder = "DpColorGrad";
        }
        seamFinder->find(warpedF, cornersF, masksF);
        for (int i = 0; i < n; ++i) {
            masksF[i].copyTo(seamMasksLo[i]);
            seamSizes[i] = seamMasksLo[i].size();
            warpedF[i].release();
            masksF[i].release();
            proxyMask[i].release();
        }
    }
    proxyWarped.clear();
    proxyMask.clear();
    metrics.seamTimeMs = nowMs() - tSeam0;
    noteMemory(metrics, metrics.memoryAfterSeamMB);
    trace.checkpoint("seamAnalysis", -1, 0, 0);

    // =====================================================================
    // PASS B — streaming full-res: load → warp → gain → seam upscale → feed → release
    // =====================================================================
    metrics.memoryBeforeBlendMB = peakMemoryMB();
    metrics.peakMemoryMB = std::max(metrics.peakMemoryMB, metrics.memoryBeforeBlendMB);
    const double tBlend0 = nowMs();
    const int outW = config.outputWidth;
    const int outH = config.outputHeight;

    std::vector<double> focalsFull;
    for (int i = 0; i < n; ++i) focalsFull.push_back(cameras[i].focal);
    std::nth_element(focalsFull.begin(), focalsFull.begin() + focalsFull.size() / 2, focalsFull.end());
    double fullWarperScale = focalsFull[focalsFull.size() / 2];
    Ptr<RotationWarper> fullWarper = warperCreator->create(static_cast<float>(fullWarperScale));

    std::vector<Point> fullCorners(n);
    std::vector<Size> fullSizes(n);
    for (int i = 0; i < n; ++i) {
        Mat K = cameraK(cameras[i]);
        Mat R;
        cameras[i].R.convertTo(R, CV_32F);
        Rect roi = fullWarper->warpRoi(nativeSizes[i], K, R);
        fullCorners[i] = roi.tl();
        fullSizes[i] = roi.size();
    }
    Rect dstRoi = resultRoi(fullCorners, fullSizes);
    if (dstRoi.width < 10 || dstRoi.height < 10) {
        return fail("degenerate warp ROI");
    }

    Ptr<Blender> blender = Blender::createDefault(Blender::MULTI_BAND, false);
    if (MultiBandBlender *mb = dynamic_cast<MultiBandBlender *>(blender.get())) {
        mb->setNumBands(blendBands);
    }
    blender->prepare(dstRoi);

    int residentWarped = 0;
    for (int i = 0; i < n; ++i) {
        Mat full = imread(frames[i].jpegPath, IMREAD_COLOR);
        if (full.empty()) {
            return fail("failed to reload keyframe for render: " + frames[i].jpegPath);
        }
        metrics.maxLoadedFullResCount = std::max(metrics.maxLoadedFullResCount, 1);

        Mat K = cameraK(cameras[i]);
        Mat R;
        cameras[i].R.convertTo(R, CV_32F);

        Mat warped, warpedMask;
        Point corner = fullWarper->warp(full, K, R, INTER_LINEAR, BORDER_REFLECT, warped);
        full.release();

        Mat srcMask = Mat::ones(nativeSizes[i], CV_8U) * 255;
        if (frames[i].translationM > 0.35f) {
            erode(srcMask, srcMask, getStructuringElement(MORPH_ELLIPSE, Size(31, 31)));
        }
        corner = fullWarper->warp(srcMask, K, R, INTER_NEAREST, BORDER_CONSTANT, warpedMask);
        srcMask.release();
        fullCorners[i] = corner;
        fullSizes[i] = warped.size();
        residentWarped = 1;
        metrics.maxWarpedResidentCount = std::max(metrics.maxWarpedResidentCount, residentWarped);

        // Apply scalar gain from analysis pass.
        double g = (i < static_cast<int>(exposureGains.size())) ? exposureGains[i] : 1.0;
        if (std::abs(g - 1.0) > 1e-6) {
            multiply(warped, g, warped);
        }

        // Upscale seam mask + intersect coverage.
        Mat seamFull;
        if (!seamMasksLo[i].empty()) {
            resize(seamMasksLo[i], seamFull, warped.size(), 0, 0, INTER_NEAREST);
        } else {
            seamFull = Mat::ones(warped.size(), CV_8U) * 255;
        }
        bitwise_and(seamFull, warpedMask, warpedMask);
        seamFull.release();
        seamMasksLo[i].release();

        Mat warped16;
        warped.convertTo(warped16, CV_16S);
        warped.release();
        blender->feed(warped16, warpedMask, corner);
        warped16.release();
        warpedMask.release();
        residentWarped = 0;

        std::ostringstream stage;
        stage << "renderFrame_" << i;
        trace.checkpoint(stage.str().c_str(), i, 0, 0);
    }

    Mat result16, resultMask;
    blender->blend(result16, resultMask);
    blender.release();
    Mat result8;
    result16.convertTo(result8, CV_8U);
    result16.release();
    metrics.blendTimeMs = nowMs() - tBlend0;
    noteMemory(metrics, metrics.memoryAfterBlendMB);
    trace.checkpoint("blend", -1, 0, 0);

    if (!config.debugDirectory.empty()) {
        imwrite(config.debugDirectory + "/preblend_preview.jpg", result8);
        imwrite(config.debugDirectory + "/hole_mask.png", resultMask);
    }

    const double tEnc0 = nowMs();
    Mat pano;
    resize(result8, pano, Size(outW, outH), 0, 0, INTER_AREA);
    result8.release();
    Mat panoMask;
    if (!resultMask.empty()) {
        resize(resultMask, panoMask, Size(outW, outH), 0, 0, INTER_NEAREST);
        resultMask.release();
    } else {
        panoMask = Mat::ones(outH, outW, CV_8U) * 255;
    }

    int hole = 0, zenHole = 0, nadHole = 0;
    const int zenRows = std::max(1, outH / 10);
    const int nadStart = outH - zenRows;
    for (int y = 0; y < outH; ++y) {
        const uchar *row = panoMask.ptr<uchar>(y);
        for (int x = 0; x < outW; ++x) {
            if (row[x] == 0) {
                hole++;
                if (y < zenRows) zenHole++;
                if (y >= nadStart) nadHole++;
            }
        }
    }
    const double totalPx = static_cast<double>(outW) * outH;
    metrics.holePercent = 100.0 * hole / totalPx;
    metrics.zenithHolePercent = 100.0 * zenHole / (zenRows * outW);
    metrics.nadirHolePercent = 100.0 * nadHole / (zenRows * outW);

    for (int y = 0; y < outH; ++y) {
        uchar *row = pano.ptr<uchar>(y);
        const uchar *m = panoMask.ptr<uchar>(y);
        for (int x = 0; x < outW; ++x) {
            if (m[x] == 0) {
                row[x * 3 + 0] = 0;
                row[x * 3 + 1] = 0;
                row[x * 3 + 2] = 0;
            }
        }
    }

    std::vector<int> jpgParams = {IMWRITE_JPEG_QUALITY, 92};
    if (!imwrite(config.outputPath, pano, jpgParams)) {
        return fail("failed to write output JPEG");
    }
    metrics.encodeTimeMs = nowMs() - tEnc0;
    noteMemory(metrics, metrics.memoryAfterEncodeMB);
    trace.checkpoint("encode", -1, 0, 0);

    struct stat st {};
    if (::stat(config.outputPath.c_str(), &st) == 0) {
        metrics.outputFileSizeMB = static_cast<double>(st.st_size) / (1024.0 * 1024.0);
    }

    metrics.outputResolution = std::to_string(outW) + "x" + std::to_string(outH);
    metrics.success = true;
    metrics.errorMessage.clear();
    metrics.processingTimeMs = nowMs() - tAll;
    metrics.peakMemoryMB = std::max(metrics.peakMemoryMB, peakMemoryMB());

    if (!config.debugDirectory.empty()) {
        writeText(config.debugDirectory + "/metrics.json", metricsToJSON(metrics));
    }
    return true;
}

bool GonggiOpenCVStitchPanorama(
    const std::vector<GonggiOpenCVFrameInput> &frames,
    const GonggiOpenCVStitchConfig &config,
    GonggiOpenCVStitchMetrics &metrics
) {
    const double tAll = nowMs();
    try {
        return GonggiOpenCVStitchPanoramaImpl(frames, config, metrics);
    } catch (const cv::Exception &e) {
        metrics.success = false;
        metrics.errorMessage = std::string("cv::Exception: ") + e.what();
        metrics.processingTimeMs = nowMs() - tAll;
        metrics.peakMemoryMB = std::max(metrics.peakMemoryMB, peakMemoryMB());
        if (!config.debugDirectory.empty()) {
            ensureDir(config.debugDirectory);
            writeText(config.debugDirectory + "/metrics.json", metricsToJSON(metrics));
        }
        return false;
    } catch (const std::bad_alloc &e) {
        metrics.success = false;
        metrics.errorMessage = std::string("std::bad_alloc: ") + e.what();
        metrics.processingTimeMs = nowMs() - tAll;
        metrics.peakMemoryMB = std::max(metrics.peakMemoryMB, peakMemoryMB());
        if (!config.debugDirectory.empty()) {
            ensureDir(config.debugDirectory);
            writeText(config.debugDirectory + "/metrics.json", metricsToJSON(metrics));
        }
        return false;
    } catch (const std::exception &e) {
        metrics.success = false;
        metrics.errorMessage = std::string("std::exception: ") + e.what();
        metrics.processingTimeMs = nowMs() - tAll;
        metrics.peakMemoryMB = std::max(metrics.peakMemoryMB, peakMemoryMB());
        if (!config.debugDirectory.empty()) {
            ensureDir(config.debugDirectory);
            writeText(config.debugDirectory + "/metrics.json", metricsToJSON(metrics));
        }
        return false;
    } catch (...) {
        metrics.success = false;
        metrics.errorMessage = "unknown C++ exception in OpenCV stitch";
        metrics.processingTimeMs = nowMs() - tAll;
        metrics.peakMemoryMB = std::max(metrics.peakMemoryMB, peakMemoryMB());
        if (!config.debugDirectory.empty()) {
            ensureDir(config.debugDirectory);
            writeText(config.debugDirectory + "/metrics.json", metricsToJSON(metrics));
        }
        return false;
    }
}
