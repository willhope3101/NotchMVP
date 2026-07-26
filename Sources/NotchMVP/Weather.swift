import CoreLocation
import Foundation

struct WeatherNow: Equatable {
    var temperature: Double
    var code: Int
    var isDay: Bool

    // WMO weather codes, as used by Open-Meteo.
    var symbol: String {
        switch code {
        case 0:         return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2:      return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3:         return "cloud.fill"
        case 45, 48:    return "cloud.fog.fill"
        case 51...57:   return "cloud.drizzle.fill"
        case 61...65, 80...82: return "cloud.rain.fill"
        case 66, 67:    return "cloud.sleet.fill"
        case 71...77, 85, 86:  return "cloud.snow.fill"
        case 95...99:   return "cloud.bolt.rain.fill"
        default:        return "cloud.fill"
        }
    }

    var summary: String {
        switch code {
        case 0:         return "Trời quang"
        case 1, 2:      return "Ít mây"
        case 3:         return "Nhiều mây"
        case 45, 48:    return "Sương mù"
        case 51...57:   return "Mưa phùn"
        case 61...65:   return "Mưa"
        case 66, 67:    return "Mưa băng"
        case 71...77:   return "Tuyết"
        case 80...82:   return "Mưa rào"
        case 85, 86:    return "Tuyết rơi"
        case 95...99:   return "Dông"
        default:        return ""
        }
    }
}

// Current conditions from Open-Meteo (no API key required), for wherever
// CoreLocation says we are. Without location permission there's no weather to
// show, so the widget simply stays hidden.
final class WeatherService: NSObject, ObservableObject {
    @Published private(set) var current: WeatherNow?

    private let locations = CLLocationManager()
    private var refreshTimer: Timer?
    private var coordinate: CLLocationCoordinate2D?
    // One failed attempt used to mean no weather until the next quarter-hour tick,
    // which is very visible right after a launch: the widget simply isn't there.
    private var retryWork: DispatchWorkItem?
    private var attempt = 0
    private static let retryDelays: [TimeInterval] = [8, 25, 90]

    func start() {
        locations.delegate = self
        locations.desiredAccuracy = kCLLocationAccuracyKilometer
        requestLocation()

        // Conditions don't change fast; a quarter-hour is plenty.
        let t = Timer(timeInterval: 900, repeats: true) { [weak self] _ in
            self?.requestLocation()
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    private func requestLocation() {
        switch locations.authorizationStatus {
        case .notDetermined:
            locations.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            locations.requestLocation()
        default:
            notchDebug("weather: location permission denied")
        }
    }

    // Backs off a few times, then leaves it to the quarter-hour refresh.
    private func scheduleRetry(_ reason: String) {
        guard attempt < Self.retryDelays.count else {
            notchDebug("weather: giving up until next refresh (\(reason))")
            return
        }
        let delay = Self.retryDelays[attempt]
        attempt += 1
        notchDebug("weather: retrying in \(Int(delay))s (\(reason))")
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.requestLocation() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fetch(for coordinate: CLLocationCoordinate2D) {
        let lat = String(format: "%.3f", coordinate.latitude)
        let lon = String(format: "%.3f", coordinate.longitude)
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)"
            + "&current=temperature_2m,weather_code,is_day&timezone=auto"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let data = data else {
                let message = error?.localizedDescription ?? "no data"
                DispatchQueue.main.async { self?.scheduleRetry("fetch failed: \(message)") }
                return
            }
            guard let payload = try? JSONDecoder().decode(Response.self, from: data) else {
                DispatchQueue.main.async { self?.scheduleRetry("unparseable response") }
                return
            }
            let value = WeatherNow(temperature: payload.current.temperature_2m,
                                   code: payload.current.weather_code,
                                   isDay: payload.current.is_day == 1)
            DispatchQueue.main.async {
                self?.attempt = 0
                self?.current = value
                notchDebug("weather: \(Int(value.temperature))° code=\(value.code) day=\(value.isDay)")
            }
        }.resume()
    }

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int
        }
        let current: Current
    }
}

extension WeatherService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        coordinate = location.coordinate
        fetch(for: location.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep showing the last reading rather than blanking the widget, and try
        // again shortly — a failure right after launch is common.
        if let coordinate = coordinate {
            fetch(for: coordinate)
        } else {
            scheduleRetry("location failed: \(error.localizedDescription)")
        }
    }
}
