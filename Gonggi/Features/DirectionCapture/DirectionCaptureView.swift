import SwiftUI

/// Full-screen 20-direction auto capture → enqueue async generation → home.
struct DirectionCaptureView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = DirectionCaptureViewModel()
    let onClose: () -> Void
    /// When set, caller owns generation enqueue (Build 72 Space Link).
    var onCaptureCompleted: ((DirectionCaptureResult) -> Void)? = nil

    var body: some View {
        ZStack {
            if viewModel.useMockCamera {
                LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.14, blue: 0.18),
                        Color(red: 0.04, green: 0.06, blue: 0.08)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                Text(L("Mock camera"))
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(GonggiColors.textTertiary)
            } else {
                PanoramaCaptureCameraPreview(session: viewModel.engine.session)
                    .ignoresSafeArea()
            }

            overlay
        }
        .onAppear {
            viewModel.configure(mockMode: appState.isMockMode)
        }
        .onChange(of: viewModel.didComplete) { _, done in
            guard done, let result = viewModel.result else { return }
            if let onCaptureCompleted {
                onCaptureCompleted(result)
            } else {
                appState.startSpaceGeneration(from: result)
            }
            viewModel.close()
            onClose()
        }
        .statusBarHidden(true)
    }

    /// Shared WHIK capture HUD: top bar, one guide card, ring + direction count, start button.
    private var overlay: some View {
        VStack(spacing: 12) {
            WhikCaptureTopBar(title: L("360° Space"), onClose: {
                GonggiHaptics.light()
                viewModel.close()
                onClose()
            })
            WhikCaptureGuideCard(guide: DirectionCaptureView.guide(
                phase: viewModel.phase,
                phaseTitle: viewModel.phaseTitle,
                guideText: viewModel.guideText,
                isPhotoPending: viewModel.isPhotoPending
            ))

            #if DEBUG
            Text("\(viewModel.yawDisplay), \(viewModel.pitchDisplay)")
                .font(GonggiTypography.caption(11))
                .foregroundStyle(.white.opacity(0.65))
            #endif

            Spacer()

            bottomPanel
        }
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    static let totalDirections = 20

    /// Guide card for each phase. Before starting: where to stand and what to tap; while capturing: the turn
    /// (eye level / up / down) and the live direction hint; a failure is a warning with its message.
    static func guide(phase: DirectionCapturePhase, phaseTitle: String, guideText: String,
                      isPhotoPending: Bool) -> WhikCaptureGuide {
        switch phase {
        case .idle, .ready:
            return WhikCaptureGuide(title: L("Look around from one spot"), subtitle: L("Tap Start capture to begin"))
        case .failed(let message):
            return WhikCaptureGuide(title: L("Try again"), subtitle: message, tone: .warning)
        case .completed:
            return WhikCaptureGuide(title: L("Capture complete"), subtitle: nil, tone: .done)
        default:
            if isPhotoPending { return WhikCaptureGuide(title: L("Capturing…"), subtitle: nil) }
            return WhikCaptureGuide(title: phaseTitle, subtitle: guideText.isEmpty ? nil : guideText)
        }
    }

    private var bottomPanel: some View {
        let done = viewModel.completed.count
        let isDone = viewModel.phase == .completed
        return WhikCapturePanel {
            switch viewModel.phase {
            case .idle, .ready, .failed:
                WhikCaptureActionButton(title: L("Start capture"), systemImage: "camera", fullWidth: true) {
                    viewModel.startCapture()
                }
            default:
                HStack(spacing: 12) {
                    WhikCaptureProgressRing(
                        fraction: Double(done) / Double(Self.totalDirections),
                        tone: isDone ? .done : .normal
                    )
                    WhikCaptureCountLabel(
                        count: "\(done) / \(Self.totalDirections)",
                        caption: L("Keep moving, capturing automatically")
                    )
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
