//
//  OpenCVPanoramaBridge.h
//  Gonggi — narrow ObjC façade for OpenCV (Phase 2).
//
//  Swift → this header → OpenCVPanoramaBridge.mm → C++ OpenCV
//  Pass only POD / paths. Never ARFrame / SwiftUI / RealityKit.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Phase 2A smoke + Phase 2B+ stitch request (POD only).
@interface OpenCVPanoramaStitchRequest : NSObject
@property (nonatomic, copy) NSArray<NSString *> *keyframeJPEGPaths;
/// Each element: 9 floats, row-major 3×3 camera→world (gravity CaptureBasis space).
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *rotationsRowMajor9;
@property (nonatomic, copy) NSArray<NSNumber *> *fx;
@property (nonatomic, copy) NSArray<NSNumber *> *fy;
@property (nonatomic, copy) NSArray<NSNumber *> *cx;
@property (nonatomic, copy) NSArray<NSNumber *> *cy;
@property (nonatomic, copy) NSArray<NSNumber *> *imageWidths;
@property (nonatomic, copy) NSArray<NSNumber *> *imageHeights;
@property (nonatomic, copy) NSString *outputPath;
@property (nonatomic, assign) NSInteger outputWidth;
@property (nonatomic, assign) NSInteger outputHeight;
@property (nonatomic, assign) float firstForwardYawDeg;
@property (nonatomic, assign) float firstForwardPitchDeg;
/// Optional debug root: …/panorama/debug/ab/opencv/
@property (nonatomic, copy, nullable) NSString *debugDirectoryPath;
/// CaptureBasis yaw/pitch degrees (pair selection). Same length as keyframes.
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *yawDeg;
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *pitchDeg;
/// Translation magnitude (m) for high-parallax downweight.
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *translationM;
@end

@interface OpenCVPanoramaStitchResult : NSObject
@property (nonatomic, assign) BOOL success;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@property (nonatomic, assign) double processingTimeMs;
@property (nonatomic, assign) double peakMemoryMB;
@property (nonatomic, copy, nullable) NSString *metricsJSON;
@end

@interface OpenCVPanoramaBridge : NSObject

/// True when opencv2.xcframework is linked and bridge can call into OpenCV.
+ (BOOL)isAvailable;

/// e.g. "4.10.0"
+ (NSString *)openCVVersionString;

/// Dummy C++ call for Phase 2A smoke tests (a + b via cv::Mat).
+ (NSInteger)smokeTestAddLeft:(NSInteger)a right:(NSInteger)b;

/// Phase 2B–2C reconstruction. Phase 2A returns structured failure if not ready.
+ (OpenCVPanoramaStitchResult *)stitchWithRequest:(OpenCVPanoramaStitchRequest *)request;

/// Build 25: synthetic BundleAdjusterRay contract scenarios (valid3/sparse/invalidIdx/…).
/// Returns JSON detail; `success` means scenario behaved safely (no invalid BA input path).
+ (OpenCVPanoramaStitchResult *)runBAContractTestScenario:(NSString *)scenario;

/// Build 26: guided-target FOV overlap analysis JSON (report only; does not change layout).
+ (NSString *)captureOverlapAnalysisJSON;

@end

NS_ASSUME_NONNULL_END
