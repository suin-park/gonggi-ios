import Foundation

/// Build 72 — directed space connection (서버 linked row + 로컬 draft).
enum SpaceLinkStatus: String, Codable, Sendable, Equatable {
    case draft
    case capturing
    case generating
    case linked
    case failed
}

enum SpaceLinkLabelSize: String, Codable, Sendable, Equatable, CaseIterable {
    case small = "SMALL"
    case medium = "MEDIUM"
    case large = "LARGE"

    static let `default`: SpaceLinkLabelSize = .medium

    var displayTitle: String {
        switch self {
        case .small: return "작게"
        case .medium: return "보통"
        case .large: return "크게"
        }
    }

    var captionScale: Double {
        switch self {
        case .small: return 0.8
        case .medium: return 1.0
        case .large: return 1.3
        }
    }
}

struct SpaceLink: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var sourceSpaceId: String
    var targetSpaceId: String?
    var yawDeg: Float
    var pitchDeg: Float
    var radius: Float
    /// Optional hotspot display name (API: `label` / `displayName`).
    var label: String?
    /// Optional https URL opened from the hotspot (never auto-fetched).
    var externalUrl: String?
    /// Semantic hotspot label size. Nil from server/legacy means MEDIUM.
    var labelSize: SpaceLinkLabelSize?
    var status: SpaceLinkStatus
    var targetEntryYawDeg: Float?
    var targetSessionId: String?
    var targetResultImageURL: String?
    var targetStatus: String?
    var createdAt: Date
    var updatedAt: Date

    /// Product alias for `label`.
    var displayName: String? {
        get { label }
        set { label = newValue }
    }

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

    enum CodingKeys: String, CodingKey {
        case id, sourceSpaceId, targetSpaceId, yawDeg, pitchDeg, radius
        case label, displayName, externalUrl, labelSize, status, targetEntryYawDeg
        case targetSessionId, targetResultImageURL, targetStatus, createdAt, updatedAt
    }

    init(
        id: String,
        sourceSpaceId: String,
        targetSpaceId: String?,
        yawDeg: Float,
        pitchDeg: Float,
        radius: Float,
        label: String?,
        externalUrl: String? = nil,
        labelSize: SpaceLinkLabelSize? = nil,
        status: SpaceLinkStatus,
        targetEntryYawDeg: Float?,
        targetSessionId: String?,
        targetResultImageURL: String?,
        targetStatus: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.sourceSpaceId = sourceSpaceId
        self.targetSpaceId = targetSpaceId
        self.yawDeg = yawDeg
        self.pitchDeg = pitchDeg
        self.radius = radius
        self.label = label
        self.externalUrl = externalUrl
        self.labelSize = labelSize
        self.status = status
        self.targetEntryYawDeg = targetEntryYawDeg
        self.targetSessionId = targetSessionId
        self.targetResultImageURL = targetResultImageURL
        self.targetStatus = targetStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sourceSpaceId = try c.decode(String.self, forKey: .sourceSpaceId)
        targetSpaceId = try c.decodeIfPresent(String.self, forKey: .targetSpaceId)
        yawDeg = try c.decode(Float.self, forKey: .yawDeg)
        pitchDeg = try c.decode(Float.self, forKey: .pitchDeg)
        radius = try c.decode(Float.self, forKey: .radius)
        let decodedLabel = try c.decodeIfPresent(String.self, forKey: .label)
        let decodedDisplay = try c.decodeIfPresent(String.self, forKey: .displayName)
        label = SpaceLinkExternalURL.normalizeDisplayName(decodedLabel ?? decodedDisplay)
        externalUrl = try c.decodeIfPresent(String.self, forKey: .externalUrl)
        labelSize = try c.decodeIfPresent(SpaceLinkLabelSize.self, forKey: .labelSize)
        status = try c.decode(SpaceLinkStatus.self, forKey: .status)
        targetEntryYawDeg = try c.decodeIfPresent(Float.self, forKey: .targetEntryYawDeg)
        targetSessionId = try c.decodeIfPresent(String.self, forKey: .targetSessionId)
        targetResultImageURL = try c.decodeIfPresent(String.self, forKey: .targetResultImageURL)
        targetStatus = try c.decodeIfPresent(String.self, forKey: .targetStatus)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceSpaceId, forKey: .sourceSpaceId)
        try c.encodeIfPresent(targetSpaceId, forKey: .targetSpaceId)
        try c.encode(yawDeg, forKey: .yawDeg)
        try c.encode(pitchDeg, forKey: .pitchDeg)
        try c.encode(radius, forKey: .radius)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(externalUrl, forKey: .externalUrl)
        try c.encodeIfPresent(labelSize, forKey: .labelSize)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(targetEntryYawDeg, forKey: .targetEntryYawDeg)
        try c.encodeIfPresent(targetSessionId, forKey: .targetSessionId)
        try c.encodeIfPresent(targetResultImageURL, forKey: .targetResultImageURL)
        try c.encodeIfPresent(targetStatus, forKey: .targetStatus)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    static func makeDraft(
        sourceSpaceId: String,
        yawDeg: Float,
        pitchDeg: Float,
        radius: Float = defaultRadius,
        label: String? = nil,
        externalUrl: String? = nil,
        labelSize: SpaceLinkLabelSize = .default
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
            externalUrl: externalUrl,
            labelSize: labelSize,
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
    var externalUrl: String?
    var labelSize: SpaceLinkLabelSize?
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
    var displayName: String?
    var externalUrl: String?
    var labelSize: SpaceLinkLabelSize?
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
        let name = SpaceLinkExternalURL.normalizeDisplayName(label ?? displayName)
        return SpaceLink(
            id: id,
            sourceSpaceId: sourceSpaceId,
            targetSpaceId: targetSpaceId,
            yawDeg: Float(yawDeg),
            pitchDeg: Float(pitchDeg),
            radius: SpaceLink.clampRadius(Float(radius)),
            label: name,
            externalUrl: externalUrl,
            labelSize: labelSize,
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
