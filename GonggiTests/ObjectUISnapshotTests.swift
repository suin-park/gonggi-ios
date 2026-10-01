import SwiftUI
import UIKit
import XCTest
@testable import Gonggi

/// Synthetic renders of the product-capture guidance UI: the real box overlay view and the real copy over a plain
/// placeholder backdrop. These are NOT device captures — the AR camera and real plane detection do not exist in the
/// simulator — and each image says so. They show wording and colour states, nothing about tracking or accuracy.
///
/// With `TEST_RUNNER_GONGGI_SNAPSHOT_DIR=<dir>` the PNGs are also written to that host directory; they are always
/// attached to the test result.
@MainActor
final class ObjectUISnapshotTests: XCTestCase {
    /// Corners in `ObjectCaptureBox.corners` order (sx, sy, sz each -1 then +1), drawn as a simple oblique cube.
    private func cube(center: CGPoint, half: CGSize, depth: CGSize) -> [CGPoint] {
        var out: [CGPoint] = []
        for sx in [-1.0, 1.0] {
            for sy in [-1.0, 1.0] {
                for sz in [-1.0, 1.0] {
                    out.append(CGPoint(
                        x: center.x + CGFloat(sx) * half.width + CGFloat(sz) * depth.width,
                        y: center.y - CGFloat(sy) * half.height - CGFloat(sz) * depth.height
                    ))
                }
            }
        }
        return out
    }

    private struct Mock: View {
        let topText: String
        let corners: [CGPoint]?
        let highlight: Bool
        let caption: String

        var body: some View {
            ZStack {
                LinearGradient(colors: [Color(white: 0.28), Color(white: 0.52)], startPoint: .top, endPoint: .bottom)
                ObjectBoxOverlay(corners: corners, highlight: highlight)
                VStack(alignment: .leading, spacing: 8) {
                    if !topText.isEmpty {
                        Text(topText)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    Spacer()
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func save(_ name: String, _ mock: Mock) throws {
        let renderer = ImageRenderer(content: mock.frame(width: 390, height: 640))
        renderer.scale = 2
        guard let image = renderer.uiImage, let data = image.pngData() else {
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
    }

    private let note = "합성 화면(실기기 캡처 아님): 실제 상자 오버레이와 문구, 단색 배경"

    func testRenderGuidanceStates() throws {
        let inside = cube(center: CGPoint(x: 195, y: 330), half: CGSize(width: 70, height: 85), depth: CGSize(width: 24, height: 16))
        let clippedTop = cube(center: CGPoint(x: 195, y: 190), half: CGSize(width: 70, height: 85), depth: CGSize(width: 24, height: 16))
        let rightEdge = cube(center: CGPoint(x: 350, y: 330), half: CGSize(width: 70, height: 85), depth: CGSize(width: 24, height: 16))

        try save("01_자동배치후_기본문구", Mock(
            topText: ObjectCaptureCopy.sizingHint, corners: inside, highlight: false,
            caption: "자동 배치 직후 (사용자가 위치와 크기를 맞추는 단계) — " + note
        ))
        try save("02_수동배치_안내", Mock(
            topText: ObjectCaptureCopy.manualPlacementHint, corners: nil, highlight: false,
            caption: "자동 배치가 안 될 때 (상자 없음) — " + note
        ))
        try save("03_촬영가능_상자전체보임", Mock(
            topText: ObjectCaptureGuidance.walkAround(towardLeft: true).text, corners: inside, highlight: true,
            caption: "촬영 가능 색(상자 전체가 화면 안) — " + note
        ))
        try save("04_제품이_잘림", Mock(
            topText: ObjectCaptureGuidance.productCutOff.text, corners: rightEdge, highlight: false,
            caption: "제품이 화면 가장자리에 닿음: 촬영 가능 색이 아님 — " + note
        ))
        try save("05_상자일부_화면밖_예시", Mock(
            topText: ObjectCaptureGuidance.walkAround(towardLeft: true).text, corners: clippedTop, highlight: true,
            caption: "예시: 제품 판정이 연결된 경우에만 나타나는 상태 (검증 통과 전에는 연결하지 않음) — " + note
        ))
    }
}
