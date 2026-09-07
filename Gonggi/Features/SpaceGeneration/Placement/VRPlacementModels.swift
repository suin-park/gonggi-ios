import Foundation
import simd

enum VRInteractionMode: String, Codable, Sendable {
    case view
    case edit
}

enum VREditTool: String, Codable, Sendable {
    case none
    case move
    case rotate
    case scale
    case delete
}

struct VRPlacementLayout: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let coordinateFrame = "gonggi.vr.v1"
    static let defaultFloorY: Float = -1.35
    static let maxAssets = 8

    var version: Int
    var frame: String
    var floorY: Float
    var assets: [VRPlacedAssetEntry]

    init(
        version: Int = Self.currentVersion,
        frame: String = Self.coordinateFrame,
        floorY: Float = Self.defaultFloorY,
        assets: [VRPlacedAssetEntry] = []
    ) {
        self.version = version
        self.frame = frame
        self.floorY = floorY
        self.assets = Array(assets.prefix(Self.maxAssets))
    }

    var entries: [VRPlacedAssetEntry] {
        get { assets }
        set { assets = Array(newValue.prefix(Self.maxAssets)) }
    }

    mutating func append(_ entry: VRPlacedAssetEntry) -> Bool {
        guard assets.count < Self.maxAssets else { return false }
        assets.append(entry)
        return true
    }

    mutating func enforceLimits() {
        assets = Array(assets.prefix(Self.maxAssets))
        for index in assets.indices {
            assets[index].uniformScale = VRPlacedAssetEntry.clampedScale(assets[index].uniformScale)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case frame
        case floorY
        case assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        frame = try container.decodeIfPresent(String.self, forKey: .frame) ?? Self.coordinateFrame
        floorY = try container.decodeIfPresent(Float.self, forKey: .floorY) ?? Self.defaultFloorY
        let decoded = try container.decodeIfPresent([VRPlacedAssetEntry].self, forKey: .assets) ?? []
        assets = Array(decoded.prefix(Self.maxAssets))
        enforceLimits()
    }
}

struct VRPlacedAssetEntry: Codable, Equatable, Identifiable, Sendable {
    static let minimumScale: Float = 0.1
    static let maximumScale: Float = 5

    var id: String
    var assetId: String
    var position: SIMD3<Float>
    var rotationY: Float
    var uniformScale: Float
    var shadowRadius: Float?
    var shadowOpacity: Float?
    var sortIndex: Int

    init(
        id: String = UUID().uuidString,
        assetId: String,
        position: SIMD3<Float>,
        rotationY: Float = 0,
        uniformScale: Float = 1,
        shadowRadius: Float? = nil,
        shadowOpacity: Float? = nil,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.assetId = assetId
        self.position = position
        self.rotationY = rotationY
        self.uniformScale = Self.clampedScale(uniformScale)
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.sortIndex = sortIndex
    }

    static func clampedScale(_ scale: Float) -> Float {
        min(max(scale, minimumScale), maximumScale)
    }

    mutating func setUniformScale(_ scale: Float) {
        uniformScale = Self.clampedScale(scale)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case assetId
        case position
        case rotationY
        case uniformScale
        case shadowRadius
        case shadowOpacity
        case sortIndex
    }

    private struct Position: Codable {
        var x: Float
        var y: Float
        var z: Float
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        assetId = try container.decode(String.self, forKey: .assetId)
        if let value = try? container.decode(Position.self, forKey: .position) {
            position = SIMD3(value.x, value.y, value.z)
        } else {
            let values = try container.decode([Float].self, forKey: .position)
            guard values.count == 3 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .position,
                    in: container,
                    debugDescription: "Position must contain x, y, z."
                )
            }
            position = SIMD3(values[0], values[1], values[2])
        }
        rotationY = try container.decodeIfPresent(Float.self, forKey: .rotationY) ?? 0
        uniformScale = Self.clampedScale(
            try container.decodeIfPresent(Float.self, forKey: .uniformScale) ?? 1
        )
        shadowRadius = try container.decodeIfPresent(Float.self, forKey: .shadowRadius)
        shadowOpacity = try container.decodeIfPresent(Float.self, forKey: .shadowOpacity)
        sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(assetId, forKey: .assetId)
        try container.encode(
            Position(x: position.x, y: position.y, z: position.z),
            forKey: .position
        )
        try container.encode(rotationY, forKey: .rotationY)
        try container.encode(Self.clampedScale(uniformScale), forKey: .uniformScale)
        try container.encodeIfPresent(shadowRadius, forKey: .shadowRadius)
        try container.encodeIfPresent(shadowOpacity, forKey: .shadowOpacity)
        try container.encode(sortIndex, forKey: .sortIndex)
    }
}

struct MobileAssetDTO: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var thumbUrl: String?
    var usdzStatus: String?
    var usdzUrl: String?
    var glbKey: String?
    var widthCm: Double?
    var heightCm: Double?
    var depthCm: Double?
    var createdAt: String?
    var availableForPlacement: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, thumbUrl, usdzStatus, usdzUrl, glbKey
        case widthCm, heightCm, depthCm, createdAt, availableForPlacement
    }

    init(
        id: String,
        name: String,
        thumbUrl: String? = nil,
        usdzStatus: String? = nil,
        usdzUrl: String? = nil,
        glbKey: String? = nil,
        widthCm: Double? = nil,
        heightCm: Double? = nil,
        depthCm: Double? = nil,
        createdAt: String? = nil,
        availableForPlacement: Bool = false
    ) {
        self.id = id
        self.name = name
        self.thumbUrl = thumbUrl
        self.usdzStatus = usdzStatus
        self.usdzUrl = usdzUrl
        self.glbKey = glbKey
        self.widthCm = widthCm
        self.heightCm = heightCm
        self.depthCm = depthCm
        self.createdAt = createdAt
        self.availableForPlacement = availableForPlacement
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        thumbUrl = try container.decodeIfPresent(String.self, forKey: .thumbUrl)
        usdzStatus = try container.decodeIfPresent(String.self, forKey: .usdzStatus)
        usdzUrl = try container.decodeIfPresent(String.self, forKey: .usdzUrl)
        glbKey = try container.decodeIfPresent(String.self, forKey: .glbKey)
        widthCm = try container.decodeIfPresent(Double.self, forKey: .widthCm)
        heightCm = try container.decodeIfPresent(Double.self, forKey: .heightCm)
        depthCm = try container.decodeIfPresent(Double.self, forKey: .depthCm)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        availableForPlacement =
            try container.decodeIfPresent(Bool.self, forKey: .availableForPlacement) ?? false
    }
}
