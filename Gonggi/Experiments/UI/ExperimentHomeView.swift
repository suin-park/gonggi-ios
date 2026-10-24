import SwiftUI

/// 기록하기 › 실험. 센서 검증 도구의 첫 화면이다.
/// 이 화면은 전체 화면으로 열리며(기존 촬영 흐름과 같은 방식) 닫으면 기록하기로 돌아간다.
/// 카메라는 각 검사 화면이 하나씩 소유하고, 화면을 벗어나면 세션을 정리한다.
struct ExperimentHomeView: View {
    let onClose: () -> Void

    private enum Route: Hashable {
        case realtime, surfaceV2, gaussianOpt, productGS, productBm, smoothProduct, smoothSpace, sensor, depth, coexist, results, guide
    }

    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    KmoPageTitle(text: "실험")
                    ExpCard {
                        Text("이 기기의 센서를 직접 검사하는 도구예요. 3D 생성이나 학습은 하지 않아요.")
                            .font(.subheadline).foregroundStyle(GonggiColors.textPrimary)
                        Text("기본은 숫자·상태 로그만 이 기기에 저장해요. 서버로 자동 전송하지 않고, 결과는 공유 시트로 직접 보낼 때만 나가요.")
                            .font(.footnote).foregroundStyle(GonggiColors.textSecondary)
                        Text("검사하는 동안 카메라를 쓰고 기기가 따뜻해질 수 있어요. 기기가 많이 뜨거워지면 검사를 자동으로 끝내요.")
                            .font(.footnote).foregroundStyle(GonggiColors.textSecondary)
                    }
                    RecordSection(title: "실시간 제품 3DGS") {
                        RecordChoiceRow(choice: .init(title: "실시간 제품 3DGS (기기 내)", line: "고정된 제품을 휴대폰으로 비추며 가우시안을 만들고, 다른 시점에서 비출수록 디테일이 좋아져요. 서버 없음", icon: "cube")) { path.append(.productGS) }
                        divider
                        RecordChoiceRow(choice: .init(title: "제품 Bm 보기 (저장한 결과)", line: "저장한 제품 결과의 사진을 섞어 보는 Bm과 3DGS를 같은 카메라로 돌려 보며 비교해요. 서버 없음", icon: "photo.stack")) { path.append(.productBm) }
                        divider
                        RecordChoiceRow(choice: .init(title: "매끈한 표면 만들기 (저장한 제품)", line: "촬영 뒤 이 기기에서 털 뭉침 없는 매끈한 표면 3DGS를 만들고 걸린 시간을 기록해요. 서버 없음", icon: "circle.hexagongrid")) { path.append(.smoothProduct) }
                    }
                    RecordSection(title: "실시간 공간 생성") {
                        RecordChoiceRow(choice: .init(title: "가우시안 최적화 (기기 내)", line: "촬영 중 기기에서 가우시안을 실제로 최적화해요. 서버 없음", icon: "sparkles")) { path.append(.gaussianOpt) }
                        divider
                        RecordChoiceRow(choice: .init(title: "매끈한 표면 만들기 (저장한 공간)", line: "가우시안 최적화로 저장한 공간을 촬영 뒤 매끈한 표면 3DGS로 다시 만들고 걸린 시간을 기록해요. 서버 없음", icon: "circle.hexagongrid")) { path.append(.smoothSpace) }
                        divider
                        RecordChoiceRow(choice: .init(title: "실시간 공간 생성 V2", line: "서버·학습·모델 없이 표면을 만들고 원본 영상을 입혀 저장해요", icon: "square.3.layers.3d")) { path.append(.surfaceV2) }
                        divider
                        RecordChoiceRow(choice: .init(title: "실시간 공간 생성", line: "ARKit로 움직이며 가우시안 표면을 쌓고 둘러봐요 (비교용)", icon: "cube.transparent")) { path.append(.realtime) }
                    }
                    RecordSection(title: "센서 검사") {
                        RecordChoiceRow(choice: .init(title: "기본 센서 검사", line: "ARKit 추적, 노출, Core Motion과 기능별 부하 비교", icon: "gyroscope")) { path.append(.sensor) }
                        divider
                        RecordChoiceRow(choice: .init(title: "후면 깊이 검사", line: "듀얼 와이드 깊이가 실제로 들어오는지 확인해요", icon: "square.stack.3d.down.right")) { path.append(.depth) }
                        divider
                        RecordChoiceRow(choice: .init(title: "카메라 공존 검사", line: "ARKit과 후면 깊이를 함께 쓸 수 있는지 봐요", icon: "camera.on.rectangle")) { path.append(.coexist) }
                        divider
                        RecordChoiceRow(choice: .init(title: "실험 결과", line: "실행 이력을 보고 결과를 내보내요", icon: "doc.text.magnifyingglass")) { path.append(.results) }
                    }
                    RecordSection(title: "안내") {
                        RecordChoiceRow(choice: .init(title: "실험 절차", line: "순서대로 따라 하는 8단계와 거리 비교 방법", icon: "list.number")) { path.append(.guide) }
                    }
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .background(GonggiAmbientBackground())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onClose) { Label("닫기", systemImage: "xmark") }
                        .accessibilityLabel("실험 닫기")
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .realtime: RealtimeGSView()
                case .surfaceV2: RealtimeSurfaceV2View()
                case .gaussianOpt: GaussianOptView()
                case .productGS: ProductGSView()
                case .productBm: BmHomeView()
                case .smoothProduct: SGSHomeView(mode: .product)
                case .smoothSpace: SGSHomeView(mode: .space)
                case .sensor: ExperimentSensorView()
                case .depth: ExperimentDepthView()
                case .coexist: ExperimentCoexistView()
                case .results: ExperimentResultsView()
                case .guide: ExperimentGuideView()
                }
            }
        }
        .tint(GonggiColors.accentTeal)
    }

    private var divider: some View {
        Rectangle().fill(GonggiColors.borderSubtle).frame(height: 1).padding(.leading, 76)
    }
}
