import ARKit
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
    /// Hardware identifier such as "iPhone15,4", recorded with a saved map so a restore is judged on the same model.
    static var identifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

enum StoreShelfObservedOffset {
    static let options: [(key: String, label: String)] = [
        ("not_checked", "확인 안 함"),
        ("within_2cm", "2cm 이내"),
        ("within_5cm", "5cm 이내"),
        ("within_10cm", "10cm 이내"),
        ("over_10cm", "10cm 초과"),
    ]
}

// MARK: - Flow: store choice, then the camera

/// 매대 기록하기 / 제품 찾기 entry. A store is chosen (or created, in record mode) before a camera opens.
struct StoreShelfFlowView: View {
    let onClose: () -> Void

    @State private var mode: StoreShelfFlowMode
    @State private var stores: [StoreRecord] = []
    @State private var selected: StoreRecord?
    @State private var newName = ""
    @State private var errorText: String?
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
                    StoreShelfRecordCameraView(store: store, repository: repository, onBack: { selected = nil; reload() })
                case .search:
                    StoreShelfSearchCameraView(
                        store: store,
                        repository: repository,
                        onBack: { selected = nil; reload() },
                        onRecordFirst: { mode = .record }
                    )
                }
            } else {
                chooser
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        stores = repository.stores()
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
                    Text(mode == .record ? "기록할 매장을 고르거나 새로 만들어요" : "찾을 매장을 골라요")
                        .font(.subheadline)
                        .foregroundStyle(GonggiColors.textSecondary)
                    ForEach(stores) { store in
                        storeRow(store)
                    }
                    if mode == .record { createStoreSection }
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
        let info = repository.worldMapInfo(storeId: store.id)
        return Button {
            GonggiHaptics.medium()
            selected = store
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.name)
                        .font(.headline)
                        .foregroundStyle(GonggiColors.textPrimary)
                    Text(info == nil ? "매대 기록 전" : "매대 기록됨")
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
        .accessibilityLabel("\(store.name), \(info == nil ? "매대 기록 전" : "매대 기록됨")")
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
            reload()
            selected = store
        } catch {
            errorText = "매장 이름을 입력해 주세요."
        }
    }
}

// MARK: - Record camera

struct StoreShelfRecordCameraView: View {
    let store: StoreRecord
    let repository: any StoreShelfWriting
    let onBack: () -> Void

    @StateObject private var controller = StoreShelfARController()
    @State private var markers: [StoreTestMarker] = []
    @State private var saveText: String?
    @State private var saving = false

    private var markersEnabled: Bool { StoreShelfFeatureFlags.testMarkersEnabled }

    var body: some View {
        ZStack {
            StoreShelfARViewHost(controller: controller, role: .record, showsMarkers: markersEnabled) {
                controller.startRecording()
            }
            .ignoresSafeArea()

            if markersEnabled {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityHidden(true)
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                panel
            }
        }
        .onDisappear { controller.stop() }
    }

    private var topBar: some View {
        HStack {
            Button {
                controller.stop()
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .accessibilityLabel("뒤로")
            Text(store.name)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.4), in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Text(controller.trackingText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text(statusLine)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
            if markersEnabled {
                Text(StoreShelfCopy.testMarkerNotice + " (\(markers.count)개)")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                SecondaryButton(title: "시험용 표시 놓기", icon: "mappin") { placeMarker() }
            }
            if controller.saveReadiness != .ready {
                Text(StoreShelfCopy.saveNeedsMoreScan)
                    .font(.footnote)
                    .foregroundStyle(GonggiColors.warningCritical)
            }
            PrimaryButton(title: saving ? "저장 중..." : "이 매대 저장하기", icon: "square.and.arrow.down") { save() }
                .disabled(saving)
            if let saveText {
                Text(saveText)
                    .font(.footnote)
                    .foregroundStyle(.white)
            }
            if let message = controller.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(GonggiColors.warningCritical)
            }
        }
        .padding(GonggiSpacing.md)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var statusLine: String {
        switch controller.saveReadiness {
        case .ready: return "저장할 수 있어요"
        case .needsMoreScan: return "매대 주변을 더 비춰 주세요"
        case .notAvailable: return "주변을 인식하고 있어요"
        }
    }

    private func placeMarker() {
        let label = "시험 \(markers.count + 1)"
        if let marker = controller.placeTestMarker(label: label) {
            markers.append(marker)
            GonggiHaptics.light()
        }
    }

    private func save() {
        saving = true
        saveText = nil
        controller.captureWorldMap { result in
            saving = false
            switch result {
            case .failure(let error):
                if let e = error as? StoreWorldMapError, e == .notReady {
                    saveText = StoreShelfCopy.saveNeedsMoreScan
                } else {
                    saveText = "저장하지 못했어요. 잠시 후 다시 시도해 주세요."
                }
            case .success(let map):
                do {
                    let data = try StoreWorldMapCoding.archive(map)
                    let current = controller.currentMarkers(known: markers)
                    let info = StoreWorldMapInfo(
                        savedAt: Date(),
                        byteCount: data.count,
                        mappingStatus: controller.mappingName,
                        markerCount: current.count,
                        extent: [map.extent.x, map.extent.y, map.extent.z],
                        center: [map.center.x, map.center.y, map.center.z],
                        deviceModel: StoreShelfDevice.identifier
                    )
                    try repository.saveWorldMap(storeId: store.id, data: data, info: info, markers: current)
                    markers = current
                    saveText = "매대를 저장했어요 (\(data.count / 1024) KB)"
                    GonggiHaptics.success()
                } catch {
                    saveText = "저장하지 못했어요. 저장 공간을 확인해 주세요."
                }
            }
        }
    }
}

// MARK: - Search camera

/// 제품 찾기 camera. In this stage it only restores the saved map; it recognises nothing and writes no shelf data.
struct StoreShelfSearchCameraView: View {
    let store: StoreRecord
    let repository: any StoreShelfReading & StoreRestoreLogWriting
    let onBack: () -> Void
    let onRecordFirst: () -> Void

    @StateObject private var controller = StoreShelfARController()
    @State private var loadError: String?
    @State private var observedOffset = "not_checked"
    @State private var logText: String?

    private var info: StoreWorldMapInfo? { repository.worldMapInfo(storeId: store.id) }
    private var markersEnabled: Bool { StoreShelfFeatureFlags.testMarkersEnabled }

    var body: some View {
        ZStack {
            if info == nil {
                noMap
            } else {
                StoreShelfARViewHost(controller: controller, role: .search, showsMarkers: markersEnabled) {
                    begin()
                }
                .ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    panel
                }
            }
        }
        .onDisappear { controller.stop() }
    }

    private var noMap: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.md) {
            HStack {
                Button("뒤로") { onBack() }
                    .foregroundStyle(GonggiColors.textSecondary)
                Spacer()
            }
            Text(store.name)
                .font(.title2.weight(.bold))
                .foregroundStyle(GonggiColors.textPrimary)
            Text(StoreShelfCopy.noWorldMapLine)
                .font(.subheadline)
                .foregroundStyle(GonggiColors.textSecondary)
            PrimaryButton(title: StoreShelfCopy.recordTitle, icon: "viewfinder") { onRecordFirst() }
            Spacer()
        }
        .padding(20)
    }

    private var topBar: some View {
        HStack {
            Button {
                controller.stop()
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .accessibilityLabel("뒤로")
            Text(store.name)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.4), in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Text(restoreLine)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            if let loadError {
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(GonggiColors.warningCritical)
            }
            if !StoreShelfFeatureFlags.productRecognitionAvailable {
                Text(StoreShelfCopy.recognitionUnavailable)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
            }
            if markersEnabled {
                Text(StoreShelfCopy.testMarkerNotice + " 불러온 표시 \(controller.restoredMarkerCount)/\(controller.expectedMarkerCount)")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                if case .restored = controller.restorePhase { checkSection }
            }
            if case .failed = controller.restorePhase {
                SecondaryButton(title: "다시 불러오기", icon: "arrow.clockwise") { begin() }
            }
        }
        .padding(GonggiSpacing.md)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    /// The tester's check against a known real-world spot, recorded with the restore attempt.
    private var checkSection: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            Text("실제 기준점과 표시 위치의 차이")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
            Picker("차이", selection: $observedOffset) {
                ForEach(StoreShelfObservedOffset.options, id: \.key) { option in
                    Text(option.label).tag(option.key)
                }
            }
            .pickerStyle(.menu)
            .tint(.white)
            SecondaryButton(title: "복원 결과 기록", icon: "list.clipboard") { logAttempt() }
            if let logText {
                Text(logText)
                    .font(.footnote)
                    .foregroundStyle(.white)
            }
        }
    }

    private var restoreLine: String {
        switch controller.restorePhase {
        case .idle: return "저장한 매대를 불러오고 있어요"
        case .relocalizing: return StoreShelfCopy.relocalizeHint
        case .restored(let seconds): return "저장한 위치를 불러왔어요 (\(Int(seconds.rounded()))초)"
        case .failed: return "저장한 위치를 불러오지 못했어요. 저장할 때 비춘 매대 가까이에서 다시 시도해 주세요."
        }
    }

    private func begin() {
        loadError = nil
        guard let info else { return }
        do {
            let data = try repository.loadWorldMapData(storeId: store.id)
            let map = try StoreWorldMapCoding.unarchive(data)
            controller.startRestoring(map: map, expectedMarkers: info.markerCount)
        } catch {
            loadError = "저장한 매대 정보를 읽지 못했어요. 매대를 다시 기록해 주세요."
        }
    }

    private func logAttempt() {
        let attempt = StoreRestoreAttempt(
            id: UUID().uuidString,
            startedAt: controller.startedAt ?? Date(),
            outcome: controller.outcomeName,
            secondsToRelocalize: controller.secondsToRelocalize,
            markersExpected: controller.expectedMarkerCount,
            markersPresentAfterRestore: controller.restoredMarkerCount,
            trackingReasonsSeen: controller.trackerReasons,
            observedOffset: observedOffset,
            note: nil
        )
        do {
            try repository.appendRestoreAttempt(storeId: store.id, attempt: attempt)
            logText = "기록했어요"
        } catch {
            logText = "기록하지 못했어요"
        }
    }
}
