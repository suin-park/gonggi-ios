import SwiftUI

/// ① 기본 센서 검사
struct ExperimentSensorView: View {
    @StateObject private var vm = ExperimentSensorViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                preview
                optionsCard
                ExpRunControls(state: vm.state, duration: $vm.duration, showDuration: !vm.compareMode,
                               onStart: { vm.start() }, onStop: { vm.requestStop(.userStopped) })
                if !vm.message.isEmpty {
                    Text(vm.message).font(.footnote).foregroundStyle(ExpTheme.warn)
                }
                if vm.state.isBusy || vm.state == .finished { liveCard }
                if let s = vm.summaryText { ExpSummaryCard(text: s, shareItems: vm.shareItems) }
            }
            .padding(20)
        }
        .background(GonggiAmbientBackground())
        .navigationTitle("기본 센서 검사")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { vm.requestStop(.userStopped) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { vm.requestStop(.backgrounded) }
        }
    }

    @ViewBuilder private var preview: some View {
        if let box = vm.session {
            ExpARPreview(session: box.runner.session)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
                .accessibilityLabel("카메라 미리보기")
        } else {
            ExpCard {
                Text("시작하면 카메라 미리보기와 센서 값이 나타나요. 파일은 저장하지 않고 숫자 로그만 남겨요.")
                    .font(.subheadline).foregroundStyle(GonggiColors.textSecondary)
            }
        }
    }

    private var optionsCard: some View {
        ExpCard("검사 구성") {
            Toggle("부하 비교 (옵션을 20초씩 하나씩 켜는 자동 단계)", isOn: $vm.compareMode)
                .disabled(vm.isBusy)
            if !vm.compareMode {
                Text("기본은 위치 추적만 켜요. 아래 기능을 켜고 부하를 비교해 보세요.")
                    .font(.footnote).foregroundStyle(GonggiColors.textTertiary)
                Toggle("평면 검출", isOn: $vm.optPlanes).disabled(vm.isBusy)
                Toggle("Core Motion", isOn: $vm.optMotion).disabled(vm.isBusy)
                Toggle("렌즈 상태 읽기 (ARKit 장치, 읽기만)", isOn: $vm.optLens).disabled(vm.isBusy)
                Toggle("사람 마스크·깊이 (사람 영역 전용)", isOn: $vm.optPersonDepth)
                    .disabled(vm.isBusy || !vm.supportsPersonDepth)
                if !vm.supportsPersonDepth {
                    Text("이 기기/OS에서는 사람 마스크·깊이를 쓸 수 없어요.").font(.footnote).foregroundStyle(GonggiColors.textTertiary)
                }
            }
            Text("ARKit sceneDepth(공간 깊이)는 LiDAR가 필요해요. \(vm.sceneDepthSupported ? "이 기기는 지원해요." : "이 기기는 지원하지 않아요. 후면 듀얼 와이드 깊이와는 별개예요.")")
                .font(.footnote).foregroundStyle(GonggiColors.textTertiary)
        }
    }

    private var liveCard: some View {
        let l = vm.live
        return ExpCard("실시간 값 (\(l.phase))") {
            ExpMetricRow(title: "경과", value: expFormat(l.elapsed, 0, suffix: " 초"))
            ExpMetricRow(title: "추적 상태", value: l.tracking, tone: l.tracking == "normal" ? ExpTheme.ok : ExpTheme.warn)
            ExpMetricRow(title: "위치 (m)", value: l.position.map { String(format: "%.2f, %.2f, %.2f", $0[0], $0[1], $0[2]) } ?? "—")
            ExpMetricRow(title: "방향 (도, pitch·yaw·roll)", value: l.eulerDeg.map { String(format: "%.0f, %.0f, %.0f", $0[0], $0[1], $0[2]) } ?? "—")
            ExpMetricRow(title: "영상 해상도", value: l.imageSize.map { "\($0[0])×\($0[1])" } ?? "—")
            ExpMetricRow(title: "실제 수신 FPS (최근 2초)", value: expFormat(l.fps, 1))
            ExpMetricRow(title: "수신 프레임", value: "\(l.frames)")
            ExpMetricRow(title: "희소 특징점", value: l.rawPoints.map { "\($0)" } ?? "—")
            ExpMetricRow(title: "검출 평면 (수평 / 수직)", value: "\(l.planesHorizontal) / \(l.planesVertical)")
            ExpMetricRow(title: "노출 시간", value: l.exposureDurationS.map { String(format: "%.4f 초", $0) } ?? "—")
            ExpMetricRow(title: "노출 오프셋", value: l.exposureOffset.map { String(format: "%.2f", $0) } ?? "—")
            ExpMetricRow(title: "조명 추정", value: l.lightIntensity.map { String(format: "%.0f lm / %.0f K", $0, l.lightTemperature ?? 0) } ?? "—")
            ExpMetricRow(title: "EXIF 항목", value: l.exifKeyCount > 0 ? "\(l.exifKeyCount)개" : "—")
            if !l.exifSummary.isEmpty {
                Text(l.exifSummary.joined(separator: "\n"))
                    .font(.footnote.monospaced()).foregroundStyle(GonggiColors.textSecondary)
            }
            ExpMetricRow(title: "Core Motion 수신", value: expFormat(l.motionHz, 0, suffix: " Hz"))
            if let lens = l.lens {
                ExpMetricRow(title: "렌즈 위치 / ISO", value: String(format: "%.3f / %.0f", lens.lensPosition, lens.iso))
                ExpMetricRow(title: "초점·노출 조정 중", value: "\(lens.isAdjustingFocus ? "초점" : "-") / \(lens.isAdjustingExposure ? "노출" : "-")")
                ExpMetricRow(title: "읽은 지 (프레임 시각 아님)", value: expFormat(l.lensAgeS, 1, suffix: " 초 전"))
            }
            ExpMetricRow(title: "사람 마스크·깊이 버퍼", value: l.personDepthSeen ? "수신됨" : "없음")
            ExpMetricRow(title: "콜백 처리 시간 p50", value: expFormat(l.cbMsP50, 2, suffix: " ms"))
            ExpMetricRow(title: "메모리", value: expFormat(l.footprintMB, 0, suffix: " MB"))
            ExpMetricRow(title: "열 상태", value: l.thermal, tone: (l.thermal == "nominal" || l.thermal == "fair") ? ExpTheme.ok : ExpTheme.bad)
            ExpMetricRow(title: "중단·오류", value: "\(l.eventCount)건")
        }
    }
}
