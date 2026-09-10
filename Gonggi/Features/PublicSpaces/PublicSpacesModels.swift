import Foundation
import simd

// MARK: - Visibility

enum GonggiSpaceVisibility: String, CaseIterable, Equatable, Sendable {
    case privateSpace = "PRIVATE"
    case unlisted = "UNLISTED"
    case `public` = "PUBLIC"
}

enum GonggiModerationStatus: String, Equatable, Sendable {
    case pending = "PENDING"
    case approved = "APPROVED"
    case rejected = "REJECTED"
    case hidden = "HIDDEN"
}

struct GonggiOwnerVisibilityState: Equatable, Sendable {
    var visibility: GonggiSpaceVisibility
    var shareEnabled: Bool = false
    var shareToken: String? = nil
    var shareUrl: String? = nil
    var publicSlug: String? = nil
    var moderationStatus: GonggiModerationStatus? = nil
    var moderationReason: String? = nil
    var publishedAt: String? = nil
    var publicUpdatedAt: String? = nil
    var publicDisplayName: String? = nil
    var ownerStatusMessage: String? = nil
    /// Server default true; preserved across PRIVATE/UNLISTED but only edited while PUBLIC.
    var commentsAllowed: Bool = true
}

// MARK: - Public catalog

struct PublicSpaceListItem: Equatable, Identifiable, Sendable {
    var id: String { publicSlug }
    var publicSlug: String
    var title: String
    var publisherDisplayName: String
    var publishedAt: String
    var thumbnailUrl: String?
    var likeCount: Int = 0
    var commentCount: Int = 0
}

struct PublicSpaceListPage: Equatable, Sendable {
    var spaces: [PublicSpaceListItem]
    var nextCursor: String?
}

struct PublicSpaceSlugRoute: Identifiable, Hashable {
    var id: String { slug }
    var slug: String
}

struct PublicSpaceHotspot: Equatable, Identifiable, Sendable {
    var id: String
    var yawDeg: Double
    var pitchDeg: Double
    var radius: Double
    var displayName: String?
    var labelSize: String?
    var externalHostname: String?
    var externalUrl: String?
    var externalUrlDisabled: Bool
    var canNavigate: Bool
    var targetPublicSlug: String?
    var targetShareToken: String?
    var targetTitle: String?
    var targetThumbnailUrl: String?
}

struct PublicSpacePlacementAsset: Equatable, Identifiable, Sendable {
    var id: String
    var assetId: String
    var positionX: Double
    var positionY: Double
    var positionZ: Double
    var rotationY: Double
    var uniformScale: Double
    var modelUrl: String?
    var sortIndex: Int
}

struct PublicSpaceAudio: Equatable, Sendable {
    var title: String?
    var durationSec: Double?
    var mimeType: String?
    var audioUrl: String
}

struct PublicSpaceDetail: Equatable, Sendable {
    var publicSlug: String
    var title: String
    var publisherDisplayName: String
    var publishedAt: String?
    var width: Int?
    var height: Int?
    var panoramaUrl: String
    var hotspots: [PublicSpaceHotspot]
    var placementFloorY: Double
    var placementAssets: [PublicSpacePlacementAsset]
    var publisherBlockToken: String
    var supportUrl: String
    var audio: PublicSpaceAudio? = nil
    var likeCount: Int = 0
    var commentCount: Int = 0
    var commentsAllowed: Bool = true
    var isLiked: Bool = false
    var publisherAvatarUrl: String? = nil
    var shareUrl: String? = nil
}

// MARK: - Comments / likes

struct PublicSpaceComment: Equatable, Identifiable, Sendable {
    var id: String
    var body: String
    var createdAt: String
    var editedAt: String?
    var authorDisplayName: String
    var authorAvatarUrl: String?
    var authorBlockToken: String?
    var isMine: Bool
    var canEdit: Bool
    var canDelete: Bool
    var canHide: Bool
}

struct PublicSpaceCommentsPage: Equatable, Sendable {
    var comments: [PublicSpaceComment]
    var nextCursor: String?
    var commentsAllowed: Bool
    var commentCount: Int
}

struct PublicSpaceLikeState: Equatable, Sendable {
    var likeCount: Int
    var isLiked: Bool
}

enum PublicSpaceReportReason: String, CaseIterable, Equatable, Sendable {
    case personalInfo = "PERSONAL_INFO"
    case inappropriate = "INAPPROPRIATE"
    case copyright = "COPYRIGHT"
    case misleading = "MISLEADING"
    case dangerousLink = "DANGEROUS_LINK"
    case other = "OTHER"
}

enum PublicCommentReportReason: String, CaseIterable, Equatable, Sendable {
    case personalInfo = "PERSONAL_INFO"
    case harassment = "HARASSMENT"
    case spam = "SPAM"
    case inappropriate = "INAPPROPRIATE"
    case copyright = "COPYRIGHT"
    case other = "OTHER"
}

struct PublicBlockedCreator: Equatable, Identifiable, Sendable {
    var id: String
    var blockToken: String
    var displayName: String
    var createdAt: String
}

// MARK: - Policy / copy (unit-tested)

enum PublicSpacesPolicy {
    static let visibilitySaveFailedMessage = "공개 설정을 저장하지 못했어요. 다시 시도해주세요."
    static let reportAcceptedMessage = "신고가 접수됐어요."
    static let publicConfirmTitle = "이 공간을 전체 공개할까요?"
    static let publicConfirmCheckboxLabel = "위 내용을 확인했어요"
    static let linkedPrivateHotspotNote = "비공개 공간으로 연결된 핫스팟은 공개되지 않아요."
    static let commentsDisabledMessage = "이 공간은 새 댓글을 받고 있지 않아요."
    static let likeRequiresLoginMessage = "로그인이 필요해요."
    static let commentRequiresLoginMessage = "로그인이 필요해요."
    static let publishedItemsSummary =
        "공간 이름, 360°, 공간 오디오, 핫스팟, 연결 공간, 3D, 작성자 이름, 좋아요 수, 댓글"

    static func pickerTitle(for visibility: GonggiSpaceVisibility) -> String {
        switch visibility {
        case .privateSpace: return "비공개"
        case .unlisted: return "링크 공유"
        case .public: return "전체 공개"
        }
    }

    static func pickerSubtitle(for visibility: GonggiSpaceVisibility) -> String {
        switch visibility {
        case .privateSpace:
            return "나만 이 공간을 볼 수 있어요."
        case .unlisted:
            return "링크를 받은 사람이 공간을 볼 수 있어요."
        case .public:
            return "공개 공간에 표시되며 누구나 볼 수 있어요."
        }
    }

    /// PUBLIC requires an explicit confirmation sheet before the PATCH is sent.
    static func requiresPublicConfirmation(
        from current: GonggiSpaceVisibility,
        to next: GonggiSpaceVisibility
    ) -> Bool {
        next == .public && current != .public
    }

    /// Single confirmation checkbox must be checked before enabling “전체 공개”.
    static func canEnablePublicPublish(confirmed: Bool) -> Bool { confirmed }

    /// Show commentsAllowed toggle only while targeting / editing PUBLIC.
    static func showsCommentsAllowedToggle(for visibility: GonggiSpaceVisibility) -> Bool {
        visibility == .public
    }

    static func publicConfirmBody(includeLinkedPrivateHotspotNote: Bool) -> String {
        var parts = [
            "공간 이미지와 오디오, 핫스팟, 배치된 3D 자산을 다른 사용자가 볼 수 있어요. 사람의 얼굴이나 목소리, 주소와 개인정보가 포함되지 않았는지 확인해주세요.",
            "공개되는 항목: \(publishedItemsSummary).",
        ]
        if includeLinkedPrivateHotspotNote {
            parts.append(linkedPrivateHotspotNote)
        }
        return parts.joined(separator: "\n\n")
    }

    static func surfacesOwnerStatusMessage(_ state: GonggiOwnerVisibilityState) -> String? {
        guard state.visibility == .public else { return nil }
        guard let status = state.moderationStatus else { return state.ownerStatusMessage }
        switch status {
        case .pending, .rejected, .hidden:
            return state.ownerStatusMessage
        case .approved:
            return nil
        }
    }

    static func shouldShowHomeSection(spaces: [PublicSpaceListItem]) -> Bool {
        !spaces.isEmpty
    }

    static func homePreviewLimit(_ spaces: [PublicSpaceListItem], max: Int = 4) -> [PublicSpaceListItem] {
        Array(spaces.prefix(max))
    }

    static func mergePaginatedPage(
        existing: [PublicSpaceListItem],
        page: PublicSpaceListPage,
        replacing: Bool
    ) -> (spaces: [PublicSpaceListItem], nextCursor: String?) {
        if replacing {
            return (page.spaces, page.nextCursor)
        }
        var seen = Set(existing.map(\.publicSlug))
        var merged = existing
        for item in page.spaces where !seen.contains(item.publicSlug) {
            seen.insert(item.publicSlug)
            merged.append(item)
        }
        return (merged, page.nextCursor)
    }

    /// Home / list cards always show counts, including zero. Never like from the card.
    static func shouldShowEngagementCountsOnCard() -> Bool { true }

    static func engagementCountLabel(_ count: Int) -> String {
        String(max(0, count))
    }

    /// Manual public audio only when payload present with a usable URL. Absence → no controls.
    static func hasPublicAudio(_ audio: PublicSpaceAudio?) -> Bool {
        guard let audio else { return false }
        return !audio.audioUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// isLiked is server-derived per access token; never cache in PublicSpacesAccountStore.
    static func shouldPersistIsLikedLocally() -> Bool { false }

    static func shareURLIfAvailable(from detail: PublicSpaceDetail) -> String? {
        let trimmed = detail.shareUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func reportReasonLabel(_ reason: PublicSpaceReportReason) -> String {
        switch reason {
        case .personalInfo: return "개인정보 노출"
        case .inappropriate: return "부적절한 콘텐츠"
        case .copyright: return "저작권 침해"
        case .misleading: return "허위 또는 오해를 일으키는 정보"
        case .dangerousLink: return "위험한 외부 링크"
        case .other: return "기타"
        }
    }

    static func reportReason(fromAPI raw: String) -> PublicSpaceReportReason? {
        PublicSpaceReportReason(rawValue: raw)
    }

    static func commentReportReasonLabel(_ reason: PublicCommentReportReason) -> String {
        switch reason {
        case .personalInfo: return "개인정보 노출"
        case .harassment: return "괴롭힘·혐오"
        case .spam: return "스팸"
        case .inappropriate: return "부적절한 내용"
        case .copyright: return "저작권 침해"
        case .other: return "기타"
        }
    }

    static func commentReportReason(fromAPI raw: String) -> PublicCommentReportReason? {
        PublicCommentReportReason(rawValue: raw)
    }

    /// Public viewer must never expose owner edit/repair/delete/audio/memo controls.
    static func publicViewerAllowsOwnerControls() -> Bool { false }

    static func resolveMediaURL(relativeOrAbsolute path: String, apiBaseURL: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let absolute = URL(string: trimmed), let scheme = absolute.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return absolute
        }
        if trimmed.hasPrefix("/") {
            return URL(string: trimmed, relativeTo: apiBaseURL)?.absoluteURL
        }
        return apiBaseURL.appendingPathComponent(trimmed)
    }

    /// Map public DTO hotspots → SpaceLink for read-only VR chrome.
    static func spaceLinks(from hotspots: [PublicSpaceHotspot], sourceId: String) -> [SpaceLink] {
        let now = Date()
        return hotspots.compactMap { hotspot in
            if !hotspot.canNavigate
                && (hotspot.externalUrl == nil || hotspot.externalUrlDisabled)
                && hotspot.displayName == nil {
                return nil
            }
            var targetId: String?
            var targetSession: String?
            if hotspot.canNavigate, let slug = hotspot.targetPublicSlug, !slug.isEmpty {
                targetId = "public:\(slug)"
                targetSession = targetId
            } else if hotspot.canNavigate, let token = hotspot.targetShareToken, !token.isEmpty {
                targetId = "share:\(token)"
                targetSession = targetId
            }
            let labelSize = hotspot.labelSize.flatMap(SpaceLinkLabelSize.init(rawValue:))
            return SpaceLink(
                id: hotspot.id,
                sourceSpaceId: sourceId,
                targetSpaceId: targetId,
                yawDeg: Float(hotspot.yawDeg),
                pitchDeg: Float(hotspot.pitchDeg),
                radius: Float(hotspot.radius),
                label: hotspot.displayName,
                externalUrl: hotspot.externalUrlDisabled ? nil : hotspot.externalUrl,
                labelSize: labelSize,
                status: .linked,
                targetEntryYawDeg: nil,
                targetSessionId: targetSession,
                targetResultImageURL: hotspot.targetThumbnailUrl,
                targetStatus: targetId == nil ? nil : "completed",
                createdAt: now,
                updatedAt: now
            )
        }
    }

    static func placementLayout(from detail: PublicSpaceDetail) -> VRPlacementLayout {
        let entries = detail.placementAssets
            .sorted { $0.sortIndex < $1.sortIndex }
            .map { asset in
                VRPlacedAssetEntry(
                    id: asset.id,
                    assetId: asset.assetId,
                    position: SIMD3(
                        Float(asset.positionX),
                        Float(asset.positionY),
                        Float(asset.positionZ)
                    ),
                    rotationY: Float(asset.rotationY),
                    uniformScale: Float(asset.uniformScale),
                    sortIndex: asset.sortIndex,
                    supportMode: .floor,
                    supportY: Float(detail.placementFloorY)
                )
            }
        return VRPlacementLayout(floorY: Float(detail.placementFloorY), assets: entries)
    }

    static func publicTargetKeyPrefixes() -> (public: String, share: String) {
        ("public:", "share:")
    }
}

/// Bundled public overlay for SpaceViewerSession (hotspots + placement + media base).
struct PublicViewerOverlay: Equatable, Sendable {
    var publicSlug: String
    var title: String
    var hotspots: [PublicSpaceHotspot]
    var placementFloorY: Double
    var placementAssets: [PublicSpacePlacementAsset]
    var apiBaseURLString: String

    init(detail: PublicSpaceDetail, apiBaseURL: URL) {
        publicSlug = detail.publicSlug
        title = detail.title
        hotspots = detail.hotspots
        placementFloorY = detail.placementFloorY
        placementAssets = detail.placementAssets
        apiBaseURLString = apiBaseURL.absoluteString
    }

    var apiBaseURL: URL? { URL(string: apiBaseURLString) }
}

// MARK: - Account-scoped local cache keys (home preview / last cursor)

enum PublicSpacesAccountStore {
    private static let homePreviewPrefix = "gonggi.publicSpaces.homePreview.v1."
    private static let lastCursorPrefix = "gonggi.publicSpaces.listCursor.v1."
    private static let boundUserKey = "gonggi.publicSpaces.boundUser.v1"

    static func homePreviewKey(userId: String) -> String {
        homePreviewPrefix + sanitize(userId)
    }

    static func listCursorKey(userId: String) -> String {
        lastCursorPrefix + sanitize(userId)
    }

    static func saveHomePreviewSlugs(_ slugs: [String], userId: String, defaults: UserDefaults = .standard) {
        defaults.set(slugs, forKey: homePreviewKey(userId: userId))
    }

    static func homePreviewSlugs(userId: String, defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: homePreviewKey(userId: userId)) ?? []
    }

    static func saveListCursor(_ cursor: String?, userId: String, defaults: UserDefaults = .standard) {
        let key = listCursorKey(userId: userId)
        if let cursor, !cursor.isEmpty {
            defaults.set(cursor, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    static func listCursor(userId: String, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: listCursorKey(userId: userId))
    }

    static func clear(userId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: homePreviewKey(userId: userId))
        defaults.removeObject(forKey: listCursorKey(userId: userId))
    }

    /// Bind active account — clears previous account's local public-space keys when switching.
    static func bind(userId: String, defaults: UserDefaults = .standard) {
        let previous = defaults.string(forKey: boundUserKey)
        if let previous, previous != userId {
            clear(userId: previous, defaults: defaults)
        }
        defaults.set(userId, forKey: boundUserKey)
    }

    static func unbind(defaults: UserDefaults = .standard) {
        if let previous = defaults.string(forKey: boundUserKey) {
            clear(userId: previous, defaults: defaults)
        }
        defaults.removeObject(forKey: boundUserKey)
    }

    private static func sanitize(_ userId: String) -> String {
        userId.replacingOccurrences(of: "/", with: "_")
    }
}

enum PublicSpacesAPIMessageSanitizer {
    static func isUnsafeServerMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("prisma")
            || lower.contains("does not exist")
            || lower.contains("invocation")
            || lower.contains("gonggispace")
            || lower.contains("column")
            || lower.contains("stack")
            || message.contains("\n")
    }

    static func safeMessage(_ message: String?, fallback: String) -> String {
        guard let message, !message.isEmpty else { return fallback }
        if isUnsafeServerMessage(message) { return fallback }
        return message
    }
}
