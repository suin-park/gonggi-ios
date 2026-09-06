import SwiftUI

/// Library tab body for 3D assets (shell until Locker API).
struct AssetLibraryView: View {
    @ObservedObject var store: AssetLibraryStore
    @State private var showCreate = false
    @State private var selectedAsset: AssetRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
            header
            if store.assets.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: GonggiSpacing.md) {
                    ForEach(store.assets) { asset in
                        Button {
                            selectedAsset = asset
                        } label: {
                            assetCard(asset)
                        }
                        .buttonStyle(GonggiPressableStyle())
                    }
                }
            }
        }
        .navigationDestination(item: $selectedAsset) { asset in
            AssetDetailView(asset: asset)
        }
        .sheet(isPresented: $showCreate) {
            CreateAssetFlowView(onClose: { showCreate = false })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear { store.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            Text("3D 어셋")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.accentTeal)
            Text("생성·보관한 3D를\n한곳에서 관리해요")
                .font(GonggiTypography.headline(20))
                .foregroundStyle(GonggiColors.textPrimary)
                .lineSpacing(2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: GonggiSpacing.lg) {
            Spacer(minLength: 40)
            Image(systemName: "cube.transparent")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(GonggiColors.accentTeal.opacity(0.8))
            Text("아직 3D 어셋이 없어요")
                .font(GonggiTypography.headline(18))
                .foregroundStyle(GonggiColors.textPrimary)
            Text("사진으로 새 어셋을 만들거나\n3D Locker에 있는 어셋을 불러올 수 있어요.")
                .font(GonggiTypography.caption(14))
                .foregroundStyle(GonggiColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            PrimaryButton(title: "+ 새 3D 어셋 만들기", icon: "plus") {
                GonggiHaptics.medium()
                showCreate = true
            }
            .padding(.horizontal, GonggiSpacing.lg)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    private func assetCard(_ asset: AssetRecord) -> some View {
        HStack(spacing: GonggiSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous)
                    .fill(GonggiColors.surface)
                    .frame(width: 64, height: 64)
                Image(systemName: asset.thumbnailSystemImage)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(GonggiColors.accentTeal)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(asset.name)
                    .font(GonggiTypography.body(16))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text("\(asset.typeLabel) · \(asset.status.label)")
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(GonggiColors.textSecondary)
                Text(asset.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(GonggiTypography.caption(11))
                    .foregroundStyle(GonggiColors.textTertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(GonggiColors.textTertiary)
        }
        .padding(GonggiSpacing.md)
        .background(GonggiColors.surfaceElevated.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }
}

/// Primary entry: Library → 3D 어셋 → create.
struct CreateAssetFlowView: View {
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                Text("새 3D 어셋 만들기")
                    .font(GonggiTypography.title(22))
                    .foregroundStyle(GonggiColors.textPrimary)

                Button {
                    GonggiHaptics.medium()
                    // Phase D: wire image-to-3D / Meshy / Locker partner API.
                } label: {
                    HStack(spacing: GonggiSpacing.md) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(GonggiColors.accentTeal)
                            .frame(width: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("사진으로 만들기")
                                .font(GonggiTypography.body(17))
                                .foregroundStyle(GonggiColors.textPrimary)
                            Text("한 장 또는 여러 장의 사진으로 3D 어셋을 생성해요.")
                                .font(GonggiTypography.caption(13))
                                .foregroundStyle(GonggiColors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(GonggiColors.textTertiary)
                    }
                    .padding(GonggiSpacing.md)
                    .background(GonggiColors.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
                }
                .buttonStyle(.plain)

                Text("계정 연동 후 3D Locker 생성 API에 연결됩니다.")
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(GonggiColors.textTertiary)

                Spacer()
            }
            .padding(GonggiSpacing.lg)
            .background(GonggiAmbientBackground(showGlow: false))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { onClose() }
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }
        }
    }
}

struct AssetDetailView: View {
    let asset: AssetRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                ZStack {
                    RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous)
                        .fill(GonggiColors.surface)
                        .frame(height: 220)
                    Image(systemName: asset.thumbnailSystemImage)
                        .font(.system(size: 56, weight: .ultraLight))
                        .foregroundStyle(GonggiColors.accentTeal)
                }
                Text(asset.name)
                    .font(GonggiTypography.title(24))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text("\(asset.typeLabel) · \(asset.status.label)")
                    .font(GonggiTypography.caption(14))
                    .foregroundStyle(GonggiColors.textSecondary)

                VStack(spacing: GonggiSpacing.sm) {
                    PrimaryButton(title: "3D로 보기", icon: "cube") {}
                    SecondaryButton(title: "AR로 보기", icon: "arkit") {}
                    SecondaryButton(title: "공간에 배치", icon: "square.stack.3d.up") {}
                    Button(role: .destructive) {} label: {
                        Text("삭제")
                            .font(GonggiTypography.body(16))
                            .foregroundStyle(GonggiColors.error)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
            }
            .padding(GonggiSpacing.lg)
        }
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationBarTitleDisplayMode(.inline)
    }
}
