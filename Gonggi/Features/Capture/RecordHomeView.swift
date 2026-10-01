import SwiftUI

/// 기록 tab (rev. 3): one screen, two sections.
/// - 제품: 사진으로 3D 만들기, then (once built) 제품 3D 촬영 in the second position.
/// - 공간: 360 공간, then 걸어보는 공간.
/// Each row is a title plus one short line and is itself the button. Capture how-to and duration belong to each
/// flow's own start screen. No technology names.

enum RecordHomeCopy {
    struct Choice: Equatable {
        var title: String
        var line: String
        var icon: String
    }

    static let title = "기록"
    static let productSection = "3D 자산"
    static let spaceSection = "공간"

    static let photoTo3D = Choice(title: "사진으로 3D 만들기", line: "사진 한 장으로 입체 모습을 만들어요",
                                  icon: "photo.on.rectangle.angled")
    static let productCapture = Choice(title: "3D 자산 만들기", line: "움직이지 않는 물체를 돌려 보고 확대할 수 있어요", icon: "rotate.3d")

    static let space360 = Choice(title: "360 공간", line: "한 자리에서 주변을 둘러봐요",
                                 icon: "arrow.triangle.2.circlepath.circle")
    static let walkableSpace = Choice(title: "걸어보는 공간", line: "공간 안을 이동하며 볼 수 있어요", icon: "figure.walk")

    static let photoAccepted = "3D 생성을 시작했어요. 보관함의 3D 자산에서 결과를 볼 수 있어요."
    static let walkableUnavailable = "이 계정에서는 아직 걸어보는 공간을 사용할 수 없어요."
    static let walkableUnknown = "지금은 걸어보는 공간을 확인할 수 없어요. 잠시 후 다시 시도해 주세요."
}

enum RecordProductOption: Equatable {
    case photoTo3D
    case productCapture

    /// 사진으로 3D 만들기 first; 제품 3D 촬영 second, only once it is built.
    static func visible(productCaptureAvailable: Bool) -> [RecordProductOption] {
        productCaptureAvailable ? [.photoTo3D, .productCapture] : [.photoTo3D]
    }

    var choice: RecordHomeCopy.Choice {
        switch self {
        case .photoTo3D: return RecordHomeCopy.photoTo3D
        case .productCapture: return RecordHomeCopy.productCapture
        }
    }
}

enum RecordSpaceOption: Equatable {
    case space360
    case walkable

    /// 360 공간 first, 걸어보는 공간 second.
    static func visible(walkableVisible: Bool) -> [RecordSpaceOption] {
        walkableVisible ? [.space360, .walkable] : [.space360]
    }

    var choice: RecordHomeCopy.Choice {
        switch self {
        case .space360: return RecordHomeCopy.space360
        case .walkable: return RecordHomeCopy.walkableSpace
        }
    }
}

enum RecordHomePolicy {
    /// Product multi-view (3DGS) capture on the 기록 screen — always listed (사진으로 3D 만들기 다음).
    /// Pre-release: no DEBUG / internal-tools unlock gate. Success is still judged from a real product capture.
    static let productCaptureAvailable = true

    /// Product row: the feature is in this build AND the server said it runs the product path (endpoint configured).
    /// Unknown / a server without product support → hidden, so a production-address build is safe before the server
    /// is deployed. Mock mode shows it for screenshots.
    static func productCardVisible(featureOn: Bool, mockMode: Bool, serverAvailable: Bool?) -> Bool {
        guard featureOn else { return false }
        return mockMode || serverAvailable == true
    }

    /// Walkable space row: hidden only when the server said "not available" for this account. Unknown (first launch,
    /// offline) keeps it visible; a tap then re-checks before opening.
    static func walkableCardVisible(flagOn: Bool, mockMode: Bool, available: Bool?) -> Bool {
        guard flagOn else { return false }
        return mockMode || available != false
    }
}

// MARK: - Views

/// One selectable row: icon, title, one line. The whole row is the button.
struct RecordChoiceRow: View {
    let choice: RecordHomeCopy.Choice
    let action: () -> Void

    @ScaledMetric(relativeTo: .headline) private var iconSize: CGFloat = 44

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: choice.icon)
                    .font(.title3)
                    .foregroundStyle(GonggiColors.accentTeal)
                    .frame(width: iconSize, height: iconSize)
                    .background(Circle().fill(GonggiColors.accentTeal.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.title)
                        .font(.headline)
                        .foregroundStyle(GonggiColors.textPrimary)
                    Text(choice.line)
                        .font(.subheadline)
                        .foregroundStyle(GonggiColors.textSecondary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GonggiColors.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(choice.title). \(choice.line)")
        .accessibilityAddTraits(.isButton)
    }
}

/// A section title and its rows, grouped in one surface with dividers between rows.
struct RecordSection<Rows: View>: View {
    let title: String
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(GonggiColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                rows()
            }
            .background(GonggiColors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                    .stroke(GonggiColors.borderSubtle, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        }
    }
}

private struct RecordRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(GonggiColors.borderSubtle)
            .frame(height: 1)
            .padding(.leading, 76)
    }
}

/// 기록: 제품 section above 공간 section on one screen.
struct RecordHomeScreen<Footer: View>: View {
    let productOptions: [RecordProductOption]
    let spaceOptions: [RecordSpaceOption]
    let onProduct: (RecordProductOption) -> Void
    let onSpace: (RecordSpaceOption) -> Void
    /// DEBUG screenshots: start scrolled to the last row (large-text check).
    var scrollToLastRow = false
    @ViewBuilder var footer: () -> Footer

    private static var lastRowId: String { "record-last-row" }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(RecordHomeCopy.title)
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(GonggiColors.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.top, 16)
                        Spacer(minLength: 24).frame(maxHeight: 56)
                        RecordSection(title: RecordHomeCopy.productSection) {
                            ForEach(Array(productOptions.enumerated()), id: \.offset) { index, option in
                                if index > 0 { RecordRowDivider() }
                                RecordChoiceRow(choice: option.choice) { onProduct(option) }
                            }
                        }
                        Spacer(minLength: 32).frame(maxHeight: 48)
                        RecordSection(title: RecordHomeCopy.spaceSection) {
                            ForEach(Array(spaceOptions.enumerated()), id: \.offset) { index, option in
                                if index > 0 { RecordRowDivider() }
                                RecordChoiceRow(choice: option.choice) { onSpace(option) }
                                    .id(index == spaceOptions.count - 1 ? Self.lastRowId : "space-\(index)")
                            }
                        }
                        footer()
                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 20)
                    .frame(minHeight: geo.size.height, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onAppear {
                    guard scrollToLastRow else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        proxy.scrollTo(Self.lastRowId, anchor: .bottom)
                    }
                }
            }
        }
    }
}
