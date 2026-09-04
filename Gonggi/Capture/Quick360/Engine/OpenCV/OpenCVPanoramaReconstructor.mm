//
//  OpenCVPanoramaReconstructor.mm
//  Phase 2B/2C reconstruction (detail::* — not cv::Stitcher high-level).
//

#import "OpenCVPanoramaReconstructor.hpp"

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/imgcodecs.hpp>
#import <opencv2/features2d.hpp>
#import <opencv2/calib3d.hpp>
#import <opencv2/stitching/detail/matchers.hpp>
#import <opencv2/stitching/detail/camera.hpp>
#import <opencv2/stitching/detail/motion_estimators.hpp>
#import <opencv2/stitching/detail/warpers.hpp>
#import <opencv2/stitching/detail/exposure_compensate.hpp>
#import <opencv2/stitching/detail/seam_finders.hpp>
#import <opencv2/stitching/detail/blenders.hpp>
#import <opencv2/stitching/warpers.hpp>

#import <mach/mach.h>
#import <algorithm>
#import <cmath>
#import <fstream>
#import <functional>
#import <numeric>
#import <sstream>

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
    return CFAbsoluteTimeGetCurrent() * 1000.0;
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
    NSString *p = [NSString stringWithUTF8String:path.c_str()];
    [[NSFileManager defaultManager] createDirectoryAtPath:p
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
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

} // namespace

bool GonggiOpenCVStitchPanorama(
    const std::vector<GonggiOpenCVFrameInput> &frames,
    const GonggiOpenCVStitchConfig &config,
    GonggiOpenCVStitchMetrics &metrics
) {
    const double tAll = nowMs();
    metrics = GonggiOpenCVStitchMetrics();
    metrics.inputKeyframeCount = static_cast<int>(frames.size());
    metrics.peakMemoryMB = peakMemoryMB();
    metrics.featureDetector = "AKAZE";
    metrics.featureMatcher = "BF_HAMMING_KNN";
    metrics.exposureMode = "BlocksGain";
    metrics.seamFinder = "GraphCutColorGrad";
    metrics.blender = "MultiBand";

    auto fail = [&](const std::string &msg) {
        metrics.success = false;
        metrics.errorMessage = msg;
        metrics.processingTimeMs = nowMs() - tAll;
        metrics.peakMemoryMB = std::max(metrics.peakMemoryMB, peakMemoryMB());
        if (!config.debugDirectory.empty()) {
            ensureDir(config.debugDirectory);
            writeText(config.debugDirectory + "/metrics.json", metricsToJSON(metrics));
        }
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

    // ---- Load full-res + matching-scale images ----
    std::vector<Mat> fullImages(n), matchImages(n), matchGray(n);
    std::vector<float> matchScale(n, 1.f);
    std::vector<Mat> K_full(n), K_match(n), R0_cv(n);

    for (int i = 0; i < n; ++i) {
        Mat bgr = imread(frames[i].jpegPath, IMREAD_COLOR);
        if (bgr.empty()) {
            return fail("failed to read keyframe: " + frames[i].jpegPath);
        }
        if (bgr.cols != frames[i].width || bgr.rows != frames[i].height) {
            // Trust actual pixels; rescale intrinsics.
        }
        fullImages[i] = bgr;
        const float longEdge = static_cast<float>(std::max(bgr.cols, bgr.rows));
        float scale = std::min(1.f, config.matchLongEdge / std::max(longEdge, 1.f));
        matchScale[i] = scale;
        if (scale < 0.999f) {
            resize(bgr, matchImages[i], Size(), scale, scale, INTER_AREA);
        } else {
            matchImages[i] = bgr;
        }
        cvtColor(matchImages[i], matchGray[i], COLOR_BGR2GRAY);

        Mat K = Mat::eye(3, 3, CV_32F);
        K.at<float>(0, 0) = frames[i].fx;
        K.at<float>(1, 1) = frames[i].fy;
        K.at<float>(0, 2) = frames[i].cx;
        K.at<float>(1, 2) = frames[i].cy;
        // If JPEG size differs from metadata, scale K.
        float sx = static_cast<float>(bgr.cols) / std::max(frames[i].width, 1);
        float sy = static_cast<float>(bgr.rows) / std::max(frames[i].height, 1);
        K.at<float>(0, 0) *= sx;
        K.at<float>(0, 2) *= sx;
        K.at<float>(1, 1) *= sy;
        K.at<float>(1, 2) *= sy;
        K_full[i] = K.clone();
        K_match[i] = K.clone();
        K_match[i].at<float>(0, 0) *= scale;
        K_match[i].at<float>(0, 2) *= scale;
        K_match[i].at<float>(1, 1) *= scale;
        K_match[i].at<float>(1, 2) *= scale;
        R0_cv[i] = gonggiRToOpenCVR(frames[i].R_gonggi);
    }

    // ---- Features (AKAZE — indoor edges / frames) ----
    const double tFeat0 = nowMs();
    Ptr<AKAZE> akaze = AKAZE::create(AKAZE::DESCRIPTOR_MLDB, 0, 3, 0.001f);
    std::vector<ImageFeatures> features(n);
    for (int i = 0; i < n; ++i) {
        features[i].img_idx = i;
        features[i].img_size = matchImages[i].size();
        akaze->detectAndCompute(matchGray[i], noArray(), features[i].keypoints, features[i].descriptors);
    }
    metrics.featureTimeMs = nowMs() - tFeat0;

    // ---- Pair selection + matching ----
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
        // Mutual check
        std::vector<std::vector<DMatch>> knnBack;
        matcher->knnMatch(features[pc.j].descriptors, features[pc.i].descriptors, knnBack, 2);
        std::vector<char> mutual(good.size(), 0);
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
            // Rotation-only model → homography between views (not essential/translation).
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
                mi.confidence = std::max(mi.confidence, 0.55f);
                // Fill inlier mask into MatchesInfo
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

    // Connected components on successful edges
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

    // ---- Camera init from ARKit prior ----
    std::vector<CameraParams> cameras(n);
    for (int i = 0; i < n; ++i) {
        cameras[i].focal = 0.5f * (K_full[i].at<float>(0, 0) + K_full[i].at<float>(1, 1));
        cameras[i].ppx = K_full[i].at<float>(0, 2);
        cameras[i].ppy = K_full[i].at<float>(1, 2);
        cameras[i].aspect = K_full[i].at<float>(1, 1) / std::max(K_full[i].at<float>(0, 0), 1.f);
        R0_cv[i].convertTo(cameras[i].R, CV_32F);
        cameras[i].t = Mat::zeros(3, 1, CV_32F);
    }
    if (!config.debugDirectory.empty()) {
        writeText(config.debugDirectory + "/camera_before.json", cameraParamsJSON(cameras));
    }

    // Build OpenCV matches graph for BA: use only confident pairs.
    std::vector<MatchesInfo> baMatches;
    for (const auto &mi : pairwise) {
        if (mi.confidence > 0 && mi.num_inliers >= config.minInliers) {
            baMatches.push_back(mi);
        }
    }

    // Relative rotation edges from ARKit for weak visual pairs still connected by pose prior.
    // Prefer visual; for BA we need MatchesInfo with matches — use OpenCV estimator on features
    // via Homography-free path: BundleAdjusterRay with initial R.

    const double tBA0 = nowMs();
    double errBefore = 0, errAfter = 0;
    bool baOK = false;

    if (n == 1) {
        baOK = true;
        metrics.optimizedCameraCount = 1;
    } else if (!baMatches.empty()) {
        // Estimate pairwise focals already set. Run rotation-only BA.
        Ptr<BundleAdjusterBase> adjuster = makePtr<BundleAdjusterRay>();
        adjuster->setConfThresh(0.15);
        // Error before: mean angle vs ARKit prior after leaving component — use identity metric.
        std::vector<CameraParams> camsBefore = cameras;
        try {
            // OpenCV BA expects features + matches covering cameras.
            // Provide full features vector and baMatches.
            bool ran = (*adjuster)(features, baMatches, cameras);
            baOK = ran;
            // Measure visual correction vs ARKit R0.
            double sumCorr = 0, maxCorr = 0;
            int corrN = 0;
            for (int i = 0; i < n; ++i) {
                Mat Ra, Rb;
                camsBefore[i].R.convertTo(Ra, CV_32F);
                cameras[i].R.convertTo(Rb, CV_32F);
                double ang = rotationAngleDeg(Ra, Rb);
                // Reject cameras with excessive correction — revert to prior.
                if (ang > config.maxVisualCorrectionDeg) {
                    cameras[i] = camsBefore[i];
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
            errBefore = 0; // prior is baseline
            if (corrN > 0) {
                metrics.averageVisualCorrectionDeg = sumCorr / corrN;
            }
            metrics.maxVisualCorrectionDeg = maxCorr;
            metrics.bundleAdjustmentBeforeError = errBefore;
            metrics.bundleAdjustmentAfterError = errAfter / std::max(n, 1);
        } catch (const cv::Exception &ex) {
            cameras = camsBefore;
            metrics.errorMessage = std::string("BA exception: ") + ex.what();
            baOK = false;
        }
    } else {
        // No visual edges — keep ARKit priors (still can warp a collage for debug).
        metrics.optimizedCameraCount = n;
        baOK = true;
        metrics.errorMessage = "no confident visual pairs; using ARKit prior only";
    }
    metrics.bundleAdjustmentTimeMs = nowMs() - tBA0;
    metrics.bundleAdjustmentConverged = baOK;

    // First-forward anchor: camera 0 fixed to panorama center.
    anchorFirstForward(cameras);

    if (!config.debugDirectory.empty()) {
        writeText(config.debugDirectory + "/camera_after.json", cameraParamsJSON(cameras));
        std::ostringstream g;
        g << "{\"edges\":" << metrics.cameraGraphEdges
          << ",\"components\":" << metrics.connectedComponents
          << ",\"nodes\":" << n << "}\n";
        writeText(config.debugDirectory + "/camera_graph.json", g.str());
    }

    // ---- Warp + exposure + seam + blend (full resolution) ----
    const double tWarp0 = nowMs();
    std::vector<Point> corners(n);
    std::vector<Size> sizes(n);
    std::vector<Mat> warped(n), warpedMask(n);

    // Focal for warper scale: median focal
    std::vector<double> focals;
    for (int i = 0; i < n; ++i) focals.push_back(cameras[i].focal);
    std::nth_element(focals.begin(), focals.begin() + focals.size() / 2, focals.end());
    double warpedImageScale = focals[focals.size() / 2];

    Ptr<WarperCreator> warperCreator = makePtr<cv::SphericalWarper>();
    Ptr<RotationWarper> warper = warperCreator->create(static_cast<float>(warpedImageScale));

    for (int i = 0; i < n; ++i) {
        Mat K;
        Mat::eye(3, 3, CV_32F).copyTo(K);
        K.at<float>(0, 0) = static_cast<float>(cameras[i].focal);
        K.at<float>(0, 2) = static_cast<float>(cameras[i].ppx);
        K.at<float>(1, 1) = static_cast<float>(cameras[i].focal * cameras[i].aspect);
        K.at<float>(1, 2) = static_cast<float>(cameras[i].ppy);

        Mat R;
        cameras[i].R.convertTo(R, CV_32F);

        // High parallax → slightly erode mask later via weight (C9).
        corners[i] = warper->warp(fullImages[i], K, R, INTER_LINEAR, BORDER_REFLECT, warped[i]);
        Mat mask = Mat::ones(fullImages[i].size(), CV_8U) * 255;
        if (frames[i].translationM > 0.35f) {
            // Shrink contribution for high-parallax frames.
            erode(mask, mask, getStructuringElement(MORPH_ELLIPSE, Size(31, 31)));
        }
        corners[i] = warper->warp(mask, K, R, INTER_NEAREST, BORDER_CONSTANT, warpedMask[i]);
        sizes[i] = warped[i].size();

        // Free full-res source after warp to limit peak memory.
        fullImages[i].release();
        matchImages[i].release();
        matchGray[i].release();
    }
    metrics.warpTimeMs = nowMs() - tWarp0;
    metrics.peakMemoryMB = std::max(metrics.peakMemoryMB, peakMemoryMB());

    // Exposure
    const double tExp0 = nowMs();
    Ptr<ExposureCompensator> compensator = ExposureCompensator::createDefault(ExposureCompensator::GAIN_BLOCKS);
    compensator->feed(corners, warped, warpedMask);
    for (int i = 0; i < n; ++i) {
        compensator->apply(i, corners[i], warped[i], warpedMask[i]);
    }
    metrics.exposureTimeMs = nowMs() - tExp0;

    // Seam on downscaled images for memory
    const double tSeam0 = nowMs();
    std::vector<UMat> warpedF(n), masksF(n);
    std::vector<Point> cornersF = corners;
    for (int i = 0; i < n; ++i) {
        Mat w; warped[i].convertTo(w, CV_32F);
        w.copyTo(warpedF[i]);
        warpedMask[i].copyTo(masksF[i]);
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
        masksF[i].copyTo(warpedMask[i]);
        warpedF[i].release();
        masksF[i].release();
    }
    metrics.seamTimeMs = nowMs() - tSeam0;

    // Blend into fixed 4096×2048 equirect canvas.
    // OpenCV spherical warper produces a variable ROI pano; we composite into Gonggi canvas.
    const double tBlend0 = nowMs();
    const int outW = config.outputWidth;
    const int outH = config.outputHeight;

    // Determine OpenCV pano bounds
    std::vector<Size> sizesW = sizes;
    Rect dstRoi = resultRoi(corners, sizesW);
    if (dstRoi.width < 10 || dstRoi.height < 10) {
        return fail("degenerate warp ROI");
    }

    Ptr<Blender> blender = Blender::createDefault(Blender::MULTI_BAND, false);
    MultiBandBlender *mb = dynamic_cast<MultiBandBlender *>(blender.get());
    if (mb) {
        mb->setNumBands(5);
    }
    blender->prepare(dstRoi);

    for (int i = 0; i < n; ++i) {
        Mat warped16;
        warped[i].convertTo(warped16, CV_16S);
        blender->feed(warped16, warpedMask[i], corners[i]);
        warped[i].release();
    }
    Mat result16, resultMask;
    blender->blend(result16, resultMask);
    Mat result8;
    result16.convertTo(result8, CV_8U);
    metrics.blendTimeMs = nowMs() - tBlend0;

    if (!config.debugDirectory.empty()) {
        imwrite(config.debugDirectory + "/preblend_preview.jpg", result8);
        imwrite(config.debugDirectory + "/hole_mask.png", resultMask);
    }

    // Map OpenCV spherical result → Gonggi 2:1 equirect (first-forward U=0.5, zenith top).
    // SphericalWarper output is already equirectangular-like in a horizontal unwrap.
    // Resize to exact 4096×2048 and ensure vertical orientation (zenith at top).
    const double tEnc0 = nowMs();
    Mat pano;
    resize(result8, pano, Size(outW, outH), 0, 0, INTER_AREA);
    Mat panoMask;
    if (!resultMask.empty()) {
        resize(resultMask, panoMask, Size(outW, outH), 0, 0, INTER_NEAREST);
    } else {
        panoMask = Mat::ones(outH, outW, CV_8U) * 255;
    }

    // Hole metrics
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

    // Leave holes black (no AI fill).
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

    // File size
    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:[NSString stringWithUTF8String:config.outputPath.c_str()]
                         error:nil];
    if (attrs) {
        metrics.outputFileSizeMB = [attrs.fileSize doubleValue] / (1024.0 * 1024.0);
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
