import CoreLocation
import Foundation

/// The signed-in person's manager rights, as the SERVER reports them. Nothing local can raise them: if the request
/// fails the person is a customer.
@MainActor
final class StoreShelfRoleModel: ObservableObject {
    static let shared = StoreShelfRoleModel()

    @Published private(set) var access: StoreShelfAccess = .customer
    @Published private(set) var managedStores: [RemoteManagedStore] = []

    private let api = StoreShelfAPIClient()
    private var lastToken: String?

    func refresh() async {
        let token = MobileAuthTokenStore.shared.getAccessToken()
        guard token != nil else {
            access = .customer
            managedStores = []
            lastToken = nil
            return
        }
        do {
            let stores = try await api.myStores().filter { $0.status == "ACTIVE" }
            managedStores = stores
            access = StoreShelfAccess(managedStoreIds: Set(stores.map(\.id)))
            lastToken = token
        } catch {
            access = .customer
            managedStores = []
        }
    }
}

/// One-shot "when in use" location for choosing a nearby store. A denied permission is an ordinary outcome: the store
/// list can always be searched by name.
@MainActor
final class StoreShelfLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case idle
        case requesting
        case located(latitude: Double, longitude: Double)
        case denied
        case failed
    }

    @Published private(set) var state: State = .idle
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func request() {
        switch manager.authorizationStatus {
        case .notDetermined:
            state = .requesting
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            state = .denied
        default:
            state = .requesting
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .denied, .restricted: self.state = .denied
            case .authorizedWhenInUse, .authorizedAlways:
                if self.state == .requesting { self.manager.requestLocation() }
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let lat = l.coordinate.latitude, lng = l.coordinate.longitude
        Task { @MainActor in self.state = .located(latitude: lat, longitude: lng) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.state = .failed }
    }
}
