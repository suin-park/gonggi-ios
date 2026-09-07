import Foundation

/// Build 72 — directed space connection (서버 linked row + 로컬 draft).
enum SpaceLinkStatus: String, Codable, Sendable, Equatable {
    case draft
    case capturing
    case generating
    case linked
    case failed
}

struct SpaceLink: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var sourceSpaceId: String
    var targetSpaceId: String?
    var yawDeg: Float
    var pitchDeg: Float
    var radius: Float
    var label: String?
    var status: SpaceLinkStatus
    var targetEntryYawDeg: Float?
    var targetSessionId: String?
    var targetResultImageURL: String?
    var targetStatus: String?
    var createdAt: Date
    var updatedAt: Date

    /// Server-backed navigable link.
    var isNavigable: Bool {
        status == .linked
            && targetSpaceId != nil
            && (targetSessionId != nil || targetSpaceId != nil)
            && targetStatus.map { !Self.blockedTargetStatuses.contains($0.lowercased()) } ?? true
    }

    private static let blockedTargetStatuses: Set<String> = [
        "failed", "cancelled", "deleted",
    ]

    static let maxLinksPerSource = 8
    static let defaultRadius: Float = 3.0
    static let minRadius: Float = 1.5
    static let maxRadius: Float = 6.0

    static func clampRadius(_ r: Float) -> Float {
        min(maxRadius, max(minRadius, r))
    }

    static func makeDraft(
        sourceSpaceId: String,
        yawDeg: Float,
        pitchDeg: Float,
        radius: Float = defaultRadius,
        label: String? = nil
    ) -> SpaceLink {
        let now = Date()
        return SpaceLink(
            id: "draft-\(UUID().uuidString)",
            sourceSpaceId: sourceSpaceId,
            targetSpaceId: nil,
            yawDeg: VRSphereEquirectBridge.normalizeYawDeg(yawDeg),
            pitchDeg: max(-89, min(89, pitchDeg)),
            radius: clampRadius(radius),
            label: label,
            status: .draft,
            targetEntryYawDeg: nil,
            targetSessionId: nil,
            targetResultImageURL: nil,
            targetStatus: nil,
            createdAt: now,
            updatedAt: now
        )
    }
}

/// Capture started from Edit “공간 연결” — finalize SpaceLink only after target SUCCESS.
struct PendingSpaceLinkCapture: Codable, Equatable, Sendable {
    var sourceSpaceId: String
    var draftHotspotId: String
    var yawDeg: Float
    var pitchDeg: Float
    var radius: Float
    var label: String?
    var targetSessionId: String
    var createdAt: Date
}

/// API DTO (server linked only).
struct SpaceLinkDTO: Codable, Equatable, Sendable {
    var id: String
    var sourceSpaceId: String
    var targetSpaceId: String
    var yawDeg: Double
    var pitchDeg: Double
    var radius: Double
    var label: String?
    var status: String
    var targetEntryYawDeg: Double?
    var createdAt: String
    var updatedAt: String
    var targetSessionId: String?
    var targetResultImageURL: String?
    var targetStatus: String?

    func toModel() -> SpaceLink {
        let created = Self.parseDate(createdAt) ?? Date()
        let updated = Self.parseDate(updatedAt) ?? created
        return SpaceLink(
            id: id,
            sourceSpaceId: sourceSpaceId,
            targetSpaceId: targetSpaceId,
            yawDeg: Float(yawDeg),
            pitchDeg: Float(pitchDeg),
            radius: SpaceLink.clampRadius(Float(radius)),
            label: label,
            status: .linked,
            targetEntryYawDeg: targetEntryYawDeg.map { Float($0) },
            targetSessionId: targetSessionId,
            targetResultImageURL: targetResultImageURL,
            targetStatus: targetStatus,
            createdAt: created,
            updatedAt: updated
        )
    }

    private static func parseDate(_ raw: String) -> Date? {
        if let d = ISO8601DateFormatter.gonggiFractional.date(from: raw) { return d }
        return ISO8601DateFormatter.gonggi.date(from: raw)
    }
}

struct SpaceLinkListResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var spaceId: String?
    var sessionId: String?
    var links: [SpaceLinkDTO]
    var maxLinks: Int?
}

struct SpaceLinkMutationResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var spaceId: String?
    var sessionId: String?
    var link: SpaceLinkDTO?
    var error: String?
    var message: String?
}

private extension ISO8601DateFormatter {
    static let gonggiFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let gonggi: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
