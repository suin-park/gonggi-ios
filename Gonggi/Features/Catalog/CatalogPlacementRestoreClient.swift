import Foundation

/// Re-resolve Catalog USDZ for placements already saved on an owned space.
/// Works even when the product is later unpublished from Gonggi.
actor CatalogPlacementRestoreClient {
    private let config: AppConfiguration
    private let session: URLSession

    init(
        config: AppConfiguration = .production,
        session: URLSession = .shared
    ) {
        self.config = config
        self.session = session
    }

    struct Response: Decodable {
        var ok: Bool?
        var placementSpec: CatalogPlacementSpec?
        var displayName: String?
        var catalogProductId: String?
        var catalogVariantId: String?
        var catalogPartnerId: String?
    }

    func fetchPlacementSpec(spaceId: String, catalogAssetId: String) async throws -> CatalogPlacementSpec {
        var request = URLRequest(
            url: config.apiBaseURL
                .appendingPathComponent("api/gonggi/spaces")
                .appendingPathComponent(spaceId)
                .appendingPathComponent("catalog-assets")
                .appendingPathComponent(catalogAssetId)
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CatalogAPIError.server(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let spec = decoded.placementSpec else {
            throw CatalogAPIError.invalidResponse
        }
        switch CatalogPlacementSpecValidator.validate(spec) {
        case .success(let valid):
            return valid
        case .failure:
            throw CatalogAPIError.invalidResponse
        }
    }
}
