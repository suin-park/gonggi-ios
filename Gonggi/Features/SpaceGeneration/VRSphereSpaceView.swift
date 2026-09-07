import Combine
import SwiftUI
import AVFoundation
import SceneKit
import simd
import UIKit

/// Full-screen VR with long-press → selective repair flow (async after HTTP 202).
struct VRSphereSpaceView: View {
    let imageURL: URL
    let sessionId: String
    var baseRevisionId: String = "rev-0-base"
    var onClose: () -> Void
    /// Optional: notify parent of new local texture path (do not recreate viewer — orientation preserved in-place).
    var onRepairCompleted: ((URL) -> Void)? = nil

    @StateObject private var repairController: RepairSessionController
    @State private var pendingTarget: RepairTarget?
    @State private var showConfirmSheet = false
    @State private var captureTarget: RepairTarget?
    @State private var markerYawDeg: Float?
    @State private var markerPitchDeg: Float?
    @State private var textureURL: URL
    @State private var textureGeneration: Int = 0
    @State private var uploadError: String?
    @State private var panoramaReady = false
    @State private var showSelectiveRepairHint = false
    @State private var selectiveRepairHintOpacity: Double = 0
    /// True only after fade-in has started and markSeen ran for this presentation.
    @State private var selectiveRepairHintBecameVisible = false
    @State private var selectiveRepairHintTask: Task<Void, Never>?
    @State private var motionEnabled: Bool = true
    @State private var motionHardwareOK: Bool = true
    @State private var recenterToken: Int = 0
    @State private var showMotionHint = false
    @State private var motionHintOpacity: Double = 0
    @State private var motionHintTask: Task<Void, Never>?
    @State private var interactionMode: VRInteractionMode = .view
    @State private var draftLayout = VRPlacementLayout()
    @State private var selectedPlacementId: String?
    @State private var editTool: VREditTool = .none
    @State private var assetPickerPresented = false
    @State private var lockerAssets: [MobileAssetDTO] = []
    @State private var assetMetadata: [String: MobileAssetDTO] = [:]
    @State private var modelURLs: [String: URL] = [:]
    @State private var saveError: String?
    @State private var loadingAssets = false
    @State private var placementRequestToken = 0
    @State private var pendingPlacementAsset: MobileAssetDTO?
    @State private var didLoadPlacement = false
    @State private var placementTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let placementStore = VRPlacementLayoutStore()
    private let assetsClient = MobileAssetsAPIClient()
    private let usdzCache = VRUsdzCache()

    init(
        imageURL: URL,
        sessionId: String,
        baseRevisionId: String = "rev-0-base",
        onClose: @escaping () -> Void,
        onRepairCompleted: ((URL) -> Void)? = nil
    ) {
        self.imageURL = imageURL
        self.sessionId = sessionId
        self.baseRevisionId = baseRevisionId
        self.onClose = onClose
        self.onRepairCompleted = onRepairCompleted
        _textureURL = State(initialValue: imageURL)
        _repairController = StateObject(wrappedValue: RepairSessionController(sessionId: sessionId))
        _motionEnabled = State(
            initialValue: VRMotionPreferences.resolvedMotionEnabled(
                reduceMotion: UIAccessibility.isReduceMotionEnabled
            )
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Panorama360SceneOnlyView(
                imageURL: textureURL,
                textureGeneration: textureGeneration,
                markerYawDeg: markerYawDeg,
                markerPitchDeg: markerPitchDeg,
                maskRadiusYawDeg: Float(pendingTarget?.radiusYawDeg
                    ?? Double(VRSphereEquirectBridge.defaultYawRadiusDeg)),
                maskRadiusPitchDeg: Float(pendingTarget?.radiusPitchDeg
                    ?? Double(VRSphereEquirectBridge.defaultPitchRadiusDeg)),
                motionDesiredEnabled: motionEnabled,
                confirmSheetPresented: showConfirmSheet,
                recenterToken: recenterToken,
                editModeActive: interactionMode == .edit,
                repairLongPressEnabled: interactionMode == .view,
                placementEntries: draftLayout.assets,
                placementFloorY: draftLayout.floorY,
                assetMetadata: assetMetadata,
                modelURLs: modelURLs,
                selectedId: selectedPlacementId,
                editTool: editTool,
                placementRequestToken: placementRequestToken,
                environmentLightingURL: textureURL,
                onViewerReady: {
                    panoramaReady = true
                    scheduleHintFlowIfNeeded()
                    loadPlacementIfNeeded()
                },
                onLongPress: { yaw, pitch in
                    GonggiHaptics.medium()
                    markSelectiveRepairHintSeenAndHide()
                    hideMotionHintImmediate()
                    let target = RepairTarget.make(
                        sessionId: sessionId,
                        baseRevisionId: baseRevisionId,
                        targetYawDeg: Double(yaw),
                        targetPitchDeg: Double(pitch)
                    )
                    pendingTarget = target
                    markerYawDeg = yaw
                    markerPitchDeg = pitch
                    #if DEBUG
                    print(
                        "[repair-bridge] long-press equirect yaw=\(yaw) pitch=\(pitch) session=\(sessionId)"
                    )
                    #endif
                    showConfirmSheet = true
                },
                onMotionHardwareAvailable: { available in
                    motionHardwareOK = available
                },
                onPlacedAssetTapped: { id in
                    selectedPlacementId = id
                    editTool = id == nil ? .none : editTool
                },
                onPlacedAssetTransformChanged: { id, position, rotationY, scale in
                    updateDraftTransform(
                        id: id,
                        position: position,
                        rotationY: rotationY,
                        scale: scale
                    )
                },
                onPlacementPointResolved: { point in
                    addPendingAsset(at: point)
                }
            )
            .ignoresSafeArea()
            .allowsHitTesting(true)

            Button {
                GonggiHaptics.light()
                if interactionMode == .edit {
                    exitEditMode()
                } else {
                    onClose()
                }
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
            }
            .padding(.leading, 16)
            .padding(.top, 12)
            .zIndex(2)

            if interactionMode == .view {
                vrToolbar
                    .padding(.trailing, 16)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .zIndex(2)
            } else {
                editDoneButton
                    .zIndex(3)
            }

            if showMotionHint {
                motionHintPill
                    .opacity(motionHintOpacity)
                    .padding(.horizontal, 64)
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(motionHintOpacity < 0.05)
                    .zIndex(1)
            }

            if showSelectiveRepairHint {
                SelectiveRepairHintPill()
                    .opacity(selectiveRepairHintOpacity)
                    .padding(.horizontal, 64)
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(selectiveRepairHintOpacity < 0.05)
                    .zIndex(1)
            }

            #if DEBUG
            if VRSphereEquirectBridge.debugOverlayEnabled,
               let my = markerYawDeg,
               let mp = markerPitchDeg {
                VStack(alignment: .leading, spacing: 4) {
                    Text("repair target")
                        .font(.caption2.weight(.semibold))
                    Text(String(format: "yaw %+.1f°  pitch %+.1f°", my, mp))
                        .font(.caption.monospacedDigit())
                    Text(
                        "mask ±\(Int(VRSphereEquirectBridge.defaultYawRadiusDeg))° / ±\(Int(VRSphereEquirectBridge.defaultPitchRadiusDeg))° · 넓게 적용됨"
                    )
                        .font(.caption2)
                }
                .foregroundStyle(.white)
                .padding(10)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.trailing, 16)
                .padding(.top, 56)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
            }
            #endif

            repairBanner
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 28)
                .allowsHitTesting(true)

            if interactionMode == .edit {
                editBottomBar
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 28)
                    .zIndex(3)
            }

            if saveError != nil {
                saveErrorBanner
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 68)
                    .zIndex(4)
            }
        }
        .statusBarHidden(true)
        .onChange(of: repairController.completedTextureURL) { _, newURL in
            guard let newURL else { return }
            applyCompletedTexture(newURL)
        }
        .onAppear {
            repairController.refreshFromStore()
            if let url = repairController.completedTextureURL {
                applyCompletedTexture(url)
            }
            if panoramaReady {
                scheduleHintFlowIfNeeded()
            }
        }
        .onDisappear {
            cancelSelectiveRepairHintTask(resetIfNotYetVisible: true)
            motionHintTask?.cancel()
            motionHintTask = nil
            placementTask?.cancel()
            placementTask = nil
        }
        .sheet(isPresented: $showConfirmSheet, onDismiss: {
            if captureTarget == nil {
                clearRepairSelection()
            }
        }) {
            RepairConfirmSheet(
                onRecapture: {
                    guard let target = pendingTarget else { return }
                    showConfirmSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        captureTarget = target
                    }
                },
                onCancel: {
                    showConfirmSheet = false
                    clearRepairSelection()
                }
            )
            .presentationDetents([.height(220)])
        }
        .sheet(isPresented: $assetPickerPresented) {
            assetPicker
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $captureTarget) { target in
            RepairManualCaptureView(
                target: target,
                onCancel: {
                    captureTarget = nil
                    clearRepairSelection()
                },
                onSubmitted: {
                    // 202 + persist + success feedback already shown in capture.
                    // Dismiss capture + VR; SpaceRepairRuntime polling keeps running.
                    captureTarget = nil
                    markerYawDeg = nil
                    markerPitchDeg = nil
                    pendingTarget = nil
                    // Do not set repairing banner — user leaves VR; card shows “수정 중”.
                    onClose()
                }
            )
        }
        .alert("부분 수정에 실패했어요", isPresented: Binding(
            get: { uploadError != nil },
            set: { if !$0 { uploadError = nil } }
        )) {
            Button("확인", role: .cancel) { uploadError = nil }
        } message: {
            Text(uploadError ?? "")
        }
    }

    private var editDoneButton: some View {
        Button("완료") {
            GonggiHaptics.light()
            Task { await saveAndFinishEditing() }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Color.blue.opacity(0.9))
        .clipShape(Capsule())
        .padding(.trailing, 16)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .topTrailing)
        .zIndex(3)
    }

    @ViewBuilder
    private var editBottomBar: some View {
        VStack(spacing: 10) {
            if let selectedPlacementId,
               let entry = draftLayout.assets.first(where: { $0.id == selectedPlacementId }),
               modelURLs[entry.assetId] == nil {
                Text("원본을 불러올 수 없어요")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.55), in: Capsule())
            }

            HStack(spacing: 8) {
                if selectedPlacementId != nil {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("한 손가락으로 이동")
                        Text("두 손가락으로 회전·크기 조절")
                    }
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 4)

                    Button {
                        deleteSelectedPlacement()
                    } label: {
                        Label("삭제", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else {
                    Button {
                        assetPickerPresented = true
                    } label: {
                        Label("+ 3D 오브젝트", systemImage: "cube")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draftLayout.assets.count >= VRPlacementLayout.maxAssets)
                }
            }
            .font(.footnote.weight(.semibold))
            .padding(10)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var saveErrorBanner: some View {
        HStack(spacing: 10) {
            Text("배치를 저장하지 못했어요")
                .font(.footnote.weight(.medium))
            Button("다시 시도") {
                Task { await saveAndFinishEditing() }
            }
            .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.red.opacity(0.85), in: Capsule())
    }

    private var assetPicker: some View {
        NavigationStack {
            Group {
                if loadingAssets {
                    ProgressView("3D 오브젝트를 불러오는 중")
                } else {
                    List(lockerAssets) { asset in
                        let available = asset.availableForPlacement
                            && asset.usdzUrl.flatMap(URL.init(string:)) != nil
                        Button {
                            guard available else { return }
                            pendingPlacementAsset = asset
                            assetPickerPresented = false
                            placementRequestToken += 1
                        } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: asset.thumbUrl.flatMap(URL.init(string:))) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Color.gray.opacity(0.2)
                                        .overlay(Image(systemName: "cube"))
                                }
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(asset.name)
                                        .foregroundStyle(.primary)
                                    if let createdAt = asset.createdAt {
                                        Text(createdAt)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if !available {
                                        Text("3D 준비 중")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .disabled(!available || draftLayout.assets.count >= VRPlacementLayout.maxAssets)
                    }
                }
            }
            .navigationTitle("3D 오브젝트")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var vrToolbar: some View {
        HStack(spacing: 8) {
            Button {
                enterEditMode()
            } label: {
                Text("편집")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(height: 40)
                    .padding(.horizontal, 12)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Capsule())
            }

            Button {
                GonggiHaptics.light()
                recenterToken += 1
            } label: {
                Image(systemName: "location.north.line")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
            }
            .accessibilityLabel("시점 재설정")

            Button {
                GonggiHaptics.light()
                let next = !motionEnabled
                motionEnabled = next
                VRMotionPreferences.setMotionEnabled(next)
            } label: {
                Image(systemName: "gyroscope")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle((motionEnabled && motionHardwareOK) ? Color.white : Color.white.opacity(0.45))
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
                    .overlay {
                        if !motionEnabled || !motionHardwareOK {
                            Image(systemName: "line.diagonal")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
            }
            .accessibilityLabel(motionEnabled ? "모션 끄기" : "모션 켜기")
        }
    }

    private var motionHintPill: some View {
        VStack(spacing: 4) {
            Text(VRMotionPreferences.motionHintPrimary)
                .font(.footnote.weight(.medium))
            Text(VRMotionPreferences.motionHintSecondary)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            Capsule()
                .fill(Color.black.opacity(0.55))
                .background(.ultraThinMaterial, in: Capsule())
        }
        .clipShape(Capsule())
        .accessibilityLabel(VRMotionPreferences.motionHintPrimary)
    }

    private func enterEditMode() {
        markSelectiveRepairHintSeenAndHide()
        hideMotionHintImmediate()
        clearRepairSelection()
        saveError = nil
        selectedPlacementId = nil
        editTool = .none
        interactionMode = .edit
    }

    private func exitEditMode() {
        interactionMode = .view
        selectedPlacementId = nil
        editTool = .none
        saveError = nil
    }

    private func saveAndFinishEditing() async {
        // Build 66: keep in-memory draft + scene nodes; switch to View immediately.
        // Never wait for PUT before showing placements in View.
        let snapshot = draftLayout
        #if DEBUG
        print(
            "[vr-place66] Done pressed draftCount=\(snapshot.assets.count) mode→view"
        )
        #endif
        try? await placementStore.saveLocal(snapshot, sessionId: sessionId)
        exitEditMode()

        do {
            let saved = try await placementStore.pushRemote(snapshot, sessionId: sessionId)
            #if DEBUG
            print(
                "[vr-place66] PUT ok requestCount=\(snapshot.assets.count) responseCount=\(saved.assets.count)"
            )
            #endif
            // Guard against empty/mismatched decode wiping local placements.
            let responseIds = Set(saved.assets.map(\.id))
            let snapshotIds = Set(snapshot.assets.map(\.id))
            if saved.assets.count >= snapshot.assets.count
                || responseIds == snapshotIds
                || snapshot.assets.isEmpty {
                draftLayout = saved
                try? await placementStore.saveLocal(saved, sessionId: sessionId)
            } else {
                #if DEBUG
                print("[vr-place66] PUT response ignored (would shrink layout); keeping draft")
                #endif
                try? await placementStore.saveLocal(snapshot, sessionId: sessionId)
            }
            saveError = nil
        } catch {
            #if DEBUG
            print("[vr-place66] PUT failed; keeping draft count=\(draftLayout.assets.count)")
            #endif
            saveError = "배치를 저장하지 못했어요"
        }
    }

    private func loadPlacementIfNeeded() {
        guard !didLoadPlacement else { return }
        didLoadPlacement = true
        loadingAssets = true
        placementTask = Task {
            let local = try? await placementStore.loadLocal(sessionId: sessionId)
            let remote = try? await placementStore.fetchRemote(sessionId: sessionId)
            let merged = await placementStore.merge(local: local, remote: remote)
            guard !Task.isCancelled else { return }
            draftLayout = merged
            try? await placementStore.saveLocal(merged, sessionId: sessionId)

            do {
                let assets = try await assetsClient.fetchAssets()
                guard !Task.isCancelled else { return }
                lockerAssets = assets
                assetMetadata = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
                loadingAssets = false
                await downloadModels(for: assets)
            } catch {
                loadingAssets = false
            }
        }
    }

    private func downloadModels(for assets: [MobileAssetDTO]) async {
        let downloadable = assets.compactMap { asset -> (MobileAssetDTO, URL)? in
            guard asset.availableForPlacement,
                  let value = asset.usdzUrl,
                  let url = URL(string: value)
            else { return nil }
            return (asset, url)
        }
        await withTaskGroup(of: (String, URL?).self) { group in
            for (asset, remoteURL) in downloadable {
                group.addTask {
                    (asset.id, await usdzCache.localURL(assetId: asset.id, remoteURL: remoteURL))
                }
            }
            for await (assetId, localURL) in group {
                guard !Task.isCancelled else { return }
                if let localURL {
                    modelURLs[assetId] = localURL
                }
            }
        }
    }

    private func addPendingAsset(at point: SIMD3<Float>) {
        guard let asset = pendingPlacementAsset,
              draftLayout.assets.count < VRPlacementLayout.maxAssets
        else {
            pendingPlacementAsset = nil
            return
        }
        let entry = VRPlacedAssetEntry(
            assetId: asset.id,
            position: SIMD3(point.x, draftLayout.floorY, point.z),
            uniformScale: 1,
            sortIndex: draftLayout.assets.count
        )
        guard draftLayout.append(entry) else { return }
        pendingPlacementAsset = nil
        selectedPlacementId = entry.id
        editTool = .none
        saveDraftLocally()
    }

    private func updateDraftTransform(
        id: String,
        position: SIMD3<Float>,
        rotationY: Float,
        scale: Float
    ) {
        guard let index = draftLayout.assets.firstIndex(where: { $0.id == id }) else { return }
        draftLayout.assets[index].position = SIMD3(position.x, draftLayout.floorY, position.z)
        draftLayout.assets[index].rotationY = rotationY
        draftLayout.assets[index].setUniformScale(scale)
        // Disk write only on gesture end / Done — not every pan.changed (Build 66).
        saveDraftLocally()
    }

    private func deleteSelectedPlacement() {
        guard let id = selectedPlacementId else { return }
        draftLayout.assets.removeAll { $0.id == id }
        for index in draftLayout.assets.indices {
            draftLayout.assets[index].sortIndex = index
        }
        selectedPlacementId = nil
        editTool = .none
        saveDraftLocally()
    }

    private func saveDraftLocally() {
        let layout = draftLayout
        Task {
            try? await placementStore.saveLocal(layout, sessionId: sessionId)
        }
    }

    @ViewBuilder
    private var repairBanner: some View {
        switch repairController.banner {
        case .none:
            EmptyView()
        case .repairing:
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                Text("선택한 부분을 수정하고 있어요")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.55))
            .clipShape(Capsule())
        case .completed:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("선택한 부분을 수정했어요.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.7))
            .clipShape(Capsule())
            .onTapGesture { repairController.dismissCompletedBanner() }
        case .failed(let retryTarget):
            HStack(spacing: 12) {
                Text("부분 수정에 실패했어요.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                if let retryTarget {
                    Button("다시 시도") {
                        repairController.clearFailedBanner()
                        pendingTarget = retryTarget
                        captureTarget = retryTarget
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.65))
            .clipShape(Capsule())
        }
    }

    /// Motion hint first (optional), then Selective Repair one-time hint. Never stacked.
    private func scheduleHintFlowIfNeeded() {
        guard panoramaReady else { return }
        guard motionHintTask == nil, selectiveRepairHintTask == nil else { return }

        let shouldMotionHint =
            motionEnabled
            && !reduceMotion
            && !VRMotionPreferences.hasSeenMotionHint()

        if shouldMotionHint {
            motionHintTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                showMotionHint = true
                motionHintOpacity = 0
                withAnimation(.easeIn(duration: 0.3)) { motionHintOpacity = 1 }
                VRMotionPreferences.markMotionHintSeen()
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.35)) { motionHintOpacity = 0 }
                try? await Task.sleep(nanoseconds: 400_000_000)
                showMotionHint = false
                motionHintTask = nil
                scheduleSelectiveRepairHintIfNeeded()
            }
        } else {
            scheduleSelectiveRepairHintIfNeeded()
        }
    }

    private func hideMotionHintImmediate() {
        motionHintTask?.cancel()
        motionHintTask = nil
        showMotionHint = false
        motionHintOpacity = 0
    }

    /// Gate (user-global, any VR entry via this view):
    /// panorama ready → 0.5s delay → fade in → markSeen → 4.5s hold → fade out.
    /// Does not check whether the space is new; only `hintSeen`.
    private func scheduleSelectiveRepairHintIfNeeded() {
        guard panoramaReady else { return }
        guard !SelectiveRepairHintPreferences.hasSeen else { return }
        guard selectiveRepairHintTask == nil else { return }
        guard !showMotionHint else { return }

        selectiveRepairHintBecameVisible = false
        showSelectiveRepairHint = false
        selectiveRepairHintOpacity = 0

        selectiveRepairHintTask = Task { @MainActor in
            let delayNs = UInt64(SelectiveRepairHintPreferences.postReadyDelaySeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }
            guard !SelectiveRepairHintPreferences.hasSeen else { return }
            guard !showMotionHint else { return }

            showSelectiveRepairHint = true
            selectiveRepairHintOpacity = 0
            withAnimation(.easeIn(duration: SelectiveRepairHintPreferences.fadeInDurationSeconds)) {
                selectiveRepairHintOpacity = 1
            }
            // Persist only once the fade-in has begun (hint is on-screen).
            SelectiveRepairHintPreferences.markSeen()
            selectiveRepairHintBecameVisible = true

            let holdNs = UInt64(SelectiveRepairHintPreferences.displayDurationSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: holdNs)
            guard !Task.isCancelled else { return }

            withAnimation(.easeOut(duration: SelectiveRepairHintPreferences.fadeOutDurationSeconds)) {
                selectiveRepairHintOpacity = 0
            }
            let fadeNs = UInt64(SelectiveRepairHintPreferences.fadeOutDurationSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: fadeNs)
            guard !Task.isCancelled else { return }
            showSelectiveRepairHint = false
            selectiveRepairHintTask = nil
        }
    }

    private func cancelSelectiveRepairHintTask(resetIfNotYetVisible: Bool) {
        selectiveRepairHintTask?.cancel()
        selectiveRepairHintTask = nil
        if resetIfNotYetVisible, !selectiveRepairHintBecameVisible {
            // Dismissed before visible → keep seen=false; allow reschedule on next entry.
            showSelectiveRepairHint = false
            selectiveRepairHintOpacity = 0
        }
    }

    private func markSelectiveRepairHintSeenAndHide() {
        SelectiveRepairHintPreferences.markSeen()
        selectiveRepairHintBecameVisible = true
        selectiveRepairHintTask?.cancel()
        selectiveRepairHintTask = nil
        if showSelectiveRepairHint {
            withAnimation(.easeOut(duration: 0.2)) {
                selectiveRepairHintOpacity = 0
            }
            showSelectiveRepairHint = false
        }
    }

    private func clearRepairSelection() {
        markerYawDeg = nil
        markerPitchDeg = nil
        pendingTarget = nil
    }

    private func applyCompletedTexture(_ url: URL) {
        guard SpaceLatLongStore.isValidLocalFile(at: url.path) else { return }
        // In-place reload — SCNHostView keeps yaw/pitch.
        if textureURL != url {
            textureURL = url
            textureGeneration += 1
            onRepairCompleted?(url)
        } else {
            textureGeneration += 1
        }
    }
}

private struct RepairConfirmSheet: View {
    var onRecapture: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("이 부분을 다시 기록할까요?")
                .font(.headline)
            Text("현재 위치에서 이 방향을 한 장 다시 촬영하면\n선택한 부분만 더 정확하게 수정할 수 있어요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("취소", action: onCancel)
                    .buttonStyle(.bordered)
                Button("다시 촬영", action: onRecapture)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
    }
}

// MARK: - Manual repair camera + preview + upload-to-202

private enum RepairCameraPhase: Equatable {
    case camera
    case preview
    case uploading
    /// HTTP 202 + SpaceRepairStore persist succeeded — show feedback then leave VR.
    case accepted
}

/// Auto-return delay after repair 202 acceptance (seconds).
enum RepairAcceptedNavigation {
    static let autoDismissDelayNanoseconds: UInt64 = 1_200_000_000
}

struct RepairManualCaptureView: View {
    let target: RepairTarget
    var onCancel: () -> Void
    /// Called only after HTTP 202 + job persisted + success feedback delay.
    /// Parent must dismiss capture + VR; must NOT cancel the repair job.
    var onSubmitted: () -> Void

    @StateObject private var model = RepairManualCaptureModel()
    @State private var phase: RepairCameraPhase = .camera
    @State private var previewImage: UIImage?
    @State private var previewYaw: Float = 0
    @State private var previewElev: Float = 0
    @State private var showSoftWarning = false
    @State private var submitError: String?
    @State private var acceptNavigateTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if phase == .accepted {
                acceptedLayer
            } else if phase == .preview || phase == .uploading, let previewImage {
                previewLayer(image: previewImage)
            } else {
                cameraLayer
            }
        }
        .background(Color.black.ignoresSafeArea())
        .alert("업로드에 실패했어요", isPresented: Binding(
            get: { submitError != nil },
            set: { if !$0 { submitError = nil } }
        )) {
            Button("확인", role: .cancel) { submitError = nil }
        } message: {
            Text(submitError ?? "")
        }
        .onAppear {
            model.configure(target: target)
            model.start()
            model.onCaptured = { img, yaw, elev, _, _ in
                previewImage = img
                previewYaw = yaw
                previewElev = elev
                showSoftWarning = model.softMisalignmentWarning
                phase = .preview
            }
        }
        .onDisappear {
            acceptNavigateTask?.cancel()
            // Never cancel the server job — only release camera hardware.
            if phase == .uploading || phase == .accepted {
                model.stop()
            } else {
                model.cancelAndStop()
            }
        }
    }

    private var acceptedLayer: some View {
        ZStack {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .opacity(0.35)
            }
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.green.opacity(0.95))
                Text("수정을 시작했어요")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("완료되면 보관함에서 확인할 수 있어요.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.88))
                    .multilineTextAlignment(.center)
            }
            .padding(28)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("수정을 시작했어요. 완료되면 보관함에서 확인할 수 있어요.")
    }

    private var cameraLayer: some View {
        ZStack {
            RepairCameraPreview(session: model.engine.session)
                .ignoresSafeArea()

            Circle()
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                .frame(width: 28, height: 28)

            VStack(spacing: 10) {
                Text("수정할 부분을 다시 촬영해주세요.")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .multilineTextAlignment(.center)
                Text("처음 기록했던 위치에서\n수정할 부분이 잘 보이도록 한 장 촬영해주세요.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if model.softMisalignmentWarning {
                    Text("선택한 부분이 화면에 잘 보이는지 확인해주세요.")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.yellow)
                        .padding(.top, 4)
                }

                Spacer()

                HStack {
                    Button("취소") {
                        GonggiHaptics.light()
                        model.cancelAndStop()
                        onCancel()
                    }
                    .foregroundStyle(.white)
                    .frame(width: 72)

                    Spacer()

                    Button {
                        GonggiHaptics.medium()
                        model.capture()
                    } label: {
                        ZStack {
                            Circle()
                                .stroke(Color.white, lineWidth: 4)
                                .frame(width: 72, height: 72)
                            Circle()
                                .fill(Color.white)
                                .frame(width: 58, height: 58)
                        }
                    }
                    .accessibilityLabel("촬영")

                    Spacer()
                    Color.clear.frame(width: 72)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 36)
            }
            .padding(.top, 52)
        }
    }

    private func previewLayer(image: UIImage) -> some View {
        VStack(spacing: 0) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            if showSoftWarning, phase == .preview {
                Text("선택한 부분이 화면에 잘 보이는지 확인해주세요.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.yellow)
                    .padding(.top, 8)
            }

            if phase == .uploading {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("사진을 올리고 있어요…")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                }
                .padding(.vertical, 12)
            }

            HStack(spacing: 12) {
                Button("취소") {
                    GonggiHaptics.light()
                    guard phase == .preview || phase == .camera else { return }
                    model.cancelAndStop()
                    onCancel()
                }
                .buttonStyle(.bordered)
                .disabled(phase == .uploading || phase == .accepted)

                Button("다시 촬영") {
                    GonggiHaptics.light()
                    guard phase == .preview else { return }
                    previewImage = nil
                    phase = .camera
                    model.retake()
                }
                .buttonStyle(.bordered)
                .disabled(phase == .uploading || phase == .accepted)

                Button("이 사진으로 수정") {
                    GonggiHaptics.medium()
                    Task { await submit(image: image) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(phase == .uploading || phase == .accepted)
            }
            .padding(16)
            .padding(.bottom, 20)
        }
    }

    private func submit(image: UIImage) async {
        phase = .uploading
        model.stop()
        do {
            let job = try await SpaceRepairRuntime.shared.submitRepair(
                target: target,
                image: image,
                capturedYawDeg: previewYaw,
                capturedElevationDeg: previewElev,
                repairMode: "marked_region_direct_edit"
            )
            // Gate: 202 create + durable store upsert already done inside submitRepair.
            guard SpaceRepairStore.shared.job(repairJobId: job.repairJobId) != nil else {
                phase = .preview
                model.start()
                submitError = "수정 요청을 저장하지 못했어요. 다시 시도해주세요."
                return
            }
            await SpaceRepairRuntime.shared.ensurePolling(
                repairJobId: job.repairJobId,
                sessionId: job.sessionId
            )
            GonggiHaptics.success()
            phase = .accepted
            acceptNavigateTask?.cancel()
            acceptNavigateTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: RepairAcceptedNavigation.autoDismissDelayNanoseconds)
                guard !Task.isCancelled else { return }
                // Leave capture + VR; polling continues in SpaceRepairRuntime (not cancelled).
                onSubmitted()
            }
        } catch {
            // POST failed — stay on preview; do not auto-dismiss.
            phase = .preview
            model.start()
            submitError = "사진을 올리지 못했어요. 다시 시도해주세요."
        }
    }
}

@MainActor
final class RepairManualCaptureModel: ObservableObject {
    let engine = RepairOneShotCaptureEngine()
    @Published var softMisalignmentWarning = false
    var onCaptured: ((UIImage, Float, Float, Float, Float) -> Void)?

    func configure(target: RepairTarget) {
        engine.targetEquirectYawDeg = Float(target.targetYawDeg)
        engine.targetPitchDeg = Float(target.targetPitchDeg)
        engine.onUIUpdate = { [weak self] in
            Task { @MainActor in
                self?.softMisalignmentWarning = self?.engine.softMisalignmentWarning ?? false
            }
        }
        engine.onCaptured = { [weak self] img, yaw, elev, dyaw, dpitch in
            Task { @MainActor in
                self?.softMisalignmentWarning = self?.engine.softMisalignmentWarning ?? false
                self?.onCaptured?(img, yaw, elev, dyaw, dpitch)
            }
        }
    }

    func start() {
        do {
            try engine.prepareCamera(mockMode: false)
            engine.start()
        } catch {
            softMisalignmentWarning = false
        }
    }

    func capture() { engine.captureNow() }
    func retake() { engine.resetForRetake() }
    func stop() { engine.stop() }

    func cancelAndStop() {
        engine.cancelPendingPhoto()
        engine.stop()
    }
}

private struct RepairCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - SceneKit VR host representable

private struct Panorama360SceneOnlyView: UIViewRepresentable {
    let imageURL: URL
    var textureGeneration: Int
    var markerYawDeg: Float?
    var markerPitchDeg: Float?
    var maskRadiusYawDeg: Float
    var maskRadiusPitchDeg: Float
    var motionDesiredEnabled: Bool
    var confirmSheetPresented: Bool
    var recenterToken: Int
    var editModeActive: Bool
    var repairLongPressEnabled: Bool
    var placementEntries: [VRPlacedAssetEntry]
    var placementFloorY: Float
    var assetMetadata: [String: MobileAssetDTO]
    var modelURLs: [String: URL]
    var selectedId: String?
    var editTool: VREditTool
    var placementRequestToken: Int
    var environmentLightingURL: URL?
    var onViewerReady: (() -> Void)? = nil
    var onLongPress: (Float, Float) -> Void
    var onMotionHardwareAvailable: ((Bool) -> Void)? = nil
    var onPlacedAssetTapped: ((String?) -> Void)? = nil
    var onPlacedAssetTransformChanged: ((String, SIMD3<Float>, Float, Float) -> Void)? = nil
    var onPlacementPointResolved: ((SIMD3<Float>) -> Void)? = nil

    func makeUIView(context: Context) -> SCNHostView {
        let host = SCNHostView()
        host.onLongPressEquirect = onLongPress
        host.onMotionAvailabilityChanged = { available in
            onMotionHardwareAvailable?(available)
        }
        host.onPlacedAssetTapped = onPlacedAssetTapped
        host.onPlacedAssetTransformChanged = onPlacedAssetTransformChanged
        host.configure(imageURL: imageURL)
        host.setMotionDesiredEnabled(motionDesiredEnabled)
        host.setConfirmSheetPresented(confirmSheetPresented)
        host.setEditModeActive(editModeActive)
        host.setRepairLongPressEnabled(repairLongPressEnabled)
        host.syncPlacedAssets(
            placementEntries,
            floorY: placementFloorY,
            metadata: assetMetadata,
            modelURLs: modelURLs
        )
        host.setEditTool(editTool, selectedId: selectedId, floorY: placementFloorY)
        if let environmentLightingURL {
            host.applyEnvironmentLighting(from: environmentLightingURL)
        }
        host.updateSelection(
            yawDeg: markerYawDeg,
            pitchDeg: markerPitchDeg,
            radiusYawDeg: maskRadiusYawDeg,
            radiusPitchDeg: maskRadiusPitchDeg
        )
        context.coordinator.lastGeneration = textureGeneration
        context.coordinator.lastURL = imageURL
        context.coordinator.lastRecenterToken = recenterToken
        context.coordinator.lastMotionDesired = motionDesiredEnabled
        context.coordinator.lastPlacementRequestToken = placementRequestToken
        DispatchQueue.main.async {
            context.coordinator.didNotifyReady = true
            onViewerReady?()
        }
        return host
    }

    func updateUIView(_ uiView: SCNHostView, context: Context) {
        uiView.onLongPressEquirect = onLongPress
        uiView.onMotionAvailabilityChanged = { available in
            onMotionHardwareAvailable?(available)
        }
        uiView.onPlacedAssetTapped = onPlacedAssetTapped
        uiView.onPlacedAssetTransformChanged = onPlacedAssetTransformChanged
        if textureGeneration != context.coordinator.lastGeneration
            || imageURL != context.coordinator.lastURL {
            uiView.reloadTexture(from: imageURL)
            context.coordinator.lastGeneration = textureGeneration
            context.coordinator.lastURL = imageURL
        }
        if motionDesiredEnabled != context.coordinator.lastMotionDesired {
            uiView.setMotionDesiredEnabled(motionDesiredEnabled)
            context.coordinator.lastMotionDesired = motionDesiredEnabled
        }
        uiView.setConfirmSheetPresented(confirmSheetPresented)
        uiView.setEditModeActive(editModeActive)
        uiView.setRepairLongPressEnabled(repairLongPressEnabled)
        // Rebuild nodes only when membership / models change — not on every transform drag.
        let placementFingerprint = placementEntries.map { "\($0.id):\($0.assetId)" }.joined(separator: ",")
            + "|" + modelURLs.keys.sorted().joined(separator: ",")
            + "|" + "\(assetMetadata.count)|\(placementFloorY)"
        if placementFingerprint != context.coordinator.lastPlacementFingerprint {
            uiView.syncPlacedAssets(
                placementEntries,
                floorY: placementFloorY,
                metadata: assetMetadata,
                modelURLs: modelURLs
            )
            context.coordinator.lastPlacementFingerprint = placementFingerprint
        }
        uiView.setEditTool(editTool, selectedId: selectedId, floorY: placementFloorY)
        if let environmentLightingURL {
            uiView.applyEnvironmentLighting(from: environmentLightingURL)
        }
        if placementRequestToken != context.coordinator.lastPlacementRequestToken {
            context.coordinator.lastPlacementRequestToken = placementRequestToken
            let size = uiView.viewportSize
            let point = uiView.floorPointFromScreen(
                CGPoint(x: size.width * 0.5, y: size.height * 0.55),
                floorY: placementFloorY
            )
            DispatchQueue.main.async {
                onPlacementPointResolved?(point)
            }
        }
        if recenterToken != context.coordinator.lastRecenterToken {
            uiView.recenterKeepingVisual()
            context.coordinator.lastRecenterToken = recenterToken
        }
        uiView.updateSelection(
            yawDeg: markerYawDeg,
            pitchDeg: markerPitchDeg,
            radiusYawDeg: maskRadiusYawDeg,
            radiusPitchDeg: maskRadiusPitchDeg
        )
        if !context.coordinator.didNotifyReady {
            context.coordinator.didNotifyReady = true
            DispatchQueue.main.async {
                onViewerReady?()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastGeneration: Int = -1
        var lastURL: URL?
        var didNotifyReady = false
        var lastRecenterToken: Int = 0
        var lastMotionDesired: Bool = true
        var lastPlacementRequestToken: Int = 0
        var lastPlacementFingerprint: String = ""
    }
}
