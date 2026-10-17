import Foundation
import ClawdCore

public enum CoreChecks {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }
    @discardableResult public static func run() throws -> Int {
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ description: String) throws {
            guard try value() else { throw Failure(description: description) }
            count += 1
        }
        func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
        let utc = TimeZone(secondsFromGMT: 0)!
        let output = """
        Current session: 10% used · resets Oct 17, 5:19am (Europe/Moscow)
        Current week (all models): 26% used · resets Oct 19, 6am (Europe/Moscow)
        Current week (Fable): 19% used
        Current week (New model): 7% used
        What's contributing to your limits usage?
        Last 24h · 1043 requests · 28 sessions
          New future metric: 12%
        """
        let report = try UsageParser.parse(output, now: date("2026-10-17T00:00:00Z"), timeZone: utc)
        try check(report.session.percent == 10, "session percentage")
        try check(report.session.resetsAt == date("2026-10-17T02:19:00Z"), "explicit timezone")
        try check(report.week?.resetsAt == date("2026-10-19T03:00:00Z"), "optional minutes")
        try check(report.extraWeeks["Fable"]?.percent == 19, "optional Fable window")
        try check(report.extraWeeks["New model"]?.percent == 7, "unknown model window")
        try check(report.statistics.contains("New future metric"), "preserve unknown metrics")
        let empty = try UsageParser.parse("Current session: 0% used")
        try check(empty.session.percent == 0 && empty.session.resetsAt == nil, "zero without reset")
        try check(empty.week == nil && empty.extraWeeks.isEmpty, "missing optional windows")
        let now = date("2026-12-31T20:00:00Z")
        try check(UsageParser.parseReset("Jan 1, 12am", now: now, timeZone: utc) == date("2027-01-01T00:00:00Z"), "year rollover at midnight")
        try check(UsageParser.parseReset("Jan 1, 12pm", now: now, timeZone: utc) == date("2027-01-01T12:00:00Z"), "noon parsing")
        try check(UsageParser.parseReset("not a date", now: now, timeZone: utc) == nil, "malformed reset")
        try check(UsageParser.parseReset("Oct 17 at 7:09pm (Europe/Warsaw)", now: date("2026-10-17T00:00:00Z"), timeZone: utc) == date("2026-10-17T17:09:00Z"), "newer 'at' reset format")
        try check(try UsageParser.parse("Current session: 11% used · resets Oct 17 at 7:09pm (Europe/Warsaw)", now: date("2026-10-17T00:00:00Z"), timeZone: utc).session.resetsAt != nil, "session line with 'at'")
        try check(try UsageParser.parse("\u{001B}[32mCurrent session: 85% used\u{001B}[0m").session.percent == 85, "ANSI removal")
        for invalid in ["Please log in", "Current week (all models): 20% used", ""] {
            do {
                _ = try UsageParser.parse(invalid)
                throw Failure(description: "Accepted invalid usage output")
            } catch is UsageParser.ParseError { count += 1 }
        }
        let busy = Session(pid: 1, cwd: "/tmp", status: "busy")
        let waiting = Session(pid: 2, cwd: "/tmp", status: "waiting")
        try check(Mood.resolve(percent: 100, sessions: [busy, waiting]) == .dead, "exhausted priority")
        try check(Mood.resolve(percent: 20, sessions: [busy, waiting]) == .wait, "waiting priority")
        try check(Mood.resolve(percent: 20, sessions: [busy]) == .work, "working mood")
        try check(Mood.resolve(percent: nil, sessions: []) == .sleep, "sleep mood")
        try check(Mood.resolve(percent: 20, sessions: [.init(pid: 3, cwd: "/tmp")]) == .idle, "idle mood")
        for (percent, halves) in [(-1, 6), (0, 6), (50, 3), (99, 1), (100, 0), (101, 0)] {
            try check(Mood.heartHalves(percent: percent) == halves, "heart boundary \(percent)")
        }
        try check(try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(report)) == report, "history round trip")
        let session = try JSONDecoder().decode(Session.self, from: Data(#"{"pid":123,"cwd":"/Projects/widget","status":"waiting","waitingFor":"permission","procStart":"platform-specific","unknown":42}"#.utf8))
        try check(session.displayName == "widget" && session.waitingFor == "permission", "session optional/unknown fields")

        // Clawd sprite: the default pose fills the 9x3 frame, eyes are black pixels inside it.
        let rest = ClawdSprite.geometry(ClawdFrame())
        try check(!rest.body.isEmpty && rest.eyes.count >= 2 && rest.sand.isEmpty, "default pose geometry")
        try check(rest.body.allSatisfy { $0.x >= 0 && $0.x + $0.w <= 18 && $0.y >= 0 && $0.y + $0.h <= 12 }, "pose stays inside the frame")
        var buried = ClawdFrame(); buried.dig = ClawdSprite.burrowDig
        try check(!ClawdSprite.geometry(buried).sand.isEmpty && ClawdSprite.geometry(buried).body.allSatisfy { $0.y + $0.h <= 10 }, "burrow clipped at the ground")
        var flipped = ClawdFrame(); flipped.flip = true
        try check(ClawdSprite.geometry(flipped).body.allSatisfy { $0.y + $0.h <= 10 }, "flipped pose")
        try check(ClawdSprite.sequences["jump"]?.count == 12 && ClawdSprite.sequences["turn"]?.count == 19, "Claude Code sequence lengths")
        try check(ClawdSprite.clickActs.contains("wink") && !ClawdSprite.clickActs.contains("waddle") && !ClawdSprite.clickActs.contains("celebrate"), "click animations start in place")
        try check(HealthTier.tier(halves: 6).hop == 300 && HealthTier.tier(halves: 1).stagger && HealthTier.tier(halves: 0).speed == 0, "health tiers")

        // Weather and sky rules.
        try check(WeatherKind.resolve(code: 65).rain == 16 && WeatherKind.resolve(code: 61).rain == 7, "rain intensity by code")
        try check(WeatherKind.resolve(code: 95).storm && WeatherKind.resolve(code: 45).fog && WeatherKind.resolve(code: 999).name == "code 999", "weather kinds")
        try check(MetNo.code(symbol: "lightrainshowers_day") == 80 && MetNo.code(symbol: "heavysnow") == 75 && MetNo.code(symbol: "clearsky_night") == 0, "met.no symbols")
        let sun = SunCalc.times(lat: 51.5, lon: -0.13, date: date("2026-06-21T12:00:00Z"), timeZone: utc)
        try check(abs(sun.sr - 223) < 15 && abs(sun.ss - 1221) < 15, "London midsummer sunrise/sunset")
        let night = SkyPalette.blend(minute: 0, sunrise: 420, sunset: 1140, cover: 0)
        let day = SkyPalette.blend(minute: 780, sunrise: 420, sunset: 1140, cover: 0)
        try check(night.light == 0 && day.light == 1 && day.bottom.b > night.bottom.b, "sky phases")
        try check(SkyPalette.blend(minute: 780, sunrise: 420, sunset: 1140, cover: 1).bottom.b < day.bottom.b, "clouds dim the sky")
        let full = MoonPhase.pixels(age: MoonPhase.period / 2, southern: false)
        try check(full.lit.joined().filter { $0 == "#" }.count > 30 && MoonPhase.pixels(age: 0, southern: false).lit.joined().filter { $0 == "#" }.isEmpty, "moon phase pixels")
        try check(spanText(until: date("2026-10-19T06:10:00Z"), now: date("2026-10-17T00:00:00Z")) == "2d 6h", "span days")
        try check(spanText(until: date("2026-10-17T04:03:00Z"), now: date("2026-10-17T00:00:00Z")) == "4h 03m", "span hours")
        try check(spanText(until: date("2026-10-17T00:07:30Z"), now: date("2026-10-17T00:00:00Z")) == "7m" && spanText(until: now, now: now) == nil, "span minutes and expiry")
        return count
    }
}
