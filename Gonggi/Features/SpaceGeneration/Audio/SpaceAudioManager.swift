import AVFoundation
import Foundation

/// Build 80 — single-space ambient playback (no loop). Local mute only.
@MainActor
final class SpaceAudioManager: ObservableObject {
    static let shared = SpaceAudioManager()

    @Published private(set) var currentSpaceId: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var isMuted = false
    @Published private(set) var isPausedForBackground = false

    private var player: AVAudioPlayer?
    private var fadeTask: Task<Void, Never>?
    private var playbackGeneration = 0

    private init() {}

    // MARK: - Mute (session-local)

    func mute() {
        isMuted = true
        player?.volume = 0
    }

    func unmute() {
        isMuted = false
        if isPlaying, !isPausedForBackground {
            player?.volume = 1
        }
    }

    func toggleMute() {
        if isMuted { unmute() } else { mute() }
    }

    // MARK: - Resolve + play

    /// Prefer job store `audioURL`, else GET once.
    func resolveAudioURL(spaceId: String) async -> URL? {
        if let job = SpaceJobStore.shared.jobs.first(where: {
            $0.jobId == spaceId || $0.sessionId == spaceId
        }), let raw = job.audioURL, let url = URL(string: raw) {
            return url
        }
        do {
            return try await SpaceAudioStore.shared.fetchAudioURL(spaceId: spaceId)
        } catch {
            return nil
        }
    }

    /// Start (or replace) playback for a space. Play-once, fade-in.
    func playForSpace(spaceId: String, preferredURL: URL? = nil) async {
        let url: URL?
        if let preferredURL {
            url = preferredURL
        } else {
            url = await resolveAudioURL(spaceId: spaceId)
        }
        guard let url else {
            await fadeOutAndStop()
            return
        }
        await play(url: url, spaceId: spaceId, fadeIn: true)
    }

    /// Idempotent entry for library / onAppear — skip if already on this space.
    func ensurePlaying(for spaceId: String, preferredURL: URL? = nil) async {
        if currentSpaceId == spaceId, isPlaying, !isPausedForBackground { return }
        await playForSpace(spaceId: spaceId, preferredURL: preferredURL)
    }

    func play(url: URL, spaceId: String, fadeIn: Bool) async {
        fadeTask?.cancel()
        playbackGeneration += 1
        let gen = playbackGeneration

        do {
            try configureAmbientSession()
            let data: Data
            if url.isFileURL {
                data = try Data(contentsOf: url)
            } else {
                let (remote, _) = try await URLSession.shared.data(from: url)
                data = remote
            }
            guard gen == playbackGeneration else { return }

            let next = try AVAudioPlayer(data: data)
            next.numberOfLoops = 0 // Build 80: play once, no loop
            next.prepareToPlay()
            player?.stop()
            player = next
            currentSpaceId = spaceId
            isPausedForBackground = false
            isPlaying = true

            if fadeIn {
                next.volume = 0
                next.play()
                await fadeVolume(to: isMuted ? 0 : 1, duration: SpaceAudioPolicy.fadeInSeconds, generation: gen)
            } else {
                next.volume = isMuted ? 0 : 1
                next.play()
            }
        } catch {
            isPlaying = false
            currentSpaceId = nil
            player = nil
        }
    }

    func stop() {
        fadeTask?.cancel()
        playbackGeneration += 1
        player?.stop()
        player = nil
        isPlaying = false
        currentSpaceId = nil
        isPausedForBackground = false
    }

    func fadeOutAndStop(duration: TimeInterval = SpaceAudioPolicy.fadeOutSeconds) async {
        fadeTask?.cancel()
        let gen = playbackGeneration
        await fadeVolume(to: 0, duration: duration, generation: gen)
        guard gen == playbackGeneration else { return }
        stop()
    }

    /// A → B transition: fade out current, then play B with fade-in.
    func transition(toSpaceId spaceId: String, preferredURL: URL?) async {
        await fadeOutAndStop()
        await playForSpace(spaceId: spaceId, preferredURL: preferredURL)
    }

    // MARK: - Scene phase

    func pauseForBackground() {
        guard isPlaying, let player, player.isPlaying else { return }
        player.pause()
        isPausedForBackground = true
        isPlaying = false
    }

    func resumeFromBackground() {
        guard isPausedForBackground, let player else { return }
        try? configureAmbientSession()
        player.volume = isMuted ? 0 : 1
        player.play()
        isPausedForBackground = false
        isPlaying = true
    }

    // MARK: - Recording session helpers

    /// Switch to playAndRecord for mic capture; returns previous category to restore.
    @discardableResult
    func beginRecordingSession() throws -> AVAudioSession.Category {
        let session = AVAudioSession.sharedInstance()
        let previous = session.category
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        return previous
    }

    func endRecordingSession(restore category: AVAudioSession.Category) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(category, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Private

    private func configureAmbientSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }

    private func fadeVolume(to target: Float, duration: TimeInterval, generation: Int) async {
        guard let player else { return }
        let start = player.volume
        let steps = max(Int(duration / 0.03), 1)
        fadeTask?.cancel()
        let task = Task { @MainActor in
            for i in 1...steps {
                guard !Task.isCancelled, generation == self.playbackGeneration else { return }
                let t = Float(i) / Float(steps)
                player.volume = start + (target - start) * t
                try? await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1_000_000_000))
            }
            guard generation == self.playbackGeneration else { return }
            player.volume = target
        }
        fadeTask = task
        await task.value
    }
}
