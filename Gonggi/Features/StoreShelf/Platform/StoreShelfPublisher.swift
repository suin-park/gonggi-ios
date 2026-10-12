import Foundation
import Vision

/// The recognition model this device uses to make (and later compare) image features.
enum StoreShelfFeatureModelInfo {
    /// Revisions of Vision's feature print this OS can run.
    static var supportedRevisions: Set<Int> {
        Set(VNGenerateImageFeaturePrintRequest.supportedRevisions.map { Int($0) })
    }

    /// Identifier recorded with a release. Uses the request's default revision and the element count of one embedding.
    static func current(elementCount: Int) -> String {
        let request = VNGenerateImageFeaturePrintRequest()
        return StoreFeatureModel.format(revision: Int(request.revision), elementCount: elementCount)
    }
}

enum StoreShelfPublishError: Error, Equatable {
    case noMap
    case noProducts
    case notManager
}

/// Uploads a reviewed, saved shelf record as one release and publishes it. Only a server-verified manager can complete
/// this (the server checks again); a failure at any step leaves the previously published release in place.
final class StoreShelfPublisher {
    private let api: StoreShelfAPIClient
    private let repository: StoreShelfRepository

    init(api: StoreShelfAPIClient = StoreShelfAPIClient(), repository: StoreShelfRepository = .shared) {
        self.api = api
        self.repository = repository
    }

    /// Returns the published version.
    func publishLocalRecord(storeId: String, progress: @escaping (String) -> Void) async throws -> Int {
        guard let data = repository.shelfData(storeId: storeId), !data.products.isEmpty else { throw StoreShelfPublishError.noProducts }
        guard let map = try? repository.loadWorldMapData(storeId: storeId) else { throw StoreShelfPublishError.noMap }
        let dims = data.products.compactMap { $0.embeddings.first?.values.count }.first ?? 768
        let model = StoreShelfFeatureModelInfo.current(elementCount: dims)
        let store = storeId
        let repo = repository
        progress("게시 자료를 만들고 있어요")
        let bundle = try StoreReleasePacker.pack(
            data: data, worldMap: map, featureModel: model,
            images: { repo.imageData(storeId: store, fileName: $0) },
            sha256: { StoreShelfHash.sha256Hex($0) }, now: Date())
        progress("서버에 게시 준비를 요청해요")
        let draft = try await api.createDraft(storeId: storeId, declaration: bundle.declaration)
        let byPath = Dictionary(uniqueKeysWithValues: bundle.files.map { ($0.path, $0.data) })
        var n = 0
        for target in draft.uploads {
            n += 1
            progress("올리는 중 \(n)/\(draft.uploads.count)")
            guard let bytes = byPath[target.path] else { throw StoreShelfAPIError.invalidResponse }
            try await api.upload(bytes, to: target)
        }
        progress("게시하는 중")
        try await api.publish(storeId: storeId, releaseId: draft.releaseId)
        return draft.version
    }
}
