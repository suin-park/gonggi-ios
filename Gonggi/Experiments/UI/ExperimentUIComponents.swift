import SwiftUI
import AVFoundation
import ARKit

enum ExpTheme {
    static let ok = Color(red: 0.45, green: 0.85, blue: 0.62)
    static let warn = Color(red: 1.0, green: 0.74, blue: 0.35)
    static let bad = Color(red: 1.0, green: 0.50, blue: 0.45)
}

enum ExpRunState: Equatable {
    case idle, starting, running, stopping, finished

    var isBusy: Bool { self == .starting || self == .running || self == .stopping }
}

/// 둥근 카드. 제목 아래에 내용을 쌓는다.
struct ExpCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(GonggiColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GonggiColors.surfaceElevated)
        .overlay(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous).stroke(GonggiColors.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }
}

/// 이름 : 값 한 줄.
struct ExpMetricRow: View {
    let title: String
    let value: String
    var tone: Color = GonggiColors.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(GonggiColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(tone)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ExpStageRow: View {
    let stage: ExpDepthStage
    let state: ExpStageState

    private var tone: Color {
        switch state {
        case .yes: return ExpTheme.ok
        case .no: return ExpTheme.bad
        case .unknown: return ExpTheme.warn
        case .notRun: return GonggiColors.textTertiary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(tone).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(stage.title).font(.subheadline).foregroundStyle(GonggiColors.textPrimary)
            Spacer(minLength: 8)
            Text(state.label).font(.subheadline.weight(.semibold)).foregroundStyle(tone)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 시작 / 중지 버튼과 실행 시간 선택.
struct ExpRunControls: View {
    let state: ExpRunState
    @Binding var duration: Double
    var durations: [Double] = [30, 60, 120, 300]
    var showDuration = true
    var startTitle = "시작"
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if showDuration {
                Picker("실행 시간", selection: $duration) {
                    ForEach(durations, id: \.self) { Text($0 >= 60 ? "\(Int($0 / 60))분" : "\(Int($0))초").tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(state.isBusy)
            }
            Button(action: state.isBusy ? onStop : onStart) {
                Text(state == .stopping ? "정리하는 중…" : (state.isBusy ? "중지" : (state == .finished ? "다시 시작" : startTitle)))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(state.isBusy ? GonggiColors.textPrimary : GonggiColors.textOnAccent)
                    .background(
                        RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                            .fill(state.isBusy ? Color.white.opacity(0.14) : GonggiColors.accentTeal)
                    )
            }
            .disabled(state == .stopping)
            .accessibilityLabel(state.isBusy ? "중지" : startTitle)
        }
    }
}

/// 검사가 끝난 뒤 요약과 내보내기.
struct ExpSummaryCard: View {
    let text: String
    let shareItems: [URL]

    var body: some View {
        ExpCard("검사 요약") {
            Text(text)
                .font(.footnote.monospaced())
                .foregroundStyle(GonggiColors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !shareItems.isEmpty {
                ShareLink(items: shareItems) {
                    Label("결과 공유 (JSONL + 요약)", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(GonggiColors.accentTeal)
            }
        }
    }
}

func expFormat(_ v: Double?, _ digits: Int = 1, suffix: String = "") -> String {
    guard let v else { return "—" }
    return String(format: "%.\(digits)f", v) + suffix
}

// MARK: - 미리보기

/// AVFoundation 카메라 미리보기. 출력을 추가하지 않고 같은 세션을 비춘다.
struct ExpCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: ()) {
        uiView.previewLayer.session = nil
    }
}

/// ARKit 카메라 미리보기. 세션은 `ExperimentARRunner`가 소유한다.
struct ExpARPreview: UIViewRepresentable {
    let runner: ExperimentARRunner

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.session = runner.session
        v.automaticallyUpdatesLighting = false
        v.autoenablesDefaultLighting = false
        v.backgroundColor = .black
        // 뷰가 세션에 붙으면서 delegate를 건드렸을 가능성에 대비해 러너를 다시 지정한다.
        runner.reassertDelegate()
        return v
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        runner.reassertDelegate()
    }
}
