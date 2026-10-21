import Foundation
import ClawdCore

// Weather for the sky behind the mascot, as in the Windows widget: Open-Meteo
// (no key), met.no when Open-Meteo does not answer, location from the settings
// or once per run by IP via ipwho.is. Nothing here is required for usage data.

struct WeatherReport: Sendable {
    var code: Int
    var temp: Double
    var wind: Double          // km/h
    var sunrise: Double?      // minutes from local midnight
    var sunset: Double?
    var at: Date
}

struct WeatherPlace: Sendable, Equatable {
    var lat: Double
    var lon: Double
    var city: String?
}

/// A city found by name in Settings: "Warsaw · Mazovia, Poland".
struct PlaceMatch: Sendable, Identifiable, Equatable {
    var id: Int
    var name: String
    var region: String?
    var country: String?
    var lat: Double
    var lon: Double

    var detail: String { [region, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") }
    var label: String { detail.isEmpty ? name : "\(name) · \(detail)" }
}

/// City search for Settings, through Open-Meteo's geocoding API (no key). The free
/// service is shared, so the caller waits for a pause in typing, and every answer is
/// kept: the same text is never asked twice in a run.
@MainActor
enum PlaceSearch {
    static let minLength = 3
    private static var cache: [String: [PlaceMatch]] = [:]

    /// nil when the service could not be reached (or the search was cancelled).
    static func find(_ text: String) async -> [PlaceMatch]? {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard query.count >= minLength else { return [] }
        if let hit = cache[query] { return hit }
        var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        url.queryItems = [.init(name: "name", value: query), .init(name: "count", value: "8"),
                          .init(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
                          .init(name: "format", value: "json")]
        guard let j = await WeatherService.json(url.url!.absoluteString) else { return nil }
        // No "results" key at all means nothing was found.
        let found = ((j["results"] as? [[String: Any]]) ?? []).compactMap { r -> PlaceMatch? in
            guard let id = r["id"] as? Int, let name = r["name"] as? String,
                  let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else { return nil }
            return PlaceMatch(id: id, name: name, region: r["admin1"] as? String, country: r["country"] as? String, lat: lat, lon: lon)
        }
        cache[query] = found
        return found
    }
}

@MainActor
final class WeatherService: ObservableObject {
    @Published private(set) var report: WeatherReport?
    @Published private(set) var geo: WeatherPlace?
    var configured: WeatherPlace? {
        didSet { if configured != oldValue { wxTry = .distantPast } }
    }
    static let interval: TimeInterval = 900
    private var useMetNo = false
    private var geoTry = Date.distantPast
    private var wxTry = Date.distantPast
    private var fetching = false

    var place: WeatherPlace? { configured ?? geo }

    /// Weather to draw: fresh (no older than 3 hours) or nothing.
    var current: WeatherReport? {
        guard let report, Date().timeIntervalSince(report.at) < 3 * 3600 else { return nil }
        return report
    }

    func sunTimes(now: Date = .now) -> (sr: Double, ss: Double) {
        if let report, let sr = report.sunrise, let ss = report.sunset { return (sr, ss) }
        if let place { return SunCalc.times(lat: place.lat, lon: place.lon, date: now) }
        return (420, 1140)
    }

    func setDemo(_ report: WeatherReport, place: WeatherPlace) { self.report = report; geo = place }

    /// Called every few seconds; fetches only when due.
    func poll() async {
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }
        if place == nil {
            // No coordinates: first find the location by IP, then ask for the weather right away.
            guard Date().timeIntervalSince(geoTry) >= 600 else { return }
            geoTry = .now
            guard let found = await Self.locate() else { return }
            geo = found; wxTry = .distantPast
        }
        guard let place else { return }
        guard Date().timeIntervalSince(wxTry) >= Self.interval else { return }
        wxTry = .now
        if useMetNo {
            if let r = await Self.fetchMetNo(place) { report = r }
            return
        }
        if let r = await Self.fetchOpenMeteo(place) { report = r }
        else {
            // Open-Meteo is unreachable (sometimes blocked): ask met.no from now on.
            useMetNo = true
            if let r = await Self.fetchMetNo(place) { report = r }
        }
    }

    /// "City · +12°, partly cloudy", wind and sun times, for the sky tooltip.
    func tip(force: String?) -> String {
        var parts: [String] = []
        if let force { parts.append("dev · \(force)") }
        else if let wx = current {
            let temp = Int(wx.temp.rounded())
            var line = "\(temp > 0 ? "+" : "")\(temp)°, \(WeatherKind.resolve(code: wx.code).name)"
            if let city = place?.city, !city.isEmpty { line = "\(city) · \(line)" }
            parts.append(line)
            parts.append("wind \(Int((wx.wind / 3.6).rounded())) m/s")
        } else { parts.append("weather: no data") }
        let st = sunTimes()
        func clock(_ m: Double) -> String { String(format: "%02d:%02d", Int(m) / 60, Int(m) % 60) }
        parts.append("sunrise \(clock(st.sr)) · sunset \(clock(st.ss))")
        return parts.joined(separator: "\n")
    }

    // MARK: network

    static func json(_ url: String) async -> [String: Any]? {
        guard let u = URL(string: url) else { return nil }
        var request = URLRequest(url: u)
        request.timeoutInterval = 15
        request.setValue("clawd-mac (clawd-usage-winwidget port)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func locate() async -> WeatherPlace? {
        guard let j = await json("https://ipwho.is/?lang=en"), (j["success"] as? Bool) != false,
              let lat = j["latitude"] as? Double, let lon = j["longitude"] as? Double else { return nil }
        return WeatherPlace(lat: lat, lon: lon, city: j["city"] as? String)
    }

    private static func fetchOpenMeteo(_ place: WeatherPlace) async -> WeatherReport? {
        let url = "https://api.open-meteo.com/v1/forecast?latitude=\(place.lat)&longitude=\(place.lon)"
            + "&current=weather_code,temperature_2m,wind_speed_10m&daily=sunrise,sunset&forecast_days=1"
            // Sunrise and sunset in this Mac's time zone, the clock the sky is drawn by
            // (timezone=auto would give the location's, off for coordinates elsewhere).
            + "&timezone=\(TimeZone.current.identifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "auto")"
        guard let j = await json(url), let cur = j["current"] as? [String: Any],
              let code = cur["weather_code"] as? Int else { return nil }
        var wx = WeatherReport(code: code, temp: cur["temperature_2m"] as? Double ?? 0,
                               wind: cur["wind_speed_10m"] as? Double ?? 0, sunrise: nil, sunset: nil, at: .now)
        // Local time; only the hour and minute are needed.
        if let daily = j["daily"] as? [String: Any] {
            wx.sunrise = minutes((daily["sunrise"] as? [String])?.first)
            wx.sunset = minutes((daily["sunset"] as? [String])?.first)
        }
        return wx
    }

    private static func minutes(_ stamp: String?) -> Double? {
        guard let stamp, let t = stamp.split(separator: "T").last else { return nil }
        let hm = t.split(separator: ":").compactMap { Int($0) }
        guard hm.count >= 2 else { return nil }
        return Double(hm[0] * 60 + hm[1])
    }

    private static func fetchMetNo(_ place: WeatherPlace) async -> WeatherReport? {
        let url = String(format: "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=%.4f&lon=%.4f", place.lat, place.lon)
        guard let j = await json(url), let props = j["properties"] as? [String: Any],
              let series = (props["timeseries"] as? [[String: Any]])?.first,
              let data = series["data"] as? [String: Any] else { return nil }
        let details = ((data["instant"] as? [String: Any])?["details"] as? [String: Any]) ?? [:]
        let symbol = (((data["next_1_hours"] as? [String: Any])?["summary"] as? [String: Any])?["symbol_code"] as? String) ?? ""
        return WeatherReport(code: MetNo.code(symbol: symbol), temp: details["air_temperature"] as? Double ?? 0,
                             wind: 3.6 * (details["wind_speed"] as? Double ?? 0), sunrise: nil, sunset: nil, at: .now)
    }
}
