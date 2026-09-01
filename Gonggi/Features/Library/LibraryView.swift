import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedSpace: SpaceRecord?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                    header
                    LazyVStack(spacing: GonggiSpacing.md) {
                        ForEach(appState.spaces) { space in
                            MemoryArchiveCard(space: space) {
                                selectedSpace = space
                            }
                        }
                    }
                }
                .padding(GonggiSpacing.lg)
                .padding(.bottom, GonggiSpacing.xxl)
            }
            .background(GonggiAmbientBackground())
            .navigationTitle("보관함")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(item: $selectedSpace) { space in
                SpaceDetailView(space: space)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            Text("기억의 아카이브")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.accentTeal)
            Text("기록한 공간을\n다시 방문해보세요")
                .font(GonggiTypography.headline(20))
                .foregroundStyle(GonggiColors.textPrimary)
                .lineSpacing(2)
        }
        .padding(.bottom, GonggiSpacing.xs)
    }
}

#Preview {
    LibraryView()
        .environmentObject(AppState(isMockMode: true))
}
