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
                Text("Not uploaded yet")
                    .font(GonggiTypography.body(15).weight(.semibold))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text("The original capture is still on this device. Upload it again to continue.")
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
            "Upload to the signed-in account?",
            isPresented: Binding(get: { confirmItem != nil }, set: { if !$0 { confirmItem = nil } }),
            titleVisibility: .visible,
            presenting: confirmItem
        ) { item in
            Button("Upload to this account") { resend(item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("\(dateLabel(item)), \(item.photoCount) photos. Captured on this device before it was linked to an account.")
        }
    }

    private func row(_ item: UnsentCaptureResumer.Item) -> some View {
        HStack(spacing: GonggiSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.suggestedName)
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text("\(dateLabel(item)), \(item.photoCount) photos")
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
                    Text("Upload")
                }
            }
            .disabled(busySessionId != nil)
            .accessibilityLabel("Upload this capture again")
        }
        .padding(GonggiSpacing.md)
        .background(GonggiColors.surfaceElevated.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func dateLabel(_ item: UnsentCaptureResumer.Item) -> String {
        guard let d = item.capturedAt else { return "Unknown time" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    private func reload() {
        items = UnsentCaptureResumer.pending(currentUserId: GaussianGenerationStore.shared.boundUserId)
            .filter { $0.isProduct == products }
    }

    private func resend(_ item: UnsentCaptureResumer.Item) {
        guard busySessionId == nil else { return }
        busySessionId = item.sessionId
        message = "Uploading. Keep the app open until it finishes."
        Task { @MainActor in
            let error = await UnsentCaptureResumer.resend(item, service: appState.spaceService)
            busySessionId = nil
            message = error ?? (item.isProduct ? "Uploaded. Your 3D Object is being created." : "Uploaded. Your 3D Space is being created.")
            reload()
            appState.rebuildSpaces()
            appState.ensureSpaceGenerationPolling()
        }
    }
}
