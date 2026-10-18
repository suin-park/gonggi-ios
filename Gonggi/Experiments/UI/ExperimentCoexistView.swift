import SwiftUI

/// ③ 카메라 공존 검사
struct ExperimentCoexistView: View {
    @StateObject private var vm = ExperimentCoexistViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ExpCard {
                    Text("ARKit과 후면 깊이 스트림이 같은 카메라를 함께 쓸 수 있는지 시간 순서대로 측정해요. 의도적으로 두 소스를 동시에 여는 유일한 검사예요. 아래 네 검사를 직접 하나씩 시작해 주세요.")
                        .font(.subheadline).foregroundStyle(GonggiColors.textSecondary)
                    Text("‘공존 성공’은 두 스트림이 구간 안에서 실제로 계속 들어왔다는 뜻이고, RGB·깊이·포즈가 정확히 맞는지(동기화)는 따로 판정해요.")
                        .font(.footnote).foregroundStyle(GonggiColors.textTertiary)
                }
                ExpCard("검사 시작") {
                    Picker("단독 검사 시간", selection: $vm.soloSeconds) {
                        Text("20초").tag(20.0); Text("30초").tag(30.0); Text("60초").tag(60.0)
                    }
                    .pickerStyle(.segmented)
                    .disabled(vm.isBusy)
                    ForEach(ExpCoexistTest.allCases) { test in
                        Button { vm.start(test) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(test.title).font(.headline).foregroundStyle(GonggiColors.textPrimary)
                                Text(test.detail).font(.footnote).foregroundStyle(GonggiColors.textSecondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        }
                        .disabled(vm.isBusy)
                        .accessibilityElement(children: .combine)
                    }
                    if vm.isBusy {
                        Button(role: .destructive) { vm.requestStop(.userStopped) } label: {
                            Text(vm.state == .stopping ? "정리하는 중…" : "중지").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(vm.state == .stopping)
                    }
                }
                if !vm.message.isEmpty { Text(vm.message).font(.footnote).foregroundStyle(ExpTheme.warn) }
                if vm.isBusy, let p = vm.progress { progressCard(p) }
                if let s = vm.summaryText { ExpSummaryCard(text: s, shareItems: vm.shareItems) }
            }
            .padding(20)
        }
        .background(GonggiAmbientBackground())
        .navigationTitle("카메라 공존 검사")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { vm.requestStop(.userStopped) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { vm.requestStop(.backgrounded) }   // inactive(권한 창·공유 시트)에서는 멈추지 않는다
        }
    }

    private func progressCard(_ p: ExpCoexistProgress) -> some View {
        ExpCard("진행 중: \(vm.current?.title ?? "")") {
            ExpMetricRow(title: "구간", value: p.phase)
            ExpMetricRow(title: "구간 경과 / 전체 경과", value: "\(expFormat(p.phaseElapsed, 0)) / \(expFormat(p.totalElapsed, 0)) 초")
            ExpMetricRow(title: "ARKit 수신 (최근 2초)", value: expFormat(p.arHz, 1, suffix: " Hz"))
            ExpMetricRow(title: "후면 영상 수신", value: expFormat(p.videoHz, 1, suffix: " Hz"))
            ExpMetricRow(title: "후면 깊이 수신", value: expFormat(p.depthHz, 1, suffix: " Hz"))
            ExpMetricRow(title: "중단·오류", value: "\(p.events)건", tone: p.events > 0 ? ExpTheme.bad : GonggiColors.textPrimary)
        }
    }
}
