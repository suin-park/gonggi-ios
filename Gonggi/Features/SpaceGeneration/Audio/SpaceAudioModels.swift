import Foundation
import UniformTypeIdentifiers

/// Build 80 — space audio metadata (catalog + GET/POST complete).
struct SpaceAudioMetadata: Equatable, Sendable {
    var audioURL: String?
    var audioFileName: String?
    var audioMimeType: String?
    var audioDurationSec: Double?
    var audioSource: String?
    var audioUpdatedAt: String?

    var hasAudio: Bool {
        guard let url = audioURL?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
            return false
        }
        return true
    }

    static let empty = SpaceAudioMetadata(
        audioURL: nil,
        audioFileName: nil,
        audioMimeType: nil,
        audioDurationSec: nil,
        audioSource: nil,
        audioUpdatedAt: nil
    )

    static func fromCatalogRow(_ row: [String: Any]) -> SpaceAudioMetadata {
        SpaceAudioMetadata(
            audioURL: row["audioURL"] as? String,
            audioFileName: row["audioFileName"] as? String,
            audioMimeType: row["audioMimeType"] as? String,
            audioDurationSec: Self.double(from: row["audioDurationSec"]),
            audioSource: row["audioSource"] as? String,
            audioUpdatedAt: row["audioUpdatedAt"] as? String
        )
    }

    static func fromAudioObject(_ obj: [String: Any]) -> SpaceAudioMetadata {
        fromCatalogRow(obj)
    }

    private static func double(from value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String, let d = Double(s) { return d }
        return nil
    }
}

enum SpaceAudioSource: String, Equatable, Sendable {
    case upload
    case recording
}

enum SpaceAudioPolicy {
    static let maxByteSize = 20 * 1024 * 1024
    static let allowedExtensions: Set<String> = ["m4a", "mp3", "aac", "wav"]
    static let fadeInSeconds: TimeInterval = 0.4
    static let fadeOutSeconds: TimeInterval = 0.25
    static let recordingSampleRate: Double = 44_100

    static let allowedContentTypes: Set<String> = [
        "audio/mp4",
        "audio/x-m4a",
        "audio/m4a",
        "audio/mpeg",
        "audio/mp3",
        "audio/aac",
        "audio/wav",
        "audio/x-wav",
        "audio/wave",
    ]

    static var importContentTypes: [UTType] {
        var types: [UTType] = [.mpeg4Audio, .mp3, .wav]
        if let aac = UTType(filenameExtension: "aac") {
            types.append(aac)
        }
        if let m4a = UTType(filenameExtension: "m4a") {
            types.append(m4a)
        }
        return types
    }

    static func isAllowed(fileName: String, byteSize: Int, contentType: String?) -> Bool {
        guard byteSize > 0, byteSize <= maxByteSize else { return false }
        let ext = (fileName as NSString).pathExtension.lowercased()
        if allowedExtensions.contains(ext) { return true }
        if let contentType, allowedContentTypes.contains(contentType.lowercased()) { return true }
        return false
    }

    static func contentType(forFileName fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "aac": return "audio/aac"
        case "wav": return "audio/wav"
        default: return "application/octet-stream"
        }
    }

    static func formatDuration(_ sec: Double?) -> String {
        guard let sec, sec.isFinite, sec > 0 else { return "—" }
        let total = Int(sec.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    static func userMessage(for error: Error) -> String {
        if let e = error as? SpaceAudioAPIError {
            return e.userMessage
        }
        return SpaceAudioAPIError.generic.userMessage
    }
}

enum SpaceAudioAPIError: Error, Equatable {
    case invalidResponse
    case network
    case unauthorized
    case fileTooLarge
    case unsupportedType
    case missingToken
    case generic

    var userMessage: String {
        switch self {
        case .network, .invalidResponse:
            return "네트워크에 연결할 수 없습니다."
        case .unauthorized, .missingToken:
            return "로그인이 필요합니다."
        case .fileTooLarge:
            return "파일이 너무 커요. 20MB 이하로 올려 주세요."
        case .unsupportedType:
            return "지원하지 않는 오디오 형식이에요. m4a, mp3, aac, wav만 가능해요."
        case .generic:
            return "오디오를 처리하지 못했어요."
        }
    }
}

struct SpaceAudioPresignResponse: Equatable, Sendable {
    var uploadUrl: String
    var key: String
    var contentType: String
}
