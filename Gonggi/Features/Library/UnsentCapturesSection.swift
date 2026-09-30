import SwiftUI

/// Library section for captures whose upload never reached the server (see `UnsentCaptureResumer`).
/// Resending is always an explicit tap; nothing is retried automatically.
struct UnsentCapturesSection: View {
    /// true = product captures (3D 자산 tab), false = space captures (공간 tab).
    var products: Bool = false
    @EnvironmentObject private var appState: AppState
    @State private var items: [UnsentCaptureResumer.Item] = []
    @State private var busySessionId: String?
    @State private var message: String?
    @State private var confirmItem: UnsentCaptureResumer.Item?

    var body: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            if !items.isEmpty {
                Text("업로드하지 못한 촬영")
                    .font(GonggiTypography.body(15).weight(.semibold))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text("원본은 이 기기에 남아 있어요. 다시 업로드하면 같은 촬영으로 3D 생성을 이어서 요청해요.")
                    .font(GonggiTypography.body(13))
                    .foregroundStyle(GonggiColors.textSecondary)
                ForEach(items) { item in
                    row(item)
                }
            }
            if let message {
                Text(message)
                    .font(GonggiTypography.body(13))
                    .foregroundStyle(GonggiColors.textSecondary)
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            "지금 로그인한 계정으로 업로드할까요?",
            isPresented: Binding(get: { confirmItem != nil }, set: { if !$0 { confirmItem = nil } }),
            titleVisibility: .visible,
            presenting: confirmItem
        ) { item in
            Button("이 계정으로 업로드") { resend(item) }
            Button("취소", role: .cancel) {}
        } message: { item in
            Text("\(dateLabel(item)) · 사진 \(item.photoCount)장. 이 기기에서 촬영했지만 계정 정보가 기록되기 전의 촬영이에요.")
        }
    }

    private func row(_ item: UnsentCaptureResumer.Item) -> some View {
        HStack(spacing: GonggiSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.suggestedName)
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text("\(dateLabel(item)) · 사진 \(item.photoCount)장")
                    .font(GonggiTypography.body(13))
                    .foregroundStyle(GonggiColors.textSecondary)
            }
            Spacer()
            Button {
                if item.ownerUserId == nil { confirmItem = item } else { resend(item) }
            } label: {
                if busySessionId == item.sessionId {
                    ProgressView().tint(GonggiColors.textPrimary)
                } else {
                    Text("다시 업로드")
                }
            }
            .disabled(busySessionId != nil)
            .accessibilityLabel("업로드하지 못한 촬영 다시 업로드")
        }
        .padding(GonggiSpacing.md)
        .background(GonggiColors.surfaceElevated.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func dateLabel(_ item: UnsentCaptureResumer.Item) -> String {
        guard let d = item.capturedAt else { return "촬영 시각 모름" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    private func reload() {
        items = UnsentCaptureResumer.pending(currentUserId: GaussianGenerationStore.shared.boundUserId)
            .filter { $0.isProduct == products }
    }

    private func resend(_ item: UnsentCaptureResumer.Item) {
        guard busySessionId == nil else { return }
        busySessionId = item.sessionId
        message = "업로드 중이에요. 끝날 때까지 앱을 닫지 말아 주세요."
        Task { @MainActor in
            let error = await UnsentCaptureResumer.resend(item, service: appState.spaceService)
            busySessionId = nil
            message = error ?? (item.isProduct ? "업로드했어요. 제품 3D 생성을 요청했어요." : "업로드했어요. 3D 공간 생성을 요청했어요.")
            reload()
            appState.rebuildSpaces()
            appState.ensureSpaceGenerationPolling()
        }
    }
}
