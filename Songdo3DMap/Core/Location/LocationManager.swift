import Foundation
import CoreLocation
import Combine

/// GPS 위치 관리자
@MainActor
final class LocationManager: NSObject, ObservableObject {

    // MARK: - Published Properties

    @Published var currentLocation: CLLocation?
    @Published var localPosition: SIMD3<Float>?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    // MARK: - Private Properties

    private let locationManager = CLLocationManager()
    private let coordinator: CoordinateConverter

    // MARK: - Initialization

    override init() {
        self.coordinator = CoordinateConverter()
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5  // 5미터마다 업데이트
    }

    // MARK: - Public Methods

    func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        locationManager.startUpdatingLocation()
    }

    func stopUpdating() {
        locationManager.stopUpdatingLocation()
    }

    // MARK: - Private Methods

    private func handleLocationUpdate(_ location: CLLocation) {
        currentLocation = location
        localPosition = coordinator.gpsToLocal(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
    }

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        authorizationStatus = status

        if status == .authorizedWhenInUse || status == .authorizedAlways {
            startUpdating()
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let loc = CLLocation(latitude: latitude, longitude: longitude)
            self.handleLocationUpdate(loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus

        Task { @MainActor [weak self] in
            self?.handleAuthorizationChange(status)
        }
    }
}

// MARK: - Coordinate Converter

struct CoordinateConverter {

    // 송도 기준점 (index.json origin과 동일)
    static let originLatitude: Double = 37.355
    static let originLongitude: Double = 126.615

    // 미터 변환 상수
    static let latToMeters: Double = 111000.0
    static let lonToMeters: Double = 111000.0 * cos(37.39 * .pi / 180.0)

    /// GPS 좌표를 로컬 좌표로 변환
    func gpsToLocal(latitude: Double, longitude: Double) -> SIMD3<Float> {
        let x = Float((longitude - Self.originLongitude) * Self.lonToMeters)
        let z = Float((latitude - Self.originLatitude) * Self.latToMeters)
        return SIMD3<Float>(x, 0, z)
    }

    /// 로컬 좌표를 GPS 좌표로 변환
    func localToGPS(x: Float, z: Float) -> (latitude: Double, longitude: Double) {
        let longitude = Self.originLongitude + Double(x) / Self.lonToMeters
        let latitude = Self.originLatitude + Double(z) / Self.latToMeters
        return (latitude, longitude)
    }
}
