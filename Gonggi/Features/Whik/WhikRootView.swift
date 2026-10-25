import SwiftUI

/// WHIK: 3D Scanner shell. Home · Capture · Library, open without signing in.
/// Replaces `MainTabView` as the app root; the old tab view and its store / commerce / experiment entry points
/// are kept in the code base unreachable from here (see docs/WHIK_HIDDEN_FEATURES.md).
struct WhikRootView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var auth = AuthSessionController.shared
    @StateObject private var gate = WhikAuthGate()
    @StateObject private var viewers = WhikViewerPresenter()
    @State private var showAccount = false

    /// AppTab mapping: home → Home, record → Capture, library → Library (profile opens the account sheet).
    private var tab: WhikTab {
        switch appState.selectedTab {
        case .record: return .capture
        case .library: return .library
        default: return .home
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            WhikColors.background.ignoresSafeArea()
            Group {
                switch tab {
                case .home:
                    WhikHomeView(onProfile: openAccount)
                case .capture:
                    WhikCaptureView()
                case .library:
                    WhikLibraryView(onProfile: openAccount, onCapture: { select(.capture) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            WhikTabBar(selection: Binding(get: { tab }, set: { select($0) }))
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
        }
        .environmentObject(gate)
        .environmentObject(viewers)
        .whikLanguageEnvironment()
        .preferredColorScheme(.dark)
        .onAppear {
            viewers.appState = appState
            #if DEBUG
            if appState.isMockMode, ProcessInfo.processInfo.arguments.contains("-whik-preview-signed-in") {
                auth.debugPreviewSignIn()
            }
            #endif
            if case .restoring = auth.phase { auth.bootstrap() }
            if appState.selectedTab == .profile { appState.selectedTab = .home }
            appState.ensureSpaceGenerationPolling()
            openPendingPush()
        }
        .onChange(of: auth.phase) { _, _ in
            gate.phaseChanged()
            openPendingPush()
        }
        .onChange(of: appState.selectedTab) { _, newTab in
            // Old code paths that still select the profile tab open the account sheet instead.
            if newTab == .profile {
                appState.selectedTab = .home
                showAccount = true
            }
            appState.ensureSpaceGenerationPolling()
        }
        // "3D space ready" push (also set by AppState.openGaussianSpaceFromPush).
        .onChange(of: appState.pendingGaussianSpaceIdFromPush) { _, id in
            guard let id, !id.isEmpty else { return }
            appState.pendingGaussianSpaceIdFromPush = nil
            viewers.openGaussian(spaceId: id)
            Task { await GaussianLibraryReconciler.shared.reconcileIfStale(minInterval: 0) }
        }
        // 360° space ready push → AppState prepared the file; open it.
        .onChange(of: appState.pendingViewerJobId) { _, jobId in
            guard let jobId else { return }
            appState.pendingViewerJobId = nil
            viewers.openSpace(jobId: jobId)
        }
        .onChange(of: appState.pendingViewerLaunch) { _, launch in
            guard let launch else { return }
            appState.pendingViewerLaunch = nil
            viewers.vrLaunch = launch
        }
        .onChange(of: appState.forceDismissViewerEpoch) { _, _ in viewers.closeAll() }
        .onReceive(NotificationCenter.default.publisher(for: .gonggiSpaceDidDelete)) { note in
            let sessionId = note.userInfo?["sessionId"] as? String
            let jobId = note.userInfo?["jobId"] as? String
            if let launch = viewers.vrLaunch, launch.sessions.contains(where: { $0.id == sessionId || $0.id == jobId }) {
                viewers.vrLaunch = nil
            }
        }
        .sheet(item: $gate.request) { request in
            WhikSignInView(reason: request.reason, onCancel: { gate.cancel() })
        }
        .sheet(isPresented: $showAccount) {
            WhikAccountView(onClose: { showAccount = false })
                .environmentObject(appState)
                .environmentObject(gate)
        }
        .fullScreenCover(item: $viewers.gaussian) { presentation in
            GaussianSplatWebViewer(spaceId: presentation.spaceId, presentedAt: presentation.requestedAt) {
                viewers.gaussian = nil
            }
        }
        .fullScreenCover(item: $viewers.vrLaunch) { launch in
            SpaceVRNavigationHost(sessions: launch.sessions, onClose: { viewers.vrLaunch = nil })
        }
        .overlay {
            if viewers.preparing {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView().tint(.white).scaleEffect(1.2)
                }
                .accessibilityLabel(L("Opening"))
            }
        }
        .alert(L("Couldn't open this capture"), isPresented: Binding(
            get: { viewers.error != nil },
            set: { if !$0 { viewers.error = nil } }
        )) {
            Button(L("Try again")) {
                viewers.error = nil
                if let id = viewers.retryJobId { viewers.openSpace(jobId: id) }
            }
            Button(L("Close"), role: .cancel) { viewers.error = nil }
        } message: {
            Text(viewers.error ?? "")
        }
    }

    private func select(_ newTab: WhikTab) {
        GonggiHaptics.selection()
        switch newTab {
        case .home: appState.selectedTab = .home
        case .capture: appState.selectedTab = .record
        case .library: appState.selectedTab = .library
        }
    }

    /// Profile and settings, signed in or not (Language works for guests).
    private func openAccount() {
        GonggiHaptics.light()
        showAccount = true
    }

    /// A push tapped before sign-in finished restoring is opened once the session is back.
    private func openPendingPush() {
        guard gate.isSignedIn else { return }
        if let id = GonggiPushDeepLink.pendingGaussianSpaceId {
            appState.openGaussianSpaceFromPush(spaceId: id)
        }
    }
}

enum WhikTab: Hashable { case home, capture, library }

/// Floating pill tab bar: Home · Capture · Library.
struct WhikTabBar: View {
    @Binding var selection: WhikTab

    private let items: [(WhikTab, String, String, String)] = [
        (.home, L("Home"), "house", "house.fill"),
        (.capture, L("Capture"), "camera", "camera.fill"),
        (.library, L("Library"), "folder", "folder.fill"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let selected = item.0 == selection
                Button {
                    selection = item.0
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: selected ? item.3 : item.2)
                            .font(.system(size: 19, weight: .semibold))
                        Text(item.1)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selected ? WhikColors.onMint : WhikColors.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(Capsule().fill(selected ? WhikColors.mint : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.1)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(5)
        .background(Capsule().fill(WhikColors.surface.opacity(0.96)))
        .overlay(Capsule().stroke(WhikColors.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}
