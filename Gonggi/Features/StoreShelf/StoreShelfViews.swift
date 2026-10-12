import SwiftUI
import UIKit

enum StoreShelfFlowMode: Equatable {
    case record
    case search

    var title: String {
        switch self {
        case .record: return StoreShelfCopy.recordTitle
        case .search: return StoreShelfCopy.findTitle
        }
    }
}

enum StoreShelfDevice {
    /// Hardware identifier such as "iPhone14,8", recorded with a saved map so a restore is judged on the same model.
    static var identifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

// MARK: - Flow: store choice, then the camera

/// 매대 기록하기 / 제품 찾기 entry. Both use the same stores. The store used last is remembered and opened directly the
/// first time this screen appears; "다른 매장" returns to the list.
struct StoreShelfFlowView: View {
    let onClose: () -> Void

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var role = StoreShelfRoleModel.shared
    @State private var mode: StoreShelfFlowMode
    @State private var stores: [StoreRecord] = []
    @State private var selected: StoreRecord?
    @State private var newName = ""
    @State private var errorText: String?
    @State private var didAutoSelect = false
    private let repository = StoreShelfRepository.shared

    init(mode: StoreShelfFlowMode, onClose: @escaping () -> Void) {
        _mode = State(initialValue: mode)
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            GonggiAmbientBackground()
            if let store = selected {
                switch mode {
                case .record:
                    StoreShelfRecordView(store: store, onBack: { selected = nil; reload() })
                case .search:
                    StoreShelfSearchView(
                        source: StoreShelfSearchSource.localRecord(storeId: store.id, storeName: store.name),
                        onBack: { selected = nil; reload() },
                        onRecordFirst: { mode = .record })
                }
            } else {
                chooser
            }
        }
        .task {
            await role.refresh()
            reload()
            if !didAutoSelect {
                didAutoSelect = true
                if let remembered = StoreShelfSelection.resolve(among: stores), mode == .record || hasData(remembered) {
                    selected = remembered
                }
            }
        }
    }

    /// Recording lists only the stores the SERVER says this person manages (demo mode keeps the local list).
    private func reload() {
        if appState.isMockMode {
            stores = repository.stores()
        } else {
            stores = role.managedStores.map { repository.ensureStore(id: $0.id, name: $0.displayName) }
        }
    }

    private func hasData(_ store: StoreRecord) -> Bool {
        repository.worldMapInfo(storeId: store.id) != nil
    }

    private var chooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                HStack {
                    Text(mode.title)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(GonggiColors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("닫기", action: onClose)
                        .foregroundStyle(GonggiColors.textSecondary)
                }
                .padding(.top, GonggiSpacing.md)

                if mode == .search && stores.isEmpty {
                    emptySearch
                } else {
                    Text(mode == .record
                         ? (appState.isMockMode ? "기록할 매장을 고르거나 새로 만들어요" : "담당 매장을 골라요")
                         : "찾을 매장을 골라요")
                        .font(.subheadline)
                        .foregroundStyle(GonggiColors.textSecondary)
                    ForEach(stores) { store in
                        storeRow(store)
                    }
                    if mode == .record, appState.isMockMode { createStoreSection }
                    if mode == .record, !appState.isMockMode, stores.isEmpty {
                        Text("담당으로 지정된 매장이 없어요. 매장 담당자 권한은 관리자가 지정해요.")
                            .font(.subheadline)
                            .foregroundStyle(GonggiColors.textSecondary)
                    }
                }

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(GonggiColors.warningCritical)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, GonggiSpacing.xxl)
        }
    }

    private var emptySearch: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Text(StoreShelfCopy.noStoreTitle)
                .font(.headline)
                .foregroundStyle(GonggiColors.textPrimary)
            Text(StoreShelfCopy.noStoreLine)
                .font(.subheadline)
                .foregroundStyle(GonggiColors.textSecondary)
            PrimaryButton(title: StoreShelfCopy.recordTitle, icon: "viewfinder") { mode = .record }
                .padding(.top, GonggiSpacing.sm)
        }
        .padding(GonggiSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GonggiColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }

    private func storeRow(_ store: StoreRecord) -> some View {
        let data = repository.shelfData(storeId: store.id)
        let recorded = hasData(store)
        let summary = recorded ? "제품 \(data?.products.count ?? 0)개 · 매대 \(data?.shelves.count ?? 0)곳" : "매대 기록 전"
        let last = StoreShelfSelection.lastStoreId == store.id
        return Button {
            GonggiHaptics.medium()
            selected = store
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.name)
                        .font(.headline)
                        .foregroundStyle(GonggiColors.textPrimary)
                    Text(summary + (last ? " · 마지막 사용" : ""))
                        .font(.subheadline)
                        .foregroundStyle(GonggiColors.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GonggiColors.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(GonggiColors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(store.name), \(summary)")
    }

    private var createStoreSection: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Text("새 매장 만들기")
                .font(.headline)
                .foregroundStyle(GonggiColors.textPrimary)
            TextField("매장 이름", text: $newName)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
            PrimaryButton(title: "만들고 기록하기", icon: "plus") { createStore() }
        }
        .padding(.top, GonggiSpacing.sm)
    }

    private func createStore() {
        do {
            let store = try repository.createStore(name: newName)
            newName = ""
            errorText = nil
            StoreShelfSelection.lastStoreId = store.id
            reload()
            selected = store
        } catch {
            errorText = "매장 이름을 입력해 주세요."
        }
    }
}
