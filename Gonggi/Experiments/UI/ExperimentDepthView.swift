import SwiftUI

/// ② 후면 깊이 검사
struct ExperimentDepthView: View {
    @StateObject private var vm = ExperimentDepthViewModel()
    @Environment(\.scenePhase) private var scenePhase

    private var stages: [ExpDepthStage: ExpStageState] {
        var s: [ExpDepthStage: ExpStageState] = [:]
        for st in ExpDepthStage.allCases { s[st] = .notRun }
        if let d = vm.discovery {
            s[.deviceFound] = d.dualWideFound ? .yes : .no
            s[.photoDepth] = d.photoDepth
            s[.streamFormats] = d.dualWideFound ? (d.formatsPresent ? .yes : .no) : .notRun
        }
        if vm.state.isBusy || vm.state == .finished {
            for (k, v) in vm.live.stages where v != .notRun { s[k] = v }
        }
        return s
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                stageCard
                if vm.state.isBusy || vm.state == .finished || vm.previewSession != nil { previewCard }
                settingsCard
                ExpRunControls(state: vm.state, duration: $vm.duration,
                               onStart: { vm.start() }, onStop: { vm.requestStop(.userStopped) })
                if !vm.message.isEmpty { Text(vm.message).font(.footnote).foregroundStyle(ExpTheme.warn) }
                if vm.state.isBusy || vm.state == .finished { liveCard }
                if vm.state == .running { targetCard }
                if let s = vm.summaryText { ExpSummaryCard(text: s, shareItems: vm.shareItems) }
            }
            .padding(20)
        }
        .background(GonggiAmbientBackground())
        .navigationTitle("후면 깊이 검사")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.discover() }
        .onDisappear { vm.requestStop(.userStopped) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { vm.requestStop(.backgrounded) }   // inactive(권한 창·공유 시트)에서는 멈추지 않는다
        }
    }

    private var stageCard: some View {
        ExpCard("단계별 상태") {
            ForEach(ExpDepthStage.allCases, id: \.self) { st in
                ExpStageRow(stage: st, state: stages[st] ?? .notRun)
            }
            Text("앞 단계가 ‘예’여도 다음 단계의 증거가 아니에요. 마지막 ‘실제 깊이 콜백 수신’만 연속 깊이가 실제로 들어왔다는 뜻이에요.")
                .font(.footnote).foregroundStyle(GonggiColors.textTertiary)
            if let d = vm.discovery, !d.note.isEmpty {
                Text(d.note).font(.footnote).foregroundStyle(ExpTheme.warn)
            }
            if !vm.state.isBusy {
                Button { vm.discover() } label: {
                    Text(vm.discovering ? "확인 중…" : "장치·포맷 다시 확인").font(.subheadline.weight(.semibold))
                }
                .disabled(vm.discovering)
            }
        }
    }

    private var previewCard: some View {
        ExpCard("미리보기") {
            if let session = vm.previewSession {
                ExpCameraPreview(session: session)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("영상 미리보기")
            }
            if let img = vm.live.preview {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("깊이 색상 미리보기")
                HStack(spacing: 6) {
                    Text("낮은 값").font(.caption)
                    LinearGradient(colors: [.blue, .cyan, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing)
                        .frame(height: 8).clipShape(Capsule())
                    Text("높은 값").font(.caption)
                }
                .foregroundStyle(GonggiColors.textSecondary)
                Text("색은 프레임마다 값 범위(5~95%)를 늘려 입힌 상대 표시예요. 거리 눈금이 아니에요. 회색은 값이 없는 픽셀이에요. 영상·깊이는 센서 방향 그대로라 옆으로 누워 보일 수 있어요.")
                    .font(.footnote).foregroundStyle(GonggiColors.textTertiary)
            } else if vm.state == .running {
                Text("깊이 프레임을 기다리는 중…").font(.subheadline).foregroundStyle(GonggiColors.textSecondary)
            }
        }
    }

    private var settingsCard: some View {
        ExpCard("검사 구성") {
            if let d = vm.discovery, !d.choices.isEmpty {
                Picker("포맷", selection: $vm.choiceId) {
                    Text("자동 (1920 이하 중 가장 큰 영상 + 가장 큰 깊이)").tag("auto")
                    ForEach(d.choices) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.menu)
                .disabled(vm.isBusy)
            } else {
                Text("선택할 수 있는 영상·깊이 포맷이 아직 없어요.").font(.footnote).foregroundStyle(GonggiColors.textTertiary)
            }
            Toggle("깊이 필터링 (노이즈 평활·빈 값 채움)", isOn: $vm.filtering).disabled(vm.isBusy)
            Toggle("깊이 색상 미리보기 (약 5Hz)", isOn: $vm.previewDepth).disabled(vm.isBusy)
            Toggle("분석용 샘플 저장 (최대 10장 · 12MB)", isOn: $vm.saveSamples).disabled(vm.isBusy)
            Text(vm.saveSamples ? "켜면 영상(JPEG)·깊이(float32)가 기기 안에 저장돼요. 공유는 직접 선택할 때만 돼요." : "기본은 숫자 로그만 저장해요. 영상·깊이 이미지는 저장하지 않아요.")
                .font(.footnote).foregroundStyle(GonggiColors.textTertiary)
        }
    }

    private var liveCard: some View {
        let l = vm.live
        return ExpCard("실시간 값") {
            ExpMetricRow(title: "경과", value: expFormat(l.elapsed, 0, suffix: " 초"))
            ExpMetricRow(title: "영상 해상도 / 실제 FPS", value: "\(l.videoSize.map { "\($0[0])×\($0[1])" } ?? "—") / \(expFormat(l.videoHz, 1))")
            ExpMetricRow(title: "깊이 해상도 / 실제 FPS", value: "\(l.depthSize.map { "\($0[0])×\($0[1])" } ?? "—") / \(expFormat(l.depthHz, 1))")
            ExpMetricRow(title: "수신 프레임 (영상 / 깊이)", value: "\(l.videoFrames) / \(l.depthFrames)")
            ExpMetricRow(title: "드롭 (영상 / 깊이)", value: "\(l.videoDrops) / \(l.depthDrops)", tone: (l.videoDrops + l.depthDrops) > 0 ? ExpTheme.warn : GonggiColors.textPrimary)
            ExpMetricRow(title: "유효 깊이 픽셀 비율 (값이 채워진 비율, 정확도 아님)", value: l.validRatio.map { expFormat($0 * 100, 0, suffix: "%") } ?? "—")
            ExpMetricRow(title: "깊이 형식", value: l.depthKind ?? "—")
            ExpMetricRow(title: "accuracy / quality", value: "\(l.accuracy ?? "—") / \(l.quality ?? "—")",
                         tone: l.accuracy == "absolute" ? ExpTheme.ok : (l.accuracy == nil ? GonggiColors.textPrimary : ExpTheme.warn))
            ExpMetricRow(title: "필터링됨", value: l.filtered.map { $0 ? "예" : "아니오" } ?? "—")
            ExpMetricRow(title: "calibration 제공", value: l.calibrationPresent.map { $0 ? "예" : "아니오" } ?? "—")
            ExpMetricRow(title: "영상·깊이가 한 묶음으로 온 비율", value: l.pairFraction.map { expFormat($0 * 100, 0, suffix: "%") } ?? "—")
            ExpMetricRow(title: "묶음 안 시간차 p50 / p95", value: "\(expFormat(l.offsetP50Ms, 1)) / \(expFormat(l.offsetP95Ms, 1)) ms")
            ExpMetricRow(title: "화면 가운데 값 (원값 / 변환값)", value: "\(l.centerNative.map { String(format: "%.4f", $0) } ?? "—") / \(l.centerConverted.map { String(format: "%.3f", $0) } ?? "—")")
            ExpMetricRow(title: "중단·오류", value: "\(l.eventCount)건", tone: l.eventCount > 0 ? ExpTheme.bad : GonggiColors.textPrimary)
            if !l.message.isEmpty { Text(l.message).font(.footnote).foregroundStyle(ExpTheme.warn) }
        }
    }

    private var targetCard: some View {
        ExpCard("거리를 아는 표적 기록") {
            Text("종이를 화면 가운데 정면에 두고, 렌즈에서 표면까지 줄자로 잰 거리와 같은 버튼을 눌러요. 최근 몇 장의 가운데 값을 기록해요.")
                .font(.footnote).foregroundStyle(GonggiColors.textSecondary)
            HStack(spacing: 8) {
                ForEach([0.5, 1.0, 2.0, 3.0], id: \.self) { m in
                    Button { vm.recordTarget(m) } label: {
                        Text(m == 0.5 ? "0.5m" : "\(Int(m))m").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(GonggiColors.accentTeal)
                }
            }
            if !vm.targetMessage.isEmpty { Text(vm.targetMessage).font(.footnote).foregroundStyle(GonggiColors.textPrimary) }
        }
    }
}
