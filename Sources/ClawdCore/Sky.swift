import Foundation

// Sky and weather rules ported from the Windows widget's lib/weather.ps1 and
// lib/sky.ps1 (MIT, see THIRD_PARTY_NOTICES). Pure: no drawing, no network.

public struct RGBA: Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    /// "#AARRGGBB" or "#RRGGBB", as in WPF.
    public init(_ hex: String) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 6 { s = "FF" + s }
        let v = UInt32(s, radix: 16) ?? 0
        a = Double((v >> 24) & 255) / 255; r = Double((v >> 16) & 255) / 255
        g = Double((v >> 8) & 255) / 255; b = Double(v & 255) / 255
    }
    public static func mix(_ a: RGBA, _ b: RGBA, _ k: Double) -> RGBA {
        let k = min(1, max(0, k))
        return RGBA(r: a.r + (b.r - a.r) * k, g: a.g + (b.g - a.g) * k, b: a.b + (b.b - a.b) * k, a: a.a + (b.a - a.a) * k)
    }
    /// Cloudiness: the color fades toward gray and darkens.
    public func dimmed(_ g: Double) -> RGBA {
        let l = 0.3 * r + 0.59 * self.g + 0.11 * b
        let f = 1 - 0.3 * g
        return RGBA(r: (r + (l - r) * g) * f, g: (self.g + (l - self.g) * g) * f, b: (b + (l - b) * g) * f, a: a)
    }
    public func opacity(_ o: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: a * o) }
}

/// WMO weather code groups. rain/snow: drops or flakes at medium intensity;
/// three codes in a group are light, moderate and heavy.
public struct WeatherKind: Equatable, Sendable {
    public var id: String
    public var name: String
    public var cover: Double
    public var fog = false
    public var storm = false
    public var rain = 0
    public var snow = 0

    static let table: [(codes: [Int], id: String, name: String, cover: Double, fog: Bool, storm: Bool, rain: Int, snow: Int)] = [
        ([0], "clear", "clear", 0.0, false, false, 0, 0),
        ([1], "mostlyClear", "mostly clear", 0.2, false, false, 0, 0),
        ([2], "partly", "partly cloudy", 0.5, false, false, 0, 0),
        ([3], "overcast", "overcast", 0.85, false, false, 0, 0),
        ([45, 48], "fog", "fog", 0.7, true, false, 0, 0),
        ([51, 53, 55], "drizzle", "drizzle", 0.8, false, false, 6, 0),
        ([56, 57], "iceDrizzle", "freezing drizzle", 0.8, false, false, 6, 0),
        ([61, 63, 65], "rain", "rain", 0.9, false, false, 12, 0),
        ([66, 67], "iceRain", "freezing rain", 0.9, false, false, 12, 0),
        ([71, 73, 75], "snow", "snow", 0.85, false, false, 0, 10),
        ([77], "grains", "snow grains", 0.85, false, false, 0, 8),
        ([80, 81, 82], "showers", "rain showers", 0.85, false, false, 16, 0),
        ([85, 86], "snowShowers", "snow showers", 0.9, false, false, 0, 14),
        ([95, 96, 99], "storm", "thunderstorm", 1.0, false, true, 16, 0)
    ]
    /// Codes worth previewing from the developer menu, in display order.
    public static let previewCodes: [(code: Int, name: String)] = table.map { ($0.codes[$0.codes.count / 2], $0.name) }

    public static func resolve(code: Int) -> WeatherKind {
        for k in table {
            guard let i = k.codes.firstIndex(of: code) else { continue }
            let mul = k.codes.count == 3 ? [0.6, 1.0, 1.35][i] : 1.0
            return WeatherKind(id: k.id, name: k.name, cover: k.cover, fog: k.fog, storm: k.storm,
                               rain: Int((Double(k.rain) * mul).rounded()), snow: Int((Double(k.snow) * mul).rounded()))
        }
        return WeatherKind(id: "code", name: "code \(code)", cover: 0.5)
    }
}

/// met.no describes weather with a word: "lightrainshowers_day" -> WMO code.
public enum MetNo {
    public static func code(symbol: String) -> Int {
        let sym = symbol.replacingOccurrences(of: "_(day|night|polartwilight)$", with: "", options: .regularExpression)
        let lvl = sym.hasPrefix("light") ? 0 : sym.hasPrefix("heavy") ? 2 : 1
        let shw = sym.contains("showers")
        if sym.contains("thunder") { return 95 }
        if sym.contains("snow") { return shw ? [85, 85, 86][lvl] : [71, 73, 75][lvl] }
        if sym.contains("sleet") { return lvl == 2 ? 67 : 66 }
        if sym.contains("rain") { return shw ? [80, 81, 82][lvl] : [61, 63, 65][lvl] }
        if sym.hasPrefix("fog") { return 45 }
        if sym.hasPrefix("cloudy") { return 3 }
        if sym.hasPrefix("partlycloudy") { return 2 }
        if sym.hasPrefix("fair") { return 1 }
        if sym.hasPrefix("clearsky") { return 0 }
        return 3
    }
}

/// Sunrise and sunset from coordinates (NOAA formulas), local time, minutes from midnight.
public enum SunCalc {
    public static func times(lat: Double, lon: Double, date: Date = .now, timeZone: TimeZone = .current) -> (sr: Double, ss: Double) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let doy = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 1)
        let gm = 2 * Double.pi / 365 * (doy - 0.5)
        let eq = 229.18 * (0.000075 + 0.001868 * cos(gm) - 0.032077 * sin(gm) - 0.014615 * cos(2 * gm) - 0.040849 * sin(2 * gm))
        let dec = 0.006918 - 0.399912 * cos(gm) + 0.070257 * sin(gm) - 0.006758 * cos(2 * gm) + 0.000907 * sin(2 * gm)
            - 0.002697 * cos(3 * gm) + 0.00148 * sin(3 * gm)
        let la = lat * Double.pi / 180
        var c = cos(90.833 * Double.pi / 180) / (cos(la) * cos(dec)) - tan(la) * tan(dec)
        c = max(-0.999, min(0.999, c))   // polar day or night: the sun never sets or never rises
        let ha = acos(c) * 180 / Double.pi
        let tz = Double(timeZone.secondsFromGMT(for: date)) / 60
        func wrap(_ m: Double) -> Double { ((m.truncatingRemainder(dividingBy: 1440)) + 1440).truncatingRemainder(dividingBy: 1440) }
        return (wrap(720 - 4 * (lon + ha) - eq + tz), wrap(720 - 4 * (lon - ha) - eq + tz))
    }
}

public enum SkyPhase: String, CaseIterable, Sendable { case dawn, day, dusk, night }

public enum SkyPalette {
    struct Phase { let top: RGBA; let bottom: RGBA; let light: Double }
    static let phases: [SkyPhase: Phase] = [
        .night: Phase(top: RGBA("#00304A8C"), bottom: RGBA("#1A304A8C"), light: 0.0),
        .dawn: Phase(top: RGBA("#00404E8A"), bottom: RGBA("#33E08A66"), light: 0.5),
        .day: Phase(top: RGBA("#004A8CCB"), bottom: RGBA("#2E6FA8D8"), light: 1.0),
        .dusk: Phase(top: RGBA("#00383070"), bottom: RGBA("#33D86A50"), light: 0.5)
    ]
    public static let sunHigh = RGBA("#FFFDE68A"), sunLow = RGBA("#FFFB923C")
    public static let snowDay = RGBA("#80DDE4EC"), snowNight = RGBA("#50A1A8B5")
    public static let cloudDay = RGBA("#FFB4B4BC"), cloudNight = RGBA("#FF5E5E68"), cloudRain = RGBA("#FF52525B")

    /// Sky gradient for minute `t` of the day given sunrise/sunset minutes and cloud cover.
    public static func blend(minute t: Double, sunrise sr: Double, sunset ss: Double, cover: Double) -> (top: RGBA, bottom: RGBA, light: Double) {
        let stops: [(Double, SkyPhase)] = [(sr - 80, .night), (sr - 10, .dawn), (sr + 70, .day), (ss - 70, .day), (ss + 10, .dusk), (ss + 80, .night)]
        var a = phases[.night]!, b = phases[.night]!, k = 0.0
        for i in 0..<(stops.count - 1) where t >= stops[i].0 && t < stops[i + 1].0 {
            a = phases[stops[i].1]!; b = phases[stops[i + 1].1]!
            k = (t - stops[i].0) / (stops[i + 1].0 - stops[i].0)
            break
        }
        let g = cover * 0.9
        return (RGBA.mix(a.top, b.top, k).dimmed(g), RGBA.mix(a.bottom, b.bottom, k).dimmed(g), a.light + (b.light - a.light) * k)
    }

    /// Minute of day to show for a forced phase.
    public static func minute(for phase: SkyPhase, sunrise sr: Double, sunset ss: Double) -> Double {
        switch phase {
        case .dawn: return sr - 10
        case .day: return (sr + ss) / 2
        case .dusk: return ss + 10
        case .night: return 0
        }
    }
}

/// Moon phase from the mean synodic month since the new moon of January 6, 2000.
/// A pixel is lit if it is on the bright side of the terminator u = cos(θ)·√(1-v²).
public enum MoonPhase {
    public static let period = 29.530588853
    public static func age(at date: Date = .now) -> Double {
        let epoch = Date(timeIntervalSince1970: 947_182_440)   // 2000-01-06 18:14 UTC
        let days = date.timeIntervalSince(epoch) / 86400
        return ((days.truncatingRemainder(dividingBy: period)) + period).truncatingRemainder(dividingBy: period)
    }
    /// 7x7 pixel rows for the lit and the dark parts; south of the equator the waxing moon is on the left.
    public static func pixels(age: Double, southern: Bool) -> (lit: [String], dark: [String]) {
        let th = 2 * Double.pi * age / period
        let k = cos(th)
        let n = 7, r = 3.5
        var lit: [String] = [], dark: [String] = []
        for y in 0..<n {
            var a = "", b = ""
            for x in 0..<n {
                var u = (Double(x) + 0.5 - r) / r
                let v = (Double(y) + 0.5 - r) / r
                if southern { u = -u }
                let inside = u * u + v * v <= 1.05
                let t = k * sqrt(max(0, 1 - v * v))
                let on = inside && (th < Double.pi ? u > t : u < -t)
                a += on ? "#" : "."
                b += inside && !on ? "#" : "."
            }
            lit.append(a); dark.append(b)
        }
        return (lit, dark)
    }
}

/// Runs of "#" in pixel-art rows, merged into rectangles of unit pixels.
public func pixelRects(_ rows: [String], on: Character = "#") -> [PixelRect] {
    var out: [PixelRect] = []
    for (y, row) in rows.enumerated() {
        let chars = Array(row)
        var x = 0
        while x < chars.count {
            if chars[x] != on { x += 1; continue }
            let x0 = x
            while x < chars.count && chars[x] == on { x += 1 }
            out.append(PixelRect(Double(x0), Double(y), Double(x - x0), 1))
        }
    }
    return out
}

/// "2d 10h", "4h 24m", "7m"; nil once the moment has passed.
public func spanText(until date: Date, now: Date = .now) -> String? {
    let seconds = date.timeIntervalSince(now)
    if seconds <= 0 { return nil }
    let minutes = Int(seconds / 60)
    if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
    if minutes >= 60 { return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" }
    return "\(minutes)m"
}
