import SwiftUI

/// 실험 절차 안내. 앱 안 화면과 docs/SENSOR_EXPERIMENT_GUIDE.md가 같은 순서를 따른다.
enum ExperimentGuideText {
    struct Step: Identifiable {
        let id: Int
        let title: String
        let body: String
    }

    static let steps: [Step] = [
        Step(id: 1, title: "기본 센서 검사 60초",
             body: "실험 › 기본 센서 검사. 옵션은 모두 끄고 60초 실행해요. 같은 장소에서 ‘센서 부하 비교’(옵션을 20초씩 하나씩 켜는 자동 5단계)도 한 번 실행해요. 정지해서 한 번, 천천히 걸으며 한 번."),
        Step(id: 2, title: "후면 깊이 검사 60초",
             body: "실험 › 후면 깊이 검사. 화면 위쪽의 단계 표시를 먼저 확인해요(장치 발견 → 사진용 깊이 → 포맷 → 연결 → 실제 콜백). ‘자동’ 포맷으로 60초 실행해요."),
        Step(id: 3, title: "0.5·1·2·3m 표적 비교",
             body: "벽에 무늬 있는 종이(A4 이상)를 붙이고, 후면 카메라 렌즈에서 종이 표면까지의 수직 거리(카메라가 바라보는 방향의 거리)를 줄자로 0.5·1·2·3m로 재요. 종이를 화면 가운데에 정면으로 두고 ‘표적 기록’의 해당 거리 버튼을 눌러요. 화면 가운데 4칸 값을 기록하며, 가장자리는 쓰지 않아요."),
        Step(id: 4, title: "무늬 있는 면 · 흰 벽 · 물체 경계 비교",
             body: "같은 거리(1m 권장)에서 ① 무늬 있는 면 ② 아무 무늬 없는 흰 벽 ③ 물체와 배경 경계(의자 다리 같은 얇은 물체 포함)를 각각 20초 이상 비춰요. 요약의 ‘유효 깊이 픽셀 비율’은 값이 채워진 비율일 뿐 정확도가 아니에요."),
        Step(id: 5, title: "정지와 천천히 이동 비교",
             body: "후면 깊이 검사를 정지 상태 30초, 천천히 걷거나 팔을 움직이는 상태 30초로 나눠 실행해요. 두 결과의 빈도, 드롭, 열 상태를 비교해요."),
        Step(id: 6, title: "공존 검사 실행",
             body: "실험 › 카메라 공존 검사. ① ARKit 단독 ② 후면 깊이 단독 ③ ARKit → 후면 깊이 ④ 후면 깊이 → ARKit 순서로 각각 직접 시작해요. 단독 검사를 먼저 해야 ③④에서 단독 대비 저하를 비교할 수 있어요. 공존 성공과 동기화 성공은 따로 표시돼요."),
        Step(id: 7, title: "기존 기록 기능으로 복귀 확인",
             body: "실험 화면을 닫고 기록하기에서 360 공간 또는 3D 자산 촬영을 시작해 카메라와 추적이 정상인지 확인해요. 문제가 있으면 앱을 완전히 종료한 뒤 다시 시도하고, 그 사실을 알려 주세요."),
        Step(id: 8, title: "결과 공유",
             body: "각 검사가 끝나면 ‘결과 공유’를 눌러 JSONL과 요약을 보내요. 지난 결과는 실험 › 실험 결과에서 다시 공유할 수 있어요. 서버로 자동 업로드하지 않아요.")
    ]

    static let distanceNote = """
    거리 기준: 후면 카메라 렌즈에서 표적 표면까지 카메라가 바라보는 방향으로 잰 거리(camera-Z)예요. \
    렌즈에서 점까지 직선 거리(range)와는 화면 가장자리에서 달라요. 그래서 화면 가운데만 비교해요. \
    듀얼 와이드의 깊이는 disparity(상대 역깊이)로 올 수 있어 ‘원값’과 ‘변환값’을 따로 기록해요. \
    변환값이 있어도 accuracy가 relative면 절대 거리 정확도는 보장되지 않아요.
    """
}

struct ExperimentGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("실험 절차")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(GonggiColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("iPhone 14 Plus에서 순서대로 따라 해 주세요. 이 도구는 센서를 검증하는 용도예요. 3D 생성이나 학습은 하지 않아요.")
                    .font(.subheadline)
                    .foregroundStyle(GonggiColors.textSecondary)
                ForEach(ExperimentGuideText.steps) { step in
                    ExpCard("\(step.id). \(step.title)") {
                        Text(step.body)
                            .font(.subheadline)
                            .foregroundStyle(GonggiColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ExpCard("거리 비교 기준") {
                    Text(ExperimentGuideText.distanceNote)
                        .font(.subheadline)
                        .foregroundStyle(GonggiColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
        .background(GonggiAmbientBackground())
        .navigationTitle("실험 절차")
        .navigationBarTitleDisplayMode(.inline)
    }
}
