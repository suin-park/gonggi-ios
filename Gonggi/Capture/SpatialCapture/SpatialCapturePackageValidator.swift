import Foundation

enum SpatialCapturePackageValidationError: Error, Equatable, LocalizedError {
    case missingDirectory(String)
    case missingFile(String)
    case keyframeCountMismatch(expected: Int, jpegCount: Int, poseCount: Int, intrinsicsCount: Int)
    case missingJPEG(String)
    case missingIntrinsics(String)
    case invalidTimestamp(String)
    case nonMonotonicTimestamp(String)
    case duplicateFrameId(String)
    case nanTransform(String)
    case emptyPackage

    var errorDescription: String? {
        switch self {
        case .missingDirectory(let p): return "패키지 폴더가 없습니다: \(p)"
        case .missingFile(let p): return "필수 파일이 없습니다: \(p)"
        case .keyframeCountMismatch(let e, let j, let p, let i):
            return "키프레임 수 불일치 (meta=\(e) jpeg=\(j) poses=\(p) intrinsics=\(i))"
        case .missingJPEG(let id): return "이미지 파일이 없습니다: \(id)"
        case .missingIntrinsics(let id): return "intrinsics가 없습니다: \(id)"
        case .invalidTimestamp(let id): return "잘못된 timestamp: \(id)"
        case .nonMonotonicTimestamp(let id): return "timestamp가 단조 증가하지 않습니다: \(id)"
        case .duplicateFrameId(let id): return "중복 frameId: \(id)"
        case .nanTransform(let id): return "잘못된 camera transform: \(id)"
        case .emptyPackage: return "선택된 키프레임이 없습니다"
        }
    }
}

enum SpatialCapturePackageValidator {
    static func validate(packageRoot: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: packageRoot.path, isDirectory: &isDir), isDir.boolValue else {
            throw SpatialCapturePackageValidationError.missingDirectory(packageRoot.lastPathComponent)
        }

        let metadataURL = packageRoot.appendingPathComponent(SpatialCaptureConfig.metadataFileName)
        let posesURL = packageRoot.appendingPathComponent(SpatialCaptureConfig.posesFileName)
        let intrinsicsURL = packageRoot.appendingPathComponent(SpatialCaptureConfig.intrinsicsFileName)
        let qualityURL = packageRoot.appendingPathComponent(SpatialCaptureConfig.qualityFileName)
        let framesDir = packageRoot.appendingPathComponent(SpatialCaptureConfig.framesDirectoryName, isDirectory: true)

        for url in [metadataURL, posesURL, intrinsicsURL, qualityURL] {
            guard fm.fileExists(atPath: url.path) else {
                throw SpatialCapturePackageValidationError.missingFile(url.lastPathComponent)
            }
        }
        guard fm.fileExists(atPath: framesDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw SpatialCapturePackageValidationError.missingDirectory(SpatialCaptureConfig.framesDirectoryName)
        }

        let decoder = JSONDecoder()
        let metadata = try decoder.decode(SpatialCapturePackageMetadata.self, from: Data(contentsOf: metadataURL))
        let poses = try decoder.decode(SpatialCapturePosesFile.self, from: Data(contentsOf: posesURL))
        let intrinsics = try decoder.decode(SpatialCaptureIntrinsicsFile.self, from: Data(contentsOf: intrinsicsURL))
        _ = try decoder.decode(SpatialCaptureQualityFile.self, from: Data(contentsOf: qualityURL))

        if metadata.selectedKeyframeCount == 0 || poses.frames.isEmpty {
            throw SpatialCapturePackageValidationError.emptyPackage
        }

        let jpegNames = try fm.contentsOfDirectory(atPath: framesDir.path)
            .filter { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".jpeg") }
        if metadata.selectedKeyframeCount != jpegNames.count
            || metadata.selectedKeyframeCount != poses.frames.count
            || metadata.selectedKeyframeCount != intrinsics.frames.count
        {
            throw SpatialCapturePackageValidationError.keyframeCountMismatch(
                expected: metadata.selectedKeyframeCount,
                jpegCount: jpegNames.count,
                poseCount: poses.frames.count,
                intrinsicsCount: intrinsics.frames.count
            )
        }

        var seenIds = Set<String>()
        var lastTimestamp: Double?
        let intrinsicIds = Set(intrinsics.frames.map(\.frameId))
        for pose in poses.frames {
            if !seenIds.insert(pose.frameId).inserted {
                throw SpatialCapturePackageValidationError.duplicateFrameId(pose.frameId)
            }
            guard pose.arTimestampSeconds.isFinite else {
                throw SpatialCapturePackageValidationError.invalidTimestamp(pose.frameId)
            }
            if let lastTimestamp, pose.arTimestampSeconds < lastTimestamp {
                throw SpatialCapturePackageValidationError.nonMonotonicTimestamp(pose.frameId)
            }
            lastTimestamp = pose.arTimestampSeconds
            guard pose.cameraToWorldColumnMajor.count == 16,
                  pose.cameraToWorldColumnMajor.allSatisfy({ $0.isFinite })
            else {
                throw SpatialCapturePackageValidationError.nanTransform(pose.frameId)
            }
            guard intrinsicIds.contains(pose.frameId) else {
                throw SpatialCapturePackageValidationError.missingIntrinsics(pose.frameId)
            }
            let jpeg = framesDir.appendingPathComponent("\(pose.frameId).jpg")
            guard fm.fileExists(atPath: jpeg.path) else {
                throw SpatialCapturePackageValidationError.missingJPEG(pose.frameId)
            }
        }
    }
}
