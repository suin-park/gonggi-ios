import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState

    private var recentSpace: SpaceRecord? {
        appState.spaces.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GonggiSpacing.xl) {
                    GonggiBrandMark()
                    heroSection
                    if let recent = recentSpace {
                        recentSection(recent)
                    }
                    actions
                }
                .padding(GonggiSpacing.lg)
                .padding(.bottom, GonggiSpacing.xxl)
            }
            .background(GonggiAmbientBackground())
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous)
                .fill(GonggiColors.heroGradient)
                .frame(height: 200)
            PortalIllustration()
                .padding(GonggiSpacing.lg)
            LinearGradient(
                colors: [.clear, GonggiColors.backgroundPrimary.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous))
            Text("소중한 공간을\n오래도록 기억하세요")
                .font(GonggiTypography.headline(18))
                .foregroundStyle(GonggiColors.textPrimary.opacity(0.92))
                .padding(GonggiSpacing.lg)
        }
        .overlay(
            RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous)
                .stroke(GonggiColors.border, lineWidth: 1)
        )
        .accessibilityLabel("공간을 기록하는 일러스트")
    }

    private func recentSection(_ space: SpaceRecord) -> some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Text("최근 기록한 공간")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textTertiary)
            Button {
                appState.selectTab(.library)
            } label: {
                HStack(spacing: GonggiSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous)
                            .fill(GonggiColors.surface)
                            .frame(width: 56, height: 56)
                        Image(systemName: space.thumbnailSystemImage)
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(GonggiColors.accentTeal)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(space.name)
                            .font(GonggiTypography.headline(16))
                            .foregroundStyle(GonggiColors.textPrimary)
                        Text(space.capturedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(GonggiTypography.caption(12))
                            .foregroundStyle(GonggiColors.textTertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(GonggiColors.textTertiary)
                }
                .padding(GonggiSpacing.md)
                .background(GonggiColors.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                        .stroke(GonggiColors.borderSubtle, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
            }
            .buttonStyle(GonggiPressableStyle())
        }
    }

    private var actions: some View {
        VStack(spacing: GonggiSpacing.sm) {
            PrimaryButton(title: "파노라마로 공간 기록", icon: "pano") {
                appState.selectTab(.scan)
            }
            SecondaryButton(title: "보관함 보기", icon: "archivebox") {
                appState.selectTab(.library)
            }
        }
    }
}

private struct PortalIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                GonggiColors.accentCyan.opacity(glow ? 0.32 : 0.22),
                                GonggiColors.accentTeal.opacity(0.06),
                                .clear,
                            ],
                            center: .center,
                            startRadius: 8,
                            endRadius: min(w, h) * 0.48
                        )
                    )
                    .frame(width: w * 0.75, height: w * 0.75)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(GonggiColors.accentCyan.opacity(0.4), lineWidth: 1.5)
                    .frame(width: w * 0.38, height: h * 0.52)
                    .rotationEffect(.degrees(-6))
                Image(systemName: "cube.transparent")
                    .font(.system(size: 40, weight: .ultraLight))
                    .foregroundStyle(GonggiColors.textPrimary.opacity(0.8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState(isMockMode: true))
}
