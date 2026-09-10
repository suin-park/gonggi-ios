import AVFoundation
import Combine
import Foundation

/// Lightweight manual public-space audio — no autoplay; independent of SpaceAudioManager.ensurePlaying.
@MainActor
final class PublicSpaceAudioController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var muteCancellable: AnyCancellable?
    private let spaceAudio = SpaceAudioManager.shared

    init() {
        muteCancellable = spaceAudio.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyMuteVolume()
            }
    }

    func beginLoading() {
        isLoading = true
        loadFailed = false
    }

    func markLoadFailed() {
        isLoading = false
        loadFailed = true
        stop()
    }

    deinit {
        muteCancellable?.cancel()
    }

    func prepare(fileURL: URL, fallbackDurationSec: Double?) {
        stop()
        loadFailed = false
        isLoading = false
        let item = AVPlayerItem(url: fileURL)
        let next = AVPlayer(playerItem: item)
        next.actionAtItemEnd = .pause
        player = next
        duration = fallbackDurationSec ?? 0
        currentTime = 0
        isPlaying = false
        applyMuteVolume()

        timeObserver = next.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? max(0, time.seconds) : 0
                if let itemDuration = next.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
            }
        }
    }

    func play() {
        guard let player else { return }
        applyMuteVolume()
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func restart() {
        guard let player else { return }
        player.seek(to: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.currentTime = 0
                self?.play()
            }
        }
    }

    func seek(to seconds: TimeInterval) {
        guard let player, duration > 0 else { return }
        let clamped = min(max(0, seconds), duration)
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time) { [weak self] _ in
            Task { @MainActor in
                self?.currentTime = clamped
            }
        }
    }

    func stop() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        isLoading = false
    }

    private func applyMuteVolume() {
        player?.volume = spaceAudio.isMuted ? 0 : 1
    }
}
