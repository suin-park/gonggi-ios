import XCTest
@testable import Gonggi

final class PublicSpacesTests: XCTestCase {
    func testVisibilityPickerLabelMapping() {
        XCTAssertEqual(PublicSpacesPolicy.pickerTitle(for: .privateSpace), "비공개")
        XCTAssertEqual(
            PublicSpacesPolicy.pickerSubtitle(for: .privateSpace),
            "나만 이 공간을 볼 수 있어요."
        )
        XCTAssertEqual(PublicSpacesPolicy.pickerTitle(for: .unlisted), "링크 공유")
        XCTAssertEqual(
            PublicSpacesPolicy.pickerSubtitle(for: .unlisted),
            "링크를 받은 사람이 공간을 볼 수 있어요."
        )
        XCTAssertEqual(PublicSpacesPolicy.pickerTitle(for: .public), "전체 공개")
        XCTAssertEqual(
            PublicSpacesPolicy.pickerSubtitle(for: .public),
            "공개 공간에 표시되며 누구나 볼 수 있어요."
        )
    }

    func testConfirmationRequiredBeforePublic() {
        XCTAssertTrue(PublicSpacesPolicy.requiresPublicConfirmation(from: .privateSpace, to: .public))
        XCTAssertTrue(PublicSpacesPolicy.requiresPublicConfirmation(from: .unlisted, to: .public))
        XCTAssertFalse(PublicSpacesPolicy.requiresPublicConfirmation(from: .public, to: .public))
        XCTAssertFalse(PublicSpacesPolicy.requiresPublicConfirmation(from: .privateSpace, to: .unlisted))
        XCTAssertFalse(PublicSpacesPolicy.requiresPublicConfirmation(from: .public, to: .privateSpace))
        XCTAssertTrue(
            PublicSpacesPolicy.publicConfirmBody(includeLinkedPrivateHotspotNote: true)
                .contains(PublicSpacesPolicy.linkedPrivateHotspotNote)
        )
        XCTAssertEqual(PublicSpacesPolicy.publicConfirmTitle, "이 공간을 전체 공개할까요?")
        XCTAssertEqual(PublicSpacesPolicy.publicConfirmCheckboxLabel, "위 내용을 확인했어요")
        XCTAssertFalse(PublicSpacesPolicy.canEnablePublicPublish(confirmed: false))
        XCTAssertTrue(PublicSpacesPolicy.canEnablePublicPublish(confirmed: true))
    }

    func testPublicConfirmCopyIncludesAudioAndEngagement() {
        let body = PublicSpacesPolicy.publicConfirmBody(includeLinkedPrivateHotspotNote: false)
        XCTAssertTrue(body.contains("공간 이미지와 오디오, 핫스팟, 배치된 3D 자산을 다른 사용자가 볼 수 있어요."))
        XCTAssertTrue(body.contains("사람의 얼굴이나 목소리, 주소와 개인정보가 포함되지 않았는지 확인해주세요."))
        XCTAssertTrue(body.contains(PublicSpacesPolicy.publishedItemsSummary))
        XCTAssertTrue(body.contains("공간 오디오"))
        XCTAssertTrue(body.contains("좋아요 수"))
        XCTAssertTrue(body.contains("댓글"))
        XCTAssertFalse(body.contains("공개되지 않는 항목"))
    }

    func testCommentsAllowedToggleVisibility() {
        XCTAssertTrue(PublicSpacesPolicy.showsCommentsAllowedToggle(for: .public))
        XCTAssertFalse(PublicSpacesPolicy.showsCommentsAllowedToggle(for: .privateSpace))
        XCTAssertFalse(PublicSpacesPolicy.showsCommentsAllowedToggle(for: .unlisted))

        let json: [String: Any] = [
            "visibility": "PUBLIC",
            "shareEnabled": true,
            "commentsAllowed": false,
        ]
        let state = MobilePublicSpacesAPIClient.parseVisibility(json)
        XCTAssertEqual(state?.commentsAllowed, false)

        let defaultJSON: [String: Any] = [
            "visibility": "PRIVATE",
            "shareEnabled": false,
        ]
        let privateState = MobilePublicSpacesAPIClient.parseVisibility(defaultJSON)
        XCTAssertEqual(privateState?.commentsAllowed, true)
    }

    func testPendingRejectedHiddenMessageSurfaces() {
        let pending = GonggiOwnerVisibilityState(
            visibility: .public,
            shareEnabled: true,
            moderationStatus: .pending,
            ownerStatusMessage: "전체 공개 검토 중이에요. 승인되면 공개 공간 목록에 표시돼요."
        )
        XCTAssertEqual(
            PublicSpacesPolicy.surfacesOwnerStatusMessage(pending),
            pending.ownerStatusMessage
        )

        let rejected = GonggiOwnerVisibilityState(
            visibility: .public,
            shareEnabled: true,
            moderationStatus: .rejected,
            ownerStatusMessage: "전체 공개가 거절됐어요."
        )
        XCTAssertNotNil(PublicSpacesPolicy.surfacesOwnerStatusMessage(rejected))

        let hidden = GonggiOwnerVisibilityState(
            visibility: .public,
            shareEnabled: true,
            moderationStatus: .hidden,
            ownerStatusMessage: "공개가 중단됐어요."
        )
        XCTAssertNotNil(PublicSpacesPolicy.surfacesOwnerStatusMessage(hidden))

        let approved = GonggiOwnerVisibilityState(
            visibility: .public,
            shareEnabled: true,
            moderationStatus: .approved,
            ownerStatusMessage: nil
        )
        XCTAssertNil(PublicSpacesPolicy.surfacesOwnerStatusMessage(approved))

        let privateState = GonggiOwnerVisibilityState(
            visibility: .privateSpace,
            shareEnabled: false,
            moderationStatus: .pending,
            ownerStatusMessage: "should hide"
        )
        XCTAssertNil(PublicSpacesPolicy.surfacesOwnerStatusMessage(privateState))
    }

    func testHomeSectionHiddenWhenEmpty() {
        XCTAssertFalse(PublicSpacesPolicy.shouldShowHomeSection(spaces: []))
        let item = PublicSpaceListItem(
            publicSlug: "s1",
            title: "거실",
            publisherDisplayName: "neo",
            publishedAt: "2026-09-10T00:00:00Z",
            thumbnailUrl: nil,
            likeCount: 0,
            commentCount: 0
        )
        XCTAssertTrue(PublicSpacesPolicy.shouldShowHomeSection(spaces: [item]))
        XCTAssertEqual(PublicSpacesPolicy.homePreviewLimit(Array(repeating: item, count: 6), max: 4).count, 4)
    }

    func testLikeAndCommentCountDisplayPolicyShowsZero() {
        XCTAssertTrue(PublicSpacesPolicy.shouldShowEngagementCountsOnCard())
        XCTAssertEqual(PublicSpacesPolicy.engagementCountLabel(0), "0")
        XCTAssertEqual(PublicSpacesPolicy.engagementCountLabel(12), "12")

        let row: [String: Any] = [
            "publicSlug": "slug",
            "title": "카페",
            "publisherDisplayName": "neo",
            "publishedAt": "2026-09-10T00:00:00Z",
            "likeCount": 0,
            "commentCount": 0,
        ]
        let item = MobilePublicSpacesAPIClient.parseListItem(row)
        XCTAssertEqual(item?.likeCount, 0)
        XCTAssertEqual(item?.commentCount, 0)
    }

    func testPaginationCursorPlumbing() {
        let a = PublicSpaceListItem(
            publicSlug: "a", title: "A", publisherDisplayName: "p", publishedAt: "t", thumbnailUrl: nil
        )
        let b = PublicSpaceListItem(
            publicSlug: "b", title: "B", publisherDisplayName: "p", publishedAt: "t", thumbnailUrl: nil
        )
        let page1 = PublicSpaceListPage(spaces: [a], nextCursor: "c1")
        let first = PublicSpacesPolicy.mergePaginatedPage(existing: [], page: page1, replacing: true)
        XCTAssertEqual(first.spaces.map(\.publicSlug), ["a"])
        XCTAssertEqual(first.nextCursor, "c1")

        let page2 = PublicSpaceListPage(spaces: [a, b], nextCursor: "c2")
        let merged = PublicSpacesPolicy.mergePaginatedPage(existing: first.spaces, page: page2, replacing: false)
        XCTAssertEqual(merged.spaces.map(\.publicSlug), ["a", "b"])
        XCTAssertEqual(merged.nextCursor, "c2")
    }

    func testPublicViewerHasNoOwnerControlsFlag() {
        XCTAssertFalse(PublicSpacesPolicy.publicViewerAllowsOwnerControls())
        let session = SpaceViewerSession(
            id: "public:slug",
            fileURL: URL(fileURLWithPath: "/tmp/latlong.jpg"),
            allowsOwnerControls: PublicSpacesPolicy.publicViewerAllowsOwnerControls()
        )
        XCTAssertFalse(session.allowsOwnerControls)
        XCTAssertFalse(session.startInEditMode)
        XCTAssertNil(session.audioURL)
    }

    func testPublicAudioAbsenceMeansNoManualControls() {
        XCTAssertFalse(PublicSpacesPolicy.hasPublicAudio(nil))
        XCTAssertFalse(PublicSpacesPolicy.hasPublicAudio(
            PublicSpaceAudio(title: nil, durationSec: nil, mimeType: nil, audioUrl: "  ")
        ))
        XCTAssertTrue(PublicSpacesPolicy.hasPublicAudio(
            PublicSpaceAudio(title: "Ambient", durationSec: 12, mimeType: "audio/mp4", audioUrl: "/api/gonggi/public/spaces/s/audio")
        ))

        let detailJSON: [String: Any] = [
            "publicSlug": "slug-1",
            "title": "카페",
            "publisherDisplayName": "neo",
            "panoramaUrl": "/api/gonggi/public/spaces/slug-1/panorama",
            "publisherBlockToken": "tok",
            "supportUrl": "https://www.3d-locker.com/support",
            "hotspots": [],
            "placement": ["floorY": 0, "assets": []],
            "audio": NSNull(),
        ]
        let detail = MobilePublicSpacesAPIClient.parseDetail(detailJSON)
        XCTAssertNil(detail?.audio)
        XCTAssertFalse(PublicSpacesPolicy.hasPublicAudio(detail?.audio))
    }

    func testReportReasonMapping() {
        XCTAssertEqual(PublicSpacesPolicy.reportReasonLabel(.personalInfo), "개인정보 노출")
        XCTAssertEqual(PublicSpacesPolicy.reportReasonLabel(.inappropriate), "부적절한 콘텐츠")
        XCTAssertEqual(PublicSpacesPolicy.reportReasonLabel(.copyright), "저작권 침해")
        XCTAssertEqual(PublicSpacesPolicy.reportReasonLabel(.misleading), "허위 또는 오해를 일으키는 정보")
        XCTAssertEqual(PublicSpacesPolicy.reportReasonLabel(.dangerousLink), "위험한 외부 링크")
        XCTAssertEqual(PublicSpacesPolicy.reportReasonLabel(.other), "기타")
        XCTAssertEqual(PublicSpacesPolicy.reportReason(fromAPI: "PERSONAL_INFO"), .personalInfo)
        XCTAssertEqual(PublicSpacesPolicy.reportReason(fromAPI: "DANGEROUS_LINK"), .dangerousLink)
        XCTAssertNil(PublicSpacesPolicy.reportReason(fromAPI: "SPAM"))
        XCTAssertEqual(PublicSpaceReportReason.allCases.count, 6)
        XCTAssertEqual(PublicSpacesPolicy.reportAcceptedMessage, "신고가 접수됐어요.")
    }

    func testCommentReportReasonLabels() {
        XCTAssertEqual(PublicSpacesPolicy.commentReportReasonLabel(.personalInfo), "개인정보 노출")
        XCTAssertEqual(PublicSpacesPolicy.commentReportReasonLabel(.harassment), "괴롭힘·혐오")
        XCTAssertEqual(PublicSpacesPolicy.commentReportReasonLabel(.spam), "스팸")
        XCTAssertEqual(PublicSpacesPolicy.commentReportReasonLabel(.inappropriate), "부적절한 내용")
        XCTAssertEqual(PublicSpacesPolicy.commentReportReasonLabel(.copyright), "저작권 침해")
        XCTAssertEqual(PublicSpacesPolicy.commentReportReasonLabel(.other), "기타")
        XCTAssertEqual(PublicSpacesPolicy.commentReportReason(fromAPI: "HARASSMENT"), .harassment)
        XCTAssertEqual(PublicSpacesPolicy.commentReportReason(fromAPI: "SPAM"), .spam)
        XCTAssertNil(PublicSpacesPolicy.commentReportReason(fromAPI: "MISLEADING"))
        XCTAssertEqual(PublicCommentReportReason.allCases.count, 6)
        XCTAssertEqual(PublicSpacesPolicy.commentsDisabledMessage, "이 공간은 새 댓글을 받고 있지 않아요.")
    }

    func testBlockTokenPlumbing() {
        let token = "gonggi-pub-block-token-opaque"
        let detailJSON: [String: Any] = [
            "publicSlug": "slug-1",
            "title": "카페",
            "publisherDisplayName": "neo",
            "panoramaUrl": "/api/gonggi/public/spaces/slug-1/panorama",
            "publisherBlockToken": token,
            "supportUrl": "https://www.3d-locker.com/support",
            "hotspots": [],
            "placement": ["floorY": 0, "assets": []],
        ]
        let detail = MobilePublicSpacesAPIClient.parseDetail(detailJSON)
        XCTAssertEqual(detail?.publisherBlockToken, token)
        XCTAssertNotEqual(detail?.publisherBlockToken, detail?.publicSlug)

        let blockJSON: [String: Any] = [
            "id": "blk1",
            "blockToken": token,
            "displayName": "neo",
            "createdAt": "2026-09-10T00:00:00Z",
        ]
        let block = MobilePublicSpacesAPIClient.parseBlock(blockJSON)
        XCTAssertEqual(block?.blockToken, token)
    }

    func testIsLikedIsAccountScopedAndNotPersistedLocally() {
        XCTAssertFalse(PublicSpacesPolicy.shouldPersistIsLikedLocally())

        let likedJSON: [String: Any] = [
            "publicSlug": "slug-1",
            "title": "카페",
            "publisherDisplayName": "neo",
            "panoramaUrl": "/api/gonggi/public/spaces/slug-1/panorama",
            "publisherBlockToken": "tok",
            "supportUrl": "https://www.3d-locker.com/support",
            "hotspots": [],
            "placement": ["floorY": 0, "assets": []],
            "isLiked": true,
            "likeCount": 3,
        ]
        let liked = MobilePublicSpacesAPIClient.parseDetail(likedJSON)
        XCTAssertEqual(liked?.isLiked, true)

        let anonymousJSON: [String: Any] = [
            "publicSlug": "slug-1",
            "title": "카페",
            "publisherDisplayName": "neo",
            "panoramaUrl": "/api/gonggi/public/spaces/slug-1/panorama",
            "publisherBlockToken": "tok",
            "supportUrl": "https://www.3d-locker.com/support",
            "hotspots": [],
            "placement": ["floorY": 0, "assets": []],
        ]
        let anonymous = MobilePublicSpacesAPIClient.parseDetail(anonymousJSON)
        XCTAssertEqual(anonymous?.isLiked, false)

        let suiteName = "PublicSpacesTests.isLiked.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PublicSpacesAccountStore.bind(userId: "user_a", defaults: defaults)
        PublicSpacesAccountStore.saveHomePreviewSlugs(["slug-1"], userId: "user_a", defaults: defaults)
        PublicSpacesAccountStore.bind(userId: "user_b", defaults: defaults)
        // Account switch clears local catalog keys; isLiked must never live there.
        XCTAssertEqual(PublicSpacesAccountStore.homePreviewSlugs(userId: "user_a", defaults: defaults), [])
        XCTAssertFalse(PublicSpacesPolicy.shouldPersistIsLikedLocally())
    }

    func testAccountSwitchIsolation() {
        let suiteName = "PublicSpacesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PublicSpacesAccountStore.saveHomePreviewSlugs(["a", "b"], userId: "user_a", defaults: defaults)
        PublicSpacesAccountStore.saveListCursor("cursorA", userId: "user_a", defaults: defaults)
        PublicSpacesAccountStore.bind(userId: "user_a", defaults: defaults)

        XCTAssertEqual(PublicSpacesAccountStore.homePreviewSlugs(userId: "user_a", defaults: defaults), ["a", "b"])
        XCTAssertEqual(PublicSpacesAccountStore.listCursor(userId: "user_a", defaults: defaults), "cursorA")

        PublicSpacesAccountStore.saveHomePreviewSlugs(["x"], userId: "user_b", defaults: defaults)
        PublicSpacesAccountStore.bind(userId: "user_b", defaults: defaults)

        // Previous account local keys cleared on bind switch.
        XCTAssertEqual(PublicSpacesAccountStore.homePreviewSlugs(userId: "user_a", defaults: defaults), [])
        XCTAssertNil(PublicSpacesAccountStore.listCursor(userId: "user_a", defaults: defaults))
        XCTAssertEqual(PublicSpacesAccountStore.homePreviewSlugs(userId: "user_b", defaults: defaults), ["x"])

        PublicSpacesAccountStore.unbind(defaults: defaults)
        XCTAssertEqual(PublicSpacesAccountStore.homePreviewSlugs(userId: "user_b", defaults: defaults), [])
    }

    func testVisibilitySaveFailedCopyAndUnsafeSanitizer() {
        XCTAssertEqual(
            PublicSpacesPolicy.visibilitySaveFailedMessage,
            "공개 설정을 저장하지 못했어요. 다시 시도해주세요."
        )
        XCTAssertTrue(PublicSpacesAPIMessageSanitizer.isUnsafeServerMessage("PrismaClientKnownRequestError"))
        XCTAssertEqual(
            PublicSpacesAPIMessageSanitizer.safeMessage("column does not exist", fallback: "safe"),
            "safe"
        )
        XCTAssertEqual(
            PublicSpacesAPIMessageSanitizer.safeMessage("완성된 공간만 전체 공개할 수 있어요.", fallback: "safe"),
            "완성된 공간만 전체 공개할 수 있어요."
        )
    }

    func testResolveMediaURLAgainstAPIBase() {
        let base = URL(string: "https://www.3d-locker.com")!
        let relative = PublicSpacesPolicy.resolveMediaURL(
            relativeOrAbsolute: "/api/gonggi/public/spaces/s/thumbnail",
            apiBaseURL: base
        )
        XCTAssertEqual(relative?.absoluteString, "https://www.3d-locker.com/api/gonggi/public/spaces/s/thumbnail")
        let absolute = PublicSpacesPolicy.resolveMediaURL(
            relativeOrAbsolute: "https://cdn.example.com/t.jpg",
            apiBaseURL: base
        )
        XCTAssertEqual(absolute?.absoluteString, "https://cdn.example.com/t.jpg")
        XCTAssertEqual(
            MobilePublicSpacesAPIClient.publicAudioProxyPath(slug: "cafe"),
            "/api/gonggi/public/spaces/cafe/audio"
        )
    }

    func testParseDetailEngagementAndAudio() {
        let detailJSON: [String: Any] = [
            "publicSlug": "slug-1",
            "title": "카페",
            "publisherDisplayName": "neo",
            "panoramaUrl": "/api/gonggi/public/spaces/slug-1/panorama",
            "publisherBlockToken": "tok",
            "supportUrl": "https://www.3d-locker.com/support",
            "hotspots": [],
            "placement": ["floorY": 0, "assets": []],
            "likeCount": 4,
            "commentCount": 2,
            "commentsAllowed": false,
            "isLiked": true,
            "publisherAvatarUrl": "https://cdn.example.com/a.png",
            "shareUrl": "https://www.3d-locker.com/gonggi/public/slug-1",
            "audio": [
                "title": "Rain",
                "durationSec": 32.5,
                "mimeType": "audio/mp4",
                "audioUrl": "/api/gonggi/public/spaces/slug-1/audio",
            ],
        ]
        let detail = MobilePublicSpacesAPIClient.parseDetail(detailJSON)
        XCTAssertEqual(detail?.likeCount, 4)
        XCTAssertEqual(detail?.commentCount, 2)
        XCTAssertEqual(detail?.commentsAllowed, false)
        XCTAssertEqual(detail?.isLiked, true)
        XCTAssertEqual(detail?.publisherAvatarUrl, "https://cdn.example.com/a.png")
        XCTAssertEqual(detail?.shareUrl, "https://www.3d-locker.com/gonggi/public/slug-1")
        XCTAssertEqual(detail?.audio?.title, "Rain")
        XCTAssertEqual(
            PublicSpacesPolicy.shareURLIfAvailable(from: detail!),
            "https://www.3d-locker.com/gonggi/public/slug-1"
        )
    }

    func testParseCommentDTO() {
        let row: [String: Any] = [
            "id": "c1",
            "body": "좋아요",
            "createdAt": "2026-09-10T00:00:00Z",
            "editedAt": "2026-09-10T01:00:00Z",
            "authorDisplayName": "neo",
            "authorAvatarUrl": "https://cdn.example.com/a.png",
            "authorBlockToken": "bt",
            "isMine": true,
            "canEdit": true,
            "canDelete": true,
            "canHide": false,
        ]
        let comment = MobilePublicSpacesAPIClient.parseComment(row)
        XCTAssertEqual(comment?.id, "c1")
        XCTAssertEqual(comment?.isMine, true)
        XCTAssertEqual(comment?.canEdit, true)
        XCTAssertEqual(comment?.canHide, false)
    }
}
