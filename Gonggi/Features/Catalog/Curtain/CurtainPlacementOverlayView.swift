import SwiftUI

struct CurtainPlacementConsentSheet: View {
    var onAccept: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
            Text("AI 커튼 미리보기")
                .font(GonggiTypography.headline(20))
                .foregroundStyle(GonggiColors.textPrimary)
            Text(
                "커튼 설치 모습을 만들기 위해 선택한 공간 이미지와 창문 위치, 상품 이미지가 AI 처리 서비스로 전송됩니다. 결과는 실제 시공 모습 및 치수와 다를 수 있습니다."
            )
            .font(GonggiTypography.body(15))
            .foregroundStyle(GonggiColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            Button {
                GonggiHaptics.medium()
                onAccept()
            } label: {
                Text("동의하고 미리보기 만들기")
                    .font(GonggiTypography.body(16))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(GonggiColors.accentCyan))
                    .foregroundStyle(GonggiColors.textOnAccent)
            }
            Button("취소") { onCancel() }
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textSecondary)
                .frame(maxWidth: .infinity)
        }
        .padding(GonggiSpacing.lg)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

struct CurtainPlacementBanner: View {
    let message: String
    var warnings: [CurtainSeedWarning] = []
    var showConfirmActions: Bool = false
    var onConfirm: (() -> Void)?
    var onReselect: (() -> Void)?

    var body: some View {
        VStack(spacing: GonggiSpacing.sm) {
            if !warnings.isEmpty {
                ForEach(warnings, id: \.rawValue) { warning in
                    Text(warning.userFacingLabel)
                        .font(GonggiTypography.caption(12))
                        .foregroundStyle(.yellow)
                        .multilineTextAlignment(.center)
                }
            }
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if showConfirmActions {
                HStack(spacing: GonggiSpacing.sm) {
                    Button("다시 선택") {
                        GonggiHaptics.light()
                        onReselect?()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.white)
                    Button("이 위치로 만들기") {
                        GonggiHaptics.medium()
                        onConfirm?()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(GonggiColors.accentCyan)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, GonggiSpacing.md)
    }
}

struct CurtainPlacementCompareSheet: View {
    let originalPath: String
    let resultPath: String
    var onSave: () -> Void
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                    compareSection(title: "원본", path: originalPath)
                    compareSection(title: "미리보기", path: resultPath)
                    Text("설치 분위기를 확인하는 미리보기이며 실제 제작 치수와 다를 수 있습니다.")
                        .font(GonggiTypography.caption(12))
                        .foregroundStyle(GonggiColors.textTertiary)
                    Button {
                        GonggiHaptics.medium()
                        onSave()
                    } label: {
                        Text("새 버전으로 저장")
                            .font(GonggiTypography.body(16))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Capsule().fill(GonggiColors.accentCyan))
                            .foregroundStyle(GonggiColors.textOnAccent)
                    }
                }
                .padding(GonggiSpacing.lg)
            }
            .background(GonggiAmbientBackground())
            .navigationTitle("미리보기 비교")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { onClose() }
                }
            }
        }
    }

    @ViewBuilder
    private func compareSection(title: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Text(title)
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textPrimary)
            if let img = UIImage(contentsOfFile: path) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                    .fill(GonggiColors.surfaceElevated)
                    .frame(height: 160)
                    .overlay {
                        Text("이미지를 불러올 수 없어요")
                            .font(GonggiTypography.caption(12))
                            .foregroundStyle(GonggiColors.textTertiary)
                    }
            }
        }
    }
}

/// Hosted by `VRSphereSpaceView` so curtain sheets stay outside the main type-check graph.
struct CurtainPlacementPresentationModifier: ViewModifier {
    @ObservedObject var session: CurtainPlacementSession
    @Binding var showCompare: Bool
    let sessionId: String
    var onCompositeSaved: (URL) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $session.showConsentSheet) {
                CurtainPlacementConsentSheet(
                    onAccept: { session.acceptConsentAndCreateJob() },
                    onCancel: { session.cancelConsent() }
                )
            }
            .sheet(isPresented: $showCompare) {
                compareSheetContent
            }
            .alert("커튼 미리보기", isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) { session.errorMessage = nil }
            } message: {
                Text(session.errorMessage ?? "")
            }
            .onChange(of: session.phase) { _, phase in
                if case .comparing = phase {
                    showCompare = true
                }
            }
    }

    @ViewBuilder
    private var compareSheetContent: some View {
        if case .comparing(let original, let result, _) = session.phase {
            CurtainPlacementCompareSheet(
                originalPath: original,
                resultPath: result,
                onSave: {
                    Task { @MainActor in
                        await session.saveCompositeRevision(originalTexturePath: original)
                        if case .saved = session.phase,
                           let latest = try? SpaceLatLongStore.latestLatLongURL(sessionId: sessionId) {
                            onCompositeSaved(latest)
                        }
                        showCompare = false
                    }
                },
                onClose: { showCompare = false }
            )
        }
    }
}
