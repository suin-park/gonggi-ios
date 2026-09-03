//
//  OpenCVPanoramaBridge.mm
//  ObjC++ → OpenCV. Phase 2A smoke + Phase 2B/C stitch.
//

#import "OpenCVPanoramaBridge.h"
#import "OpenCVPanoramaReconstructor.hpp"

#import <CoreFoundation/CoreFoundation.h>
#import <opencv2/core.hpp>

#import <mach/mach.h>
#import <cmath>
#import <string>
#import <vector>

@implementation OpenCVPanoramaStitchRequest
@end

@implementation OpenCVPanoramaStitchResult
@end

namespace {

double gonggi_peak_memory_mb() {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) {
        return 0;
    }
    return static_cast<double>(info.phys_footprint) / (1024.0 * 1024.0);
}

} // namespace

@implementation OpenCVPanoramaBridge

+ (BOOL)isAvailable {
    return YES;
}

+ (NSString *)openCVVersionString {
    return [NSString stringWithUTF8String:CV_VERSION];
}

+ (NSInteger)smokeTestAddLeft:(NSInteger)a right:(NSInteger)b {
    cv::Mat m = (cv::Mat_<double>(1, 2) << static_cast<double>(a), static_cast<double>(b));
    cv::Scalar s = cv::sum(m);
    return static_cast<NSInteger>(std::lround(s[0]));
}

+ (OpenCVPanoramaStitchResult *)stitchWithRequest:(OpenCVPanoramaStitchRequest *)request {
    OpenCVPanoramaStitchResult *result = [OpenCVPanoramaStitchResult new];
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    double peak = gonggi_peak_memory_mb();

    @try {
        if (request == nil || request.keyframeJPEGPaths.count == 0) {
            result.success = NO;
            result.errorMessage = @"empty keyframes";
            result.processingTimeMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
            result.peakMemoryMB = peak;
            return result;
        }

        const NSUInteger n = request.keyframeJPEGPaths.count;
        if (request.rotationsRowMajor9.count != n
            || request.fx.count != n
            || request.fy.count != n
            || request.cx.count != n
            || request.cy.count != n
            || request.imageWidths.count != n
            || request.imageHeights.count != n) {
            result.success = NO;
            result.errorMessage = @"mismatched keyframe array lengths";
            result.processingTimeMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
            result.peakMemoryMB = peak;
            return result;
        }

        std::vector<GonggiOpenCVFrameInput> frames;
        frames.reserve(n);
        for (NSUInteger i = 0; i < n; ++i) {
            GonggiOpenCVFrameInput f;
            f.jpegPath = [request.keyframeJPEGPaths[i] UTF8String];
            NSArray<NSNumber *> *row = request.rotationsRowMajor9[i];
            if (row.count < 9) {
                result.success = NO;
                result.errorMessage = @"rotation must have 9 floats";
                result.processingTimeMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
                return result;
            }
            for (NSUInteger k = 0; k < 9; ++k) {
                f.R_gonggi[k] = row[k].floatValue;
            }
            f.fx = request.fx[i].floatValue;
            f.fy = request.fy[i].floatValue;
            f.cx = request.cx[i].floatValue;
            f.cy = request.cy[i].floatValue;
            f.width = request.imageWidths[i].intValue;
            f.height = request.imageHeights[i].intValue;
            if (request.yawDeg.count == n) {
                f.yawDeg = request.yawDeg[i].floatValue;
            } else {
                f.yawDeg = 0;
            }
            if (request.pitchDeg.count == n) {
                f.pitchDeg = request.pitchDeg[i].floatValue;
            } else {
                f.pitchDeg = 0;
            }
            if (request.translationM.count == n) {
                f.translationM = request.translationM[i].floatValue;
            } else {
                f.translationM = 0;
            }
            frames.push_back(f);
        }

        GonggiOpenCVStitchConfig config;
        config.outputPath = request.outputPath.UTF8String;
        config.outputWidth = static_cast<int>(request.outputWidth);
        config.outputHeight = static_cast<int>(request.outputHeight);
        config.firstForwardYawDeg = request.firstForwardYawDeg;
        config.firstForwardPitchDeg = request.firstForwardPitchDeg;
        if (request.debugDirectoryPath.length > 0) {
            config.debugDirectory = request.debugDirectoryPath.UTF8String;
        }

        GonggiOpenCVStitchMetrics metrics;
        bool ok = GonggiOpenCVStitchPanorama(frames, config, metrics);

        result.success = ok ? YES : NO;
        result.errorMessage = metrics.errorMessage.empty()
            ? nil
            : [NSString stringWithUTF8String:metrics.errorMessage.c_str()];
        result.processingTimeMs = metrics.processingTimeMs > 0
            ? metrics.processingTimeMs
            : (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
        result.peakMemoryMB = std::max(peak, metrics.peakMemoryMB);

        // Serialize key metrics for Swift reports.
        NSDictionary *dict = @{
            @"success": @(ok),
            @"inputKeyframeCount": @(metrics.inputKeyframeCount),
            @"matchedPairCount": @(metrics.matchedPairCount),
            @"failedPairCount": @(metrics.failedPairCount),
            @"averageRawMatches": @(metrics.averageRawMatches),
            @"averageFilteredMatches": @(metrics.averageFilteredMatches),
            @"averageInliers": @(metrics.averageInliers),
            @"averageInlierRatio": @(metrics.averageInlierRatio),
            @"cameraGraphEdges": @(metrics.cameraGraphEdges),
            @"connectedComponents": @(metrics.connectedComponents),
            @"bundleAdjustmentConverged": @(metrics.bundleAdjustmentConverged),
            @"bundleAdjustmentBeforeError": @(metrics.bundleAdjustmentBeforeError),
            @"bundleAdjustmentAfterError": @(metrics.bundleAdjustmentAfterError),
            @"optimizedCameraCount": @(metrics.optimizedCameraCount),
            @"rejectedCameraCount": @(metrics.rejectedCameraCount),
            @"averageVisualCorrectionDeg": @(metrics.averageVisualCorrectionDeg),
            @"maxVisualCorrectionDeg": @(metrics.maxVisualCorrectionDeg),
            @"averageOverlap": @(metrics.averageOverlap),
            @"featureTimeMs": @(metrics.featureTimeMs),
            @"matchingTimeMs": @(metrics.matchingTimeMs),
            @"bundleAdjustmentTimeMs": @(metrics.bundleAdjustmentTimeMs),
            @"warpTimeMs": @(metrics.warpTimeMs),
            @"exposureTimeMs": @(metrics.exposureTimeMs),
            @"seamTimeMs": @(metrics.seamTimeMs),
            @"blendTimeMs": @(metrics.blendTimeMs),
            @"encodeTimeMs": @(metrics.encodeTimeMs),
            @"totalTimeMs": @(metrics.processingTimeMs),
            @"peakMemoryMB": @(metrics.peakMemoryMB),
            @"holePercent": @(metrics.holePercent),
            @"zenithHolePercent": @(metrics.zenithHolePercent),
            @"nadirHolePercent": @(metrics.nadirHolePercent),
            @"outputResolution": [NSString stringWithUTF8String:metrics.outputResolution.c_str()],
            @"outputFileSizeMB": @(metrics.outputFileSizeMB),
            @"featureDetector": [NSString stringWithUTF8String:metrics.featureDetector.c_str()],
            @"featureMatcher": [NSString stringWithUTF8String:metrics.featureMatcher.c_str()],
            @"exposureMode": [NSString stringWithUTF8String:metrics.exposureMode.c_str()],
            @"seamFinder": [NSString stringWithUTF8String:metrics.seamFinder.c_str()],
            @"blender": [NSString stringWithUTF8String:metrics.blender.c_str()],
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
        if (json) {
            result.metricsJSON = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        }
        return result;
    } @catch (NSException *ex) {
        result.success = NO;
        result.errorMessage = ex.reason ?: @"OpenCV stitch exception";
        result.processingTimeMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
        result.peakMemoryMB = std::max(peak, gonggi_peak_memory_mb());
        return result;
    }
}

@end
