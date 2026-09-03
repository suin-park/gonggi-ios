//
//  OpenCVPanoramaBridge.mm
//  ObjC++ → OpenCV. Phase 2A: version + smoke. Phase 2B/C: reconstruction (detail::*).
//

#import "OpenCVPanoramaBridge.h"

#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/imgcodecs.hpp>
#import <opencv2/features2d.hpp>
#import <opencv2/calib3d.hpp>
#import <opencv2/stitching.hpp>
#import <opencv2/stitching/detail/matchers.hpp>
#import <opencv2/stitching/detail/motion_estimators.hpp>
#import <opencv2/stitching/detail/camera.hpp>
#import <opencv2/stitching/detail/warpers.hpp>
#import <opencv2/stitching/detail/exposure_compensate.hpp>
#import <opencv2/stitching/detail/seam_finders.hpp>
#import <opencv2/stitching/detail/blenders.hpp>
#import <opencv2/stitching/warpers.hpp>

#import <mach/mach.h>
#import <cmath>
#import <fstream>
#import <sstream>
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

std::string gonggi_escape_json(const std::string &s) {
    std::ostringstream o;
    for (char c : s) {
        switch (c) {
            case '"': o << "\\\""; break;
            case '\\': o << "\\\\"; break;
            case '\n': o << "\\n"; break;
            default: o << c; break;
        }
    }
    return o.str();
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
    // Force a real OpenCV C++ call (not just a macro).
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

        // Phase 2A: bridge is live; full reconstruction lands in Phase 2B/2C.
        // Return structured failure so A/B / production Legacy path stay safe.
        NSString *msg = [NSString stringWithFormat:
            @"OpenCV bridge ready (v%@); panorama stitch not implemented until Phase 2B/2C",
            [self openCVVersionString]];
        result.success = NO;
        result.errorMessage = msg;
        result.processingTimeMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
        peak = std::max(peak, gonggi_peak_memory_mb());
        result.peakMemoryMB = peak;
        result.metricsJSON = [NSString stringWithFormat:
            @"{\"openCVVersion\":\"%@\",\"bridgeReady\":true,\"stitchImplemented\":false}",
            [self openCVVersionString]];
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
