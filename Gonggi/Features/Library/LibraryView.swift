import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedSpace: SpaceRecord?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GonggiSpacing.md) {
                    header
                    ForEach(appState.spaces) { space in
                        SpaceCard(
                            space: space,
                            onOpen: { selectedSpace = space },
                            onMore: {}
                        )
                    }
                }
                .padding(GonggiSpacing.lg)
            }
            .background(GonggiColors.backgroundPrimary.ignoresSafeArea())
            .navigationTitle("보관함")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(item: $selectedSpace) { space in
                SpaceDetailView(space: space)
            }
        }
    }

    private var header: some View {
        Text("기록한 공간을 다시 방문해보세요.")
            .font(GonggiTypography.body(15))
            .foregroundStyle(GonggiColors.textSecondary)
            .padding(.bottom, GonggiSpacing.xs)
    }
}

#Preview {
    LibraryView()
        .environmentObject(AppState(isMockMode: true))
}
