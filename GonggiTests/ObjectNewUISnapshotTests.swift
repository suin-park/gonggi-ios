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
        let panel: Content

        var body: some View {
            ZStack {
                LinearGradient(colors: [Color(white: 0.28), Color(white: 0.52)], startPoint: .top, endPoint: .bottom)
                ObjectBoxOverlay(corners: nil, highlight: highlight)
                VStack(spacing: 10) {
                    if !top.isEmpty {
                        Text(top)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
