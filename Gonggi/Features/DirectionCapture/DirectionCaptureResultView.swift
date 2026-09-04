import SwiftUI

/// Post-capture grid of the 10 named direction images (no AI / stitch).
struct DirectionCaptureResultView: View {
    let result: DirectionCaptureResult
    let onRetake: () -> Void
    let onDone: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(result.images, id: \.direction) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Image(uiImage: item.image)
                                .resizable()
                                .scaledToFill()
                                .frame(minHeight: 160)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            Text(item.direction.rawValue)
                                .font(GonggiTypography.caption(13))
                                .foregroundStyle(GonggiColors.textPrimary)
                        }
                    }
                }
                .padding(16)
            }
            .background(GonggiAmbientBackground())
            .navigationTitle("방향 캡처 결과")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    HStack(spacing: 12) {
                        Button("다시 촬영") {
                            GonggiHaptics.medium()
                            onRetake()
                        }
                        Spacer()
                        Button("완료") {
                            GonggiHaptics.medium()
                            onDone()
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
        }
    }
}
