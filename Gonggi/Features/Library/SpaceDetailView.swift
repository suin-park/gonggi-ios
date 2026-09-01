import SwiftUI
import WebKit

struct SpaceDetailView: View {
    let space: SpaceRecord
    @State private var showViewer = false
    @State private var showDeleteConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                thumbnail
                Text(space.name)
                    .font(GonggiTypography.title(24))
                    .foregroundStyle(GonggiColors.textPrimary)
                Label(space.capturedAt.formatted(date: .long, time: .shortened), systemImage: "calendar")
                    .font(GonggiTypography.caption(14))
                    .foregroundStyle(GonggiColors.textSecondary)
                statusBadge
                if let note = space.note {
                    GlassCard {
                        Text(note)
                            .font(GonggiTypography.body(15))
                            .foregroundStyle(GonggiColors.textSecondary)
                    }
                }
                PrimaryButton(title: "공간 보기", icon: "cube.transparent") {
                    showViewer = true
                }
                HStack(spacing: GonggiSpacing.sm) {
                    SecondaryButton(title: "공유") {}
                    SecondaryButton(title: "삭제") { showDeleteConfirm = true }
                }
            }
            .padding(GonggiSpacing.lg)
        }
        .background(GonggiColors.backgroundPrimary.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showViewer) {
            ViewerPlaceholderView(space: space)
        }
        .alert("공간을 삭제할까요?", isPresented: $showDeleteConfirm) {
            Button("삭제", role: .destructive) {}
            Button("취소", role: .cancel) {}
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous)
                .fill(GonggiColors.heroGradient)
                .frame(height: 200)
            Image(systemName: space.thumbnailSystemImage)
                .font(.system(size: 56))
                .foregroundStyle(GonggiColors.accentCyan)
        }
        .accessibilityLabel("\(space.name) 썸네일")
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: space.status == .ready ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
            Text(space.status.label)
        }
        .font(GonggiTypography.caption(13))
        .foregroundStyle(space.status == .ready ? GonggiColors.successGreen : GonggiColors.accentCyan)
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
                    VStack(spacing: GonggiSpacing.md) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 48))
                            .foregroundStyle(GonggiColors.accentCyan)
                        Text("3D 뷰어 연결 준비 중")
                            .font(GonggiTypography.headline(18))
                        Text("향후 3D Locker viewer URL 또는 native viewer가 연결됩니다.")
                            .font(GonggiTypography.caption(14))
                            .foregroundStyle(GonggiColors.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
            .background(GonggiColors.backgroundPrimary)
            .navigationTitle(space.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
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
