import Foundation

// From the server's analysis draft to the data the rest of the app already understands (shelves, products with image
// features, placements). Pure Swift: image cropping and feature extraction are injected (`AnalysisImportHooks`).
//
// Rules
//  - A shelf's position is whatever the phone measured (`spatial`). A shelf without it is kept as "위치 확인 필요" and is
//    never guided to.
//  - A product's name is what was read on the package. An unread name stays the placeholder "제품 N" with a review
//    reason; nothing is invented. A name the manager set is never replaced.
//  - Quantity is what was visible when photographed (`visibleCount`, `countBasis`, `lastObservedAt`), never stock, and
//    never added up across captures: a new capture replaces the observations of the shelves it saw.

struct AnalysisProductImage: Sendable {
    var jpeg: Data
    var embedding: [Float]
    var color: [Float]
}

struct AnalysisImportHooks {
    /// Crop of a product (box in the upright photo, fractions) with its image features; nil when it cannot be made.
    var productImage: (_ photoId: String, _ box: RemoteBox) -> AnalysisProductImage?
    /// The upright photo as JPEG (shelf representative image).
    var shelfPhoto: (_ photoId: String) -> Data?
}

struct AnalysisImportSummary: Equatable, Sendable {
    var shelves = 0
    var shelvesWithoutPosition = 0
    var products = 0
    var productsNeedingReview = 0
    var productsKeptFromBefore = 0
    var productsRemovedFromBefore = 0
    var productsWithoutShelf = 0
    /// Shelves a customer can be guided to (measured position or recorded approach point).
    var shelvesGuidable = 0
    /// Of those, shelves guided to a recorded approach point because the shelf position was not measured.
    var shelvesApproachOnly = 0
    var shelvesAmbiguous = 0
}

struct AnalysisImportResult {
    var data: StoreShelfData
    var images: [String: Data]
    var summary: AnalysisImportSummary
}

/// Which captured photos go to the server. The app keeps at most `StoreAutoCaptureConfig.maxPhotos`, the server accepts
/// `serverMaxPhotos` per session; a larger local session (older build) is uploaded as an evenly spread subset instead of
/// failing, and every photo stays on the device.
enum StoreUploadPlan {
    static let serverMaxPhotos = 40

    static func subset<T>(_ photos: [T], max limit: Int) -> [T] {
        guard limit > 0, photos.count > limit else { return photos }
        if limit == 1 { return [photos[0]] }
        var seen = Set<Int>()
        var out: [T] = []
        for i in 0..<limit {
            let idx = Int((Double(i) * Double(photos.count - 1) / Double(limit - 1)).rounded())
            if seen.insert(idx).inserted { out.append(photos[idx]) }
        }
        return out
    }
}

enum AnalysisImporter {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        if let d = iso.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        return plain.date(from: s)
    }

    static func vec(_ a: [Float]) -> Vec3? {
        a.count == 3 && a.allSatisfy({ $0.isFinite }) ? Vec3(a[0], a[1], a[2]) : nil
    }

    /// Plane of a shelf front from the measured position and normal: (u, v, n) right-handed, v = up.
    static func plane(position: Vec3, normal: Vec3) -> ShelfPlane? {
        guard let n = normal.horizontal.normalized else { return nil }
        guard let u = Vec3.up.cross(n).normalized else { return nil }
        return ShelfPlane(origin: position, uAxis: u, normal: n)
    }

    static func importDraft(draft: RemoteAnalysisDraft, existing: StoreShelfData, storeId: String, capturedAt: Date,
                            walkTrail: [ShelfWalkSample], newId: () -> String, hooks: AnalysisImportHooks,
                            referencePoints: [ShelfReferencePoint] = []) -> AnalysisImportResult {
        var data = StoreShelfData.empty(storeId: storeId)
        var images: [String: Data] = [:]
        var summary = AnalysisImportSummary()
        let now = Date()

        // Shelves.
        var shelfIdByKey: [String: String] = [:]
        for s in draft.shelves {
            let id = newId()
            shelfIdByKey[s.key] = id
            var plane = ShelfPlane(origin: .zero, uAxis: Vec3(1, 0, 0), normal: Vec3(0, 0, 1))
            var status = "unknown"
            if let sp = s.spatial, let pos = vec(sp.position), let n = vec(sp.normal), let p = Self.plane(position: pos, normal: n) {
                plane = p
                status = sp.status == "confirmed" ? "confirmed" : "needs_confirmation"
            }
            var photoName: String?
            if let pid = s.representativePhotoId, let jpeg = hooks.shelfPhoto(pid) {
                photoName = "shelf-\(id).jpg"
                images[photoName!] = jpeg
            }
            var layout = ShelfLayout(id: id, name: (s.name?.isEmpty == false ? s.name! : "매대 \(data.shelves.count + 1)"), plane: plane,
                                     tierBoundaries: [], createdAt: now, updatedAt: now, photoFileName: photoName)
            layout.locationStatus = status
            layout.positionMethod = status == "unknown" ? nil : s.spatial?.source
            if let a = s.approach, let p = vec(a.point), let d = vec(a.viewDir) {
                layout.approach = ShelfApproachPoint(point: p, viewDir: d, bestPhotoId: a.bestPhotoId, evidencePhotoCount: a.photoIds.count,
                                                     distanceToShelfM: a.distanceToShelfM, status: a.status)
            }
            if let g = s.guidance, layout.approach != nil || g.target != "approach_point" {
                // Ambiguous shelf keys are replaced by shelf ids below, once every shelf has its id.
                layout.guidance = ShelfGuidanceTarget(target: g.target, status: g.status, basis: g.basis, ambiguousWithShelfIds: g.ambiguousWith)
            }
            layout.lastObservedAt = parseDate(s.lastObservedAt) ?? capturedAt
            data.shelves.append(layout)
            summary.shelves += 1
            if status == "unknown" { summary.shelvesWithoutPosition += 1 }
        }

        for i in data.shelves.indices {
            guard var g = data.shelves[i].guidance else { continue }
            g.ambiguousWithShelfIds = g.ambiguousWithShelfIds.compactMap { shelfIdByKey[$0] }
            data.shelves[i].guidance = g
            if data.shelves[i].isGuidable { summary.shelvesGuidable += 1 }
            if !data.shelves[i].hasMeasuredPosition, data.shelves[i].hasApproachDestination { summary.shelvesApproachOnly += 1 }
            if !g.ambiguousWithShelfIds.isEmpty { summary.shelvesAmbiguous += 1 }
        }
        data.referencePoints = referencePoints.isEmpty ? nil : referencePoints

        // Products: an existing product with the same printed name keeps its id (and a name a person set).
        var existingByKey: [String: ShelfProduct] = [:]
        for p in existing.products where !ShelfProductNameExtractor.isPlaceholder(p.name) {
            existingByKey[ShelfProductNameExtractor.key(p.name)] = p
        }
        var productIdByKey: [String: String] = [:]
        var matchedExisting = Set<String>()
        var counter = 0
        for p in draft.products {
            counter += 1
            let read = p.nameOriginal.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
            let nameKey = read ? ShelfProductNameExtractor.key(p.nameOriginal!) : ""
            var product: ShelfProduct
            if read, let old = existingByKey[nameKey] {
                product = old
                matchedExisting.insert(old.id)
                summary.productsKeptFromBefore += 1
                product.embeddings = []
                product.colorDescriptors = []
                product.imageFileNames = []
                product.similarProductIds = []
                if !product.nameIsProtected {
                    product.name = p.nameOriginal!
                    product.nameSource = ShelfNameSource.auto
                }
            } else {
                product = ShelfProduct(
                    id: newId(), name: read ? p.nameOriginal! : "제품 \(counter)", createdAt: now, imageFileNames: [], embeddings: [],
                    colorDescriptors: [], similarProductIds: [], needsReview: false, reviewReasons: [])
                product.nameSource = read ? ShelfNameSource.auto : nil
            }
            product.brand = p.brand
            product.variantText = p.variant
            product.volumeText = p.volumeText ?? volumeText(value: p.volumeValue, unit: p.volumeUnit)
            var tokens = Set<String>()
            for t in p.printedText + [p.nameOriginal ?? ""] {
                let k = ShelfProductNameExtractor.key(t)
                if k.count >= 2 { tokens.insert(k) }
            }
            product.ocrTokens = Array(tokens.sorted().prefix(24))

            // Review reasons from what could not be confirmed (the server's texts are kept as they are).
            var reasons: [String] = []
            if !read || p.nameReadStatus == "unreadable" {
                reasons.append(ShelfNameReview.unread)
            } else if p.nameReadStatus == "partial" {
                reasons.append(ShelfNameReview.confirm)
            }
            for raw in p.reviewReasons {
                let r = StoreUserText.scrub(raw)
                // The same sentence twice (up to spacing and punctuation) is one warning.
                let key = ShelfProductNameExtractor.key(r)
                if r.isEmpty || r == "이름을 읽지 못했어요" || r.hasPrefix("이름이 일부만") { continue }
                if reasons.contains(where: { ShelfProductNameExtractor.key($0) == key }) { continue }
                reasons.append(r)
            }
            if product.nameIsProtected { reasons.removeAll { ShelfNameReview.all.contains($0) } }
            product.reviewReasons = reasons

            // Image: the representative crop; image features for live search.
            if let rep = p.representative, let img = hooks.productImage(rep.photoId, rep.box) {
                let file = "img-\(newId()).jpg"
                images[file] = img.jpeg
                product.imageFileNames = [file]
                product.embeddings = [StoreVector(img.embedding)]
                product.colorDescriptors = [StoreVector(img.color)]
            }
            // Additional views for matching: other sightings (bounded).
            for s in p.sightings.prefix(4) where product.embeddings.count < 4 {
                if let rep = p.representative, rep.photoId == s.photoId, rep.box == s.box { continue }
                if let img = hooks.productImage(s.photoId, s.box) {
                    product.embeddings.append(StoreVector(img.embedding))
                    product.colorDescriptors.append(StoreVector(img.color))
                }
            }
            productIdByKey[p.key] = product.id
            data.products.append(product)
        }

        // Placements: one per product and shelf, with the quantity seen at that time.
        var hasShelf = Set<String>()
        for o in draft.observations {
            guard let pid = productIdByKey[o.productKey], let sk = o.shelfKey, let sid = shelfIdByKey[sk],
                  let shelf = data.shelves.first(where: { $0.id == sid }) else { continue }
            let observed = parseDate(o.observedAt) ?? capturedAt
            var placement = ShelfPlacement(
                id: newId(), productId: pid, shelfId: sid, u: 0, v: 0, tier: 0, world: shelf.plane.origin, widthM: 0.1, heightM: 0.2,
                uncertaintyM: 0.3, observationCount: max(1, o.evidencePhotoIds.count), firstObservedAt: observed, lastObservedAt: observed,
                status: .present, needsReview: shelf.locationStatus != "confirmed")
            placement.visibleCount = o.visibleCount
            placement.countBasis = o.countBasis
            data.placements.append(placement)
            hasShelf.insert(pid)
        }
        for i in data.products.indices {
            if !hasShelf.contains(data.products[i].id) {
                summary.productsWithoutShelf += 1
                let note = "어느 매대에 있는지 확인되지 않았어요"
                if !data.products[i].reviewReasons.contains(note) { data.products[i].reviewReasons.append(note) }
            }
            data.products[i].needsReview = !data.products[i].reviewReasons.isEmpty
            if data.products[i].needsReview { summary.productsNeedingReview += 1 }
        }

        // Products of the previous record that this capture did not see: only a person-named product is kept.
        for old in existing.products where !matchedExisting.contains(old.id) {
            if old.nameIsProtected, !data.products.contains(where: { $0.id == old.id }) {
                var kept = old
                kept.needsReview = true
                if !kept.reviewReasons.contains("이번 촬영에서는 보이지 않았어요") { kept.reviewReasons.append("이번 촬영에서는 보이지 않았어요") }
                data.products.append(kept)
                summary.productsKeptFromBefore += 1
            } else {
                summary.productsRemovedFromBefore += 1
            }
        }
        // Image files of kept products stay (the caller copies them from the repository by name).
        for p in data.products where matchedExisting.contains(p.id) == false && p.imageFileNames.isEmpty { _ = p }

        data.walkTrail = Array(walkTrail.suffix(4000))
        data.updatedAt = now
        summary.products = data.products.count
        return AnalysisImportResult(data: data, images: images, summary: summary)
    }

    static func volumeText(value: Double?, unit: String?) -> String? {
        guard let value, let unit, !unit.isEmpty else { return nil }
        let n = value.rounded() == value ? String(Int(value)) : String(value)
        return n + unit
    }
}

/// The quantity line shown to customers and managers. "촬영 당시", never "재고".
enum VisibleQuantityText {
    static func line(visibleCount: Int?, basis: String?) -> String {
        guard let n = visibleCount, basis != "cannot_count" else { return "수량은 확인되지 않았어요" }
        return basis == "lower_bound" ? "촬영 당시 최소 \(n)개 확인" : "촬영 당시 \(n)개 확인"
    }
}

/// What the processing screen says about a run: the model that really answered (not only the one asked for), the
/// state, and how many photos were analysed.
enum AnalysisRunText {
    static func detail(_ run: RemoteAnalysisRun) -> String {
        var parts: [String] = []
        if let answered = run.responseModel {
            parts.append(answered == run.model ? answered : "요청 \(run.model) / 응답 \(answered)")
        } else {
            parts.append("\(run.model) (응답 대기)")
        }
        switch run.status {
        case "SUCCEEDED": parts.append("완료")
        case "FAILED": parts.append("실패")
        default: parts.append("분석 중")
        }
        if let c = run.coverage {
            parts.append(c.complete ? "사진 \(c.analyzedPhotos)장 모두 분석" : "사진 \(c.totalPhotos)장 중 \(c.analyzedPhotos)장만 분석 · 일부 영역 미분석")
        }
        return parts.joined(separator: " · ")
    }
}

/// The numbers shown on the review screen. A "placement" is a product-on-a-shelf link: it is not the number of shelves.
struct StoreSpaceSummary: Equatable, Sendable {
    var products = 0
    var shelves = 0
    /// Product-to-shelf links (the old "위치 N곳").
    var productShelfLinks = 0
    /// Shelves a customer can be guided to (measured position, or a recorded approach point).
    var guidableShelves = 0
    var approachOnlyShelves = 0
    /// Shelves whose position / approach is not known: the manager has to look at them.
    var shelvesNeedingPosition = 0
    var ambiguousShelves = 0
    /// Shelves a person confirmed on a device.
    var verifiedOnDeviceShelves = 0

    init(data: StoreShelfData) {
        products = data.products.count
        shelves = data.shelves.count
        productShelfLinks = data.placements.count
        for s in data.shelves {
            if s.isGuidable { guidableShelves += 1 } else { shelvesNeedingPosition += 1 }
            if !s.hasMeasuredPosition, s.hasApproachDestination { approachOnlyShelves += 1 }
            if let g = s.guidance, !g.ambiguousWithShelfIds.isEmpty { ambiguousShelves += 1 }
            if s.deviceVerifiedAt != nil { verifiedOnDeviceShelves += 1 }
        }
    }

    var headline: String {
        "제품 \(products)개 · 매대 \(shelves)곳 · AR 안내 가능 \(guidableShelves)곳 · 위치 확인 필요 \(shelvesNeedingPosition)곳"
    }
}

enum ShelfPositionText {
    /// How the shelf position was obtained, in words a manager can check.
    static func method(_ s: ShelfLayout) -> String {
        if s.hasMeasuredPosition {
            switch s.positionMethod {
            case "plane_intersection": return "매대 위치: 벽면 인식으로 계산됨"
            case "surface_hit": return "매대 위치: 표면 측정으로 계산됨"
            default: return "매대 위치: 직접 지정"
            }
        }
        if s.hasApproachDestination { return "매대 위치는 계산하지 못했어요 · 촬영한 위치까지 안내" }
        return "위치 확인 필요"
    }

    /// "계산됨" never means "실기기 검증됨".
    static func verification(_ s: ShelfLayout) -> String {
        s.deviceVerifiedAt != nil ? "실기기 안내 확인됨" : "실기기 안내 검증 전"
    }
}
