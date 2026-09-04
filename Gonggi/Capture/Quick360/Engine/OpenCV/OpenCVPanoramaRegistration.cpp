//
//  OpenCVPanoramaRegistration.cpp
//  Build 26 — rotation-only alignment + ARKit-regularized pose graph.
//

#include "OpenCVPanoramaRegistration.hpp"

#include <opencv2/calib3d.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/imgcodecs.hpp>

#include <sys/stat.h>

#include <cstdio>
#include <algorithm>
#include <cmath>
#include <fstream>
#include <functional>
#include <numeric>
#include <sstream>

using namespace cv;
using namespace cv::detail;

namespace {

constexpr double kPi = 3.14159265358979323846;

void ensureDir2(const std::string &path) {
    if (path.empty()) return;
    std::string cur;
    for (size_t i = 0; i < path.size(); ++i) {
        cur.push_back(path[i]);
        if (path[i] == '/' || i + 1 == path.size()) {
            std::string dir = cur;
            while (dir.size() > 1 && dir.back() == '/') dir.pop_back();
            if (dir != "/") ::mkdir(dir.c_str(), 0755);
        }
    }
}

void writeText(const std::string &path, const std::string &text) {
    if (path.empty()) return;
    std::ofstream out(path);
    out << text;
}

double rotationAngleDeg(const Mat &Ra, const Mat &Rb) {
    Mat A, B;
    Ra.convertTo(A, CV_64F);
    Rb.convertTo(B, CV_64F);
    Mat Rrel = A.t() * B;
    double tr = trace(Rrel)[0];
    double c = std::max(-1.0, std::min(1.0, (tr - 1.0) * 0.5));
    return std::acos(c) * 180.0 / kPi;
}

Vec3d rotToYPR(const Mat &R32or64) {
    // OpenCV camera: X right, Y down, Z forward. Approximate yaw(Y), pitch(X), roll(Z).
    Mat R;
    R32or64.convertTo(R, CV_64F);
    double r00 = R.at<double>(0, 0), r01 = R.at<double>(0, 1), r02 = R.at<double>(0, 2);
    double r10 = R.at<double>(1, 0), r11 = R.at<double>(1, 1), r12 = R.at<double>(1, 2);
    double r20 = R.at<double>(2, 0), r21 = R.at<double>(2, 1), r22 = R.at<double>(2, 2);
    double pitch = std::atan2(-r12, std::sqrt(r02 * r02 + r22 * r22));
    double yaw = std::atan2(r02, r22);
    double roll = std::atan2(r10, r11);
    return Vec3d(yaw * 180.0 / kPi, pitch * 180.0 / kPi, roll * 180.0 / kPi);
}

Vec3d deltaYPR(const Mat &Rarkit, const Mat &Rref) {
    Mat A, B;
    Rarkit.convertTo(A, CV_64F);
    Rref.convertTo(B, CV_64F);
    Mat dR = A.t() * B;
    return rotToYPR(dR);
}

Mat kabschR(const std::vector<Vec3d> &a, const std::vector<Vec3d> &b) {
    // R maps b -> a
    Mat H = Mat::zeros(3, 3, CV_64F);
    for (size_t i = 0; i < a.size(); ++i) {
        Mat aa = (Mat_<double>(3, 1) << a[i][0], a[i][1], a[i][2]);
        Mat bb = (Mat_<double>(3, 1) << b[i][0], b[i][1], b[i][2]);
        H += aa * bb.t();
    }
    SVD svd(H, SVD::FULL_UV);
    Mat R = svd.u * svd.vt;
    if (determinant(R) < 0) {
        Mat vt = svd.vt.clone();
        vt.row(2) *= -1;
        R = svd.u * vt;
    }
    return R;
}

Vec3d normalizeRay(const Mat &K32, const Point2f &pt) {
    Mat K;
    K32.convertTo(K, CV_64F);
    Mat Kinv = K.inv();
    Mat p = (Mat_<double>(3, 1) << pt.x, pt.y, 1.0);
    Mat r = Kinv * p;
    double n = norm(r);
    if (n < 1e-12) return Vec3d(0, 0, 1);
    return Vec3d(r.at<double>(0) / n, r.at<double>(1) / n, r.at<double>(2) / n);
}

double angularErrorDeg(const Vec3d &a, const Vec3d &b) {
    double d = a.dot(b);
    d = std::max(-1.0, std::min(1.0, d));
    return std::acos(d) * 180.0 / kPi;
}

Mat averageRotations(const std::vector<Mat> &Rs, const std::vector<double> &w) {
    Mat M = Mat::zeros(3, 3, CV_64F);
    double sumW = 0;
    for (size_t i = 0; i < Rs.size(); ++i) {
        Mat R;
        Rs[i].convertTo(R, CV_64F);
        double ww = (i < w.size()) ? w[i] : 1.0;
        M += ww * R;
        sumW += ww;
    }
    if (sumW > 0) M /= sumW;
    SVD svd(M, SVD::FULL_UV);
    Mat R = svd.u * svd.vt;
    if (determinant(R) < 0) {
        Mat vt = svd.vt.clone();
        vt.row(2) *= -1;
        R = svd.u * vt;
    }
    return R;
}

Mat dampRollTowardArkit(const Mat &Rarkit32, const Mat &Rcand64, double rollDamp) {
    Mat A, B;
    Rarkit32.convertTo(A, CV_64F);
    Rcand64.convertTo(B, CV_64F);
    Mat dR = A.t() * B;
    Mat rvec;
    Rodrigues(dR, rvec);
    // Camera Z ≈ roll axis in OpenCV convention.
    rvec.at<double>(2, 0) *= rollDamp;
    Mat dR2;
    Rodrigues(rvec, dR2);
    return A * dR2;
}

int spatialBinCount(const std::vector<Point2f> &pts, Size imgSize, const std::vector<uchar> &mask) {
    const int gx = 3, gy = 3;
    std::vector<int> bins(gx * gy, 0);
    for (size_t i = 0; i < pts.size(); ++i) {
        if (i < mask.size() && !mask[i]) continue;
        int bx = std::min(gx - 1, std::max(0, (int)(pts[i].x / std::max(imgSize.width, 1) * gx)));
        int by = std::min(gy - 1, std::max(0, (int)(pts[i].y / std::max(imgSize.height, 1) * gy)));
        bins[by * gx + bx]++;
    }
    int occupied = 0;
    for (int c : bins) if (c > 0) occupied++;
    return occupied;
}

MatchesInfo emptyPair(int src, int dst) {
    MatchesInfo mi;
    mi.src_img_idx = src;
    mi.dst_img_idx = dst;
    mi.confidence = 0;
    mi.num_inliers = 0;
    return mi;
}

MatchesInfo makeDual(const MatchesInfo &fwd) {
    MatchesInfo dual = fwd;
    dual.src_img_idx = fwd.dst_img_idx;
    dual.dst_img_idx = fwd.src_img_idx;
    if (!fwd.H.empty()) {
        try { dual.H = fwd.H.inv(); } catch (...) { dual.H = Mat(); }
    }
    for (auto &m : dual.matches) std::swap(m.queryIdx, m.trainIdx);
    return dual;
}

double percentile(std::vector<double> v, double p) {
    if (v.empty()) return 0;
    std::sort(v.begin(), v.end());
    double idx = p * (v.size() - 1);
    size_t i = (size_t)idx;
    double f = idx - i;
    if (i + 1 < v.size()) return v[i] * (1 - f) + v[i + 1] * f;
    return v.back();
}

} // namespace

std::string GonggiCaptureOverlapAnalysisJSON() {
    // Mirrors Quick360Config.pitchBandSpecs + Quick360CaptureFOVAnalysis (report only).
    const double hFov = 53.0;
    const double vFov = 67.0;
    auto overlap = [](double fov, double sep) {
        return std::max(0.0, (fov - std::abs(sep)) / std::max(fov, 1.0));
    };
    std::ostringstream o;
    o << "{"
      << "\"deviceHint\":\"iPhone14Plus_portrait\","
      << "\"approxHFOVDeg\":" << hFov << ","
      << "\"approxVFOVDeg\":" << vFov << ","
      << "\"targetUsefulOverlapRange\":\"0.35-0.50\","
      << "\"bands\":["
      << "{\"pitchDeg\":0,\"yawSteps\":12,\"yawStepDeg\":30,\"horizontalOverlap\":" << overlap(hFov, 30) << "},"
      << "{\"pitchDeg\":45,\"yawSteps\":10,\"yawStepDeg\":36,\"horizontalOverlap\":" << overlap(hFov, 36)
      << ",\"verticalOverlapFromHorizon\":" << overlap(vFov, 45) << "},"
      << "{\"pitchDeg\":-45,\"yawSteps\":10,\"yawStepDeg\":36,\"horizontalOverlap\":" << overlap(hFov, 36)
      << ",\"verticalOverlapFromHorizon\":" << overlap(vFov, 45) << "},"
      << "{\"pitchDeg\":75,\"yawSteps\":4,\"yawStepDeg\":90,\"horizontalOverlap\":" << overlap(hFov, 90)
      << ",\"verticalOverlapFromUpper\":" << overlap(vFov, 30) << "},"
      << "{\"pitchDeg\":-75,\"yawSteps\":4,\"yawStepDeg\":90,\"horizontalOverlap\":" << overlap(hFov, 90)
      << ",\"verticalOverlapFromLower\":" << overlap(vFov, 30) << "}"
      << "],"
      << "\"notes\":\"Horizon ~43% OK; upper/lower ring vertical ~33% is marginal vs 35-50% target; "
         "zenith/nadir yaw steps are sparse by design.\""
      << "}\n";
    return o.str();
}

bool GonggiRunRotationRegistration(
    const std::vector<ImageFeatures> &features,
    const std::vector<Mat> &K_match,
    const std::vector<Mat> &R_arkit_cv,
    const std::vector<Mat> &matchImagesBGR,
    const std::vector<float> &yawDeg,
    const std::vector<float> &pitchDeg,
    const GonggiRegistrationConfig &config,
    const std::string &debugDirectory,
    std::vector<CameraParams> &camerasInOut,
    std::vector<MatchesInfo> &pairwiseNxNOut,
    std::vector<GonggiRegPairDebug> &pairDebugOut,
    GonggiRegistrationMetrics &metricsOut
) {
    metricsOut = GonggiRegistrationMetrics();
    const int n = static_cast<int>(features.size());
    if (n == 0 || (int)K_match.size() != n || (int)R_arkit_cv.size() != n || (int)camerasInOut.size() != n) {
        return false;
    }

    ensureDir2(debugDirectory);
    if (!debugDirectory.empty()) {
        ensureDir2(debugDirectory + "/matches");
        writeText(debugDirectory + "/capture_overlap_analysis.json", GonggiCaptureOverlapAnalysisJSON());
    }

    pairwiseNxNOut.assign((size_t)n * (size_t)n, MatchesInfo());
    for (int i = 0; i < n; ++i) {
        for (int j = 0; j < n; ++j) {
            pairwiseNxNOut[(size_t)i * n + j] = emptyPair(i, j);
        }
    }

    Ptr<DescriptorMatcher> matcher = BFMatcher::create(NORM_HAMMING, false);

    struct Edge {
        int i, j;
        Mat R_ij; // CV_64F
        double weight;
        double medianErr;
    };
    std::vector<Edge> edges;
    std::vector<double> acceptedErrs;
    pairDebugOut.clear();

    auto expectedOverlap = [&](int i, int j) -> double {
        float yi = (i < (int)yawDeg.size()) ? yawDeg[i] : 0;
        float yj = (j < (int)yawDeg.size()) ? yawDeg[j] : 0;
        float pi = (i < (int)pitchDeg.size()) ? pitchDeg[i] : 0;
        float pj = (j < (int)pitchDeg.size()) ? pitchDeg[j] : 0;
        float dy = std::abs(yi - yj);
        if (dy > 180) dy = 360 - dy;
        float dp = std::abs(pi - pj);
        double h = std::max(0.0, (53.0 - dy) / 53.0);
        double v = std::max(0.0, (67.0 - dp) / 67.0);
        return std::min(h, v);
    };

    // Candidate pairs: geometrically plausible ARKit neighbors.
    for (int i = 0; i < n; ++i) {
        for (int j = i + 1; j < n; ++j) {
            GonggiRegPairDebug dbg;
            dbg.src = i;
            dbg.dst = j;
            dbg.overlapEstimate = expectedOverlap(i, j);
            if (dbg.overlapEstimate < 0.12) {
                dbg.rejectReason = "low_expected_overlap";
                metricsOut.rejectedPairCount++;
                pairDebugOut.push_back(dbg);
                continue;
            }
            if (features[i].descriptors.empty() || features[j].descriptors.empty()) {
                dbg.rejectReason = "empty_descriptors";
                metricsOut.rejectedPairCount++;
                pairDebugOut.push_back(dbg);
                continue;
            }

            std::vector<std::vector<DMatch>> knn;
            matcher->knnMatch(features[i].descriptors, features[j].descriptors, knn, 2);
            dbg.rawMatches = (int)knn.size();
            std::vector<DMatch> good;
            for (const auto &v : knn) {
                if (v.size() >= 2 && v[0].distance < 0.75f * v[1].distance) good.push_back(v[0]);
            }
            std::vector<std::vector<DMatch>> knnBack;
            matcher->knnMatch(features[j].descriptors, features[i].descriptors, knnBack, 2);
            std::vector<DMatch> mutual;
            for (const auto &m : good) {
                if (m.trainIdx >= 0 && m.trainIdx < (int)knnBack.size()
                    && !knnBack[m.trainIdx].empty()
                    && knnBack[m.trainIdx][0].trainIdx == m.queryIdx) {
                    mutual.push_back(m);
                }
            }
            dbg.mutualMatches = (int)mutual.size();

            Mat Ri, Rj;
            R_arkit_cv[i].convertTo(Ri, CV_64F);
            R_arkit_cv[j].convertTo(Rj, CV_64F);
            // OpenCV CameraParams: ray ≈ R * X_world → ray_i ≈ (Ri * Rj^T) * ray_j
            Mat Rprior = Ri * Rj.t();

            std::vector<Vec3d> raysI, raysJ;
            std::vector<Point2f> ptsI, ptsJ;
            std::vector<DMatch> keptMatches;
            for (const auto &m : mutual) {
                Point2f p1 = features[i].keypoints[m.queryIdx].pt;
                Point2f p2 = features[j].keypoints[m.trainIdx].pt;
                Vec3d r1 = normalizeRay(K_match[i], p1);
                Vec3d r2 = normalizeRay(K_match[j], p2);
                Mat r2m = (Mat_<double>(3, 1) << r2[0], r2[1], r2[2]);
                Mat pred = Rprior * r2m;
                Vec3d rp(pred.at<double>(0), pred.at<double>(1), pred.at<double>(2));
                double nrm = norm(pred);
                if (nrm > 1e-12) rp *= (1.0 / nrm);
                if (angularErrorDeg(r1, rp) <= config.priorAngularGateDeg) {
                    raysI.push_back(r1);
                    raysJ.push_back(r2);
                    ptsI.push_back(p1);
                    ptsJ.push_back(p2);
                    keptMatches.push_back(m);
                }
            }

            if ((int)keptMatches.size() < config.minInliers) {
                dbg.rejectReason = "insufficient_prior_consistent_matches";
                metricsOut.rejectedPairCount++;
                pairDebugOut.push_back(dbg);
                continue;
            }

            // Rotation-only RANSAC around Kabsch.
            Mat bestR = Rprior.clone();
            int bestInliers = 0;
            std::vector<uchar> bestMask(keptMatches.size(), 0);
            cv::RNG rng(12345 + i * 97 + j);
            const int iters = std::min(200, std::max(40, (int)keptMatches.size() * 2));
            for (int it = 0; it < iters; ++it) {
                if (keptMatches.size() < 3) break;
                int i0 = rng.uniform(0, (int)keptMatches.size());
                int i1 = rng.uniform(0, (int)keptMatches.size());
                int i2 = rng.uniform(0, (int)keptMatches.size());
                if (i0 == i1 || i0 == i2 || i1 == i2) continue;
                std::vector<Vec3d> sa = {raysI[i0], raysI[i1], raysI[i2]};
                std::vector<Vec3d> sb = {raysJ[i0], raysJ[i1], raysJ[i2]};
                Mat R = kabschR(sa, sb);
                if (rotationAngleDeg(R, Rprior) > config.maxVisualCorrectionDeg * 1.5) continue;
                int inl = 0;
                std::vector<uchar> mask(keptMatches.size(), 0);
                for (size_t k = 0; k < keptMatches.size(); ++k) {
                    Mat rj = (Mat_<double>(3, 1) << raysJ[k][0], raysJ[k][1], raysJ[k][2]);
                    Mat pred = R * rj;
                    Vec3d rp(pred.at<double>(0), pred.at<double>(1), pred.at<double>(2));
                    double nn = norm(pred);
                    if (nn > 1e-12) rp *= (1.0 / nn);
                    if (angularErrorDeg(raysI[k], rp) <= config.inlierAngularThreshDeg) {
                        mask[k] = 1;
                        inl++;
                    }
                }
                if (inl > bestInliers) {
                    bestInliers = inl;
                    bestMask.swap(mask);
                    bestR = R;
                }
            }

            // Refine on inliers.
            std::vector<Vec3d> ia, ib;
            std::vector<double> errs;
            for (size_t k = 0; k < keptMatches.size(); ++k) {
                if (!bestMask[k]) continue;
                ia.push_back(raysI[k]);
                ib.push_back(raysJ[k]);
            }
            if ((int)ia.size() >= config.minInliers) {
                bestR = kabschR(ia, ib);
            }
            for (size_t k = 0; k < keptMatches.size(); ++k) {
                if (!bestMask[k]) continue;
                Mat rj = (Mat_<double>(3, 1) << raysJ[k][0], raysJ[k][1], raysJ[k][2]);
                Mat pred = bestR * rj;
                Vec3d rp(pred.at<double>(0), pred.at<double>(1), pred.at<double>(2));
                double nn = norm(pred);
                if (nn > 1e-12) rp *= (1.0 / nn);
                errs.push_back(angularErrorDeg(raysI[k], rp));
            }

            dbg.inliers = bestInliers;
            dbg.inlierRatio = keptMatches.empty() ? 0 : (double)bestInliers / (double)keptMatches.size();
            dbg.medianAngularErrorDeg = percentile(errs, 0.5);
            Vec3d dyp = deltaYPR(Rprior, bestR);
            dbg.visualDeltaYawDeg = dyp[0];
            dbg.visualDeltaPitchDeg = dyp[1];
            dbg.visualDeltaRollDeg = dyp[2];

            int bins = spatialBinCount(ptsI, features[i].img_size, bestMask);
            bool ok = true;
            if (bestInliers < config.minInliers) {
                ok = false; dbg.rejectReason = "low_inliers";
            } else if (dbg.inlierRatio < config.minInlierRatio) {
                ok = false; dbg.rejectReason = "low_inlier_ratio";
            } else if (dbg.medianAngularErrorDeg > config.inlierAngularThreshDeg * 1.25) {
                ok = false; dbg.rejectReason = "high_median_angular_error";
            } else if (rotationAngleDeg(bestR, Rprior) > config.maxVisualCorrectionDeg) {
                ok = false; dbg.rejectReason = "correction_too_large";
            } else if (std::abs(dbg.visualDeltaRollDeg) > 4.0) {
                ok = false; dbg.rejectReason = "roll_correction_too_large";
            } else if (bins < config.minSpatialBins) {
                ok = false; dbg.rejectReason = "poor_spatial_distribution";
            }

            dbg.accepted = ok;
            if (!ok) {
                metricsOut.rejectedPairCount++;
                pairDebugOut.push_back(dbg);
            } else {
                metricsOut.acceptedPairCount++;
                acceptedErrs.push_back(dbg.medianAngularErrorDeg);
                Edge e;
                e.i = i; e.j = j;
                e.R_ij = bestR;
                e.medianErr = dbg.medianAngularErrorDeg;
                e.weight = std::max(1.0, (double)bestInliers) / (1.0 + dbg.medianAngularErrorDeg);
                edges.push_back(e);

                // Fill OpenCV MatchesInfo for secondary BA / diagnostics.
                MatchesInfo mi;
                mi.src_img_idx = i;
                mi.dst_img_idx = j;
                mi.matches = mutual;
                mi.inliers_mask.assign(mutual.size(), 0);
                // Map kept inliers onto mutual list.
                for (size_t k = 0; k < keptMatches.size(); ++k) {
                    if (!bestMask[k]) continue;
                    for (size_t t = 0; t < mutual.size(); ++t) {
                        if (mutual[t].queryIdx == keptMatches[k].queryIdx
                            && mutual[t].trainIdx == keptMatches[k].trainIdx) {
                            mi.inliers_mask[t] = 1;
                            break;
                        }
                    }
                }
                mi.num_inliers = bestInliers;
                mi.confidence = std::max(0.55, dbg.inlierRatio);
                // Store relative rotation as H placeholder unused by Ray BA; keep empty H.
                mi.H = Mat();
                pairwiseNxNOut[(size_t)i * n + j] = mi;
                pairwiseNxNOut[(size_t)j * n + i] = makeDual(mi);
                pairDebugOut.push_back(dbg);
            }

            if (!debugDirectory.empty()) {
                char pairTag[64];
                std::snprintf(pairTag, sizeof(pairTag), "pair_%02d_%02d", i, j);
                std::ostringstream body;
                body << "{"
                     << "\"src\":" << i << ",\"dst\":" << j
                     << ",\"rawMatches\":" << dbg.rawMatches
                     << ",\"mutualMatches\":" << dbg.mutualMatches
                     << ",\"inliers\":" << dbg.inliers
                     << ",\"inlierRatio\":" << dbg.inlierRatio
                     << ",\"medianAngularErrorDeg\":" << dbg.medianAngularErrorDeg
                     << ",\"overlapEstimate\":" << dbg.overlapEstimate
                     << ",\"visualDeltaYawDeg\":" << dbg.visualDeltaYawDeg
                     << ",\"visualDeltaPitchDeg\":" << dbg.visualDeltaPitchDeg
                     << ",\"visualDeltaRollDeg\":" << dbg.visualDeltaRollDeg
                     << ",\"accepted\":" << (dbg.accepted ? "true" : "false")
                     << ",\"rejectReason\":\"" << dbg.rejectReason << "\""
                     << "}\n";
                writeText(debugDirectory + "/matches/" + std::string(pairTag) + ".json", body.str());

                if (i < (int)matchImagesBGR.size() && j < (int)matchImagesBGR.size()
                    && !matchImagesBGR[i].empty() && !matchImagesBGR[j].empty()
                    && !mutual.empty()) {
                    Mat matchesImg;
                    drawMatches(matchImagesBGR[i], features[i].keypoints,
                                matchImagesBGR[j], features[j].keypoints,
                                mutual, matchesImg,
                                Scalar(0, 255, 0), Scalar(0, 0, 255),
                                std::vector<char>(), DrawMatchesFlags::NOT_DRAW_SINGLE_POINTS);
                    imwrite(debugDirectory + "/matches/" + std::string(pairTag) + "_matches.jpg", matchesImg);
                    std::vector<DMatch> drawInl;
                    for (size_t k = 0; k < keptMatches.size(); ++k) {
                        if (k < bestMask.size() && bestMask[k]) drawInl.push_back(keptMatches[k]);
                    }
                    if (!drawInl.empty()) {
                        Mat inlImg;
                        drawMatches(matchImagesBGR[i], features[i].keypoints,
                                    matchImagesBGR[j], features[j].keypoints,
                                    drawInl, inlImg,
                                    Scalar(0, 255, 0), Scalar(0, 0, 255),
                                    std::vector<char>(), DrawMatchesFlags::NOT_DRAW_SINGLE_POINTS);
                        imwrite(debugDirectory + "/matches/" + std::string(pairTag) + "_inliers.jpg", inlImg);
                    }
                }
            }
        }
    }

    metricsOut.poseGraphEdgeCount = (int)edges.size();
    metricsOut.medianPairAngularErrorDeg = percentile(acceptedErrs, 0.5);
    metricsOut.p90PairAngularErrorDeg = percentile(acceptedErrs, 0.9);

    // Connected components on accepted edges.
    std::vector<int> parent(n);
    std::iota(parent.begin(), parent.end(), 0);
    std::function<int(int)> find = [&](int x) {
        return parent[x] == x ? x : parent[x] = find(parent[x]);
    };
    for (const auto &e : edges) {
        int a = find(e.i), b = find(e.j);
        if (a != b) parent[b] = a;
    }
    std::vector<int> roots;
    for (int i = 0; i < n; ++i) roots.push_back(find(i));
    std::sort(roots.begin(), roots.end());
    roots.erase(std::unique(roots.begin(), roots.end()), roots.end());
    metricsOut.connectedComponents = (int)roots.size();

    // Pose graph: start from ARKit, iterate neighbor + prior averaging, damp roll.
    std::vector<Mat> R(n);
    for (int i = 0; i < n; ++i) {
        R_arkit_cv[i].convertTo(R[i], CV_64F);
    }

    auto writePoseGraph = [&](const std::string &name) {
        if (debugDirectory.empty()) return;
        std::ostringstream o;
        o << "{\"cameras\":[";
        for (int i = 0; i < n; ++i) {
            Mat Rf;
            R[i].convertTo(Rf, CV_32F);
            Vec3d corr = deltaYPR(R_arkit_cv[i], Rf);
            o << "{\"index\":" << i
              << ",\"correctionYawDeg\":" << corr[0]
              << ",\"correctionPitchDeg\":" << corr[1]
              << ",\"correctionRollDeg\":" << corr[2]
              << ",\"R\":[";
            for (int r = 0; r < 3; ++r) {
                for (int c = 0; c < 3; ++c) {
                    if (r || c) o << ",";
                    o << R[i].at<double>(r, c);
                }
            }
            o << "]}";
            if (i + 1 < n) o << ",";
        }
        o << "],\"edges\":[";
        for (size_t e = 0; e < edges.size(); ++e) {
            o << "{\"i\":" << edges[e].i << ",\"j\":" << edges[e].j
              << ",\"weight\":" << edges[e].weight
              << ",\"medianAngularErrorDeg\":" << edges[e].medianErr << "}";
            if (e + 1 < edges.size()) o << ",";
        }
        o << "]}\n";
        writeText(debugDirectory + "/" + name, o.str());
    };
    writePoseGraph("pose_graph_before.json");

    if (!edges.empty()) {
        for (int iter = 0; iter < config.poseGraphIters; ++iter) {
            std::vector<Mat> Rnew = R;
            for (int i = 0; i < n; ++i) {
                std::vector<Mat> props;
                std::vector<double> ws;
                props.push_back(R_arkit_cv[i]);
                ws.push_back(config.priorWeight);
                for (const auto &e : edges) {
                    // R_ij maps ray_j → ray_i, and R_i ≈ R_ij * R_j
                    if (e.i == i) {
                        props.push_back(e.R_ij * R[e.j]);
                        ws.push_back(e.weight);
                    } else if (e.j == i) {
                        props.push_back(e.R_ij.t() * R[e.i]);
                        ws.push_back(e.weight);
                    }
                }
                Mat avg = averageRotations(props, ws);
                avg = dampRollTowardArkit(R_arkit_cv[i], avg, config.rollDamp);
                // Clamp total correction vs ARKit.
                if (rotationAngleDeg(R_arkit_cv[i], avg) > config.maxVisualCorrectionDeg) {
                    R_arkit_cv[i].convertTo(avg, CV_64F);
                }
                Rnew[i] = avg;
            }
            // Keep camera 0 as ARKit until first-forward anchor (done outside).
            R_arkit_cv[0].convertTo(Rnew[0], CV_64F);
            R.swap(Rnew);
        }
        metricsOut.poseGraphConverged = true;
    } else {
        metricsOut.poseGraphConverged = false;
        metricsOut.registrationMode = "arkit_prior_only";
    }

    writePoseGraph("pose_graph_after.json");

    double sumCorr = 0, maxCorr = 0;
    int corrN = 0;
    for (int i = 0; i < n; ++i) {
        Mat Rf32;
        R[i].convertTo(Rf32, CV_32F);
        double ang = rotationAngleDeg(R_arkit_cv[i], Rf32);
        sumCorr += ang;
        maxCorr = std::max(maxCorr, ang);
        corrN++;
        camerasInOut[i].R = Rf32;
    }
    metricsOut.averageCameraCorrectionDeg = corrN ? sumCorr / corrN : 0;
    metricsOut.maxCameraCorrectionDeg = maxCorr;
    metricsOut.baRole = config.runSecondaryOpenCVBA ? "secondary_enabled" : "secondary_skipped";
    return true;
}
