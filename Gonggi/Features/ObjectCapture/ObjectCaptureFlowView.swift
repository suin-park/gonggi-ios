import ARKit
import RealityKit
import SwiftUI

enum ObjectCaptureCopy {
    static var title: String { L("Create a 3D Object") }
    static var introLines: [String] { [
        ObjectCaptureSubject.stillObject.startLine,
        L("Leave the object in place and walk slowly around it holding the phone"),
        L("Move objects away from the wall a little"),
        L("It's fine if the floor and surroundings are in the shot. Only the object is kept in the result"),
    ] }
    /// Shown under the lines above, in a different style: what is NOT supported in this version.
    static let unsupportedLine = ObjectCaptureSubject.person.startLine
    static var start: String { L("Start") }
    /// After the box is placed (automatically or by tap). The box is a guide the user fits; it does not know the product.
    static var sizingHint: String { L("Adjust the box's position and size so it fully surrounds the object.") }
    /// Loose box switched on (internal test): the box only has to roughly surround the object.
    static var sizingHintLoose: String { L("The box only needs to roughly surround the object. It doesn't have to be exact.") }
    /// Default placing: tap the support surface under the product (floor / table).
    static var manualPlacementHint: String { L("Tap the floor or table under the object to place the box.") }
    /// The worker keeps only what is inside the box, so a tight box cuts the product off.
    static var sizingTips: String { L("Fit the box around the object. Use the slider for size and drag the box to move it") }
    /// Capture-screen footnote: green means a good place to take photos, not that the whole object is verified in frame.
    static var captureNote: String { L("A green box is a good position to capture. Check that the object isn't cut off at the edges") }
    /// Optional auxiliary locating: tap the object itself from two places.
    static var tapObjectHint: String { L("Tap the center of the object") }
    static var secondTapHint: String { L("Move two or three steps to the side, then tap the center of the object again") }
    static var readyHint: String { L("The box just needs to surround the object. Move and resize it with your fingers") }
    static var walkProgress: String { L("Angle moved") }
    static var showDiagnostics: String { L("Show position diagnostics") }
    static var twoTapInstead: String { L("Place by tapping the object twice (assist)") }
    static var floorTapInstead: String { L("Place by tapping the floor") }
    static var showCube: String { L("Show box") }
    static var shareTrace: String { L("Share position diagnostics") }
    static var uniformSize: String { L("Size") }
    static var advanced: String { L("Fine-tune") }
    static var advancedTips: String { L("For long objects, set width, height and depth separately. Make the height a little above the top of the object") }
    static var looseToggle: String { L("Loose box mode (internal test)") }
    static var looseToggleNote: String { L("Off keeps the current behavior. Turn it on only after the new 3D server is ready") }
    static var reviewTitle: String { L("Some directions still need photos") }
    static var reviewMore: String { L("Take more") }
    static var reviewAsIs: String { L("Create the 3D Object anyway") }
    static var width: String { L("Width") }
    static var height: String { L("Height") }
    static var depth: String { L("Depth") }
    static var placeAgain: String { L("Place again") }
    static var beginCapture: String { L("Start capture") }
    static var finish: String { L("End capture") }
    static var finishing: String { L("Organizing photos") }
    static var close: String { L("Close") }
    static var bands: [String] { [L("Low"), L("Middle"), L("High")] }
    static var rangeHoldResume: String { L("Continue capturing") }
    static var rangeHoldFinish: String { L("Finish with these photos") }
    static var rangeHoldNewSession: String { L("Start a new capture") }

    static func photos(_ n: Int) -> String { L("%@ photos", "\(n)") }

    static func defaultName(date: Date) -> String {
        WhikAutoName.object(date)
    }
}

/// Full-screen product capture: place the box under the product, size it, walk around, then upload through the
/// same Processing screen as space capture (captureKind object is detected from object.json in the package).
struct ObjectCaptureFlowView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var session = ObjectCaptureSession()
    @State private var showIntro = true
    @State private var summary: CaptureSessionSummary?
    let onClose: () -> Void

    var body: some View {
        ZStack {
            ObjectCaptureARView(session: session)
                .ignoresSafeArea()
            // Two-tap auxiliary only: show where the first tap landed. No floor ring on the main screen.
            if session.stage == .secondTap, session.firstTapMarker != nil {
                ObjectFootprintOverlay(
                    ring: nil, marker: session.firstTapMarker, highlight: false
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            if session.showsCube {
                ObjectBoxOverlay(corners: session.cornersOnScreen, highlight: session.framing == .ok)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            if session.showsDiagnostics, let text = session.diagnosticsReadout {
                ObjectDiagnosticsChip(text: text)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 12) {
                WhikCaptureTopBar(title: L("3D Object"), onClose: {
                    session.stop()
                    onClose()
                })
                if let guide = cardGuide {
                    WhikCaptureGuideCard(guide: guide)
                }
                Spacer()
                bottomPanel
            }
            .padding(.vertical, 12)
        }
        .onAppear { session.start() }
        .onDisappear { session.stop() }
        .sheet(isPresented: $showIntro) {
            ObjectCaptureIntroView(onStart: { showIntro = false }, onClose: {
                showIntro = false
                onClose()
            })
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled()
        }
        .fullScreenCover(item: $summary) { s in
            ProcessingView(
                summary: s,
                spaceService: appState.spaceService,
                qualityProfile: ServerGenerationProfileMapper.spatialPackageProfile,
                sourceLatLongSessionId: nil,
                allowStubVideoInMock: appState.isMockMode,
                onComplete: { _, _ in
                    summary = nil
                    onClose()
                    appState.preferredLibraryCategory = .assets
                    appState.pendingLibraryTab = .assets
                    appState.selectTab(.library)
                },
                onHandedOff: { _, _ in
                    summary = nil
                    appState.gaussianLibraryBanner = L("3D Object creation has started.")
                    appState.rebuildSpaces()
                    appState.ensureGaussianGenerationPolling()
                    onClose()
                    // Product results are filed under 보관함 › 3D 자산.
                    appState.preferredLibraryCategory = .assets
                    appState.pendingLibraryTab = .assets
                    appState.selectTab(.library)
                },
                onDismiss: { summary = nil }
            )
        }
    }

    /// One guide card (shared WHIK capture HUD). Tracking / range recovery replaces placement and walk guidance
    /// as a warning (never both at once, D3); otherwise the step hint with its supporting note.
    private var cardGuide: WhikCaptureGuide? {
        if let note = session.rangeHoldNote {
            return WhikCaptureGuide(title: note, subtitle: nil, tone: .warning)
        }
        if let note = session.trackingNote {
            return WhikCaptureGuide(title: note, subtitle: session.trackingHelper, tone: .warning)
        }
        guard !topText.isEmpty else { return nil }
        let subtitle: String?
        switch session.stage {
        case .placing, .secondTap: subtitle = session.locatingNote
        case .capturing: subtitle = ObjectCaptureCopy.captureNote
        default: subtitle = nil
        }
        if case .failed = session.stage {
            return WhikCaptureGuide(title: topText, subtitle: nil, tone: .warning)
        }
        return WhikCaptureGuide(title: topText, subtitle: subtitle)
    }

    private var topText: String {
        // Tracking / range recovery replaces placement and walk guidance (no duplicate chip lines).
        if session.trackingNote != nil || session.rangeHoldNote != nil {
            return ""
        }
        switch session.stage {
        case .placing:
            if session.floorTapMode {
                return session.placementHint ?? ObjectCaptureCopy.manualPlacementHint
            }
            return session.placementHint ?? ObjectCaptureCopy.tapObjectHint
        case .secondTap:
            return ObjectCaptureCopy.secondTapHint
        case .sizing: return ObjectCaptureCopy.readyHint
        case .capturing: return session.guidance?.text ?? ObjectCaptureGuidance.walkAround(towardLeft: true).text
        case .finishing: return ObjectCaptureCopy.finishing
        case .failed(let message): return message
        }
    }

    @ViewBuilder
    private var bottomPanel: some View {
        switch session.stage {
        case .placing, .secondTap:
            ObjectLocatingPanel(session: session)
        case .sizing:
            ObjectSizingPanel(session: session)
        case .capturing:
            ObjectCapturingPanel(session: session) {
                Task {
                    // Clears discontinuity hold (if any) then writes package with locked processingBox.
                    if let s = await session.finishPreservingCapture() { summary = s }
                }
            }
        case .finishing:
            ProgressView().tint(.white)
        case .failed:
            WhikCapturePanel {
                WhikCaptureActionButton(title: ObjectCaptureCopy.close, fullWidth: true) { onClose() }
            }
        }
    }

}

/// Sizing step: one size slider, the rest under "자세히 조절". A struct of its own so the real panel can be rendered in tests.
struct ObjectSizingPanel: View {
    @ObservedObject var session: ObjectCaptureSession
    @State private var advancedOpen: Bool

    init(session: ObjectCaptureSession, startExpanded: Bool = false) {
        self.session = session
        _advancedOpen = State(initialValue: startExpanded)
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(ObjectCaptureCopy.sizingTips)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(ObjectCaptureCopy.uniformSize)
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 36, alignment: .leading)
                Slider(
                    value: Binding(get: { Double(session.uniformScale) }, set: { session.setUniformScale(Float($0)) }),
                    in: 0.15...7.0,
                    onEditingChanged: { session.setControlsActive($0) }
                )
                Text("\(Int((session.box.size.max() * 100).rounded()))cm")
                    .font(.subheadline.monospacedDigit())
                    .frame(minWidth: 52, alignment: .trailing)
            }
            .foregroundStyle(.white)
            DisclosureGroup(ObjectCaptureCopy.advanced, isExpanded: $advancedOpen) {
                VStack(spacing: 10) {
                    Text(ObjectCaptureCopy.advancedTips)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    sizeSlider(ObjectCaptureCopy.width, value: session.box.size.x) { session.setSize(width: $0) }
                    sizeSlider(ObjectCaptureCopy.height, value: session.box.size.y) { session.setSize(height: $0) }
                    sizeSlider(ObjectCaptureCopy.depth, value: session.box.size.z) { session.setSize(depth: $0) }
                    HStack(spacing: 12) {
                        Button { session.rotate(byRadians: -.pi / 36) } label: { Image(systemName: "rotate.left") }
                            .accessibilityLabel(L("Rotate box left"))
                        Button { session.rotate(byRadians: .pi / 36) } label: { Image(systemName: "rotate.right") }
                            .accessibilityLabel(L("Rotate box right"))
                        Spacer()
                    }
                    Toggle(ObjectCaptureCopy.showCube, isOn: $session.showsCube)
                        .font(.subheadline.weight(.semibold))
                    Toggle(ObjectCaptureCopy.showDiagnostics, isOn: $session.showsDiagnostics)
                        .font(.subheadline.weight(.semibold))
                    ObjectTraceShareButton(session: session)
                    Toggle(isOn: Binding(get: { session.looseBox }, set: { session.setLooseBox($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ObjectCaptureCopy.looseToggle).font(.subheadline.weight(.semibold))
                            Text(ObjectCaptureCopy.looseToggleNote).font(.caption).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                .padding(.top, 6)
            }
            .font(.body.weight(.semibold))
            .tint(.white)
            .foregroundStyle(.white)
            HStack(spacing: 12) {
                Spacer()
                Button(ObjectCaptureCopy.placeAgain) { session.placeAgain() }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
            }
            WhikCaptureActionButton(title: ObjectCaptureCopy.beginCapture, systemImage: "camera", fullWidth: true) {
                session.beginCapture()
            }
        }
        .whikCapturePanelStyle()
    }

    private func sizeSlider(_ label: String, value: Float, set: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 36, alignment: .leading)
            Slider(
                value: Binding(get: { Double(value) }, set: { set(Float($0)) }),
                in: Double(ObjectCaptureConfig.minSide)...Double(ObjectCaptureConfig.maxSide),
                onEditingChanged: { session.setControlsActive($0) }
            )
            Text("\(Int((value * 100).rounded()))cm")
                .font(.subheadline.monospacedDigit())
                .frame(minWidth: 52, alignment: .trailing)
        }
        .foregroundStyle(.white)
    }

}

/// Capturing step: the footnote, the orbit rings, saved-photo counts and the finish button.
struct ObjectCapturingPanel: View {
    @ObservedObject var session: ObjectCaptureSession
    /// Called when the user finishes (directly, or after choosing "그대로 3D 자산 만들기" in the review).
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if session.rangeConsistencyHold {
                rangeHoldControls
            } else {
                // The capture note is the guide card's supporting line (shared WHIK capture HUD).
                capturingControls
            }
        }
        .confirmationDialog(
            ObjectCaptureCopy.reviewTitle,
            isPresented: Binding(get: { session.review != nil }, set: { if !$0 { session.continueCapturing() } }),
            titleVisibility: .visible
        ) {
            Button(ObjectCaptureCopy.reviewMore) { session.continueCapturing() }
            Button(ObjectCaptureCopy.reviewAsIs) {
                session.continueCapturing()
                onFinish()
            }
        } message: {
            Text(session.review?.message ?? "")
        }
    }

    private var rangeHoldControls: some View {
        VStack(spacing: 10) {
            if session.canResumeSameCapture {
                Button(ObjectCaptureCopy.rangeHoldResume) { session.resumeCaptureAfterRangeCheck() }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(GonggiColors.accentTeal, in: Capsule())
                    .foregroundStyle(.white)
            }
            // Camera-frame break: close this package (preserve photos + diagnostics). Never append more frames.
            Button(ObjectCaptureCopy.rangeHoldFinish) { onFinish() }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(session.canResumeSameCapture ? Color.white.opacity(0.2) : GonggiColors.accentTeal, in: Capsule())
                .foregroundStyle(.white)
            Button(ObjectCaptureCopy.rangeHoldNewSession) {
                if session.savedPhotos >= 2 {
                    // Preserve current package via the normal finish path, then the user starts again from the entry screen.
                    onFinish()
                } else {
                    session.beginNewCaptureSessionAfterPreserve()
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
        }
        .whikCapturePanelStyle()
    }

    private var capturingControls: some View {
        // Same row as the other modes: ring, photo count with a short status line, end button. The orbit rings are
        // this mode's ring (one ring per height band; the band percentages are read out for VoiceOver).
        HStack(alignment: .center, spacing: 12) {
            ObjectOrbitRingsView(counts: session.coverageCounts, currentAzimuthDeg: session.currentAzimuthDeg)
                .frame(width: 64, height: 64)
                .accessibilityLabel(ringsAccessibility)
            WhikCaptureCountLabel(
                count: ObjectCaptureCopy.photos(session.savedPhotos),
                caption: L("Angles covered %@", "\(coveredPercent)%")
            )
            Spacer(minLength: 0)
            WhikCaptureActionButton(title: ObjectCaptureCopy.finish, enabled: session.savedPhotos >= 2) {
                guard session.requestFinish() else { return }
                onFinish()
            }
        }
        .whikCapturePanelStyle()
    }

    private var coveredPercent: Int {
        guard !session.bandFill.isEmpty else { return 0 }
        return Int((session.bandFill.reduce(0, +) / Double(session.bandFill.count) * 100).rounded())
    }

    private var ringsAccessibility: String {
        zip(ObjectCaptureCopy.bands, session.bandFill)
            .map { L("%1$@ %2$@ percent", "\($0)", "\(Int(($1 * 100).rounded()))") }
            .joined(separator: ", ")
    }

}

/// Start screen: what a 3D asset capture is, and what is not supported yet.
struct ObjectCaptureIntroView: View {
    let onStart: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ObjectCaptureCopy.title)
                .font(.title2.weight(.bold))
            ForEach(ObjectCaptureCopy.introLines, id: \.self) { line in
                Label(line, systemImage: "checkmark.circle")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(ObjectCaptureCopy.unsupportedLine, systemImage: "xmark.circle")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            PrimaryButton(title: ObjectCaptureCopy.start, icon: "arrow.right") { onStart() }
            Button(ObjectCaptureCopy.close) {
                onClose()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(24)
    }
}

/// Locating step: floor tap is the default; two-tap on the object is an optional auxiliary.
struct ObjectLocatingPanel: View {
    @ObservedObject var session: ObjectCaptureSession

    var body: some View {
        VStack(spacing: 10) {
            if session.stage == .secondTap {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: session.walkProgress)
                        .tint(GonggiColors.accentTeal)
                    Text("\(ObjectCaptureCopy.walkProgress) \(Int((session.walkProgress * Double(ObjectTwoTap.goodConvergenceDeg)).rounded()))° / \(Int(ObjectTwoTap.goodConvergenceDeg))°")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                }
                HStack {
                    Spacer()
                    Button(ObjectCaptureCopy.placeAgain) { session.placeAgain() }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
            } else if session.floorTapMode {
                Button(ObjectCaptureCopy.twoTapInstead) { session.useTwoTapLocating() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Button(ObjectCaptureCopy.floorTapInstead) { session.useFloorTap() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .whikCapturePanelStyle()
    }
}

/// Small live readout under the status bar: tracking, anchor movement, floor height, the return check.
struct ObjectDiagnosticsChip: View {
    let text: String

    var body: some View {
        VStack {
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 150)
                .padding(.horizontal, 12)
            Spacer()
        }
    }
}

/// Shares the placement trace (a small JSON file) through the system share sheet.
struct ObjectTraceShareButton: View {
    @ObservedObject var session: ObjectCaptureSession
    @State private var url: URL?
    @State private var showSheet = false

    var body: some View {
        Button(ObjectCaptureCopy.shareTrace) {
            url = session.writeTraceFile()
            showSheet = url != nil
        }
        .font(.subheadline.weight(.semibold))
        .sheet(isPresented: $showSheet) {
            if let url { ObjectActivitySheet(items: [url]) }
        }
    }
}

struct ObjectActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The floor ring (a loose selection: nothing to fit) and the place where the first tap landed.
struct ObjectFootprintOverlay: View {
    let ring: [CGPoint]?
    let marker: CGPoint?
    let highlight: Bool

    var body: some View {
        Canvas { ctx, _ in
            let color: Color = highlight ? GonggiColors.accentTeal : .white.opacity(0.9)
            if let pts = ring, pts.count >= 3 {
                var path = Path()
                path.move(to: pts[0])
                for p in pts.dropFirst() { path.addLine(to: p) }
                path.closeSubpath()
                ctx.fill(path, with: .color(color.opacity(0.14)))
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3, dash: [10, 7]))
                let cx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count)
                let cy = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 4, y: cy - 4, width: 8, height: 8)), with: .color(color))
            }
            if let m = marker {
                var cross = Path()
                cross.move(to: CGPoint(x: m.x - 14, y: m.y)); cross.addLine(to: CGPoint(x: m.x + 14, y: m.y))
                cross.move(to: CGPoint(x: m.x, y: m.y - 14)); cross.addLine(to: CGPoint(x: m.x, y: m.y + 14))
                ctx.stroke(cross, with: .color(.white), lineWidth: 3)
                ctx.stroke(Path(ellipseIn: CGRect(x: m.x - 18, y: m.y - 18, width: 36, height: 36)), with: .color(.white.opacity(0.9)), lineWidth: 2)
            }
        }
    }
}

private extension Array {
    /// Out-of-range → nil (orbit rows / band fill arrays are fixed-size, this only guards drawing).
    func objectCaptureElement(at i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Camera feed; a tap places the box on the support surface under the product.
struct ObjectCaptureARView: UIViewRepresentable {
    let session: ObjectCaptureSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.session = session.arSession
        view.automaticallyConfigureSession = false
        view.renderOptions = [.disablePersonOcclusion, .disableMotionBlur]
        let coaching = ARCoachingOverlayView()
        coaching.goal = .horizontalPlane
        coaching.session = session.arSession
        coaching.activatesAutomatically = true
        coaching.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(coaching)
        NSLayoutConstraint.activate([
            coaching.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            coaching.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            coaching.topAnchor.constraint(equalTo: view.topAnchor),
            coaching.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        // Placed box: one finger on the cube drags it on the floor plane; two fingers turn it (drag stops).
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        let turn = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.turned(_:)))
        turn.delegate = context.coordinator
        view.addGestureRecognizer(turn)
        session.arView = view
        context.coordinator.session = session
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var session: ObjectCaptureSession?

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let session, let view = g.view else { return false }
            if g is UIPanGestureRecognizer {
                return session.canStartDrag(at: g.location(in: view))
            }
            if g is UIRotationGestureRecognizer {
                return session.stage == .sizing
            }
            return true
        }

        /// A second finger landing during a drag starts the turn; the drag then stops (see `panned`).
        func gestureRecognizer(
            _ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            (g is UIPanGestureRecognizer && other is UIRotationGestureRecognizer)
                || (g is UIRotationGestureRecognizer && other is UIPanGestureRecognizer)
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let session, session.stage == .placing || session.stage == .secondTap, let view = g.view else { return }
            session.tapObject(at: g.location(in: view))
        }

        @objc func panned(_ g: UIPanGestureRecognizer) {
            guard let session, session.stage == .sizing, let view = g.view else { return }
            // Two fingers down = turning: the box must not slide at the same time.
            if g.numberOfTouches > 1 {
                session.dragBox(at: .zero, phase: .ended)
                return
            }
            let phase: ObjectCaptureSession.DragPhase
            switch g.state {
            case .began: phase = .began
            case .changed: phase = .changed
            default: phase = .ended
            }
            session.dragBox(at: g.location(in: view), phase: phase)
        }

        @objc func turned(_ g: UIRotationGestureRecognizer) {
            guard let session, session.stage == .sizing, g.state == .changed else { return }
            // Screen clockwise twist = box turns clockwise seen from above (yaw is counter-clockwise positive).
            session.rotate(byRadians: -Float(g.rotation))
            g.rotation = 0
        }
    }
}

/// Product box wireframe drawn from the projected corners.
struct ObjectBoxOverlay: View {
    let corners: [CGPoint]?
    let highlight: Bool

    var body: some View {
        Canvas { ctx, _ in
            guard let c = corners, c.count == 8 else { return }
            var path = Path()
            for (a, b) in ObjectCaptureBox.edgeIndexPairs {
                path.move(to: c[a])
                path.addLine(to: c[b])
            }
            ctx.stroke(path, with: .color(highlight ? GonggiColors.accentTeal : .white.opacity(0.85)), lineWidth: 2.5)
        }
    }
}

/// Top view of the orbit: three rings (low / middle / high, outer to inner), one segment per azimuth bin.
struct ObjectOrbitRingsView: View {
    let counts: [[Int]]
    let currentAzimuthDeg: Double?

    var body: some View {
        Canvas { ctx, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2 - 4
            let ringWidth = outer / 4.2
            let n = ObjectCaptureConfig.azimuthBinCount
            let step = 2 * Double.pi / Double(n)
            for (band, row) in counts.enumerated() {
                let r = outer - CGFloat(band) * (ringWidth + 3) - ringWidth / 2
                for bin in 0..<n {
                    let start = Angle(radians: Double(bin) * step + 0.03)
                    let end = Angle(radians: Double(bin + 1) * step - 0.03)
                    var arc = Path()
                    arc.addArc(center: centre, radius: r, startAngle: start, endAngle: end, clockwise: false)
                    let c = row.objectCaptureElement(at: bin) ?? 0
                    let color: Color = c >= ObjectCaptureConfig.coveredPhotosPerCell
                        ? GonggiColors.accentTeal
                        : (c > 0 ? GonggiColors.accentTeal.opacity(0.45) : .white.opacity(0.22))
                    ctx.stroke(arc, with: .color(color), lineWidth: ringWidth)
                }
            }
            if let az = currentAzimuthDeg {
                let a = az * .pi / 180
                let p = CGPoint(x: centre.x + CGFloat(cos(a)) * (outer + 1), y: centre.y + CGFloat(sin(a)) * (outer + 1))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.white))
            }
        }
    }
}
