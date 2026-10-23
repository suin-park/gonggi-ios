import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 기록하기 › 실험 › 제품 Bm 보기. 저장한 제품 결과(지도 + 재생 기록 사진)를 목록으로 보여 주고, 열면 Bm(사진 혼합)과 순수 3DGS를 같은 카메라로 비교한다.
struct BmHomeView: View {
    @State private var items: [GSOStore.Item] = []
    @State private var importing = false
    @State private var importMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                KmoPageTitle(text: "제품 Bm 보기")
                ExpCard {
                    Text("저장한 제품 결과의 사진 여러 장을 지도 깊이로 다시 투영해 섞는 보기(기존 Bm), 외곽 형태로 윤곽을 고정한 V4, 지도를 그대로 그린 3DGS를 같은 카메라로 비교해요.")
                        .font(.subheadline).foregroundStyle(GonggiColors.textPrimary)
                    Text("제품 촬영 화면에서 '연구 기록'을 켜고, '새 방식: 텍스처 스플랫 레이어'를 끈 채로 촬영·저장한 결과에서만 볼 수 있어요. 처음 열 때 한 번 준비하고, 준비 결과는 기기에 저장돼 다음부터는 바로 열려요.")
                        .font(.footnote).foregroundStyle(GonggiColors.textSecondary)
                }
                ExpCard("저장한 제품 결과") {
                    if items.isEmpty {
                        Text("저장한 제품 결과가 없어요. 실험 › 실시간 제품 3DGS에서 촬영·저장하거나 아래에서 파일을 가져오세요.")
                            .font(.footnote).foregroundStyle(GonggiColors.textSecondary)
                    }
                    ForEach(items) { it in
                        NavigationLink {
                            BmViewerView(item: it)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.url.lastPathComponent).font(.subheadline).foregroundStyle(GonggiColors.textPrimary)
                                Text(rowDetail(it)).font(.caption).foregroundStyle(GonggiColors.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                        }
                    }
                }
                ExpCard("파일 가져오기") {
                    Text("다른 곳에서 받은 저장본(.kmogs)과 재생 자료(.kmoreplay)를 함께 선택하세요. 파일 이름이 같은 묶음이어야 해요.")
                        .font(.footnote).foregroundStyle(GonggiColors.textSecondary)
                    Button { importing = true } label: {
                        Label("저장본 파일 가져오기", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    if let m = importMessage { Text(m).font(.footnote).foregroundStyle(GonggiColors.textSecondary) }
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(GonggiAmbientBackground())
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { items = ProductGSStore.list() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                importMessage = "가져오는 중… (파일이 크면 시간이 걸려요)"
                Task.detached(priority: .userInitiated) {
                    var msg: String
                    do {
                        let n = try BmStore.importFiles(urls)
                        msg = "\(n)개 파일을 가져왔어요."
                    } catch { msg = "가져오기 실패: \(error.localizedDescription)" }
                    let text = msg
                    await MainActor.run {
                        importMessage = text
                        items = ProductGSStore.list()
                    }
                }
            case .failure(let e): importMessage = "가져오기 취소 또는 실패: \(e.localizedDescription)"
            }
        }
    }

    private func rowDetail(_ it: GSOStore.Item) -> String {
        var s = "\(it.bytes / 1024) KB"
        if let d = it.date { s += " · " + ExperimentResultsView.dateText(d) }
        s += it.replayURL != nil ? " · 재생 자료 있음(Bm 가능)" : " · 재생 자료 없음(3DGS만)"
        let cb = BmCache.size(for: it)
        if cb > 0 { s += " · 준비 결과 저장됨(\(cb / 1_048_576) MB)" } else if FileManager.default.fileExists(atPath: BmStore.stateURL(for: it).path) { s += " · 사진 맞춤 일부 저장됨" }
        return s
    }
}

/// 한 저장 결과를 여는 화면.
struct BmViewerView: View {
    @StateObject private var session: BmSession
    @State private var showInfo = false
    @Environment(\.displayScale) private var displayScale

    init(item: GSOStore.Item) { _session = StateObject(wrappedValue: BmSession(item: item)) }

    var body: some View {
        // 이미지와 보기 전환은 스크롤 밖에 고정한다(이미지 위 제스처가 스크롤과 겹치지 않게).
        VStack(spacing: 10) {
            canvas.padding(.horizontal, 16).padding(.top, 8)
            modePicker.padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let n = session.notice { Text(n).font(.footnote).foregroundStyle(ExpTheme.warn) }
                    if session.phase == .ready { coverageCard }
                    controls
                    statusCard
                    diagnosticsCard
                    shareCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .background(GonggiAmbientBackground())
        .navigationTitle(session.item.url.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { session.open() }
        .onDisappear { session.close() }
    }

    @ViewBuilder private var canvas: some View {
        ZStack {
            BmCanvas(image: session.image,
                     onOrbit: { dx, dy in session.rotate(dx: dx, dy: dy) },
                     onPan: { dx, dy in session.pan(dx: dx, dy: dy) },
                     onPinch: { s in session.pinch(scale: s) },
                     onActive: { a in session.gestureChanged(active: a) },
                     onDoubleTap: { session.resetView() })
                .disabled(session.phase != .ready)
            switch session.phase {
            case .loading(let p):
                VStack(spacing: 10) {
                    Text("\(p.title) · \(p.percent)%").font(.headline).foregroundStyle(.white)
                    ProgressView(value: Double(p.percent), total: 100).tint(GonggiColors.accentTeal).frame(maxWidth: 240)
                    Text(p.stage).font(.footnote).foregroundStyle(.white.opacity(0.85))
                    Button("취소") { session.cancelLoading() }.buttonStyle(.bordered).tint(.white)
                }
                .padding(16).background(Color.black.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 12))
            case .failed(let msg):
                VStack(spacing: 10) {
                    Text(msg).font(.footnote).foregroundStyle(.white).multilineTextAlignment(.center)
                    Button("다시 시도") { session.retry() }.buttonStyle(.bordered).tint(.white)
                }
                .padding(16).background(Color.black.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 12)).padding(16)
            case .idle:
                ProgressView().tint(.white)
            case .ready:
                EmptyView()
            }
            if session.phase == .ready {
                VStack {
                    HStack {
                        Text(session.mode.label).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.black.opacity(0.55)).foregroundStyle(.white).clipShape(Capsule())
                        Spacer()
                        if session.limitToObserved {
                            Text("회전 제한 켜짐").font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.black.opacity(0.55)).foregroundStyle(.white).clipShape(Capsule())
                        }
                    }
                    Spacer()
                    if let w = session.coverageWarning {
                        Text(w).font(.caption2).multilineTextAlignment(.leading).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.orange.opacity(0.85)).foregroundStyle(.black).clipShape(RoundedRectangle(cornerRadius: 6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(GeometryReader { g in
            // 출력 해상도 = 이 칸의 물리 화소 폭(화면에서 늘이지 않는다).
            Color.black
                .onAppear { session.setViewport(widthPx: Int(g.size.width * displayScale)) }
                .onChange(of: g.size.width) { _, w in session.setViewport(widthPx: Int(w * displayScale)) }
        })
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("보기", selection: $session.mode) {
                ForEach(BmSession.Mode.allCases) { m in Text(m.short).tag(m) }
            }
            .pickerStyle(.segmented)
            .disabled(session.phase != .ready)
            Text("한 손가락: 회전 · 두 손가락: 이동 · 핀치: 확대 · 두 번 탭: 처음 시점 · 모드를 바꿔도 카메라는 그대로예요. 반반은 왼쪽 기존 Bm, 오른쪽 V4예요.")
                .font(.caption).foregroundStyle(GonggiColors.textSecondary)
            if session.phase == .ready && !session.v4Available && session.bmAvailable {
                Text("이 결과는 V4 외곽이 없어 V4·반반을 고를 수 없어요.").font(.caption).foregroundStyle(ExpTheme.warn)
            }
        }
    }

    private var controls: some View {
        ExpCard("카메라") {
            VStack(alignment: .leading, spacing: 4) {
                Text("거리 (왼쪽 접근 ↔ 오른쪽 후퇴)").font(.caption).foregroundStyle(GonggiColors.textSecondary)
                Slider(value: Binding(get: { session.orbit.distScale }, set: { session.setDistance($0) }), in: BmOrbit.distRange)
                Text("확대 (오른쪽이 더 크게)").font(.caption).foregroundStyle(GonggiColors.textSecondary)
                Slider(value: Binding(get: { session.orbit.zoom }, set: { session.setZoom($0) }), in: BmOrbit.zoomRange)
            }
            .disabled(session.phase != .ready)
            Toggle("고품질(느림, 내부 3배 격자)", isOn: $session.highQuality).font(.subheadline).disabled(session.phase != .ready || !session.bmAvailable)
            Toggle("관측 범위 안에서만 회전(촬영한 높이로 제한)", isOn: $session.limitToObserved).font(.subheadline).disabled(session.phase != .ready || !session.bmAvailable)
            Button { session.resetView() } label: { Label("처음 시점으로", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity, minHeight: 40) }
                .disabled(session.phase != .ready)
        }
    }

    private var statusCard: some View {
        ExpCard("측정") {
            if let s = session.firstScreenSeconds {
                Text(String(format: "열기 → 첫 화면: %.1f초 (이 기기에서 잰 값)", s)).font(.subheadline).foregroundStyle(GonggiColors.textPrimary)
            } else {
                Text("첫 화면까지 측정 중…").font(.subheadline).foregroundStyle(GonggiColors.textSecondary)
            }
            if !session.lastFrameInfo.isEmpty { Text(session.lastFrameInfo).font(.caption.monospaced()).foregroundStyle(GonggiColors.textSecondary) }
            Text("Bm은 지도 깊이로 사진을 다시 투영해 섞어요. V4는 사진 마스크로 깎은 외곽 형태로 윤곽을 고정하고, 윤곽 안인데 사진 색이 닿지 않은 곳은 가까운 색으로 채워요(채운 화소 비율이 위 줄에 나와요). V4는 PC 시험에서 귀 같은 가는 돌출이 깎이거나 오목한 곳이 채워지는 경우가 있었어요. 형태·외곽선·글자·겹침을 기존 Bm과 같은 시점에서 직접 비교해 주세요.")
                .font(.caption).foregroundStyle(GonggiColors.textSecondary)
        }
    }

    private var coverageCard: some View {
        ExpCard("촬영 관측") {
            if session.coverageText.isEmpty {
                Text("이 결과는 사진 관측 정보가 없어요.").font(.caption).foregroundStyle(GonggiColors.textSecondary)
            } else {
                Text(session.coverageText).font(.caption.monospaced()).foregroundStyle(GonggiColors.textPrimary)
                Text("찍지 않은 높이·방향은 사진에 없는 면이라 실제와 다르게 보일 수 있어요. 회전 제한을 켜면 촬영한 높이 범위 안에서만 돌아가요(자유 회전 품질이 해결된 것은 아니에요).")
                    .font(.caption).foregroundStyle(GonggiColors.textSecondary)
            }
        }
    }

    private var diagnosticsCard: some View {
        ExpCard("상세 진단") {
            if session.phase == .ready {
                Text(session.openedFromCache ? "저장된 준비 결과로 열었어요(원본 사진을 다시 준비하지 않음)." : "이번에 처음 준비했어요. 다음부터는 저장된 결과로 열려요.")
                    .font(.caption).foregroundStyle(GonggiColors.textPrimary)
            }
            ForEach(session.diagnostics, id: \.self) { d in Text(d).font(.caption.monospaced()).foregroundStyle(GonggiColors.textSecondary) }
            Button { session.rebuild() } label: { Label("준비 결과 지우고 다시 준비", systemImage: "arrow.clockwise").frame(maxWidth: .infinity, minHeight: 40) }
                .disabled(session.phase != .ready || !session.bmAvailable)
        }
    }

    private var shareCard: some View {
        ExpCard("진단 저장·공유") {
            Text("현재 화면(PNG)과 측정 로그(첫 화면 시간, 단계별 시간, 프레임 시간, 메모리, 열 상태, 설정)를 저장해요. 사진·지도 내용은 로그에 들어가지 않아요.")
                .font(.footnote).foregroundStyle(GonggiColors.textSecondary)
            Button { session.saveScreenshot() } label: { Label("현재 화면과 측정 로그 저장", systemImage: "camera.viewfinder").frame(maxWidth: .infinity, minHeight: 44) }
                .disabled(session.image == nil)
            if !session.shareURLs.isEmpty {
                ShareLink(items: session.shareURLs) { Label("공유 (\(session.shareURLs.count)개 파일)", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44) }
            }
        }
    }
}

/// 이미지 + 제스처(한 손가락 회전, 두 손가락 이동, 핀치 확대, 두 번 탭 초기화).
struct BmCanvas: UIViewRepresentable {
    var image: CGImage?
    var onOrbit: (CGFloat, CGFloat) -> Void
    var onPan: (CGFloat, CGFloat) -> Void
    var onPinch: (CGFloat) -> Void
    var onActive: (Bool) -> Void
    var onDoubleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.backgroundColor = .black
        iv.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(iv)
        NSLayoutConstraint.activate([iv.leadingAnchor.constraint(equalTo: v.leadingAnchor), iv.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                                     iv.topAnchor.constraint(equalTo: v.topAnchor), iv.bottomAnchor.constraint(equalTo: v.bottomAnchor)])
        context.coordinator.imageView = iv
        let one = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleOrbit(_:)))
        one.minimumNumberOfTouches = 1; one.maximumNumberOfTouches = 1
        let two = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        two.minimumNumberOfTouches = 2; two.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDouble(_:)))
        tap.numberOfTapsRequired = 2
        for g in [one, two, pinch, tap] as [UIGestureRecognizer] { g.delegate = context.coordinator; v.addGestureRecognizer(g) }
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        context.coordinator.parent = self
        if let img = image { context.coordinator.imageView?.image = UIImage(cgImage: img) }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: BmCanvas
        weak var imageView: UIImageView?
        private var active = 0
        init(_ p: BmCanvas) { parent = p }

        private func track(_ g: UIGestureRecognizer) {
            switch g.state {
            case .began: if active == 0 { parent.onActive(true) }; active += 1
            case .ended, .cancelled, .failed: active = max(0, active - 1); if active == 0 { parent.onActive(false) }
            default: break
            }
        }

        @objc func handleOrbit(_ g: UIPanGestureRecognizer) {
            track(g)
            let t = g.translation(in: g.view)
            if g.state == .changed { parent.onOrbit(t.x, t.y); g.setTranslation(.zero, in: g.view) }
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            track(g)
            let t = g.translation(in: g.view)
            if g.state == .changed { parent.onPan(t.x, t.y); g.setTranslation(.zero, in: g.view) }
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            track(g)
            if g.state == .changed { parent.onPinch(g.scale); g.scale = 1 }
        }

        @objc func handleDouble(_ g: UITapGestureRecognizer) { if g.state == .ended { parent.onDoubleTap() } }

        func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
            (a is UIPanGestureRecognizer && b is UIPinchGestureRecognizer) || (a is UIPinchGestureRecognizer && b is UIPanGestureRecognizer)
        }
    }
}
