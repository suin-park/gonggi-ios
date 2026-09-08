import Foundation

enum MobileAssetsAPIError: Error, Equatable {
    case invalidResponse
    case server(status: Int)
}

actor MobileAssetsAPIClient {
    private let config: AppConfiguration
    private let session: URLSession

    init(config: AppConfiguration = .production, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func fetchAssets() async throws -> [MobileAssetDTO] {
        let data = try await get(pathComponents: ["api", "mobile", "assets"])
        let decoder = JSONDecoder()
        if let assets = try? decoder.decode([MobileAssetDTO].self, from: data) {
            return assets
        }
        if let response = try? decoder.decode(AssetsEnvelope.self, from: data) {
            return response.assets
        }
        throw MobileAssetsAPIError.invalidResponse
    }

    func fetchAsset(id: String) async throws -> MobileAssetDTO {
        let data = try await get(pathComponents: ["api", "mobile", "assets", id])
        let decoder = JSONDecoder()
        if let asset = try? decoder.decode(MobileAssetDTO.self, from: data) {
            return asset
        }
        if let response = try? decoder.decode(AssetEnvelope.self, from: data) {
            return response.asset
        }
        throw MobileAssetsAPIError.invalidResponse
    }

    /// POST `/api/mobile/assets/:id/prepare-ar`
    func prepareAR(assetId: String) async throws -> MobilePrepareARResponse {
        let url = ["api", "mobile", "assets", assetId, "prepare-ar"].reduce(config.apiBaseURL) {
            $0.appendingPathComponent($1)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 60
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MobilePrepareARError.network
        }
        if http.statusCode == 401 {
            throw MobilePrepareARError.unauthorized
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if !(200..<300).contains(http.statusCode) {
            throw Self.mapPrepareError(json: json, status: http.statusCode)
        }
        guard let status = json?["status"] as? String else {
            throw MobilePrepareARError.invalidResponse
        }
        return MobilePrepareARResponse(
            assetId: json?["assetId"] as? String ?? assetId,
            status: status,
            usdzUrl: json?["usdzUrl"] as? String,
            alreadyReady: (json?["alreadyReady"] as? Bool) ?? false,
            claimed: (json?["claimed"] as? Bool) ?? false
        )
    }

    private func get(pathComponents: [String]) async throws -> Data {
        let url = pathComponents.reduce(config.apiBaseURL) {
            $0.appendingPathComponent($1)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MobileAssetsAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MobileAssetsAPIError.server(status: http.statusCode)
        }
        return data
    }

    private static func mapPrepareError(json: [String: Any]?, status: Int) -> MobilePrepareARError {
        let code = (json?["error"] as? String) ?? (json?["code"] as? String) ?? "UNKNOWN"
        let message = (json?["message"] as? String) ?? ""
        switch code {
        case "ASSET_NOT_FOUND", "ASSET_NOT_OWNED":
            return .assetNotFound
        case "GLB_NOT_AVAILABLE":
            return .glbNotAvailable
        case "USDZ_PREPARE_UNAVAILABLE":
            return .prepareUnavailable
        case "USDZ_PREPARE_FAILED":
            return .prepareFailed
        case "RATE_LIMITED":
            return .rateLimited
        case "AUTH_REQUIRED":
            return .unauthorized
        default:
            return .server(code: code, message: message, status: status)
        }
    }

    private struct AssetsEnvelope: Decodable {
        var assets: [MobileAssetDTO]
    }

    private struct AssetEnvelope: Decodable {
        var asset: MobileAssetDTO
    }
}
