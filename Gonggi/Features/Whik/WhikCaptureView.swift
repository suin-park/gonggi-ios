import SwiftUI

/// The three public capture types and what they open. Each card starts the existing flow unchanged.
/// Case order is the card order on the Capture tab: 360° first, then 3D Space, then 3D Object.
enum WhikCaptureKind: String, CaseIterable, Identifiable {
    /// `DirectionCaptureView` → Lat Long 360° space (server).
    case space360
    /// `ThreeDSpaceRecordFlowView` → 3DGS space (server, `ServerGenerationProfileMapper.spatialPackageProfile`).
    case space3D
    /// `ObjectCaptureFlowView` → 3DGS product/object (server).
    case object3D

    var id: String { rawValue }

    var title: String {
        switch self {
        case .space3D: return L("3D Space")
        case .space360: return L("360° Space")
        case .object3D: return L("3D Object")
        }
    }

    var line: String {
        switch self {
        case .space3D: return L("Walk around your space")
        case .space360: return L("Look around from one spot")
        case .object3D: return L("Capture every side")
        }
    }

    var photoAsset: String {
        switch self {
        case .space3D: return "WhikPhotoLivingWide"
        case .space360: return "WhikPhotoDiningWide"
        case .object3D: return "WhikPhotoChairCharcoal"
        }
    }

    /// Shown when a guest taps the card (generation and the library need an account).
    var signInReason: String {
        switch self {
        case .space3D: return L("Sign in to create a 3D Space. Your captures are saved to your account.")
        case .space360: return L("Sign in to create a 360° Space. Your captures are saved to your account.")
        case .object3D: return L("Sign in to create a 3D Object. Your captures are saved to your account.")
        }
    }
}

struct WhikCaptureView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var gate: WhikAuthGate
    @EnvironmentObject private var viewers: WhikViewerPresenter
    @State private var active: WhikCaptureKind?
    @State private var showImport = false
    @State private var checking: WhikCaptureKind?
    @State private var unavailable: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L("Capture"))
                    .font(WhikFont.largeTitle())
                    .foregroundStyle(WhikColors.textPrimary)
                    .padding(.top, 8)
                ForEach(WhikCaptureKind.allCases) { kind in
                    WhikCaptureCard(kind: kind, busy: checking == kind) { start(kind) }
                }
                Button {
                    GonggiHaptics.light()
                    gate.run(reason: L("Sign in to import a 360° photo into your library.")) { showImport = true }
                } label: {
                    Label(L("Import 360° photo"), systemImage: "square.and.arrow.up")
                        .font(.system(.body).weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(WhikColors.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, WhikLayout.sideInset)
            .padding(.bottom, WhikLayout.tabBarClearance)
        }
        .scrollIndicators(.hidden)
        .background(WhikColors.background.ignoresSafeArea())
        .fullScreenCover(item: $active) { kind in
            Group {
                switch kind {
                case .space3D: ThreeDSpaceRecordFlowView(onClose: { active = nil })
                case .space360: DirectionCaptureView(onClose: { active = nil })
                case .object3D: ObjectCaptureFlowView(onClose: { active = nil })
                }
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $showImport) {
            SpaceImportSheet(
                onImported: { jobId in viewers.openSpace(jobId: jobId) },
                onGaussianImported: { spaceId in viewers.openGaussian(spaceId: spaceId) }
            )
            .environmentObject(appState)
        }
        .alert(L("Not available yet"), isPresented: Binding(get: { unavailable != nil }, set: { if !$0 { unavailable = nil } })) {
            Button(L("OK"), role: .cancel) { unavailable = nil }
        } message: {
            Text(unavailable ?? "")
        }
    }

    private func start(_ kind: WhikCaptureKind) {
        GonggiHaptics.medium()
        gate.run(reason: kind.signInReason) {
            Task { await openWhenAvailable(kind) }
        }
    }

    /// Same account-scope checks as the old 기록 cards: 3D Space and 3D Object follow the server rollout;
    /// an unknown scope is re-checked first, so the card never dead-ends.
    private func openWhenAvailable(_ kind: WhikCaptureKind) async {
        switch kind {
        case .space360:
            active = kind
        case .space3D:
            if appState.showsSpatialRecord { active = kind; return }
            checking = kind
            await appState.refreshSpatialRecordAvailability()
            checking = nil
            if appState.showsSpatialRecord {
                active = kind
            } else {
                unavailable = appState.spatialRecordAvailable == false
                    ? L("3D Space isn't available for this account yet.")
                    : L("We couldn't check 3D Space right now. Please try again in a moment.")
            }
        case .object3D:
            if objectAvailable { active = kind; return }
            checking = kind
            await appState.refreshSpatialRecordAvailability()
            checking = nil
            if objectAvailable {
                active = kind
            } else {
                unavailable = appState.objectCaptureAvailable == false
                    ? L("3D Object isn't available for this account yet.")
                    : L("We couldn't check 3D Object right now. Please try again in a moment.")
            }
        }
    }

    private var objectAvailable: Bool {
        RecordHomePolicy.productCardVisible(
            featureOn: RecordHomePolicy.productCaptureAvailable,
            mockMode: appState.isMockMode,
            serverAvailable: appState.objectCaptureAvailable
        )
    }
}

private struct WhikCaptureCard: View {
    let kind: WhikCaptureKind
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                // Fill a fixed box: a bare scaledToFill image would widen the card (and the page) past the screen.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 196)
                    .overlay(Image(kind.photoAsset).resizable().scaledToFill())
                    .clipped()
                    .accessibilityHidden(true)
                WhikPhotoScrim(top: 0, bottom: 0.82)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(kind.title)
                            .font(WhikFont.cardTitle())
                            .foregroundStyle(WhikColors.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(kind.line)
                            .font(.system(.subheadline))
                            .foregroundStyle(WhikColors.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 8)
                    if busy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(WhikColors.textPrimary)
                    }
                }
                .padding(16)
            }
            .frame(height: 196)
            // Text sits on a fixed-height photo: grow with Dynamic Type only up to where it still fits.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(WhikColors.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(GonggiPressableStyle(scale: 0.98))
        .disabled(busy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.title), \(kind.line)")
        .accessibilityAddTraits(.isButton)
    }
}
