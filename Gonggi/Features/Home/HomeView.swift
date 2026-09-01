import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GonggiSpacing.xl) {
                    header
                    hero
                    description
                    actions
                }
                .padding(GonggiSpacing.lg)
            }
            .background(GonggiColors.backgroundPrimary.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            Text("공기")
                .font(GonggiTypography.title(34))
                .foregroundStyle(GonggiColors.textPrimary)
            Text("공간을 기록하고 기억하다")
                .font(GonggiTypography.body(16))
                .foregroundStyle(GonggiColors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var hero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous)
                .fill(GonggiColors.heroGradient)
                .frame(height: 220)
            PortalIllustration()
                .padding(GonggiSpacing.lg)
        }
        .overlay(
            RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous)
                .stroke(GonggiColors.border, lineWidth: 1)
        )
        .accessibilityLabel("공간을 보관하는 포털 일러스트")
    }

    private var description: some View {
        Text(
            "당신의 소중한 공간을 기록하고\n3D Gaussian Splatting 기술로\n오래도록 간직하세요."
        )
        .font(GonggiTypography.body(16))
        .foregroundStyle(GonggiColors.textSecondary)
        .lineSpacing(4)
    }

    private var actions: some View {
        VStack(spacing: GonggiSpacing.sm) {
            PrimaryButton(title: "공간 스캔 시작", icon: "viewfinder") {
                appState.selectTab(.scan)
            }
            SecondaryButton(title: "보관된 공간 보기") {
                appState.selectTab(.library)
            }
        }
    }
}

/// Subtle portal / light illustration (no stock SF imagery).
private struct PortalIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                GonggiColors.accentCyan.opacity(0.35),
                                GonggiColors.accentTeal.opacity(0.08),
                                .clear,
                            ],
                            center: .center,
                            startRadius: 8,
                            endRadius: min(w, h) * 0.45
                        )
                    )
                    .frame(width: w * 0.7, height: w * 0.7)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(GonggiColors.accentCyan.opacity(0.5), lineWidth: 2)
                    .frame(width: w * 0.42, height: h * 0.55)
                    .rotationEffect(.degrees(-8))
                Image(systemName: "cube.transparent")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(GonggiColors.textPrimary.opacity(0.85))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState(isMockMode: true))
}
