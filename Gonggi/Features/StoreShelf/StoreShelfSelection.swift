import Foundation

/// The store used last, kept across launches and shared by 매대 기록하기 and 제품 찾기.
enum StoreShelfSelection {
    static let defaultsKey = "GonggiStoreShelfLastStoreId"

    static var lastStoreId: String? {
        get { UserDefaults.standard.string(forKey: defaultsKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: defaultsKey) } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }

    /// The remembered store when it still exists, else the only store when there is exactly one.
    static func resolve(among stores: [StoreRecord]) -> StoreRecord? {
        if let id = lastStoreId, let hit = stores.first(where: { $0.id == id }) { return hit }
        return stores.count == 1 ? stores.first : nil
    }
}
