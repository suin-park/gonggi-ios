import CoreLocation
import Foundation

enum SpaceMetadataDateParser {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let standard = ISO8601DateFormatter()

    static func date(_ value: String) -> Date? {
        fractional.date(from: value) ?? standard.date(from: value)
    }

    static func string(_ date: Date) -> String {
        fractional.string(from: date)
    }
}

enum SpaceDetailMetadataValidationError: Error, Equatable {
    case emptyName
    case nameTooLong
    case memoTooLong
    case emptyLocationName
    case locationNameTooLong
}

enum SpaceDetailMetadataValidator {
    static func title(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpaceDetailMetadataValidationError.emptyName }
        guard trimmed.count <= 60 else { throw SpaceDetailMetadataValidationError.nameTooLong }
        return trimmed
    }

    static func memo(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 1_000 else { throw SpaceDetailMetadataValidationError.memoTooLong }
        return trimmed.isEmpty ? nil : trimmed
    }

    static func locationName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SpaceDetailMetadataValidationError.emptyLocationName
        }
        guard trimmed.count <= 100 else {
            throw SpaceDetailMetadataValidationError.locationNameTooLong
        }
        return trimmed
    }
}

enum SpaceCaptureLocationPreferences {
    private static let prefix = "gonggi.captureLocationAuto.v1."

    static func storageKey(userId: String) -> String {
        prefix + userId
    }

    static func isEnabled(userId: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let userId, !userId.isEmpty else { return false }
        return defaults.bool(forKey: storageKey(userId: userId))
    }

    static func setEnabled(
        _ enabled: Bool,
        userId: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let userId, !userId.isEmpty else { return }
        defaults.set(enabled, forKey: storageKey(userId: userId))
    }

    static func clear(userId: String?, defaults: UserDefaults = .standard) {
        guard let userId, !userId.isEmpty else { return }
        defaults.removeObject(forKey: storageKey(userId: userId))
    }

    static func resetForTesting(userIds: [String], defaults: UserDefaults = .standard) {
        userIds.forEach { defaults.removeObject(forKey: storageKey(userId: $0)) }
    }
}

struct SpaceOneShotLocationResult: Equatable {
    let latitude: Double
    let longitude: Double
    let capturedAt: Date
}

enum SpaceOneShotLocationError: Error {
    case permissionDenied
    case unavailable
    case stale
    case inaccurate
}

/// Foreground-only, single-request Core Location helper.
@MainActor
final class SpaceOneShotLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<SpaceOneShotLocationResult, Error>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func request() async throws -> SpaceOneShotLocationResult {
        guard continuation == nil else { throw SpaceOneShotLocationError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(SpaceOneShotLocationError.unavailable))
            }
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .denied, .restricted:
                finish(.failure(SpaceOneShotLocationError.permissionDenied))
            @unknown default:
                finish(.failure(SpaceOneShotLocationError.unavailable))
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(SpaceOneShotLocationError.permissionDenied))
        case .notDetermined:
            break
        @unknown default:
            finish(.failure(SpaceOneShotLocationError.unavailable))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finish(.failure(SpaceOneShotLocationError.unavailable))
            return
        }
        guard Date().timeIntervalSince(location.timestamp) <= 120 else {
            finish(.failure(SpaceOneShotLocationError.stale))
            return
        }
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100 else {
            finish(.failure(SpaceOneShotLocationError.inaccurate))
            return
        }
        finish(.success(SpaceOneShotLocationResult(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            capturedAt: location.timestamp
        )))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(SpaceOneShotLocationError.unavailable))
    }

    private func finish(_ result: Result<SpaceOneShotLocationResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }
}
