import Foundation
import OSLog

/// Maps client-side capture *guide* identity to server video-gaussian `qualityProfile`.
///
/// Backend source of truth (`whik/apps/cloud/src/lib/video-gaussian/runpodSubmit.ts`):
/// Mainline (product): `fullres_max`, `fullres_max_raw`, `fullres_dense_d1`, `capture_dense_v2`,
/// `spatial_package_v1`, `spatial_package_v2`, `spatial_package_colmap_fastergs_native_v1`
/// Default product profile: `capture_dense_v2`
/// Experimental (admin): `capture_quality_v1`, `geometry_stable_v1`
///
/// Client guide ids such as `capture_default_p1` are **not** server profiles.
enum ServerGenerationProfileMapper {
    /// Product default — matches `VIDEO_GAUSSIAN_DEFAULT_PROFILE`.
    static let defaultServerProfile = "capture_dense_v2"

    /// 3D 공간 기록 (formal, build 72+): official native Faster-GS without the 3D filter.
    /// The server runs exactly this profile or fails with `NATIVE_UNAVAILABLE` (never gsplat).
    static let spatialPackageProfile = "spatial_package_colmap_fastergs_native_v1"
    /// Build ≤71 spatial request (server resolves it to its product default).
    static let legacySpatialPackageV1Profile = "spatial_package_v1"
    static let spatialPackageColmapV2Profile = "spatial_package_colmap_v2"
    static let spatialPackageVggtV1Profile = "spatial_package_vggt_v1"
    static let spatialPackageHybridV1Profile = "spatial_package_hybrid_v1"
    static let spatialPackageColmapFasterGsV1Profile = "spatial_package_colmap_fastergs_v1"
    static let spatialPackageVggtFasterGsV1Profile = "spatial_package_vggt_fastergs_v1"

    /// Mainline allowlist (non-admin create path).
    static let mainlineServerProfiles: Set<String> = [
        "fullres_max",
        "fullres_max_raw",
        "fullres_dense_d1",
        "capture_dense_v2",
        "spatial_package_v1",
        "spatial_package_v2",
        spatialPackageProfile,
    ]

    /// Experiment allowlist (admin / internal tools / same-ZIP matrix).
    static let experimentalSpatialProfiles: Set<String> = [
        spatialPackageColmapV2Profile,
        spatialPackageVggtV1Profile,
        spatialPackageHybridV1Profile,
        spatialPackageColmapFasterGsV1Profile,
        spatialPackageVggtFasterGsV1Profile,
    ]

    private static let log = Logger(subsystem: "com.whik.gonggi", category: "GenerationProfile")

    /// Resolve the profile to send on create. Spatial package never falls back to dense video.
    static func resolveServerProfile(
        guideQualityProfile: String?,
        fallback: String = defaultServerProfile
    ) -> String {
        let trimmed = guideQualityProfile?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return sanitize(fallback)
        }
        if trimmed == spatialPackageProfile {
            return spatialPackageProfile
        }
        if experimentalSpatialProfiles.contains(trimmed) {
            return trimmed
        }
        // Explicit client guide identities → product dense walk-through.
        if trimmed == "capture_default_p1" || trimmed.hasPrefix("guide_") {
            log.info("mapped guide profile \(trimmed, privacy: .public) → \(defaultServerProfile, privacy: .public)")
            return defaultServerProfile
        }
        if mainlineServerProfiles.contains(trimmed) {
            return trimmed
        }
        log.error(
            "unknown generation profile \(trimmed, privacy: .public); falling back to \(defaultServerProfile, privacy: .public)"
        )
        return defaultServerProfile
    }

    static func sanitize(_ profile: String) -> String {
        let trimmed = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == spatialPackageProfile { return spatialPackageProfile }
        if experimentalSpatialProfiles.contains(trimmed) { return trimmed }
        if mainlineServerProfiles.contains(trimmed) { return trimmed }
        return defaultServerProfile
    }

    static func resolve(from guidePlan: AdvancedCaptureGuidePlan?) -> String {
        resolveServerProfile(guideQualityProfile: guidePlan?.qualityProfile)
    }
}
