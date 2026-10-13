import Foundation

/// Why a capture could not be analysed, in terms the person can act on. The kinds are kept apart on purpose: a photo
/// count problem must never be explained as a connection problem.
struct StoreCaptureFailure: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// The device could not reach the server (offline, timeout, dropped connection).
        case network
        /// The server refused the number of photos of a capture.
        case tooManyPhotos
        /// A photo or the capture is larger than the server accepts.
        case tooLarge
        /// The analysis service is busy or its call limit was reached.
        case rateLimited
        /// Some requests of the analysis failed; the ones that succeeded are kept.
        case partialAnalysis
        /// The analysis failed (invalid answer, service error).
        case analysisFailed
        /// The analysis is not available for this account or build.
        case unavailable
        case other
    }

    var kind: Kind
    var message: String
    /// Technical reason for logs and diagnostics only; never shown on a screen.
    var detail: String? = nil

    /// Whether "다시 시도" can help without changing anything.
    var canRetry: Bool { kind != .unavailable && kind != .tooManyPhotos && kind != .tooLarge }

    /// What to do next: one short, kind-specific action. Where the photos are is said by the screen that has the button.
    var guidance: String {
        switch kind {
        case .network: return "연결되면 이어서 진행해 주세요."
        case .tooManyPhotos: return "다시 촬영해 주세요."
        case .tooLarge: return "더 가까이에서 다시 촬영해 주세요."
        case .rateLimited: return "잠시 후 다시 시도해 주세요."
        case .partialAnalysis: return "다시 시도하면 실패한 부분만 이어서 분석해요."
        case .analysisFailed: return "다시 시도해 주세요."
        case .unavailable: return "지금은 이 계정에서 사용할 수 없어요."
        case .other: return "다시 시도해 주세요."
        }
    }

    /// From an HTTP status and the server's error code.
    static func fromServer(status: Int, code: String?) -> StoreCaptureFailure {
        switch code {
        case "TOO_MANY_PHOTOS", "TOO_MANY_PHOTOS_FOR_ANALYSIS":
            return StoreCaptureFailure(kind: .tooManyPhotos, message: "사진 수가 한도를 넘었어요")
        case "PHOTO_TOO_LARGE", "PHOTOS_TOO_LARGE_FOR_ANALYSIS", "SESSION_TOO_LARGE":
            return StoreCaptureFailure(kind: .tooLarge, message: "사진 용량이 한도를 넘었어요")
        case "ANALYSIS_LIMIT_REACHED":
            return StoreCaptureFailure(kind: .rateLimited, message: "이 촬영의 분석 횟수 한도에 도달했어요")
        case "ANALYSIS_DISABLED":
            return StoreCaptureFailure(kind: .unavailable, message: "사진 분석을 사용할 수 없어요")
        case "UPLOAD_INCOMPLETE":
            return StoreCaptureFailure(kind: .network, message: "사진 업로드가 끝나지 않았어요")
        default:
            break
        }
        if status == 429 { return StoreCaptureFailure(kind: .rateLimited, message: "요청이 많아요") }
        if status == 413 { return StoreCaptureFailure(kind: .tooLarge, message: "요청이 너무 커요") }
        if status == 401 { return StoreCaptureFailure(kind: .unavailable, message: "로그인이 필요해요") }
        if status == 403 { return StoreCaptureFailure(kind: .unavailable, message: "이 매장의 담당자가 아니에요") }
        return StoreCaptureFailure(kind: .other, message: "서버에 문제가 있어요", detail: "http_\(status)")
    }

    /// From the error code of a failed analysis run.
    static func fromRun(errorCode: String?) -> StoreCaptureFailure {
        let partial = errorCode?.hasPrefix("partial:") == true
        let code = partial ? String(errorCode!.dropFirst("partial:".count)) : (errorCode ?? "")
        let kind: Kind
        var message: String
        switch code {
        case "model_rate_limited": kind = .rateLimited; message = "분석 요청이 많아요"
        case "model_timeout": kind = partial ? .partialAnalysis : .analysisFailed; message = "분석 시간이 초과됐어요"
        case "model_disabled", "model_auth": kind = .unavailable; message = "분석 서비스를 사용할 수 없어요"
        case "photo_missing": kind = .network; message = "업로드된 사진을 찾지 못했어요"
        case "invalid_structure": kind = .analysisFailed; message = "분석 결과를 읽지 못했어요"
        case "request_limit": kind = .rateLimited; message = "한 번의 분석 요청 수 한도에 도달했어요"
        default: kind = partial ? .partialAnalysis : .analysisFailed; message = "분석을 끝내지 못했어요"
        }
        return StoreCaptureFailure(kind: kind, message: message, detail: errorCode)
    }

    static let network = StoreCaptureFailure(kind: .network, message: "네트워크에 연결하지 못했어요")
}

/// A failure can be carried in a `Result`.
extension StoreCaptureFailure: Error {}
