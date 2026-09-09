#if DEBUG
import SwiftUI

/// DEBUG-only entry for CI simulator screenshots. Does not affect production builds.
struct ScreenshotRootView: View {
    @EnvironmentObject private var appState: AppState
    let screen: ScreenshotScreen

    var body: some View {
        Group {
            switch screen {
            case .welcome, .welcomeCompact:
                AuthShellView(session: AuthSessionController.shared, decoration: .spaceLight)
            case .welcomeReduceMotion:
                AuthShellView(session: AuthSessionController.shared, decoration: .spaceLight)
            case .welcomeDynamicType:
                AuthShellView(session: AuthSessionController.shared, decoration: .spaceLight)
                    .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
            case .welcomeSpaceLight, .welcomeSpaceLightCompact:
                AuthShellView(session: AuthSessionController.shared, decoration: .spaceLight)
            case .welcomeSpaceLightReduceMotion:
                AuthShellView(session: AuthSessionController.shared, decoration: .spaceLight)
            case .welcomeSpaceLightDynamicType:
                AuthShellView(session: AuthSessionController.shared, decoration: .spaceLight)
                    .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
            case .spaceLightStoryboard:
                GonggiSpaceLightStoryboardView()
            case .loginEmail:
                EmailContinueView(session: AuthSessionController.shared)
            case .loginEmailKeyboard:
                EmailContinueView(session: AuthSessionController.shared, autofocusEmail: true)
            case .home, .profile:
                MainTabView()
                    .onAppear {
                        if screen == .profile {
                            appState.selectTab(.profile)
                        } else {
                            appState.selectTab(.home)
                        }
                    }
            case .recordMode:
                CaptureContainerView()
            case .librarySpaces:
                MainTabView()
                    .onAppear { appState.selectTab(.library) }
            case .librarySpacesLoading:
                ScreenshotLibraryStateView(
                    title: "공간 보관함",
                    subtitle: "불러오는 중",
                    content: { ProgressView().tint(GonggiColors.brandCyan) }
                )
            case .librarySpacesEmpty:
                ScreenshotLibraryStateView(
                    title: "공간 보관함",
                    subtitle: "아직 기록한 공간이 없어요",
                    content: {
                        Text("새 공간 기록하기에서 첫 공간을 남겨보세요.")
                            .font(GonggiTypography.body(15))
                            .foregroundStyle(GonggiColors.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                )
            case .librarySpacesError:
                ScreenshotLibraryStateView(
                    title: "공간 보관함",
                    subtitle: "공간을 불러오지 못했어요",
                    content: {
                        VStack(spacing: GonggiSpacing.sm) {
                            Text("잠시 후 다시 시도해 주세요.")
                                .font(GonggiTypography.body(15))
                                .foregroundStyle(GonggiColors.textSecondary)
                            SecondaryButton(title: "다시 시도", icon: "arrow.clockwise") {}
                        }
                    }
                )
            case .libraryAssetsThumb, .libraryAssetsNoThumb, .libraryAssetsGenerating:
                ScreenshotAssetLibraryFixtureView(kind: screen)
            case .capture30, .capture68, .capture90, .fastMovement, .trackingLimited, .lowTexture:
                captureScreenshot(for: screen)
            case .captureSummary:
                CaptureSummaryView(
                    summary: GonggiPreviewSamples.sampleSummary,
                    onContinueCapture: {},
                    onCreateSpace: {},
                    onPreviewSpace: nil
                )
            case .processing:
                ProcessingView(
                    summary: GonggiPreviewSamples.sampleSummary,
                    spaceService: appState.spaceService,
                    screenshotFrozenStatus: ScreenshotHarness.frozenProcessingStatus,
                    onComplete: { _, _ in },
                    onDismiss: {}
                )
            case .spaceDetail:
                NavigationStack {
                    SpaceDetailView(space: SpaceRecord.sampleArchive[0])
                }
            case .assetDetailNeedPrepare, .assetDetailProcessing, .assetDetailReady, .assetDetailFailed:
                ScreenshotAssetDetailFixtureView(kind: screen)
            case .spacePicker:
                PlaceAssetSpacePickerView(
                    spaces: SpaceRecord.sampleArchive,
                    onSelect: { _ in },
                    onClose: {}
                )
            case .assetPicker:
                ScreenshotAssetPickerFixture()
            case .vrEditMenu:
                ScreenshotVREditMenuFixture()
            case .arCameraDenied:
                ScreenshotARDeniedFixture()
            case .appIconPreview:
                ScreenshotAppIconPreview()
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("gonggi-screenshot-ready")
    }

    @ViewBuilder
    private func captureScreenshot(for screen: ScreenshotScreen) -> some View {
        let config = ScreenshotHarness.captureConfig(for: screen)
        ZStack {
            MockCameraBackground(quality: config.quality)
            CaptureOverlayView(
                guidance: config.guidance,
                onClose: {},
                onFinish: {},
                onFlash: {},
                onGuide: {}
            )
        }
        .ignoresSafeArea()
    }
}

private struct ScreenshotLibraryStateView<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            GonggiAmbientBackground()
            VStack(spacing: GonggiSpacing.lg) {
                Text(title)
                    .font(GonggiTypography.title(24))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text(subtitle)
                    .font(GonggiTypography.headline(17))
                    .foregroundStyle(GonggiColors.textSecondary)
                content()
            }
            .padding(GonggiSpacing.xl)
        }
    }
}

private struct ScreenshotAssetLibraryFixtureView: View {
    let kind: ScreenshotScreen

    var body: some View {
        ZStack {
            GonggiAmbientBackground()
            VStack(alignment: .leading, spacing: GonggiSpacing.md) {
                Text("3D 어셋")
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.brandCyan)
                Text(title)
                    .font(GonggiTypography.headline(20))
                    .foregroundStyle(GonggiColors.textPrimary)

                HStack(spacing: GonggiSpacing.md) {
                    thumb
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name)
                            .font(GonggiTypography.headline(16))
                            .foregroundStyle(GonggiColors.textPrimary)
                        Text(status)
                            .font(GonggiTypography.caption(12))
                            .foregroundStyle(GonggiColors.textTertiary)
                    }
                    Spacer()
                }
                .padding(GonggiSpacing.md)
                .background(GonggiColors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
            }
            .padding(GonggiSpacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var title: String {
        switch kind {
        case .libraryAssetsThumb: return "썸네일 있음"
        case .libraryAssetsNoThumb: return "썸네일 없음"
        default: return "생성 중"
        }
    }

    private var name: String {
        switch kind {
        case .libraryAssetsThumb: return "의자 샘플"
        case .libraryAssetsNoThumb: return "이름 없는 어셋"
        default: return "새 어셋 생성"
        }
    }

    private var status: String {
        switch kind {
        case .libraryAssetsGenerating: return "생성 중…"
        case .libraryAssetsNoThumb: return "이미지 없음"
        default: return "준비됨"
        }
    }

    @ViewBuilder
    private var thumb: some View {
        RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous)
            .fill(GonggiColors.surface)
            .frame(width: 64, height: 64)
            .overlay {
                switch kind {
                case .libraryAssetsThumb:
                    Image(systemName: "cube.fill")
                        .foregroundStyle(GonggiColors.brandCyan)
                case .libraryAssetsGenerating:
                    ProgressView().tint(GonggiColors.brandCyan)
                default:
                    Image(systemName: "photo")
                        .foregroundStyle(GonggiColors.textTertiary)
                }
            }
    }
}

private struct ScreenshotAssetDetailFixtureView: View {
    let kind: ScreenshotScreen

    var body: some View {
        ZStack {
            GonggiAmbientBackground()
            VStack(spacing: GonggiSpacing.lg) {
                RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                    .fill(GonggiColors.surfaceElevated)
                    .frame(height: 220)
                    .overlay {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 48, weight: .ultraLight))
                            .foregroundStyle(GonggiColors.textSecondary)
                    }
                Text(title)
                    .font(GonggiTypography.title(22))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text(subtitle)
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .multilineTextAlignment(.center)
                if kind == .assetDetailNeedPrepare {
                    PrimaryButton(title: "AR/공간 배치 준비하기", icon: "sparkles") {}
                } else if kind == .assetDetailProcessing {
                    ProgressView("AR/공간 배치 준비 중…")
                        .tint(GonggiColors.brandCyan)
                        .foregroundStyle(GonggiColors.textSecondary)
                } else if kind == .assetDetailReady {
                    PrimaryButton(title: "AR로 보기", icon: "arkit") {}
                    SecondaryButton(title: "공간에 배치", icon: "square.and.arrow.down") {}
                } else {
                    Text("준비를 다시 시도해 주세요.")
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.error)
                    PrimaryButton(title: "AR 다시 준비하기", icon: "arrow.clockwise") {}
                }
            }
            .padding(GonggiSpacing.lg)
        }
    }

    private var title: String {
        switch kind {
        case .assetDetailNeedPrepare: return "준비 필요"
        case .assetDetailProcessing: return "처리 중"
        case .assetDetailReady: return "준비 완료"
        default: return "준비 실패"
        }
    }

    private var subtitle: String {
        switch kind {
        case .assetDetailNeedPrepare: return "AR과 공간 배치를 사용하려면 준비가 필요해요."
        case .assetDetailProcessing: return "파일을 준비하는 중이에요."
        case .assetDetailReady: return "AR 보기와 공간 배치를 사용할 수 있어요."
        default: return "AR 파일을 준비하지 못했어요."
        }
    }
}

private struct ScreenshotAssetPickerFixture: View {
    var body: some View {
        NavigationStack {
            ZStack {
                GonggiAmbientBackground(showGlow: false)
                VStack(spacing: GonggiSpacing.md) {
                    ForEach(0 ..< 3, id: \.self) { idx in
                        HStack(spacing: GonggiSpacing.md) {
                            RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous)
                                .fill(GonggiColors.surfaceElevated)
                                .frame(width: 56, height: 56)
                                .overlay {
                                    Image(systemName: idx == 2 ? "photo" : "cube.fill")
                                        .foregroundStyle(idx == 2 ? GonggiColors.textTertiary : GonggiColors.brandCyan)
                                }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(idx == 2 ? "준비 중 어셋" : "배치 가능 어셋 \(idx + 1)")
                                    .font(GonggiTypography.body(16))
                                    .foregroundStyle(GonggiColors.textPrimary)
                                Text(idx == 2 ? "준비 필요" : "준비됨")
                                    .font(GonggiTypography.caption(12))
                                    .foregroundStyle(GonggiColors.textTertiary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(GonggiColors.textTertiary)
                        }
                        .padding(GonggiSpacing.md)
                        .background(GonggiColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
                        .opacity(idx == 2 ? 0.55 : 1)
                    }
                    Spacer()
                }
                .padding(GonggiSpacing.lg)
            }
            .navigationTitle("3D 오브젝트")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Text("닫기").foregroundStyle(GonggiColors.textSecondary)
                }
            }
        }
    }
}

private struct ScreenshotVREditMenuFixture: View {
    var body: some View {
        ZStack {
            GonggiColors.backgroundPrimary.ignoresSafeArea()
            LinearGradient(
                colors: [GonggiColors.brandCyan.opacity(0.12), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            VStack {
                HStack(spacing: 8) {
                    capsule("완료")
                    capsule("오브젝트 추가")
                    capsule("연결")
                    Spacer()
                    circle("xmark")
                }
                .padding()
                Spacer()
                HStack(spacing: 8) {
                    capsule("이동")
                    capsule("회전")
                    capsule("크기")
                    capsule("높이")
                }
                .padding()
            }
        }
    }

    private func capsule(_ title: String) -> some View {
        Text(title)
            .font(GonggiTypography.caption(14))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color.black.opacity(0.45), in: Capsule())
    }

    private func circle(_ system: String) -> some View {
        Image(systemName: system)
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Color.black.opacity(0.45), in: Circle())
    }
}

private struct ScreenshotARDeniedFixture: View {
    var body: some View {
        ZStack {
            GonggiAmbientBackground(showGlow: false)
            VStack(spacing: GonggiSpacing.lg) {
                Spacer()
                VStack(spacing: GonggiSpacing.md) {
                    Image(systemName: "arkit")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(GonggiColors.brandCyan)
                    Text(AssetARCopy.cameraNeeded)
                        .font(GonggiTypography.body(16))
                        .foregroundStyle(GonggiColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, GonggiSpacing.lg)
                    Text("설정에서 카메라 접근을 허용한 뒤 다시 시도해 주세요.")
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, GonggiSpacing.lg)
                    SecondaryButton(title: "설정 열기", icon: "gear") {}
                        .padding(.horizontal, GonggiSpacing.xl)
                }
                .padding(GonggiSpacing.lg)
                .background(GonggiColors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
                .padding(.horizontal, GonggiSpacing.lg)
                Spacer()
            }
            VStack {
                HStack {
                    Spacer()
                    Text("닫기")
                        .font(GonggiTypography.body(16))
                        .foregroundStyle(.white)
                        .padding(.horizontal, GonggiSpacing.md)
                        .padding(.vertical, GonggiSpacing.sm)
                        .background(GonggiColors.surfaceElevated, in: Capsule())
                }
                .padding()
                Spacer()
            }
        }
    }
}

private struct ScreenshotAppIconPreview: View {
    var body: some View {
        ZStack {
            GonggiAmbientBackground()
            VStack(spacing: GonggiSpacing.lg) {
                Image("GonggiAppIconPreview")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 40, style: .continuous)
                            .stroke(GonggiColors.border, lineWidth: 1)
                    )
                Text("앱 아이콘")
                    .font(GonggiTypography.headline(18))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text("원본 로고 기반 · 네이비 배경")
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textSecondary)
            }
        }
    }
}

@MainActor
enum ScreenshotHarness {
    struct CaptureConfig {
        let quality: CaptureQualityState
        let guidance: CaptureGuidanceEngine
    }

    static func captureConfig(for screen: ScreenshotScreen) -> CaptureConfig {
        switch screen {
        case .capture30:
            return CaptureConfig(
                quality: GonggiPreviewSamples.coverage30,
                guidance: GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.coverage30)
            )
        case .capture68:
            return CaptureConfig(
                quality: GonggiPreviewSamples.coverage68,
                guidance: GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.coverage68)
            )
        case .capture90:
            return CaptureConfig(
                quality: GonggiPreviewSamples.coverage90,
                guidance: GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.coverage90)
            )
        case .fastMovement:
            return CaptureConfig(
                quality: GonggiPreviewSamples.fastMovement,
                guidance: GonggiPreviewSamples.guidance(
                    quality: GonggiPreviewSamples.fastMovement,
                    message: GonggiPreviewSamples.coachFastMove
                )
            )
        case .trackingLimited:
            return CaptureConfig(
                quality: GonggiPreviewSamples.trackingLimited,
                guidance: GonggiPreviewSamples.guidance(
                    quality: GonggiPreviewSamples.trackingLimited,
                    message: GonggiPreviewSamples.coachTracking
                )
            )
        case .lowTexture:
            return CaptureConfig(
                quality: GonggiPreviewSamples.lowTexture,
                guidance: GonggiPreviewSamples.guidance(
                    quality: GonggiPreviewSamples.lowTexture,
                    message: GonggiPreviewSamples.coachLowTexture
                )
            )
        default:
            return CaptureConfig(
                quality: GonggiPreviewSamples.coverage68,
                guidance: GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.coverage68)
            )
        }
    }

    static var frozenProcessingStatus: GenerationJobStatus {
        GenerationJobStatus(
            jobId: "job-screenshot",
            spaceId: "space-screenshot",
            steps: [
                ProcessingStepState(kind: .upload, status: .completed),
                ProcessingStepState(kind: .frameAnalysis, status: .completed),
                ProcessingStepState(kind: .spaceGeneration, status: .active(progress: 0.62)),
                ProcessingStepState(kind: .optimization, status: .waiting),
            ],
            estimatedMinutesRemaining: 5,
            overallProgress: 0.58
        )
    }
}
#endif
