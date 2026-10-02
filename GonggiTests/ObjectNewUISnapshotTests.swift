import SwiftUI
import UIKit
import XCTest
@testable import Gonggi

/// Renders the REAL new panels (ObjectSizingPanel, ObjectCapturingPanel, ObjectCaptureIntroView) in an iOS Simulator window,
/// driven by a real ObjectCaptureSession that has not been started (no ARKit). The camera area is a plain placeholder and
/// each image says so: these are NOT device captures and show wording, layout and states only.
/// Images are attached to the test result and, with TEST_RUNNER_GONGGI_SNAPSHOT_DIR set, written to that directory.
@MainActor
final class ObjectNewUISnapshotTests: XCTestCase {
    private let note = "합성 화면(실기기 캡처 아님): 실제 패널 코드, 카메라 영역은 단색"

    private func cube() -> [CGPoint] {
        var out: [CGPoint] = []
        let center = CGPoint(x: 195, y: 250)
        for sx in [-1.0, 1.0] {
            for sy in [-1.0, 1.0] {
                for sz in [-1.0, 1.0] {
                    out.append(CGPoint(x: center.x + CGFloat(sx) * 70 + CGFloat(sz) * 24, y: center.y - CGFloat(sy) * 85 - CGFloat(sz) * 16))
                }
            }
        }
        return out
    }

    private struct Backdrop<Content: View>: View {
        let top: String
        let caption: String
        let highlight: Bool
        var ring: [CGPoint]? = nil
        var marker: CGPoint? = nil
        var note: String? = nil
        var helper: String? = nil
        var readout: String? = nil
        let panel: Content

        var body: some View {
            ZStack {
                LinearGradient(colors: [Color(white: 0.28), Color(white: 0.52)], startPoint: .top, endPoint: .bottom)
                ObjectFootprintOverlay(ring: ring, marker: marker, highlight: highlight)
                VStack(spacing: 10) {
                    if !top.isEmpty {
                        Text(top)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let note {
                        Text(note).font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                            .padding(10).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let helper {
                        Text(helper).font(.caption).foregroundStyle(.white.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                    panel
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                if let readout { ObjectDiagnosticsChip(text: readout) }
            }
        }
    }

    /// Real UIKit hosting (Slider / Toggle / DisclosureGroup need it; ImageRenderer cannot draw them).
    private func save(_ name: String, _ view: some View, size: CGSize = CGSize(width: 390, height: 844)) throws {
        let host = UIHostingController(rootView: view.frame(width: size.width, height: size.height))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true) }
        guard let data = image.pngData() else {
            XCTFail("could not render \(name)")
            return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["GONGGI_SNAPSHOT_DIR"], !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        window.isHidden = true
    }

    private func session(loose: Bool) -> ObjectCaptureSession {
        let s = ObjectCaptureSession()
        s.setLooseBox(loose)
        return s
    }

    func testRenderNewScreens() throws {
        // leave the persisted switch at its default for the other tests
        defer { UserDefaults.standard.removeObject(forKey: ObjectCaptureConfig.looseBoxDefaultsKey) }
        let box = ObjectCaptureBox(baseCenter: [0, 0, -1], size: [0.45, 0.5, 0.4], yawRadians: 0)

        try save("10_시작화면_3D자산_만들기", ObjectCaptureIntroView(onStart: {}, onClose: {}).background(Color(.systemBackground)))

        let off = session(loose: false)
        off.debugPresent(stage: .sizing, box: box)
        try save("11_크기패널_기본_스위치꺼짐_TF89기본", Backdrop(
            top: ObjectCaptureCopy.sizingHint, caption: "TF89 기본(스위치 꺼짐): 크기 슬라이더 1개 + 자세히 조절(접힘) — " + note,
            highlight: false, panel: ObjectSizingPanel(session: off)))

        try save("12_크기패널_자세히조절_펼침_스위치", Backdrop(
            top: ObjectCaptureCopy.sizingHint, caption: "자세히 조절을 펼친 모습: 가로·높이·깊이·회전과 넉넉한 박스 스위치(내부 테스트) — " + note,
            highlight: false, panel: ObjectSizingPanel(session: off, startExpanded: true)))

        let on = session(loose: true)
        on.debugPresent(stage: .sizing, box: box)
        try save("13_크기패널_스위치켜짐_넉넉한박스", Backdrop(
            top: ObjectCaptureCopy.sizingHintLoose, caption: "스위치를 켠 경우의 안내 문구 — " + note,
            highlight: false, panel: ObjectSizingPanel(session: on)))

        let cap = session(loose: false)
        cap.debugPresent(stage: .capturing, box: box, filledAzimuthBins: [20, 14, 3], guidance: .walkAround(towardLeft: true))
        try save("14_촬영중_저장사진기준_진행", Backdrop(
            top: ObjectCaptureGuidance.walkAround(towardLeft: true).text,
            caption: "촬영 중: 저장된 사진 기준 진행 표시와 한 문장 안내, 초록 상자 설명 — " + note,
            highlight: true, panel: ObjectCapturingPanel(session: cap, onFinish: {})))

        let ellipse: [CGPoint] = (0..<48).map { i in
            let a = Double(i) / 48 * 2 * .pi
            return CGPoint(x: 195 + 120 * cos(a), y: 430 + 48 * sin(a))
        }
        let first = session(loose: false)
        first.debugPresent(stage: .placing)
        try save("20_위치잡기_1_물체_가운데를_누르기", Backdrop(
            top: ObjectCaptureCopy.tapObjectHint, caption: "위치 잡기 1단계: 물체 자체를 누른다(바닥이 아님) — " + note,
            highlight: false, panel: ObjectLocatingPanel(session: first)))
        let second = session(loose: false)
        second.debugPresent(stage: .secondTap, walkProgress: 0.6, locatingNote: "조금 더 옆으로 이동한 뒤 눌러 주세요 (지금 21° / 35° 이상)",
                            marker: CGPoint(x: 195, y: 360))
        try save("21_위치잡기_2_옆으로_이동_후_다시_누르기", Backdrop(
            top: ObjectCaptureCopy.secondTapHint, caption: "위치 잡기 2단계: 이동 각도 표시와 거절 안내, 첫 번째 탭 위치 — " + note,
            highlight: false, marker: CGPoint(x: 195, y: 360), panel: ObjectLocatingPanel(session: second)))
        let ready = session(loose: false)
        ready.debugPresent(stage: .sizing, box: box)
        try save("22_준비됨_원_하나만_보임", Backdrop(
            top: ObjectCaptureCopy.readyHint, caption: "위치가 잡힌 뒤: 바닥 원(상자 아님)과 크기 슬라이더 — " + note,
            highlight: false, ring: ellipse, panel: ObjectSizingPanel(session: ready)))

        let weak = session(loose: false)
        weak.debugPresent(stage: .sizing, box: box, trackingNote: ObjectTrackingGate.recoveryText(.insufficientFeatures)?.line,
                          trackingHelper: ObjectTrackingGate.recoveryText(.insufficientFeatures)?.helper)
        try save("23_추적불안정_회복안내_배치_보류", Backdrop(
            top: ObjectCaptureCopy.readyHint, caption: "추적이 약할 때: 배치와 사진 저장을 잠시 멈추고 회복 안내. 무늬 있는 물건은 보조 안내일 뿐 — " + note,
            highlight: false, ring: ellipse, note: ObjectTrackingGate.recoveryText(.insufficientFeatures)?.line,
            helper: ObjectTrackingGate.recoveryText(.insufficientFeatures)?.helper, panel: ObjectSizingPanel(session: weak)))
        let diag = session(loose: false)
        diag.debugPresent(stage: .sizing, box: box)
        try save("24_위치유지_진단표시", Backdrop(
            top: ObjectCaptureCopy.readyHint, caption: "한 바퀴 돌아온 뒤의 진단 표시 예(숫자는 예시) — " + note,
            highlight: false, ring: ellipse,
            readout: "추적 normal 42초 · 지도 extending\n앵커 이동 0.0 mm · 걸은 거리 6.8 m\n바닥 높이 차 +0.3 cm\n한 바퀴 확인: 가이드-물체 화면 어긋남 3.1 px (0.09°) · 카메라 위치 차 11 cm · 앵커 이동 0.0 mm",
            panel: ObjectSizingPanel(session: diag)))

        // The finish review is a system confirmation dialog (not drawable here); show its real text.
        var coverage = ObjectOrbitCoverage()
        for bin in 0..<ObjectCaptureConfig.azimuthBinCount {
            coverage.record(.init(band: 0, azimuthBin: bin)); coverage.record(.init(band: 0, azimuthBin: bin))
            coverage.record(.init(band: 1, azimuthBin: bin)); coverage.record(.init(band: 1, azimuthBin: bin))
        }
        let review = ObjectCoverageReview.make(coverage: coverage, savedPhotos: 96)
        let reviewView = VStack(alignment: .leading, spacing: 12) {
            Text(ObjectCaptureCopy.reviewTitle).font(.headline)
            Text(review.message)
            HStack { Text(ObjectCaptureCopy.reviewMore).bold(); Spacer(); Text(ObjectCaptureCopy.reviewAsIs) }
            Text("(시스템 확인창의 문구와 버튼 이름. 확인창 자체는 시뮬레이터에서 그려지지 않아 글자만 보여 줍니다)").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
        .padding(24)
        try save("15_마침_부족한방향_안내_문구", reviewView.frame(maxHeight: .infinity).background(Color(.systemBackground)))
    }
}
