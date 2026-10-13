import Foundation

// 커모 화면의 순수 로직 (Linux 테스트 대상). 화면 문구와 최근 본 제품, 사장님 화면 전환 규칙만 담는다.

// MARK: - 확인 시각 문구

enum KmoConfirmedText {
    /// "오늘 오전 10시 확인", "어제 오후 3시 확인", 그 밖에는 "10월 12일 확인".
    static func line(iso: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let iso, let date = AnalysisImporter.parseDate(iso) else { return "확인한 시각이 없어요" }
        let dayGap = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        let hour = calendar.component(.hour, from: date)
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        let meridiem = hour < 12 ? "오전" : "오후"
        if dayGap == 0 { return "오늘 \(meridiem) \(h12)시 확인" }
        if dayGap == 1 { return "어제 \(meridiem) \(h12)시 확인" }
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return "\(month)월 \(day)일 확인"
    }
}

// MARK: - 최근 본 제품

struct KmoRecentProduct: Codable, Equatable, Identifiable, Sendable {
    var identity: String
    var name: String
    var subtitle: String
    var imageUrl: String?
    var viewedAt: Date

    var id: String { identity }
}

protocol KmoKeyValueStorage {
    func kmoData(forKey key: String) -> Data?
    func kmoSet(_ data: Data?, forKey key: String)
}

extension UserDefaults: KmoKeyValueStorage {
    func kmoData(forKey key: String) -> Data? { data(forKey: key) }

    func kmoSet(_ data: Data?, forKey key: String) {
        if let data { set(data, forKey: key) } else { removeObject(forKey: key) }
    }
}

/// 계정별 기록. 계정이 없으면 읽지도 쓰지도 않는다. 같은 제품은 하나만 남고 가장 최근 것이 앞에 온다.
struct KmoRecentStore {
    static let limit = 12
    static let keyPrefix = "kmo.recent.v1."

    var storage: KmoKeyValueStorage

    func key(account: String) -> String { Self.keyPrefix + account }

    func load(account: String?) -> [KmoRecentProduct] {
        guard let account, !account.isEmpty, let data = storage.kmoData(forKey: key(account: account)) else { return [] }
        let items = (try? JSONDecoder().decode([KmoRecentProduct].self, from: data)) ?? []
        return items.sorted { $0.viewedAt > $1.viewedAt }
    }

    @discardableResult
    func record(_ item: KmoRecentProduct, account: String?) -> [KmoRecentProduct] {
        guard let account, !account.isEmpty else { return [] }
        var items = load(account: account).filter { $0.identity != item.identity }
        items.insert(item, at: 0)
        if items.count > Self.limit { items = Array(items.prefix(Self.limit)) }
        save(items, account: account)
        return items
    }

    @discardableResult
    func remove(identity: String, account: String?) -> [KmoRecentProduct] {
        guard let account, !account.isEmpty else { return [] }
        let items = load(account: account).filter { $0.identity != identity }
        save(items, account: account)
        return items
    }

    private func save(_ items: [KmoRecentProduct], account: String) {
        storage.kmoSet(items.isEmpty ? nil : try? JSONEncoder().encode(items), forKey: key(account: account))
    }
}

// MARK: - 사장님 화면 전환

enum KmoAppMode {
    /// 전환 항목을 보여 줄지: 서버가 확인한 매장 권한이 있고, 매장 기능이 켜진 빌드(또는 데모)일 때만.
    static func switchVisible(menuFlag: Bool, isManager: Bool, mockMode: Bool) -> Bool {
        mockMode || (menuFlag && isManager)
    }

    /// 저장된 선택이 있어도 권한이 없으면 고객 화면이다. 전환은 권한을 만들지 않는다.
    static func isOwner(stored: Bool, switchVisible: Bool) -> Bool {
        stored && switchVisible
    }
}

enum KmoStorePick {
    /// 기억한 지점이 아직 담당 지점이면 그것, 아니면 첫 번째.
    static func resolve(managedIds: [String], stored: String?) -> String? {
        if let stored, managedIds.contains(stored) { return stored }
        return managedIds.first
    }
}

// MARK: - 화면 문구

enum KmoCopy {
    static let brand = "커모"
    static let tagline = "커머스의 모든 것"
    static let findProduct = "제품 찾기"
    static let namePlaceholder = "제품 이름을 입력하세요"
    static let search = "검색"
    static let camera = "카메라로 찾기"
    static let browse = "둘러보기"
    static let browseStores = "매장 둘러보기"
    static let mySpace = "내 공간에서 보기"
    static let recent = "최근 본 제품"
    static let confirmedStores = "확인된 매장"
    static let nearestFirst = "가까운 순"
    static let findInStore = "매장 안에서 AR로 찾기"
    static let slowlyAround = "매장 안에서 주변을 천천히 비춰 주세요."
}
