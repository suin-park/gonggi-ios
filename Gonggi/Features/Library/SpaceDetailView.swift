import SwiftUI
import WebKit

struct SpaceDetailView: View {
    let space: SpaceRecord
    @State private var showViewer = false
    @State private var showDeleteConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                heroSection
                metaSection
                if let note = space.note {
                    memoryNoteSection(note)
                }
                actionsSection
            }
            .padding(GonggiSpacing.lg)
            .padding(.bottom, GonggiSpacing.xxl)
        }
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showViewer) {
            ViewerPlaceholderView(space: space)
        }
        .alert("공간을 삭제할까요?", isPresented: $showDeleteConfirm) {
            Button("삭제", role: .destructive) {}
            Button("취소", role: .cancel) {}
        } message: {
            Text("삭제된 공간은 복구할 수 없습니다.")
        }
    }

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            GonggiColors.backgroundElevated,
                            GonggiColors.surface,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 240)
            RadialGradient(
                colors: [GonggiColors.accentTeal.opacity(0.25), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 200
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous))
            Image(systemName: space.thumbnailSystemImage)
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(GonggiColors.textPrimary.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            LinearGradient(
                colors: [.clear, GonggiColors.backgroundPrimary.opacity(0.7)],
                startPoint: .center,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous))
            statusBadge
                .padding(GonggiSpacing.md)
        }
        .overlay(
            RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous)
                .stroke(GonggiColors.border, lineWidth: 1)
        )
        .accessibilityLabel("\(space.name) 미리보기")
    }

    private var metaSection: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            Text(space.name)
                .font(GonggiTypography.title(26))
                .foregroundStyle(GonggiColors.textPrimary)
            Label(
                space.capturedAt.formatted(date: .long, time: .shortened),
                systemImage: "calendar"
            )
            .font(GonggiTypography.caption(14))
            .foregroundStyle(GonggiColors.textSecondary)
        }
    }

    private func memoryNoteSection(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            Text("기억 메모")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textTertiary)
            GonggiElevatedCard {
                Text(note)
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var actionsSection: some View {
        VStack(spacing: GonggiSpacing.sm) {
            PrimaryButton(title: "다시 들어가기", icon: "cube.transparent") {
                GonggiHaptics.light()
                showViewer = true
            }
            HStack(spacing: GonggiSpacing.sm) {
                SecondaryButton(title: "공유", icon: "square.and.arrow.up") {}
                SecondaryButton(title: "삭제", icon: "trash") {
                    showDeleteConfirm = true
                }
            }
        }
        .padding(.top, GonggiSpacing.xs)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(GonggiColors.statusColor(for: space.status))
                .frame(width: 7, height: 7)
            Text(space.status.label)
        }
        .font(GonggiTypography.caption(13))
        .foregroundStyle(GonggiColors.statusColor(for: space.status))
        .padding(.horizontal, GonggiSpacing.sm)
        .padding(.vertical, GonggiSpacing.xs)
        .background(GonggiColors.backgroundPrimary.opacity(0.65))
        .clipShape(Capsule())
    }
}

struct ViewerPlaceholderView: View {
    let space: SpaceRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let url = space.viewerURL {
                    WebView(url: url)
                } else {
                    VStack(spacing: GonggiSpacing.lg) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 56, weight: .ultraLight))
                            .foregroundStyle(GonggiColors.accentTeal)
                        Text("3D 공간 뷰어")
                            .font(GonggiTypography.headline(20))
                            .foregroundStyle(GonggiColors.textPrimary)
                        Text("곧 이곳에서 기록한 공간을\n다시 걸어 다닐 수 있어요.")
                            .font(GonggiTypography.body(15))
                            .foregroundStyle(GonggiColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                    }
                    .padding(GonggiSpacing.xl)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GonggiAmbientBackground(showGlow: false))
            .navigationTitle(space.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.isOpaque = false
        web.backgroundColor = .clear
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

#Preview {
    NavigationStack {
        SpaceDetailView(space: SpaceRecord.sampleArchive[0])
    }
}
