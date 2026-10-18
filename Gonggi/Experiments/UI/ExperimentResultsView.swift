import SwiftUI

/// ④ 실험 결과: 실행 이력, 요약, 내보내기
struct ExperimentResultsView: View {
    @StateObject private var vm = ExperimentResultsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if vm.runs.isEmpty {
                    ExpCard {
                        Text(vm.loading ? "불러오는 중…" : "아직 실행한 검사가 없어요. 실험 메뉴에서 검사를 실행하면 여기에 쌓여요.")
                            .font(.subheadline).foregroundStyle(GonggiColors.textSecondary)
                    }
                } else {
                    let shareAll = vm.runs.prefix(20).flatMap { [$0.jsonlURL, $0.summaryURL] }
                        .filter { FileManager.default.fileExists(atPath: $0.path) }
                    ShareLink(items: shareAll) {
                        Label("최근 \(min(20, vm.runs.count))건 모두 공유", systemImage: "square.and.arrow.up.on.square")
                            .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(GonggiColors.accentTeal)
                    ForEach(vm.runs) { run in
                        NavigationLink(value: run) { row(run) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
        .background(GonggiAmbientBackground())
        .navigationTitle("실험 결과")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ExperimentRunInfo.self) { ExperimentRunDetailView(run: $0) }
        .onAppear { vm.reload() }
    }

    private func row(_ run: ExperimentRunInfo) -> some View {
        ExpCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.title).font(.headline).foregroundStyle(GonggiColors.textPrimary)
                    Text(Self.dateText(run.startedAt) + " · " + run.machine + " · 앱 " + run.appVersion)
                        .font(.footnote).foregroundStyle(GonggiColors.textSecondary)
                    Text("\(run.sizeBytes / 1024) KB")
                        .font(.footnote).foregroundStyle(GonggiColors.textTertiary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(GonggiColors.textTertiary)
            }
        }
    }

    static func dateText(_ d: Date?) -> String {
        guard let d else { return "시각 미상" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 HH:mm:ss"
        return f.string(from: d)
    }
}

struct ExperimentRunDetailView: View {
    let run: ExperimentRunInfo
    @State private var summary: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ExpCard("실행 정보") {
                    ExpMetricRow(title: "검사", value: run.title)
                    ExpMetricRow(title: "시작", value: ExperimentResultsView.dateText(run.startedAt))
                    ExpMetricRow(title: "기기", value: run.machine)
                    ExpMetricRow(title: "앱 버전(빌드)", value: run.appVersion)
                    ExpMetricRow(title: "JSONL 크기", value: "\(run.sizeBytes / 1024) KB")
                }
                ExpSummaryCard(text: summary ?? "불러오는 중…", shareItems: ExperimentRunStore.shareItems(for: run))
            }
            .padding(20)
        }
        .background(GonggiAmbientBackground())
        .navigationTitle(run.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            summary = await Task.detached(priority: .utility) { ExperimentRunStore.summaryText(for: run) }.value
        }
    }
}
