import SwiftUI

/// Single loading / error / VR experience after 20-direction capture.
struct SpaceRecordFlowView: View {
    @ObservedObject var coordinator: SpaceGenerationCoordinator
    var onRecapture: () -> Void
    var onClose: () -> Void

    var body: some View {
        ZStack {
            switch coordinator.state {
            case .viewing:
                if let url = coordinator.localLatLongURL {
                    VRSphereSpaceView(
                        imageURL: url,
                        sessionId: "legacy-flow",
                        onClose: onClose
                    )
                } else {
                    generatingChrome
                }
            case .failed(let failure):
                failureView(failure)
            default:
                generatingChrome
            }
        }
        .preferredColorScheme(.dark)
    }

    private var generatingChrome: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.09, blue: 0.12),
                    Color(red: 0.03, green: 0.04, blue: 0.06)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(GonggiColors.accentTeal)
                    .scaleEffect(1.3)
                Text(L("Creating the space…"))
                    .font(GonggiTypography.title(22))
                    .foregroundStyle(.white)
                Text(L("Please wait a moment"))
                    .font(GonggiTypography.caption(14))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(32)
        }
    }

    private func failureView(_ failure: SpaceRecordFailure) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Text(failure.userMessage)
                    .font(GonggiTypography.title(20))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if failure == .captureIncomplete {
                    Button {
                        GonggiHaptics.medium()
                        coordinator.resetForRecapture()
                        onRecapture()
                    } label: {
                        Text(L("Capture again"))
                            .font(GonggiTypography.body(17))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(GonggiColors.accentTeal)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 32)
                } else {
                    Button {
                        GonggiHaptics.medium()
                        coordinator.retryGenerate()
                    } label: {
                        Text(L("Create again"))
                            .font(GonggiTypography.body(17))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(GonggiColors.accentTeal)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 32)

                    Button {
                        GonggiHaptics.light()
                        coordinator.resetForRecapture()
                        onRecapture()
                    } label: {
                        Text(L("Capture again"))
                            .font(GonggiTypography.body(16))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }

                Button(L("Close")) {
                    onClose()
                }
                .font(GonggiTypography.caption(14))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 8)
            }
        }
    }
}
