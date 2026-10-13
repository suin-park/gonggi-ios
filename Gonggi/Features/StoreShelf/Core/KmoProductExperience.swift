import Foundation

// 상품 체험 화면의 순수 규칙: 어떤 버튼을 보여 줄지, 가격 표시, 대표 상품 선택, 카테고리, 저장한 상품. Linux 테스트 대상.
// 판매자가 확인한 값만 쓴다. 가격이나 구매 주소를 만들어 내지 않는다.

enum KmoOfferPolicy {
    /// 외부 링크는 https만, 사용자 정보가 든 주소는 쓰지 않는다. 통과하지 못하면 nil.
    static func validHTTPS(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url.absoluteString
    }

    /// 확인된 가격만. 없거나 0이면 nil(「가격 문의」 같은 문구도 만들지 않는다).
    static func priceText(minor: Int?, currency: String?) -> String? {
        guard let minor, minor > 0 else { return nil }
        if (currency ?? "KRW").uppercased() == "KRW" {
            let digits = String(minor)
            var out = ""
            for (i, ch) in digits.reversed().enumerated() {
                if i > 0, i % 3 == 0 { out.append(",") }
                out.append(ch)
            }
            return String(out.reversed()) + "원"
        }
        return "\(minor) \(currency ?? "")"
    }

    enum Action: Equatable {
        case ar
        case buy(String)
        case inquire(String)
    }

    /// AR은 3D 자산이 준비된 상품만. 구매 링크가 있으면 「구매하러 가기」, 없고 상담 링크만 있으면 「문의하기」.
    static func actions(arReady: Bool, purchaseUrl: String?, consultationUrl: String?) -> [Action] {
        var out: [Action] = []
        if arReady { out.append(.ar) }
        if let buy = validHTTPS(purchaseUrl) {
            out.append(.buy(buy))
        } else if let ask = validHTTPS(consultationUrl) {
            out.append(.inquire(ask))
        }
        return out
    }

    static func label(_ action: Action) -> String {
        switch action {
        case .ar: return "AR로 보기"
        case .buy: return "구매하러 가기"
        case .inquire: return "문의하기"
        }
    }
}

struct KmoFeaturedCandidate: Equatable, Sendable {
    var id: String
    var isFurniture3D: Bool
    var availableForPlacement: Bool?
    var hasThumbnail: Bool
}

enum KmoFeaturedSelection {
    /// 홈 대표 상품 후보: 3D로 체험할 수 있는 가구만, 배치 불가로 표시된 상품은 뺀다. 앞선 순서를 유지한다.
    static func order(_ items: [KmoFeaturedCandidate]) -> [String] {
        items.filter { $0.isFurniture3D && $0.availableForPlacement != false }.map(\.id)
    }
}

enum KmoCategoryChips {
    struct Chip: Equatable, Sendable {
        var key: String
        var title: String
    }

    /// 실제 상품이 있는 종류만 칩이 된다. 두 종류 이상이 아니면 칩을 만들지 않는다(작동하지 않는 버튼 없음).
    static func make(hasFurniture3D: Bool, hasCurtain2D: Bool) -> [Chip] {
        var kinds: [Chip] = []
        if hasFurniture3D { kinds.append(Chip(key: "furniture", title: "가구")) }
        if hasCurtain2D { kinds.append(Chip(key: "curtain", title: "커튼")) }
        guard kinds.count >= 2 else { return [] }
        return [Chip(key: "all", title: "전체")] + kinds
    }
}

// MARK: - 저장한 상품 (이 기기, 계정별)

struct KmoSavedProduct: Codable, Equatable, Identifiable, Sendable {
    var productId: String
    var name: String
    var partner: String?
    var thumbnailUrl: String?
    var savedAt: Date

    var id: String { productId }
}

struct KmoSavedProductStore {
    static let keyPrefix = "kmo.saved.v1."
    static let limit = 100

    var storage: KmoKeyValueStorage

    private func key(_ account: String) -> String { Self.keyPrefix + account }

    func load(account: String?) -> [KmoSavedProduct] {
        guard let account, !account.isEmpty, let data = storage.kmoData(forKey: key(account)) else { return [] }
        let all = (try? JSONDecoder().decode([KmoSavedProduct].self, from: data)) ?? []
        return all.sorted { $0.savedAt > $1.savedAt }
    }

    func isSaved(productId: String, account: String?) -> Bool {
        load(account: account).contains { $0.productId == productId }
    }

    /// 저장되어 있으면 빼고, 없으면 추가한다. 결과 목록을 돌려준다.
    @discardableResult
    func toggle(_ item: KmoSavedProduct, account: String?) -> [KmoSavedProduct] {
        guard let account, !account.isEmpty else { return [] }
        var all = load(account: account)
        if all.contains(where: { $0.productId == item.productId }) {
            all.removeAll { $0.productId == item.productId }
        } else {
            all.insert(item, at: 0)
            if all.count > Self.limit { all = Array(all.prefix(Self.limit)) }
        }
        storage.kmoSet(all.isEmpty ? nil : try? JSONEncoder().encode(all), forKey: key(account))
        return all
    }
}
