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

    static var title: String { L("Capture") }
    static var productSection: String { L("3D Objects") }
    static var spaceSection: String { L("Space") }
    static let storeSection = StoreShelfCopy.sectionTitle

    static var photoTo3D: Choice { Choice(title: L("Make 3D from a photo"), line: L("Make a 3D shape from a single photo"),
                                  icon: "photo.on.rectangle.angled") }
    static var productCapture: Choice { Choice(title: L("Create a 3D Object"), line: L("Turn around an object that doesn't move"), icon: "rotate.3d") }

    static var space360: Choice { Choice(title: L("360 space"), line: L("Look around from one spot"),
                                 icon: "arrow.triangle.2.circlepath.circle") }
    static var walkableSpace: Choice { Choice(title: L("Walkable space"), line: L("Move around inside the space"), icon: "figure.walk") }

    static let recordShelf = Choice(title: StoreShelfCopy.recordTitle, line: StoreShelfCopy.recordLine,
                                    icon: "square.stack.3d.up")
    static let findProduct = Choice(title: StoreShelfCopy.findTitle, line: StoreShelfCopy.findLine,
                                    icon: "magnifyingglass")

    /// 실험 섹션(센서 검사). 빌드 설정 GONGGI_SENSOR_EXPERIMENTS가 켜진 빌드에서만 보인다.
    static var experimentSection: String { L("Experiments") }
    static var sensorExperiment: Choice { Choice(title: L("Sensor check"), line: L("Test this device's camera, rear depth and ARKit directly"),
                                         icon: "waveform.path.ecg") }

    static var photoAccepted: String { L("3D creation started. See the result in Library under 3D Objects.") }
    static var walkableUnavailable: String { L("Walkable spaces aren't available for this account yet.") }
    static var walkableUnknown: String { L("Can't check walkable spaces right now. Please try again in a moment.") }
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

/// 매장 section of the 기록 tab (under 3D 자산 and 공간): 매대 기록하기, for store managers only (the server says who
/// is one) and only behind the development flag. 제품 찾기 is a customer feature and lives on the Home tab.
enum RecordStoreOption: Equatable {
    case recordShelf
    case findProduct

    static func visible(menuVisible: Bool, isManager: Bool) -> [RecordStoreOption] {
        menuVisible && isManager ? [.recordShelf] : []
    }

    var choice: RecordHomeCopy.Choice {
        switch self {
        case .recordShelf: return RecordHomeCopy.recordShelf
        case .findProduct: return RecordHomeCopy.findProduct
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
    /// 매장 section; empty hides it (the default, so existing callers are unchanged).
    var storeOptions: [RecordStoreOption] = []
    var onStore: (RecordStoreOption) -> Void = { _ in }
    /// 실험 섹션; 꺼져 있으면 보이지 않는다(기본값이라 기존 호출은 그대로).
    var showExperiments = false
    var onExperiments: () -> Void = {}
    /// DEBUG screenshots: start scrolled to the last row (large-text check).
    var scrollToLastRow = false
    @ViewBuilder var footer: () -> Footer

    private static var lastRowId: String { "record-last-row" }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        KmoPageTitle(text: RecordHomeCopy.title)
                            .padding(.top, KmoLayout.topGap)
                        Spacer(minLength: 24).frame(maxHeight: 32)
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
                                    .id(index == spaceOptions.count - 1 && storeOptions.isEmpty && !showExperiments
                                        ? Self.lastRowId : "space-\(index)")
                            }
                        }
                        if !storeOptions.isEmpty {
                            Spacer(minLength: 32).frame(maxHeight: 48)
                            RecordSection(title: RecordHomeCopy.storeSection) {
                                ForEach(Array(storeOptions.enumerated()), id: \.offset) { index, option in
                                    if index > 0 { RecordRowDivider() }
                                    RecordChoiceRow(choice: option.choice) { onStore(option) }
                                        .id(index == storeOptions.count - 1 && !showExperiments ? Self.lastRowId : "store-\(index)")
                                }
                            }
                        }
                        if showExperiments {
                            Spacer(minLength: 32).frame(maxHeight: 48)
                            RecordSection(title: RecordHomeCopy.experimentSection) {
                                RecordChoiceRow(choice: RecordHomeCopy.sensorExperiment) { onExperiments() }
                                    .id(Self.lastRowId)
                            }
                        }
                        footer()
                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 20)
                    .frame(minHeight: geo.size.height, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
                // The last row must scroll clear of the tab bar and the home indicator.
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: GonggiSpacing.lg) }
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
