import Foundation

/// Builds a ZIP of the Spatial Capture Package for R2 upload (store method).
/// Writes incrementally to disk — does **not** load the full archive into memory.
enum SpatialCapturePackageZipper {
    static let archiveFileName = "capture.zip"

    private static let requiredRootFiles = [
        SpatialCaptureConfig.metadataFileName,
        SpatialCaptureConfig.posesFileName,
        SpatialCaptureConfig.intrinsicsFileName,
        SpatialCaptureConfig.qualityFileName,
        SpatialCaptureConfig.coordinateConventionFileName,
    ]

    struct Result: Equatable, Sendable {
        var zipURL: URL
        var byteSize: Int
        var frameCount: Int
        var createDurationSec: Double
    }

    static func buildArchive(packageRoot: URL, destinationDirectory: URL) throws -> Result {
        let started = Date()
        let fm = FileManager.default
        guard fm.fileExists(atPath: packageRoot.path) else {
            throw ZipError.packageMissing
        }
        for name in requiredRootFiles {
            let url = packageRoot.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else {
                throw ZipError.missingRequired(name)
            }
        }
        let framesDir = packageRoot.appendingPathComponent(
            SpatialCaptureConfig.framesDirectoryName,
            isDirectory: true
        )
        let frameURLs = ((try? fm.contentsOfDirectory(
            at: framesDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.pathExtension.lowercased() == "jpg" || $0.pathExtension.lowercased() == "jpeg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard frameURLs.count >= 2 else {
            throw ZipError.insufficientFrames(frameURLs.count)
        }

        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let zipURL = destinationDirectory.appendingPathComponent(archiveFileName)
        if fm.fileExists(atPath: zipURL.path) {
            try fm.removeItem(at: zipURL)
        }
        fm.createFile(atPath: zipURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: zipURL)
        defer { try? handle.close() }

        var central = Data()
        var entryCount = 0

        func appendEntry(name: String, fileURL: URL) throws {
            let nameData = Data(name.utf8)
            guard nameData.count <= Int(UInt16.max) else {
                throw ZipError.nameTooLong(name)
            }
            let attrs = try fm.attributesOfItem(atPath: fileURL.path)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            guard size >= 0, size <= Int(UInt32.max) else {
                throw ZipError.fileTooLarge(name)
            }
            let crc = try ZipCRC32.crc32(ofFileAt: fileURL)
            let localOffset = UInt32(handle.offsetInFile)

            var local = Data()
            local.appendUInt32(0x04034b50)
            local.appendUInt16(20)
            local.appendUInt16(0)
            local.appendUInt16(0) // store
            local.appendUInt16(0)
            local.appendUInt16(0)
            local.appendUInt32(crc)
            local.appendUInt32(UInt32(size))
            local.appendUInt32(UInt32(size))
            local.appendUInt16(UInt16(nameData.count))
            local.appendUInt16(0)
            local.append(nameData)
            try handle.write(contentsOf: local)
            try streamCopy(from: fileURL, to: handle)

            var cen = Data()
            cen.appendUInt32(0x02014b50)
            cen.appendUInt16(20)
            cen.appendUInt16(20)
            cen.appendUInt16(0)
            cen.appendUInt16(0)
            cen.appendUInt16(0)
            cen.appendUInt16(0)
            cen.appendUInt32(crc)
            cen.appendUInt32(UInt32(size))
            cen.appendUInt32(UInt32(size))
            cen.appendUInt16(UInt16(nameData.count))
            cen.appendUInt16(0)
            cen.appendUInt16(0)
            cen.appendUInt16(0)
            cen.appendUInt16(0)
            cen.appendUInt32(0)
            cen.appendUInt32(localOffset)
            cen.append(nameData)
            central.append(cen)
            entryCount += 1
        }

        for name in requiredRootFiles {
            try appendEntry(name: name, fileURL: packageRoot.appendingPathComponent(name))
        }
        let selectionDiag = packageRoot.appendingPathComponent(SpatialCaptureConfig.selectionDiagnosticsFileName)
        if fm.fileExists(atPath: selectionDiag.path) {
            try appendEntry(name: SpatialCaptureConfig.selectionDiagnosticsFileName, fileURL: selectionDiag)
        }
        let continuityName = SpatialCaptureConfig.frameContinuityTelemetryFileName
        let continuityURL = packageRoot.appendingPathComponent(continuityName)
        if fm.fileExists(atPath: continuityURL.path) {
            try appendEntry(name: continuityName, fileURL: continuityURL)
        }
        for frame in frameURLs {
            let name = "\(SpatialCaptureConfig.framesDirectoryName)/\(frame.lastPathComponent)"
            try appendEntry(name: name, fileURL: frame)
        }

        let centralOffset = UInt32(handle.offsetInFile)
        try handle.write(contentsOf: central)
        var eocd = Data()
        eocd.appendUInt32(0x06054b50)
        eocd.appendUInt16(0)
        eocd.appendUInt16(0)
        eocd.appendUInt16(UInt16(entryCount))
        eocd.appendUInt16(UInt16(entryCount))
        eocd.appendUInt32(UInt32(central.count))
        eocd.appendUInt32(centralOffset)
        eocd.appendUInt16(0)
        try handle.write(contentsOf: eocd)
        try handle.synchronize()

        let byteSize = Int(handle.offsetInFile)
        return Result(
            zipURL: zipURL,
            byteSize: byteSize,
            frameCount: frameURLs.count,
            createDurationSec: Date().timeIntervalSince(started)
        )
    }

    private static func streamCopy(from fileURL: URL, to handle: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while true {
            let chunk = try input.read(upToCount: 1024 * 256) ?? Data()
            if chunk.isEmpty { break }
            try handle.write(contentsOf: chunk)
        }
    }

    enum ZipError: LocalizedError {
        case packageMissing
        case missingRequired(String)
        case insufficientFrames(Int)
        case nameTooLong(String)
        case fileTooLarge(String)

        var errorDescription: String? {
            switch self {
            case .packageMissing: return "Spatial Capture package가 없습니다."
            case .missingRequired(let n): return "필수 파일 누락: \(n)"
            case .insufficientFrames(let n): return "JPEG keyframe이 부족합니다 (\(n))."
            case .nameTooLong(let n): return "ZIP 경로가 너무 깁니다: \(n)"
            case .fileTooLarge(let n): return "파일이 너무 큽니다: \(n)"
            }
        }
    }
}

enum ZipCRC32 {
    static func crc32(ofFileAt url: URL) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var crc: UInt32 = 0xFFFF_FFFF
        while true {
            let chunk = try handle.read(upToCount: 1024 * 256) ?? Data()
            if chunk.isEmpty { break }
            for byte in chunk {
                let idx = Int((crc ^ UInt32(byte)) & 0xFF)
                crc = (crc >> 8) ^ table[idx]
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()
}

private extension Data {
    mutating func appendUInt16(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
