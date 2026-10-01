import ARKit
import RealityKit
import SwiftUI

enum ObjectCaptureCopy {
    static let title = "제품 3D 촬영"
    static let introLines = [
        "움직이지 않는 무광 제품 하나를 찍어요",
        "제품은 그대로 두고, 휴대폰을 들고 주위를 걸어요",
        "벽에 붙은 제품은 조금 떼어 놓아 주세요",
        "바닥과 주변이 함께 찍혀도 괜찮아요. 결과에서는 제품만 남겨요",
    ]
    static let start = "시작"
    /// After the box is placed (automatically or by tap). The box is a guide the user fits; it does not know the product.
    static let sizingHint = "상자가 제품을 넉넉하게 감싸도록 위치와 크기를 맞춰 주세요."
    /// While no box exists and automatic placement could not find a steady surface.
    static let manualPlacementHint = "제품 아래의 바닥이나 테이블을 눌러 상자를 놓아 주세요."
    /// The worker keeps only what is inside the box, so a tight box cuts the product's top off (GONGGI_OBJECT_V1_002).
    static let sizingTips = "상자 안을 한 손가락으로 끌어 옮기고, 두 손가락으로 돌려요. 높이는 제품 맨 위보다 조금 높게 잡아 주세요"
    static let width = "가로"
    static let height = "높이"
    static let depth = "깊이"
    static let placeAgain = "다시 놓기"
    static let beginCapture = "촬영 시작"
    static let finish = "마침"
    static let finishing = "사진을 정리하고 있어요"
    static let close = "닫기"
    static let bands = ["낮게", "중간", "높게"]

    static func photos(_ n: Int) -> String { "사진 \(n)장" }

    static func defaultName(date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 HH:mm"
        return "제품 3D \(f.string(from: date))"
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
            ObjectBoxOverlay(corners: session.cornersOnScreen, highlight: session.framing == .ok)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 12) {
                topBar
                Spacer()
                bottomPanel
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .onAppear { session.start() }
        .onDisappear { session.stop() }
        .sheet(isPresented: $showIntro) {
            intro
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
                    appState.gaussianLibraryBanner = "제품 3D 생성을 시작했어요."
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

    private var topBar: some View {
        HStack(alignment: .top) {
            if !topText.isEmpty {
                Text(topText)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(ObjectCaptureCopy.close) {
                session.stop()
                onClose()
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(0.55), in: Capsule())
        }
    }

    private var topText: String {
        switch session.stage {
        case .placing: return session.placementHint ?? ""
        case .sizing: return ObjectCaptureCopy.sizingHint
        case .capturing: return session.guidance?.text ?? ObjectCaptureGuidance.walkAround(towardLeft: true).text
        case .finishing: return ObjectCaptureCopy.finishing
        case .failed(let message): return message
        }
    }

    @ViewBuilder
    private var bottomPanel: some View {
        switch session.stage {
        case .placing:
            EmptyView()
        case .sizing:
            sizingPanel
        case .capturing:
            capturingPanel
        case .finishing:
            ProgressView().tint(.white)
        case .failed:
            PrimaryButton(title: ObjectCaptureCopy.close, icon: "xmark") { onClose() }
        }
    }

    private var sizingPanel: some View {
        VStack(spacing: 10) {
            Text(ObjectCaptureCopy.sizingTips)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            sizeSlider(ObjectCaptureCopy.width, value: session.box.size.x) { session.setSize(width: $0) }
            sizeSlider(ObjectCaptureCopy.height, value: session.box.size.y) { session.setSize(height: $0) }
            sizeSlider(ObjectCaptureCopy.depth, value: session.box.size.z) { session.setSize(depth: $0) }
            HStack(spacing: 12) {
                Button { session.rotate(byRadians: -.pi / 36) } label: { Image(systemName: "rotate.left") }
                    .accessibilityLabel("상자 왼쪽으로 돌리기")
                Button { session.rotate(byRadians: .pi / 36) } label: { Image(systemName: "rotate.right") }
                    .accessibilityLabel("상자 오른쪽으로 돌리기")
                Spacer()
                Button(ObjectCaptureCopy.placeAgain) { session.placeAgain() }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            PrimaryButton(title: ObjectCaptureCopy.beginCapture, icon: "camera") { session.beginCapture() }
        }
        .padding(14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func sizeSlider(_ label: String, value: Float, set: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 36, alignment: .leading)
            Slider(
                value: Binding(get: { Double(value) }, set: { set(Float($0)) }),
                in: Double(ObjectCaptureConfig.minSide)...Double(ObjectCaptureConfig.maxSide)
            )
            Text("\(Int((value * 100).rounded()))cm")
                .font(.subheadline.monospacedDigit())
                .frame(minWidth: 52, alignment: .trailing)
        }
        .foregroundStyle(.white)
    }

    private var capturingPanel: some View {
        HStack(alignment: .center, spacing: 16) {
            ObjectOrbitRingsView(counts: session.coverageCounts, currentAzimuthDeg: session.currentAzimuthDeg)
                .frame(width: 96, height: 96)
                .accessibilityLabel(ringsAccessibility)
            VStack(alignment: .leading, spacing: 6) {
                Text(ObjectCaptureCopy.photos(session.savedPhotos))
                    .font(.headline.monospacedDigit())
                ForEach(Array(ObjectCaptureCopy.bands.enumerated()), id: \.offset) { i, name in
                    Text("\(name) \(Int(((session.bandFill.objectCaptureElement(at: i) ?? 0) * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                }
            }
            .foregroundStyle(.white)
            Spacer(minLength: 0)
            Button {
                Task {
                    if let s = await session.finish() { summary = s }
                }
            } label: {
                Text(ObjectCaptureCopy.finish)
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(GonggiColors.accentTeal, in: Capsule())
                    .foregroundStyle(.white)
            }
            .disabled(session.savedPhotos < 2)
        }
        .padding(14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var ringsAccessibility: String {
        zip(ObjectCaptureCopy.bands, session.bandFill)
            .map { "\($0) \(Int(($1 * 100).rounded()))퍼센트" }
            .joined(separator: ", ")
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ObjectCaptureCopy.title)
                .font(.title2.weight(.bold))
            ForEach(ObjectCaptureCopy.introLines, id: \.self) { line in
                Label(line, systemImage: "checkmark.circle")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            PrimaryButton(title: ObjectCaptureCopy.start, icon: "arrow.right") { showIntro = false }
            Button(ObjectCaptureCopy.close) {
                showIntro = false
                onClose()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(24)
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
        // Placed box: one finger on the box drags it along the floor (empty screen does nothing), two fingers turn it.
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
            guard let session, session.stage == .placing, let view = g.view else { return }
            session.place(at: g.location(in: view))
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
