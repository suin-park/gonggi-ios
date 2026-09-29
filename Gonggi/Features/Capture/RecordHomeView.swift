import SwiftUI

/// 기록 tab home (`RECORD_TAB_PRODUCT_SPACE_IA_20260930.md`): 제품 / 공간 choices plus "이어서 할 일".
/// Cards describe what the viewer can do with the result and what the capture needs — no technology names.

enum RecordHomeCopy {
    static let title = "기록"
    static let subtitle = "무엇을 3D로 만들까요?"

    static let productSection = "제품"
    static let productSectionCaption = "물건 하나를 3D로 만들어요"
    static let spaceSection = "공간"
    static let spaceSectionCaption = "방이나 매장을 3D로 기록해요"

    struct Card: Equatable {
        var title: String
        var result: String
        var howTo: String
        var badge: String
        var action: String
    }

    static let photoTo3D = Card(
        title: "사진으로 3D 만들기",
        result: "사진으로 빠르게 입체 모습을 만들어요.",
        howTo: "사진 1장이면 돼요. 사진에 없는 뒷면 등은 AI가 채워 만들 수 있어요.",
        badge: "AI 생성 포함",
        action: "사진 고르기"
    )
    static let walkableSpace = Card(
        title: "걸어보는 공간",
        result: "받는 사람이 공간 안을 이동하며 볼 수 있어요.",
        howTo: "공간을 고르게 걸으며 촬영해요. 몇 분 걸려요.",
        badge: "걸어서 보기",
        action: "촬영 시작"
    )
    static let space360 = Card(
        title: "360 공간",
        result: "한 자리에서 주변을 둘러볼 수 있어요. 안쪽으로 걸어 다닐 수는 없어요.",
        howTo: "한 자리에서 휴대폰을 들고 한 바퀴 돌며 촬영해요.",
        badge: "빠른 기록",
        action: "촬영 시작"
    )
    /// Product multi-view capture (not built). Copy kept for when it ships: rotating is the viewer, walking is the capture.
    static let productCapture = Card(
        title: "제품 3D 촬영",
        result: "받는 사람이 제품을 돌리고 확대해 볼 수 있어요.",
        howTo: "제품은 그대로 두고, 휴대폰을 들고 제품 주위를 천천히 한 바퀴 걸으며 촬영해요.",
        badge: "실물 촬영",
        action: "촬영 시작"
    )

    static let resumeTitle = "이어서 할 일"
    static let resumeSeeAll = "보관함에서 모두 보기"
    static let photoAccepted = "3D 생성을 시작했어요 · 보관함 ‘3D 자산’에서 볼 수 있어요"
    static let walkableUnavailable = "이 계정에서는 아직 걸어보는 공간을 사용할 수 없어요."
    static let walkableUnknown = "지금은 걸어보는 공간을 확인할 수 없어요. 잠시 후 다시 시도해 주세요."
}

enum RecordHomePolicy {
    /// Product multi-view capture is not built: no card, no entry, nothing to tap (flip only when the flow exists).
    static let productCaptureAvailable = false

    /// Walkable space card: hidden only when the server said "not available" for this account. Unknown (first launch,
    /// offline) keeps it visible; a tap then re-checks before opening.
    static func walkableCardVisible(flagOn: Bool, mockMode: Bool, available: Bool?) -> Bool {
        guard flagOn else { return false }
        return mockMode || available != false
    }
}

/// Where a "이어서 할 일" row goes. Navigation only — a tap never sends an upload or a generation request.
enum RecordResumeRoute: Equatable {
    case spaces
    case assets
    case spaceDetail(libraryId: String)
}

struct RecordResumeItem: Identifiable, Equatable {
    enum Kind: Equatable { case unsentCapture, spaceNeedsRetry, assetNeedsRetry, spaceInProgress, assetInProgress }
    var id: String
    var kind: Kind
    var text: String
    var actionTitle: String
    var route: RecordResumeRoute
}

enum RecordResumeBuilder {
    static let limit = 3

    struct SpaceJob: Equatable {
        var spaceId: String
        var name: String
        var status: SpaceGenerationStatus
        var failureLabel: String
    }

    /// Items to show (at most `limit`) and how many more are waiting in the Library.
    static func items(spaceJobs: [SpaceJob], unsentCount: Int, assetActive: Int, assetFailed: Int) -> (items: [RecordResumeItem], more: Int) {
        var out: [RecordResumeItem] = []
        if unsentCount > 0 {
            out.append(.init(id: "unsent", kind: .unsentCapture,
                             text: "업로드하지 못한 촬영 \(unsentCount)개 · 원본은 이 기기에 있어요",
                             actionTitle: "보관함에서 보기", route: .spaces))
        }
        for j in spaceJobs where j.status == .failed {
            out.append(.init(id: "space-failed-\(j.spaceId)", kind: .spaceNeedsRetry,
                             text: "‘\(j.name)’ \(j.failureLabel)", actionTitle: "보기",
                             route: .spaceDetail(libraryId: "gaussian:\(j.spaceId)")))
        }
        if assetFailed > 0 {
            out.append(.init(id: "asset-failed", kind: .assetNeedsRetry,
                             text: "사진으로 만든 3D \(assetFailed)개 실패 · 다시 시도할 수 있어요",
                             actionTitle: "보기", route: .assets))
        }
        for j in spaceJobs where j.status == .uploading || j.status == .processing {
            out.append(.init(id: "space-active-\(j.spaceId)", kind: .spaceInProgress,
                             text: "‘\(j.name)’ 만드는 중 · 앱을 닫아도 계속돼요", actionTitle: "보기",
                             route: .spaceDetail(libraryId: "gaussian:\(j.spaceId)")))
        }
        if assetActive > 0 {
            out.append(.init(id: "asset-active", kind: .assetInProgress,
                             text: "사진으로 만드는 3D \(assetActive)개 진행 중", actionTitle: "보기", route: .assets))
        }
        return (Array(out.prefix(limit)), max(0, out.count - limit))
    }
}

/// Card for the 기록 home (result line for the viewer, how-to line for the capture).
struct RecordChoiceCard: View {
    let icon: String
    let card: RecordHomeCopy.Card
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
                HStack(alignment: .top) {
                    ZStack {
                        Circle()
                            .fill(GonggiColors.accentTeal.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: icon)
                            .font(.system(size: 19, weight: .light))
                            .foregroundStyle(GonggiColors.accentTeal)
                    }
                    Spacer(minLength: 0)
                    Text(card.badge)
                        .font(GonggiTypography.caption(11))
                        .fontWeight(.semibold)
                        .foregroundStyle(GonggiColors.accentCyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(GonggiColors.accentCyan.opacity(0.14))
                        .clipShape(Capsule())
                }
                Text(card.title)
                    .font(GonggiTypography.headline(19))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text(card.result)
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textPrimary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                Text(card.howTo)
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer(minLength: 0)
                    Text(card.action)
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.accentCyan)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(GonggiColors.accentCyan)
                }
            }
            .padding(GonggiSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GonggiColors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                    .stroke(GonggiColors.borderSubtle, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(card.title). \(card.result) \(card.howTo)")
    }
}

struct RecordSectionHeader: View {
    let title: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(GonggiTypography.headline(17))
                .foregroundStyle(GonggiColors.textPrimary)
            Text(caption)
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textSecondary)
        }
        .padding(.top, GonggiSpacing.sm)
    }
}

/// "이어서 할 일" — shown only when there is something; each row opens the existing Library place for it.
struct RecordResumeStrip: View {
    let items: [RecordResumeItem]
    let more: Int
    let onOpen: (RecordResumeRoute) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Text(RecordHomeCopy.resumeTitle)
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textTertiary)
            ForEach(items) { item in
                HStack(spacing: GonggiSpacing.sm) {
                    Image(systemName: icon(item.kind))
                        .foregroundStyle(GonggiColors.accentTeal)
                    Text(item.text)
                        .font(GonggiTypography.caption(14))
                        .foregroundStyle(GonggiColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(item.actionTitle) { onOpen(item.route) }
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.accentCyan)
                }
            }
            if more > 0 {
                Button("\(RecordHomeCopy.resumeSeeAll) (+\(more))") { onOpen(.spaces) }
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.accentCyan)
            }
        }
        .padding(GonggiSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GonggiColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }

    private func icon(_ kind: RecordResumeItem.Kind) -> String {
        switch kind {
        case .unsentCapture: return "icloud.and.arrow.up"
        case .spaceNeedsRetry, .assetNeedsRetry: return "exclamationmark.circle"
        case .spaceInProgress, .assetInProgress: return "hourglass"
        }
    }
}
