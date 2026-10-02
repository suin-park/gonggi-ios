import ARKit
import RealityKit
import SwiftUI

enum ObjectCaptureCopy {
    static let title = "3D 자산 만들기"
    static let introLines = [
        ObjectCaptureSubject.stillObject.startLine,
        "물체는 그대로 두고, 휴대폰을 들고 천천히 주위를 걸어요",
        "벽에 붙은 물체는 조금 떼어 놓아 주세요",
        "바닥과 주변이 함께 찍혀도 괜찮아요. 결과에서는 물체만 남겨요",
    ]
    /// Shown under the lines above, in a different style: what is NOT supported in this version.
    static let unsupportedLine = ObjectCaptureSubject.person.startLine
    static let start = "시작"
    /// After the box is placed (automatically or by tap). The box is a guide the user fits; it does not know the product.
    static let sizingHint = "상자가 물체를 넉넉하게 감싸도록 위치와 크기를 맞춰 주세요."
    /// Loose box switched on (internal test): the box only has to roughly surround the object.
    static let sizingHintLoose = "상자가 물체를 대략 감싸면 돼요. 정확히 맞추지 않아도 괜찮아요."
    /// Default placing: tap the support surface under the product (floor / table).
    static let manualPlacementHint = "물체 아래의 바닥이나 테이블을 눌러 상자를 놓아 주세요."
    /// The worker keeps only what is inside the box, so a tight box cuts the product off.
    static let sizingTips = "상자가 물체를 감싸도록 맞추세요. 크기는 슬라이더로, 위치는 상자를 끌어 옮기세요"
    /// Capture-screen footnote: green means a good place to take photos, not that the whole object is verified in frame.
    static let captureNote = "초록 상자는 촬영하기 좋은 위치예요. 물체가 화면 밖으로 잘리지 않는지 직접 확인해 주세요"
    /// Optional auxiliary locating: tap the object itself from two places.
    static let tapObjectHint = "물체의 가운데를 눌러 주세요"
    static let secondTapHint = "옆으로 두세 걸음 이동한 뒤, 물체 가운데를 한 번 더 눌러 주세요"
    static let readyHint = "상자가 물체를 감싸면 돼요. 손가락으로 옮기고 크기를 맞춰 주세요"
    static let walkProgress = "이동한 각도"
    static let showDiagnostics = "위치 유지 진단 표시"
    static let twoTapInstead = "물체를 두 번 눌러 놓기 (보조)"
    static let floorTapInstead = "바닥을 눌러 직접 놓기"
    static let showCube = "상자 보이기"
    static let shareTrace = "위치 진단 기록 공유"
    static let uniformSize = "크기"
    static let advanced = "자세히 조절"
    static let advancedTips = "길쭉한 물체는 가로·높이·깊이를 따로 맞추세요. 높이는 물체 맨 위보다 조금 높게 잡아 주세요"
    static let looseToggle = "넉넉한 박스 방식 (내부 테스트)"
    static let looseToggleNote = "끄면 지금까지의 방식 그대로예요. 켜는 것은 새 3D 처리 서버가 준비된 뒤에 해 주세요"
    static let reviewTitle = "아직 부족한 방향이 있어요"
    static let reviewMore = "더 찍기"
    static let reviewAsIs = "그대로 3D 자산 만들기"
    static let width = "가로"
    static let height = "높이"
    static let depth = "깊이"
    static let placeAgain = "다시 놓기"
    static let beginCapture = "촬영 시작"
    static let finish = "마침"
    static let finishing = "사진을 정리하고 있어요"
    static let close = "닫기"
    static let bands = ["낮게", "중간", "높게"]
    static let rangeHoldResume = "상자가 맞아요, 이어서"
    static let rangeHoldRefit = "상자 다시 맞추기"
    static let rangeHoldRestart = "처음부터"

    static func photos(_ n: Int) -> String { "사진 \(n)장" }

    static func defaultName(date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 HH:mm"
        return "3D 자산 \(f.string(from: date))"
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
                    appState.gaussianLibraryBanner = "3D 자산 생성을 시작했어요."
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
            if showsStatusChip {
                VStack(alignment: .leading, spacing: 4) {
                    if !topText.isEmpty {
                        Text(topText)
                            .font(.headline)
                    }
                    if let note = session.locatingNote, session.trackingNote == nil {
                        Text(note)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    if let note = session.rangeHoldNote {
                        Text(note)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    } else if let note = session.trackingNote {
                        Text(note)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    if let helper = session.trackingHelper, session.trackingNote != nil {
                        Text(helper)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
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

    /// Status chip: placement touch hint XOR tracking/range recovery — never both at once (D3).
    private var showsStatusChip: Bool {
        !topText.isEmpty
            || (session.locatingNote != nil && session.trackingNote == nil)
            || session.trackingNote != nil
            || session.trackingHelper != nil
            || session.rangeHoldNote != nil
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
                    if let s = await session.finish() { summary = s }
                }
            }
        case .finishing:
            ProgressView().tint(.white)
        case .failed:
            PrimaryButton(title: ObjectCaptureCopy.close, icon: "xmark") { onClose() }
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
                            .accessibilityLabel("상자 왼쪽으로 돌리기")
                        Button { session.rotate(byRadians: .pi / 36) } label: { Image(systemName: "rotate.right") }
                            .accessibilityLabel("상자 오른쪽으로 돌리기")
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
                Text(ObjectCaptureCopy.captureNote)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
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
            Button(ObjectCaptureCopy.rangeHoldResume) { session.resumeCaptureAfterRangeCheck() }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(GonggiColors.accentTeal, in: Capsule())
                .foregroundStyle(.white)
            Button(ObjectCaptureCopy.rangeHoldRefit) { session.refitRangeAfterDiscontinuity() }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
            Button(ObjectCaptureCopy.rangeHoldRestart) { session.placeAgain() }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var capturingControls: some View {
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
                guard session.requestFinish() else { return }
                onFinish()
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
        .padding(14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
