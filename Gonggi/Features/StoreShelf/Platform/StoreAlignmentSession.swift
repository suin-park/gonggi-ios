import ARKit
import Combine
import Foundation
import UIKit

/// Restores the saved store space into a live AR session and reports whether it is aligned. Used by the search camera
/// and by recording when a store already has a map. While the state is not `.aligned`, no saved coordinate is used.
final class StoreAlignmentSession: ObservableObject {
    @Published private(set) var state: StoreAlignmentState = .notStarted
    @Published private(set) var startedAt: Date?
    @Published private(set) var alignedAt: Date?

    private let controller: StoreShelfARController
    private var coordinator: StoreAlignmentCoordinator
    private var signs: [String: ShelfReferenceSign] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

    init(controller: StoreShelfARController, timeoutSeconds: Double = 45) {
        self.controller = controller
        coordinator = StoreAlignmentCoordinator(timeoutSeconds: timeoutSeconds)
    }

    deinit { timer?.invalidate() }

    /// Reference images rebuilt from the stored sign photos (name = sign id).
    static func referenceImages(signs: [ShelfReferenceSign], imageData: (String) -> Data?) -> Set<ARReferenceImage> {
        var out = Set<ARReferenceImage>()
        for s in signs {
            guard let data = imageData(s.imageFileName), let cg = UIImage(data: data)?.cgImage, s.physicalWidthM > 0.02 else { continue }
            let ref = ARReferenceImage(cg, orientation: .up, physicalWidth: CGFloat(s.physicalWidthM))
            ref.name = s.id
            out.insert(ref)
        }
        return out
    }

    /// `map` nil means the map could not be loaded: only a reference sign can then align the session.
    func begin(map: ARWorldMap?, expectedMarkers: Int, signs: [ShelfReferenceSign], images: Set<ARReferenceImage>,
               references: [ShelfReferencePoint] = []) {
        self.signs = Dictionary(signs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cancellables.removeAll()
        coordinator.configureReferences(Dictionary(references.map { ($0.id, $0.pose) }, uniquingKeysWith: { first, _ in first }))
        controller.onReferenceAnchor = { [weak self] id, live in
            self?.coordinator.anchorObserved(id: id, livePose: live)
            self?.publish()
        }
        coordinator.start(at: ProcessInfo.processInfo.systemUptime)
        state = coordinator.state
        startedAt = Date()
        alignedAt = nil
        controller.setDetectionImages(images)
        controller.onSignPose = { [weak self] id, live in self?.signSeen(id: id, live: live) }
        controller.$restorePhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else { return }
                if case .restored = phase {
                    self.coordinator.worldMapRestored()
                    self.publish()
                }
            }
            .store(in: &cancellables)
        if let map {
            controller.startRestoring(map: map, expectedMarkers: expectedMarkers)
        } else {
            controller.startFresh()
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.coordinator.tick(at: ProcessInfo.processInfo.systemUptime)
            self.publish()
        }
    }

    func retry(map: ARWorldMap?, expectedMarkers: Int, signs: [ShelfReferenceSign], images: Set<ARReferenceImage>,
               references: [ShelfReferencePoint] = []) {
        begin(map: map, expectedMarkers: expectedMarkers, signs: signs, images: images, references: references)
    }

    /// Why the saved space could not be confirmed: the record has no reference points (made before they were kept).
    var recordLacksReferencePoints: Bool { coordinator.lacksReferencePoints }
    var referencePointsSeen: Int { coordinator.observedReferenceCount }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
        controller.onSignPose = nil
        controller.onReferenceAnchor = nil
    }

    private func signSeen(id: String, live: Rigid) {
        guard let saved = signs[id]?.savedPose else { return }
        coordinator.signObserved(savedPose: saved, livePose: live)
        publish()
    }

    private func publish() {
        if coordinator.state != state {
            state = coordinator.state
            if state.isAligned, alignedAt == nil { alignedAt = Date() }
        }
    }
}
