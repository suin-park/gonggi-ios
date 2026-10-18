import Foundation
import AVFoundation
import CoreMedia

/// 영상 포맷과 그 포맷에서 고를 수 있는 깊이 포맷의 한 쌍.
struct ExpFormatChoice: Identifiable, Hashable {
    var id: String { "\(videoIndex)-\(depthIndex)" }
    let videoIndex: Int
    let depthIndex: Int
    let videoW: Int
    let videoH: Int
    let videoFpsMax: Double
    let depthW: Int
    let depthH: Int
    let depthType: String
    let depthFpsMax: Double

    var label: String {
        String(format: "영상 %dx%d (최대 %.0ffps) · 깊이 %dx%d %@ (최대 %.0ffps)", videoW, videoH, videoFpsMax, depthW, depthH, depthType, depthFpsMax)
    }
}

struct ExpDiscoveryResult {
    var dualWideFound = false
    var multiCamSupported = false
    var cameraAuthorization = "unknown"
    /// B. 사진용 깊이 (영상 스트리밍과 별개). 확인하지 못했으면 .unknown
    var photoDepth: ExpStageState = .unknown
    /// 영상·깊이 호환 포맷이 하나라도 있는가
    var formatsPresent = false
    var choices: [ExpFormatChoice] = []
    var deviceSummaries: [[String: Any]] = []
    var note = ""
}

/// A(장치 발견)와 B(사진용 깊이)를 확인한다. C(연속 스트리밍)의 증거가 아니다.
/// 카메라를 실행하지 않고 속성만 읽는다.
enum ExperimentDiscovery {
    static let deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera,
        .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera,
        .builtInTrueDepthCamera, .builtInLiDARDepthCamera
    ]

    private static let queue = DispatchQueue(label: "gonggi.experiment.discovery", qos: .userInitiated)

    static func authorizationName(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    static func run(log: ExperimentRunLog?) async -> ExpDiscoveryResult {
        await withCheckedContinuation { (c: CheckedContinuation<ExpDiscoveryResult, Never>) in
            queue.async { c.resume(returning: probe(log: log)) }
        }
    }

    private static func fpsMax(_ f: AVCaptureDevice.Format) -> Double {
        f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    }

    private static func describe(_ f: AVCaptureDevice.Format, index: Int) -> [String: Any] {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        return [
            "index": index, "w": Int(d.width), "h": Int(d.height),
            "pixelFormat": ExpSys.fourCC(CMFormatDescriptionGetMediaSubType(f.formatDescription)),
            "fps": f.videoSupportedFrameRateRanges.map { [$0.minFrameRate, $0.maxFrameRate] },
            "binned": f.isVideoBinned, "hdr": f.isVideoHDRSupported, "multiCam": f.isMultiCamSupported,
            "fov": f.videoFieldOfView,
            "depthFormats": f.supportedDepthDataFormats.enumerated().map { (i, df) -> [String: Any] in
                let dd = CMVideoFormatDescriptionGetDimensions(df.formatDescription)
                return ["index": i, "w": Int(dd.width), "h": Int(dd.height),
                        "type": ExpSys.fourCC(CMFormatDescriptionGetMediaSubType(df.formatDescription)),
                        "fps": df.videoSupportedFrameRateRanges.map { [$0.minFrameRate, $0.maxFrameRate] }]
            }
        ]
    }

    private static func probe(log: ExperimentRunLog?) -> ExpDiscoveryResult {
        var r = ExpDiscoveryResult()
        r.cameraAuthorization = authorizationName(AVCaptureDevice.authorizationStatus(for: .video))
        r.multiCamSupported = AVCaptureMultiCamSession.isMultiCamSupported
        log?.write("auth", ["camera": r.cameraAuthorization])
        log?.write("multicam", ["isMultiCamSupported": r.multiCamSupported])

        // A. 장치 발견
        let ds = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
        for dev in ds.devices {
            let withDepth = dev.formats.filter { !$0.supportedDepthDataFormats.isEmpty }.count
            let summary: [String: Any] = [
                "type": dev.deviceType.rawValue, "position": dev.position.rawValue, "name": dev.localizedName,
                "isVirtual": dev.isVirtualDevice,
                "constituents": dev.constituentDevices.map { $0.deviceType.rawValue },
                "formatCount": dev.formats.count, "formatsWithDepthFormats": withDepth,
                "activeFormat": describe(dev.activeFormat, index: -1)
            ]
            r.deviceSummaries.append(summary)
            log?.write("device", summary)
            for (i, f) in dev.formats.enumerated() where !f.supportedDepthDataFormats.isEmpty || dev.deviceType == .builtInDualWideCamera {
                var d = describe(f, index: i)
                d["deviceType"] = dev.deviceType.rawValue
                log?.write("format", d)
            }
        }
        guard let dual = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) else {
            r.dualWideFound = false
            r.photoDepth = .notRun
            r.note = "이 기기에서는 builtInDualWideCamera(후면)가 발견되지 않았다."
            log?.write("A_result", ["dualWideFound": false, "note": r.note])
            return r
        }
        r.dualWideFound = true
        log?.write("A_result", ["dualWideFound": true, "note": "A만 확인: 장치가 존재한다. B·C의 증거가 아니다."])

        // 영상·깊이 호환 포맷
        for (vi, f) in dual.formats.enumerated() {
            let vd = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            for (di, df) in f.supportedDepthDataFormats.enumerated() {
                let dd = CMVideoFormatDescriptionGetDimensions(df.formatDescription)
                r.choices.append(ExpFormatChoice(
                    videoIndex: vi, depthIndex: di, videoW: Int(vd.width), videoH: Int(vd.height), videoFpsMax: fpsMax(f),
                    depthW: Int(dd.width), depthH: Int(dd.height),
                    depthType: ExpSys.fourCC(CMFormatDescriptionGetMediaSubType(df.formatDescription)), depthFpsMax: fpsMax(df)))
            }
        }
        r.formatsPresent = !r.choices.isEmpty
        log?.write("formats_result", ["formatsPresent": r.formatsPresent, "pairs": r.choices.count])

        // B. 사진용 깊이: 입력·출력만 붙여 속성을 읽고 세션은 실행하지 않는다. 권한이 없으면 확인하지 못한다.
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized, let input = try? AVCaptureDeviceInput(device: dual) {
            let s = AVCaptureSession()
            let photo = AVCapturePhotoOutput()
            s.beginConfiguration()
            s.sessionPreset = .photo
            var ok = false
            if s.canAddInput(input) { s.addInput(input); ok = true }
            if ok, s.canAddOutput(photo) { s.addOutput(photo) } else { ok = false }
            s.commitConfiguration()
            if ok {
                r.photoDepth = photo.isDepthDataDeliverySupported ? .yes : .no
                log?.write("B_result", [
                    "photoOutput.isDepthDataDeliverySupported": photo.isDepthDataDeliverySupported,
                    "isCameraCalibrationDataDeliverySupported": photo.isCameraCalibrationDataDeliverySupported,
                    "note": "B만 확인: 사진에 첨부되는 깊이. 연속 스트리밍(C)의 증거가 아니다."
                ])
            } else {
                r.photoDepth = .unknown
                log?.write("B_result", ["checked": false, "reason": "입력/출력을 세션에 붙이지 못함"])
            }
        } else {
            r.photoDepth = .unknown
            log?.write("B_result", ["checked": false, "reason": "카메라 권한이 없어 확인하지 못함"])
        }
        return r
    }
}
