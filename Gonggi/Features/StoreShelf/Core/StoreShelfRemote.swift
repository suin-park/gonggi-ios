import Foundation

// Server-facing data of the 매장 feature: DTOs, the publication bundle (manifest + map + images share one version),
// feature-model compatibility, role-based visibility and name search. Foundation only (Linux-testable).

// MARK: - DTOs

struct RemoteStoreItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var branchName: String?
    var address: String
    var latitude: Double?
    var longitude: Double?
    var distanceM: Int?
    var publishedVersion: Int
    var publishedAt: String?
    var productCount: Int

    /// "공기마트 강남점"
    var displayName: String {
        if let b = branchName, !b.isEmpty { return name + " " + b }
        return name
    }
}

struct RemoteManagedStore: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var branchName: String?
    var address: String
    var status: String
    var latestVersion: Int?
    var latestStatus: String?

    var displayName: String {
        if let b = branchName, !b.isEmpty { return name + " " + b }
        return name
    }
}

struct RemoteReleaseFile: Codable, Equatable, Sendable {
    var path: String
    var bytes: Int
    var sha256: String
    var url: String
}

struct RemoteProductLink: Codable, Equatable, Sendable {
    var storeProductId: String
    var catalogProductId: String
    var catalogName: String?
}

struct RemoteReleaseView: Codable, Equatable, Sendable {
    var storeId: String
    var releaseId: String
    var version: Int
    var publishedAt: String?
    var featureModel: String
    var schemaVersion: Int
    var files: [RemoteReleaseFile]
    var productLinks: [RemoteProductLink]
    var expiresInSec: Int
    /// The published catalog next to the release (names a manager corrected, products added without a capture).
    var catalog: RemoteCatalogOverlay? = nil
}

struct ReleaseDeclarationFile: Codable, Equatable, Sendable {
    var path: String
    var bytes: Int
    var sha256: String
}

struct ReleaseDeclarationBody: Codable, Equatable, Sendable {
    var featureModel: String
    var schemaVersion: Int
    var productIds: [String]
    var placementCount: Int
    var files: [ReleaseDeclarationFile]
}

struct RemoteUploadTarget: Codable, Equatable, Sendable {
    var path: String
    var url: String
    var contentType: String
    var expiresInSec: Int
}

struct RemoteDraftRelease: Codable, Equatable, Sendable {
    var releaseId: String
    var version: Int
    var uploads: [RemoteUploadTarget]
}

// MARK: - Feature model compatibility

/// Embeddings from different models or revisions are not comparable. The publisher records which one it used; a device
/// uses the same revision or does not match by image at all.
enum StoreFeatureModel {
    static let family = "vision.featureprint"

    static func format(revision: Int, elementCount: Int) -> String {
        "\(family).r\(revision).\(elementCount)"
    }

    static func parse(_ s: String) -> (revision: Int, elementCount: Int)? {
        let parts = s.split(separator: ".").map(String.init)
        // vision . featureprint . r2 . 768
        guard parts.count == 4, parts[0] + "." + parts[1] == family, parts[2].hasPrefix("r"),
              let rev = Int(parts[2].dropFirst()), let count = Int(parts[3]), rev > 0, count > 0 else { return nil }
        return (rev, count)
    }

    enum Compatibility: Equatable {
        case compatible(revision: Int, elementCount: Int)
        case incompatible(reason: String)

        var isCompatible: Bool {
            if case .compatible = self { return true }
            return false
        }
    }

    static func evaluate(release: String, supportedRevisions: Set<Int>) -> Compatibility {
        guard let parsed = parse(release) else { return .incompatible(reason: "알 수 없는 인식 모델 형식") }
        guard supportedRevisions.contains(parsed.revision) else {
            return .incompatible(reason: "이 기기는 인식 모델 r\(parsed.revision)을 지원하지 않아요")
        }
        return .compatible(revision: parsed.revision, elementCount: parsed.elementCount)
    }
}

// MARK: - Visibility by role

/// What the signed-in person may see. `managedStoreIds` comes from the server; the app never grants it by itself.
struct StoreShelfAccess: Equatable, Sendable {
    var managedStoreIds: Set<String> = []

    static let customer = StoreShelfAccess()

    var isManager: Bool { !managedStoreIds.isEmpty }

    func canRecord(storeId: String) -> Bool { managedStoreIds.contains(storeId) }

    /// 기록 탭 「매대 기록하기」: feature flag AND (a server-verified manager OR demo mode).
    static func recordMenuVisible(flag: Bool, mockMode: Bool, access: StoreShelfAccess) -> Bool {
        flag && (mockMode || access.isManager)
    }

    /// 고객 「제품 찾기」: everyone, behind the feature flag until the feature is finished.
    static func findMenuVisible(flag: Bool) -> Bool { flag }
}

// MARK: - Publication bundle

enum StoreReleasePackerError: Error, Equatable {
    case noProducts
    case manifestMissing
    case manifestUnreadable
    case worldMapMissing
    case schemaTooNew(Int)
    case fileTooLarge(String)
}

struct StoreReleaseFile: Equatable, Sendable {
    var path: String
    var data: Data
}

struct StoreReleaseBundle: Equatable, Sendable {
    var files: [StoreReleaseFile]
    var declaration: ReleaseDeclarationBody
    /// Image names that data referenced but whose bytes were not available (reported, not silently dropped).
    var missingImages: [String]
}

struct StoreReleaseManifest: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var storeId: String
    var featureModel: String
    var createdAt: Date
    var data: StoreShelfData
}

enum StoreReleasePacker {
    static let schemaVersion = 1
    static let maxImageBytes = 3 * 1024 * 1024

    /// images/ for product crops, shelves/ for shelf photos, signs/ for reference signs.
    static func releasePath(forImageName name: String) -> String {
        if name.hasPrefix("shelf-") { return "shelves/" + name }
        if name.hasPrefix("sign-") { return "signs/" + name }
        return "images/" + name
    }

    static func imageName(forReleasePath path: String) -> String? {
        for prefix in ["images/", "shelves/", "signs/"] where path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return nil
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func pack(data: StoreShelfData, worldMap: Data, featureModel: String, images: (String) -> Data?,
                     sha256: (Data) -> String, now: Date) throws -> StoreReleaseBundle {
        guard !data.products.isEmpty, !data.placements.isEmpty else { throw StoreReleasePackerError.noProducts }
        guard !worldMap.isEmpty else { throw StoreReleasePackerError.worldMapMissing }
        var names: [String] = []
        func add(_ n: String?) {
            if let n, !n.isEmpty, !names.contains(n) { names.append(n) }
        }
        data.products.forEach { $0.imageFileNames.forEach { add($0) } }
        data.shelves.forEach { add($0.photoFileName) }
        data.referenceSigns.forEach { add($0.imageFileName) }

        var files: [StoreReleaseFile] = []
        var missing: [String] = []
        for n in names {
            guard let d = images(n), !d.isEmpty else {
                missing.append(n)
                continue
            }
            guard d.count <= maxImageBytes else { throw StoreReleasePackerError.fileTooLarge(n) }
            files.append(StoreReleaseFile(path: releasePath(forImageName: n), data: d))
        }
        // A file that is missing must not be referenced: drop the reference from the published copy.
        var published = data
        if !missing.isEmpty {
            let gone = Set(missing)
            for i in published.products.indices { published.products[i].imageFileNames.removeAll { gone.contains($0) } }
            for i in published.shelves.indices where published.shelves[i].photoFileName.map(gone.contains) == true {
                published.shelves[i].photoFileName = nil
            }
            published.referenceSigns.removeAll { gone.contains($0.imageFileName) }
        }
        let manifest = StoreReleaseManifest(schemaVersion: schemaVersion, storeId: data.storeId, featureModel: featureModel,
                                            createdAt: now, data: published)
        let manifestData = try encoder().encode(manifest)
        guard manifestData.count <= 20 * 1024 * 1024 else { throw StoreReleasePackerError.fileTooLarge("manifest.json") }
        files.append(StoreReleaseFile(path: "manifest.json", data: manifestData))
        files.append(StoreReleaseFile(path: "worldmap.arworldmap", data: worldMap))
        files.sort { $0.path < $1.path }
        let declaration = ReleaseDeclarationBody(
            featureModel: featureModel, schemaVersion: schemaVersion,
            productIds: published.products.map(\.id), placementCount: published.placements.count,
            files: files.map { ReleaseDeclarationFile(path: $0.path, bytes: $0.data.count, sha256: sha256($0.data)) })
        return StoreReleaseBundle(files: files, declaration: declaration, missingImages: missing)
    }

    struct Unpacked: Equatable {
        var data: StoreShelfData
        var images: [String: Data]
        var worldMap: Data
        var featureModel: String
    }

    static func unpack(files: [String: Data]) throws -> Unpacked {
        guard let m = files["manifest.json"] else { throw StoreReleasePackerError.manifestMissing }
        guard let map = files["worldmap.arworldmap"], !map.isEmpty else { throw StoreReleasePackerError.worldMapMissing }
        guard let manifest = try? decoder().decode(StoreReleaseManifest.self, from: m) else {
            throw StoreReleasePackerError.manifestUnreadable
        }
        guard manifest.schemaVersion <= schemaVersion else { throw StoreReleasePackerError.schemaTooNew(manifest.schemaVersion) }
        var images: [String: Data] = [:]
        for (path, d) in files {
            if let n = imageName(forReleasePath: path) { images[n] = d }
        }
        return Unpacked(data: manifest.data, images: images, worldMap: map, featureModel: manifest.featureModel)
    }
}

// MARK: - Name search

enum ShelfNameSearch {
    static func normalize(_ s: String) -> String {
        let folded = s.precomposedStringWithCanonicalMapping.lowercased()
        return String(folded.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) })
    }

    /// Exact name first, then prefix, then substring; ties in name order. An empty query returns nothing. The stored name,
    /// the text read on the package (`ocrTokens`) and any verified catalogue names (`aliases`, by product id) are searched.
    static func search(_ query: String, products: [ShelfProduct], aliases: [String: [String]] = [:], limit: Int = 8) -> [ShelfProduct] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }
        var scored: [(rank: Int, product: ShelfProduct)] = []
        for p in products {
            var names = [p.name] + (aliases[p.id] ?? [])
            if let b = p.brand { names.append(b) }
            if let t = p.ocrTokens { names += t }
            var best: Int?
            for raw in names {
                let n = normalize(raw)
                guard !n.isEmpty else { continue }
                let rank = n == q ? 0 : (n.hasPrefix(q) ? 1 : (n.contains(q) ? 2 : nil))
                if let rank, rank < (best ?? Int.max) { best = rank }
            }
            if let best { scored.append((best, p)) }
        }
        scored.sort { ($0.rank, $0.product.name) < ($1.rank, $1.product.name) }
        return Array(scored.prefix(limit).map(\.product))
    }
}
