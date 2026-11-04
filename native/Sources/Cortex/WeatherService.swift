import Foundation
import CoreLocation

struct WeatherNow: Equatable {
    var temperature: Double
    var code: Int
    var isDay: Bool
    var high: Double
    var low: Double
    var place: String

    var symbol: String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    var summary: String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67, 80...82: return "Rain"
        case 71...77, 85, 86: return "Snow"
        case 95...99: return "Thunderstorm"
        default: return "Cloudy"
        }
    }
}

/// Weather from Open-Meteo (free, no key). Location from CoreLocation, falling back to your IP address.
@MainActor
final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherService()

    @Published private(set) var weather: WeatherNow?
    @Published private(set) var status = "Loading…"
    private let manager = CLLocationManager()
    private var timer: Timer?
    private var lastLocation: CLLocation?
    private var watchers = 0

    func watch() {
        watchers += 1
        guard timer == nil else { return }
        manager.delegate = self
        locate()
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.locate() }
        }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { timer?.invalidate(); timer = nil }
    }

    private func locate() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways: manager.requestLocation()
        default: Task { await fallbackLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.lastLocation = loc
            await self.fetch(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, place: nil)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in await self.fallbackLocation() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.locate() }
    }

    private func fallbackLocation() async {
        guard let url = URL(string: "https://ipwho.is/"), let (data, _) = try? await URLSession.shared.data(from: url),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let lat = (o["latitude"] as? NSNumber)?.doubleValue, let lon = (o["longitude"] as? NSNumber)?.doubleValue else {
            status = "Weather unavailable"; return
        }
        await fetch(lat: lat, lon: lon, place: o["city"] as? String)
    }

    private func fetch(lat: Double, lon: Double, place: String?) async {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)), URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"), URLQueryItem(name: "forecast_days", value: "1"),
        ]
        guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cur = o["current"] as? [String: Any], let t = (cur["temperature_2m"] as? NSNumber)?.doubleValue else { status = "Weather unavailable"; return }
        let daily = o["daily"] as? [String: Any]
        let hi = ((daily?["temperature_2m_max"] as? [NSNumber])?.first)?.doubleValue ?? t
        let lo = ((daily?["temperature_2m_min"] as? [NSNumber])?.first)?.doubleValue ?? t
        var name = place ?? ""
        if name.isEmpty, let loc = lastLocation, let p = try? await CLGeocoder().reverseGeocodeLocation(loc).first { name = p.locality ?? p.name ?? "" }
        weather = WeatherNow(temperature: t, code: (cur["weather_code"] as? NSNumber)?.intValue ?? 3,
                             isDay: ((cur["is_day"] as? NSNumber)?.intValue ?? 1) == 1, high: hi, low: lo, place: name)
        status = ""
    }
}
