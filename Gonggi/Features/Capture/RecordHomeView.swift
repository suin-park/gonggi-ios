import SwiftUI

/// 기록 tab (rev. 2, after the build 83 TestFlight review): 기록 → 제품 / 공간 → method.
/// - 기록: two choices only (제품 above 공간), whole card tappable, title + one short line.
/// - 제품: 사진으로 3D 만들기, then (once built) 제품 3D 촬영 in the second slot.
/// - 공간: 360 공간 above 걸어보는 공간.
/// Capture how-to and duration belong to each flow's own start screen, not to these cards. No technology names.

enum RecordHomeCopy {
    struct Choice: Equatable {
        var title: String
        var line: String
        var icon: String
    }

    static let title = "기록"

    static let product = Choice(title: "제품", line: "물건을 입체로 만들어요", icon: "cube")
    static let space = Choice(title: "공간", line: "방과 장소를 기록해요", icon: "square.split.bottomrightquarter")

    static let photoTo3D = Choice(title: "사진으로 3D 만들기", line: "사진 한 장으로 입체 모습을 만들어요",
                                  icon: "photo.on.rectangle.angled")
    /// Not built yet (future 3DGS product capture) — never shown while `RecordHomePolicy.productCaptureAvailable` is off.
    static let productCapture = Choice(title: "제품 3D 촬영", line: "제품을 돌려 보고 확대할 수 있어요", icon: "rotate.3d")

    static let space360 = Choice(title: "360 공간", line: "한 자리에서 주변을 둘러봐요",
                                 icon: "arrow.triangle.2.circlepath.circle")
    static let walkableSpace = Choice(title: "걸어보는 공간", line: "공간 안을 걸어 다니며 봐요", icon: "figure.walk")

    /// AI disclosure: first line of the photo source chooser (before a photo is picked), not card text.
    static let photoNotice = "사진에 없는 뒷면 같은 부분은 AI가 채워 만들어요."

    static let photoAccepted = "3D 생성을 시작했어요. 보관함의 3D 자산에서 결과를 볼 수 있어요."
    static let walkableUnavailable = "이 계정에서는 아직 걸어보는 공간을 사용할 수 없어요."
    static let walkableUnknown = "지금은 걸어보는 공간을 확인할 수 없어요. 잠시 후 다시 시도해 주세요."
}

enum RecordDestination: Hashable {
    case product
    case space
}

enum RecordProductOption: Equatable {
    case photoTo3D
    case productCapture

    /// Display order: 사진으로 3D 만들기 first; 제품 3D 촬영 second, only once it is built.
    static func visible(productCaptureAvailable: Bool) -> [RecordProductOption] {
        productCaptureAvailable ? [.photoTo3D, .productCapture] : [.photoTo3D]
    }
}

enum RecordSpaceOption: Equatable {
    case space360
    case walkable

    /// Display order: 360 공간 first, 걸어보는 공간 (3DGS) second.
    static func visible(walkableVisible: Bool) -> [RecordSpaceOption] {
        walkableVisible ? [.space360, .walkable] : [.space360]
    }
}

enum RecordHomePolicy {
    /// Product multi-view (3DGS) capture is not built: no card, no entry, nothing to tap.
    static let productCaptureAvailable = false

    /// Walkable space card: hidden only when the server said "not available" for this account. Unknown (first launch,
    /// offline) keeps it visible; a tap then re-checks before opening.
    static func walkableCardVisible(flagOn: Bool, mockMode: Bool, available: Bool?) -> Bool {
        guard flagOn else { return false }
        return mockMode || available != false
    }
}

// MARK: - Views

/// Whole-card choice: icon, title, one line; the card itself is the button. System text styles so large text wraps.
struct RecordChoiceRow: View {
    let choice: RecordHomeCopy.Choice
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: choice.icon)
                    .font(prominent ? .title : .title2)
                    .foregroundStyle(GonggiColors.accentTeal)
                    .frame(width: prominent ? 52 : 44, height: prominent ? 52 : 44)
                    .background(Circle().fill(GonggiColors.accentTeal.opacity(0.12)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(choice.title)
                        .font(prominent ? .title2.weight(.semibold) : .title3.weight(.semibold))
                        .foregroundStyle(GonggiColors.textPrimary)
                    Text(choice.line)
                        .font(.body)
                        .foregroundStyle(GonggiColors.textSecondary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, prominent ? 28 : 20)
            .frame(maxWidth: .infinity, minHeight: prominent ? 132 : 88, alignment: .leading)
            .background(GonggiColors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                    .stroke(GonggiColors.borderSubtle, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(choice.title). \(choice.line)")
        .accessibilityAddTraits(.isButton)
    }
}

/// 기록 home: 제품 above 공간.
struct RecordHomeScreen: View {
    let onOpen: (RecordDestination) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(RecordHomeCopy.title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(GonggiColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 24)
                    .padding(.bottom, 8)
                RecordChoiceRow(choice: RecordHomeCopy.product, prominent: true) { onOpen(.product) }
                RecordChoiceRow(choice: RecordHomeCopy.space, prominent: true) { onOpen(.space) }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// 제품: 사진으로 3D 만들기 (+ 제품 3D 촬영 in the second slot once built).
struct RecordProductScreen: View {
    let productCaptureAvailable: Bool
    let onPhotoTo3D: () -> Void
    var onProductCapture: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(RecordProductOption.visible(productCaptureAvailable: productCaptureAvailable), id: \.self) { option in
                    switch option {
                    case .photoTo3D:
                        RecordChoiceRow(choice: RecordHomeCopy.photoTo3D, action: onPhotoTo3D)
                    case .productCapture:
                        RecordChoiceRow(choice: RecordHomeCopy.productCapture, action: onProductCapture)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle(RecordHomeCopy.product.title)
        .navigationBarTitleDisplayMode(.large)
    }
}

/// 공간: 360 공간 above 걸어보는 공간.
struct RecordSpaceScreen<Footer: View>: View {
    let walkableVisible: Bool
    let onSpace360: () -> Void
    let onWalkable: () -> Void
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(RecordSpaceOption.visible(walkableVisible: walkableVisible), id: \.self) { option in
                    switch option {
                    case .space360:
                        RecordChoiceRow(choice: RecordHomeCopy.space360, action: onSpace360)
                    case .walkable:
                        RecordChoiceRow(choice: RecordHomeCopy.walkableSpace, action: onWalkable)
                    }
                }
                footer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle(RecordHomeCopy.space.title)
        .navigationBarTitleDisplayMode(.large)
    }
}
