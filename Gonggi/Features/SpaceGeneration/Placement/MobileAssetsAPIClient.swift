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

    private struct AssetsEnvelope: Decodable {
        var assets: [MobileAssetDTO]
    }

    private struct AssetEnvelope: Decodable {
        var asset: MobileAssetDTO
    }
}
