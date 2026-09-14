import Foundation

enum CatalogPlacementSpecValidationError: Error, Equatable, LocalizedError {
    case unsupportedContractVersion(Int)
    case unsupportedCoordinateConvention(String)
    case unsupportedPlacementType
    case missingPlacementSpec
    case invalidDimensions
    case invalidQuaternion
    case invalidScale
    case invalidCanonicalBounds
    case invalidSignedURL
    case nanOrInfinity

    var errorDescription: String? {
        switch self {
        case .unsupportedContractVersion:
            return "지원하지 않는 배치 계약 버전이에요"
        case .unsupportedCoordinateConvention:
            return "지원하지 않는 좌표계예요"
        case .unsupportedPlacementType:
            return "이 상품은 아직 공간에 배치할 수 없어요"
        case .missingPlacementSpec:
            return "배치 정보가 준비되지 않았어요"
        case .invalidDimensions:
            return "상품 치수가 올바르지 않아요"
        case .invalidQuaternion:
            return "배치 회전 값이 올바르지 않아요"
        case .invalidScale:
            return "배치 스케일이 올바르지 않아요"
        case .invalidCanonicalBounds:
            return "배치 경계 정보가 올바르지 않아요"
        case .invalidSignedURL:
            return "3D 파일 주소를 확인할 수 없어요"
        case .nanOrInfinity:
            return "배치 수치에 오류가 있어요"
        }
    }
}

enum CatalogPlacementSpecValidator {
    static func validate(_ spec: CatalogPlacementSpec?) -> Result<CatalogPlacementSpec, CatalogPlacementSpecValidationError> {
        guard let spec else { return .failure(.missingPlacementSpec) }
        guard spec.contractVersion == CatalogPlacementSpec.supportedContractVersion else {
            return .failure(.unsupportedContractVersion(spec.contractVersion))
        }
        guard spec.coordinateConvention == CatalogPlacementSpec.supportedCoordinateConvention else {
            return .failure(.unsupportedCoordinateConvention(spec.coordinateConvention))
        }
        guard spec.placementType.isSupportedForPlacement else {
            return .failure(.unsupportedPlacementType)
        }
        guard spec.dimensionsMm.isValid else { return .failure(.invalidDimensions) }
        guard isFiniteQuaternion(spec.orientation) else { return .failure(.invalidQuaternion) }
        guard isValidScale(spec.scaleX), isValidScale(spec.scaleY), isValidScale(spec.scaleZ) else {
            return .failure(.invalidScale)
        }
        guard Number.isFinite(spec.bottomOffsetMeters) else { return .failure(.nanOrInfinity) }
        guard isValidBounds(spec.canonicalBounds) else { return .failure(.invalidCanonicalBounds) }
        guard spec.usdzSignedUrl.hasPrefix("https://") else { return .failure(.invalidSignedURL) }
        guard !spec.catalogAssetId.isEmpty, !spec.catalogOwnedAssetId.isEmpty else {
            return .failure(.missingPlacementSpec)
        }
        // Canonical size should match product dims within loose tolerance (admin-approved).
        let bw = spec.canonicalBounds.max.x - spec.canonicalBounds.min.x
        let bh = spec.canonicalBounds.max.y - spec.canonicalBounds.min.y
        let bd = spec.canonicalBounds.max.z - spec.canonicalBounds.min.z
        let ew = Double(spec.dimensionsMm.widthMm) / 1000
        let eh = Double(spec.dimensionsMm.heightMm) / 1000
        let ed = Double(spec.dimensionsMm.depthMm) / 1000
        let tol = 0.06
        if abs(bw - ew) > ew * tol + 1e-6
            || abs(bh - eh) > eh * tol + 1e-6
            || abs(bd - ed) > ed * tol + 1e-6 {
            return .failure(.invalidCanonicalBounds)
        }
        return .success(spec)
    }

    private static func isValidScale(_ s: Double) -> Bool {
        Number.isFinite(s) && s > 0 && s < 1000
    }

    private static func isFiniteQuaternion(_ q: CatalogQuaternion) -> Bool {
        let vals = [q.x, q.y, q.z, q.w]
        guard vals.allSatisfy(Number.isFinite) else { return false }
        let n2 = q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w
        return n2 > 1e-12
    }

    private static func isValidBounds(_ b: CatalogCanonicalBounds) -> Bool {
        let vals = [b.min.x, b.min.y, b.min.z, b.max.x, b.max.y, b.max.z]
        guard vals.allSatisfy(Number.isFinite) else { return false }
        return b.max.x > b.min.x && b.max.y > b.min.y && b.max.z > b.min.z
    }
}

private enum Number {
    static func isFinite(_ v: Double) -> Bool { v.isFinite }
}
