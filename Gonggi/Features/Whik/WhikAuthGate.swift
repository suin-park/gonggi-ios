import SwiftUI

/// Sign-in on demand. Guests use Home and browse Capture; an action that needs the server (create, import,
/// library) asks for sign-in at that moment and continues once signed in. Cancelling leaves the user where
/// they were. Server-side auth and ownership checks are unchanged.
@MainActor
final class WhikAuthGate: ObservableObject {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let reason: String
        static func == (a: Request, b: Request) -> Bool { a.id == b.id }
    }

    @Published var request: Request?
    private var pending: (() -> Void)?
    private let auth: AuthSessionController

    init(auth: AuthSessionController = .shared) {
        self.auth = auth
    }

    var isSignedIn: Bool {
        if case .signedIn = auth.phase { return true }
        return false
    }

    /// Runs `action` now when signed in; otherwise shows the sign-in sheet and runs it after sign-in.
    func run(reason: String, action: @escaping () -> Void) {
        if isSignedIn {
            action()
            return
        }
        pending = action
        request = Request(reason: reason)
    }

    /// Plain sign-in (profile button), nothing to continue.
    func signIn(reason: String = L("Sign in to save your captures to your account.")) {
        guard !isSignedIn else { return }
        pending = nil
        request = Request(reason: reason)
    }

    /// Called by the root when the auth phase changes.
    func phaseChanged() {
        guard isSignedIn, request != nil else { return }
        let action = pending
        pending = nil
        request = nil
        // Let the sheet finish dismissing before a full-screen flow is presented.
        if let action {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: action)
        }
    }

    /// Sheet closed without signing in.
    func cancel() {
        pending = nil
        request = nil
    }
}

/// Opens results from anywhere (Library, import, push) with one set of covers kept on the root.
@MainActor
final class WhikViewerPresenter: ObservableObject {
    @Published var gaussian: GaussianViewerPresentation?
    @Published var vrLaunch: SpaceViewerLaunch?
    @Published var preparing = false
    @Published var error: String?
    private(set) var retryJobId: String?
    weak var appState: AppState?

    func openGaussian(spaceId: String) {
        gaussian = GaussianViewerPresentation(spaceId: spaceId)
    }

    /// 360° (Lat Long) result: download / reuse the cached file, then open VR. Never opens a blank viewer.
    func openSpace(jobId: String) {
        guard let appState else { return }
        retryJobId = jobId
        preparing = true
        Task {
            defer { preparing = false }
            switch await appState.prepareSpaceViewer(jobId: jobId) {
            case .success(let url):
                vrLaunch = SpaceViewerLaunch(
                    single: SpaceViewerSession(
                        id: jobId,
                        fileURL: url,
                        audioURL: AppState.preferredAudioURL(for: jobId),
                        videoURL: AppState.preferredVideoURL(for: jobId)
                    )
                )
            case .failure(let failure):
                error = failure.userMessage
            }
        }
    }

    func closeAll() {
        gaussian = nil
        vrLaunch = nil
    }
}
