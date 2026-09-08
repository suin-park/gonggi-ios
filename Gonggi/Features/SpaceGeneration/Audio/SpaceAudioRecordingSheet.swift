import AVFoundation
import SwiftUI

/// Build 80 — in-app AAC/m4a recorder for space audio.
struct SpaceAudioRecordingSheet: View {
    var onCancel: () -> Void
    var onUse: (URL, TimeInterval) -> Void

    @State private var phase: Phase = .idle
    @State private var elapsed: TimeInterval = 0
    @State private var recorder: AVAudioRecorder?
    @State private var previewPlayer: AVAudioPlayer?
    @State private var recordedURL: URL?
    @State private var recordedDuration: TimeInterval = 0
    @State private var tickTask: Task<Void, Never>?
    @State private var previousCategory: AVAudioSession.Category = .ambient
    @State private var permissionDenied = false
    @State private var errorMessage: String?

    private enum Phase {
        case idle
        case recording
        case preview
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: GonggiSpacing.lg) {
                Text("직접 녹음")
                    .font(GonggiTypography.title(22))
                    .foregroundStyle(GonggiColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(timerLabel)
                    .font(GonggiTypography.title(36))
                    .monospacedDigit()
                    .foregroundStyle(GonggiColors.textPrimary)

                if permissionDenied {
                    VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
                        Text("마이크 권한이 필요해요. 설정에서 허용해 주세요.")
                            .font(GonggiTypography.body(15))
                            .foregroundStyle(GonggiColors.textSecondary)
                        SecondaryButton(title: "설정 열기", icon: "gear") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)

                controls
            }
            .padding(GonggiSpacing.lg)
            .background(GonggiAmbientBackground(showGlow: false))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") {
                        cleanup(deleteFile: true)
                        onCancel()
                    }
                    .foregroundStyle(GonggiColors.textSecondary)
                }
            }
            .onDisappear {
                cleanup(deleteFile: false)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch phase {
        case .idle:
            PrimaryButton(title: "녹음 시작", icon: "mic.fill") {
                Task { await startRecording() }
            }
        case .recording:
            PrimaryButton(title: "녹음 중지", icon: "stop.fill") {
                stopRecording()
            }
        case .preview:
            VStack(spacing: GonggiSpacing.sm) {
                SecondaryButton(title: "미리듣기", icon: "play.fill") {
                    previewPlayback()
                }
                SecondaryButton(title: "다시 녹음", icon: "arrow.counterclockwise") {
                    reRecord()
                }
                PrimaryButton(title: "이 녹음 사용", icon: "checkmark") {
                    guard let recordedURL else { return }
                    let url = recordedURL
                    let duration = recordedDuration
                    cleanup(deleteFile: false)
                    onUse(url, duration)
                }
            }
        }
    }

    private var timerLabel: String {
        let value = phase == .preview ? recordedDuration : elapsed
        if value <= 0 { return "0:00" }
        return SpaceAudioPolicy.formatDuration(value)
    }

    private func startRecording() async {
        errorMessage = nil
        let granted = await requestMicPermission()
        guard granted else {
            permissionDenied = true
            return
        }
        permissionDenied = false
        do {
            previousCategory = try SpaceAudioManager.shared.beginRecordingSession()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("space-audio-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: SpaceAudioPolicy.recordingSampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.prepareToRecord()
            guard rec.record() else {
                errorMessage = "녹음을 시작하지 못했어요."
                return
            }
            recorder = rec
            recordedURL = url
            elapsed = 0
            phase = .recording
            startTicker()
        } catch {
            errorMessage = "녹음을 시작하지 못했어요."
        }
    }

    private func stopRecording() {
        tickTask?.cancel()
        tickTask = nil
        recorder?.stop()
        recordedDuration = recorder?.currentTime ?? elapsed
        elapsed = recordedDuration
        recorder = nil
        SpaceAudioManager.shared.endRecordingSession(restore: previousCategory)
        phase = .preview
        previewPlayer?.stop()
        previewPlayer = nil
    }

    private func reRecord() {
        previewPlayer?.stop()
        previewPlayer = nil
        if let recordedURL {
            try? FileManager.default.removeItem(at: recordedURL)
        }
        recordedURL = nil
        recordedDuration = 0
        elapsed = 0
        phase = .idle
        Task { await startRecording() }
    }

    private func previewPlayback() {
        guard let recordedURL else { return }
        previewPlayer?.stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            let player = try AVAudioPlayer(contentsOf: recordedURL)
            player.prepareToPlay()
            player.play()
            previewPlayer = player
        } catch {
            errorMessage = "미리듣기를 재생하지 못했어요."
        }
    }

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { @MainActor in
            while !Task.isCancelled, phase == .recording {
                elapsed = recorder?.currentTime ?? elapsed
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func cleanup(deleteFile: Bool) {
        tickTask?.cancel()
        tickTask = nil
        recorder?.stop()
        recorder = nil
        previewPlayer?.stop()
        previewPlayer = nil
        SpaceAudioManager.shared.endRecordingSession(restore: previousCategory)
        if deleteFile, let recordedURL {
            try? FileManager.default.removeItem(at: recordedURL)
        }
    }

    private func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }
}
