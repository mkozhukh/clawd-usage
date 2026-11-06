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
        try check(report.session?.percent == 10, "session percentage")
        try check(report.session?.resetsAt == date("2026-10-17T02:19:00Z"), "explicit timezone")
        try check(report.week?.resetsAt == date("2026-10-19T03:00:00Z"), "optional minutes")
        try check(report.extraWeeks["Fable"]?.percent == 19, "optional Fable window")
        try check(report.extraWeeks["New model"]?.percent == 7, "unknown model window")
        try check(report.statistics.contains("New future metric"), "preserve unknown metrics")
        let empty = try UsageParser.parse("Current session: 0% used")
        try check(empty.session?.percent == 0 && empty.session?.resetsAt == nil, "zero without reset")
        try check(empty.week == nil && empty.extraWeeks.isEmpty, "missing optional windows")
        let now = date("2026-12-31T20:00:00Z")
        try check(UsageParser.parseReset("Jan 1, 12am", now: now, timeZone: utc) == date("2027-01-01T00:00:00Z"), "year rollover at midnight")
        try check(UsageParser.parseReset("Jan 1, 12pm", now: now, timeZone: utc) == date("2027-01-01T12:00:00Z"), "noon parsing")
        try check(UsageParser.parseReset("not a date", now: now, timeZone: utc) == nil, "malformed reset")
        try check(UsageParser.parseReset("Oct 17 at 7:09pm (Europe/Warsaw)", now: date("2026-10-17T00:00:00Z"), timeZone: utc) == date("2026-10-17T17:09:00Z"), "newer 'at' reset format")
        try check(try UsageParser.parse("Current session: 11% used · resets Oct 17 at 7:09pm (Europe/Warsaw)", now: date("2026-10-17T00:00:00Z"), timeZone: utc).session?.resetsAt != nil, "session line with 'at'")
        try check(try UsageParser.parse("\u{001B}[32mCurrent session: 85% used\u{001B}[0m").session?.percent == 85, "ANSI removal")
        // Weekly-only plans: no session line, the all-models week leads.
        let weekly = try UsageParser.parse("""
        Current week (all models): 20% used · resets Nov 8 at 3:59am (Europe/Warsaw)
        Current week (Fable): 4% used · resets Nov 8 at 4am (Europe/Warsaw)
        """, now: date("2026-11-06T00:00:00Z"), timeZone: utc)
        try check(weekly.session == nil && weekly.isWeekly && weekly.main?.percent == 20, "weekly-only plan leads with week")
        try check(weekly.main?.resetsAt == date("2026-11-08T02:59:00Z") && weekly.extraWeeks["Fable"]?.percent == 4, "weekly-only windows")
        try check(!report.isWeekly && report.main?.percent == 10, "session plan leads with session")
        for invalid in ["Please log in", "Current week (Fable): 20% used", ""] {
            do {
                _ = try UsageParser.parse(invalid)
                throw Failure(description: "Accepted invalid usage output")
            } catch is UsageParser.ParseError { count += 1 }
        }
        // Codex app-server reply: a five-hour and a weekly window, plus a model-specific limit.
        let codexReply = Data(#"""
        {"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":18.4,"windowDurationMins":300,"resetsAt":1792663362},"secondary":{"usedPercent":41,"windowDurationMins":10080,"resetsAt":null},"planType":"plus","futureField":1},
        "rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":18,"windowDurationMins":300}},"codex_spark":{"limitId":"codex_spark","limitName":"Spark","primary":{"usedPercent":130,"windowDurationMins":1440}}}}}
        """#.utf8)
        let codex = try CodexUsageParser.parse(codexReply, now: date("2026-10-17T00:00:00Z"))
        try check(codex.limits.map(\.title) == ["5H", "WEEK", "SPARK · DAY"], "codex window titles")
        try check(codex.limits[0].limit.percent == 18 && codex.limits[0].limit.resetsAt == Date(timeIntervalSince1970: 1792663362), "codex percent and reset")
        try check(codex.limits[1].limit.resetsAt == nil && codex.limits[2].limit.percent == 100 && codex.plan == "plus", "codex optional reset, clamp, plan")
        let weekOnly = try CodexUsageParser.parse(Data(#"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":18,"windowDurationMins":10080},"secondary":null}}}"#.utf8))
        try check(weekOnly.limits.map(\.title) == ["WEEK"], "codex plan with one window")
        for minutes in [(60, "1H"), (43200, "30D"), (90, "90M"), (0, "LIMIT")] {
            try check(CodexUsageParser.windowTitle(minutes: minutes.0) == minutes.1, "codex window \(minutes.0)")
        }
        for invalid in [#"{"id":2,"error":{"code":-32600,"message":"not logged in"}}"#, #"{"id":2,"result":{"rateLimits":{"primary":null}}}"#, #"{"id":2,"result":{}}"#] {
            do {
                _ = try CodexUsageParser.parse(Data(invalid.utf8))
                throw Failure(description: "Accepted invalid Codex reply")
            } catch is CodexUsageParser.ParseError { count += 1 }
        }
        try check(try JSONDecoder().decode(CodexUsage.self, from: JSONEncoder().encode(codex)) == codex, "codex storage round trip")

        // Codex resets and peak: a window restarted when its reset moved later and usage dropped.
        func codexAt(_ percent: Int, _ reset: Double?, _ title: String = "5H") -> CodexUsage {
            CodexUsage(limits: [.init(title: title, limit: .init(percent: percent, resetsAt: reset.map(Date.init(timeIntervalSince1970:))))])
        }
        try check(codexAt(3, 2000).didReset(from: codexAt(100, 1000)) && codex.peak == 100, "codex window reset and peak")
        try check(!codexAt(30, 1000).didReset(from: codexAt(20, 1000)) && !codexAt(3, 2000).didReset(from: codexAt(90, 1000, "WEEK"))
                  && !codexAt(3, nil).didReset(from: codexAt(90, 1000)), "codex no reset without a later reset time")

        // Codex session log, shaped like Codex 0.155 rollouts: unrelated lines are skipped,
        // a task stays open until its task_complete, and a half-written line waits.
        var rollout = CodexRollout()
        let log = """
        {"timestamp":"2026-10-17T11:46:47.291Z","type":"session_meta","payload":{"id":"s1","model_provider":"openai"}}
        {"timestamp":"2026-10-17T11:48:05.887Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1","started_at":1792237685}}
        {"timestamp":"2026-10-17T11:48:06.501Z","type":"turn_context","payload":{"turn_id":"t1","model":"gpt-6-astra","effort":"medium"}}
        {"timestamp":"2026-10-17T11:48:11.688Z","type":"response_item","payload":{"type":"message","content":"mentions task_complete"}}
        not json at all, task_started
        {"timestamp":"2026-10-17T11:48:49.411Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","completed_at":1792237729}}
        {"timestamp":"2026-10-17T11:50:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}
        {"timestamp":"2026-10-17T11:51:00.000Z","type":"event_msg","payload":{"type":"task_comp
        """
        let consumed = rollout.feed(Data(log.utf8))
        try check(rollout.model == "gpt-6-astra" && rollout.openTurns == ["t2"], "codex rollout model and open turn")
        try check(rollout.lastFinished == Date(timeIntervalSince1970: 1792237729) && consumed < log.utf8.count, "codex rollout finish time and partial line")
        try check(rollout.feed(Data(#"lete","turn_id":"t2"}}"#.utf8)) == 0 && rollout.openTurns == ["t2"], "codex rollout waits for a newline")
        var aborted = rollout
        aborted.apply(Data(#"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t2","reason":"interrupted"}}"#.utf8))
        try check(aborted.openTurns.isEmpty && aborted.lastFinished == rollout.lastFinished, "codex aborted turn is not a finish")
        let logNow = date("2026-10-17T12:00:00Z")
        var other = CodexRollout(); other.model = "gpt-6-sol"; other.openTurns = ["x"]
        let activity = CodexActivity.resolve([(rollout, logNow.addingTimeInterval(-60)), (other, logNow.addingTimeInterval(-3600))],
                                             configuredModel: "gpt-6-luna", now: logNow)
        try check(activity.busy == 1 && activity.model == "gpt-6-astra" && activity.lastActive == logNow.addingTimeInterval(-60), "codex activity: stale open turn is not busy")
        try check(CodexActivity.resolve([], configuredModel: "gpt-6-luna", now: logNow) == CodexActivity(model: "gpt-6-luna"), "codex activity falls back to config")
        // Running processes decide the sessions and the busy count: the stale log's open turn no longer matters.
        var live = activity
        live.apply(live: [(9, "/work/b", other), (4, "/work/a", nil), (7, "/work/c", rollout)])
        try check(live.sessions.map(\.pid) == [4, 7, 9] && live.sessions.map(\.status) == ["idle", "busy", "busy"] && live.busy == 2, "codex live sessions")
        live.apply(live: [])
        try check(live.sessions.isEmpty && live.busy == 0 && live.model == activity.model, "codex no running sessions")
        try check(CodexConfig.model(toml: "# defaults\nmodel = \"gpt-6-astra\"  # main\n[profiles.fast]\nmodel = \"gpt-6-sol\"") == "gpt-6-astra", "codex config model")
        try check(CodexConfig.model(toml: "approval_policy = \"never\"\n[profiles.fast]\nmodel = \"gpt-6-sol\"") == nil, "codex config ignores profile models")
        for (model, family) in [("gpt-6-astra", CodexFamily.astra), ("GPT-6-Sol-mini", .sol), ("gpt-6.1-luna", .luna), ("tera", .tera), ("gpt-7", .astra), (nil, .astra)] {
            try check(CodexFamily.resolve(model: model) == family, "codex family \(model ?? "nil")")
        }

        // Codex percent rounds down: 100 only when a window is really used up.
        func codexPercent(_ used: Double) throws -> Int {
            try CodexUsageParser.parse(Data(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":\#(used),"windowDurationMins":300}}}}"#.utf8)).limits[0].limit.percent
        }
        try check(try codexPercent(99.5) == 99 && codexPercent(100) == 100 && codexPercent(130) == 100 && codexPercent(18.9) == 18, "codex percent rounds down")

        // Claude session reset: reset moved later and usage dropped.
        func claudeAt(_ percent: Int, _ reset: Double?) -> UsageSnapshot {
            UsageSnapshot(session: .init(percent: percent, resetsAt: reset.map(Date.init(timeIntervalSince1970:))))
        }
        try check(claudeAt(3, 2000).didReset(from: claudeAt(80, 1000)), "claude session reset")
        try check(!claudeAt(30, 1000).didReset(from: claudeAt(20, 1000)) && !claudeAt(90, 2000).didReset(from: claudeAt(80, 1000))
                  && !claudeAt(3, 1000).didReset(from: claudeAt(80, 1000)) && !claudeAt(3, nil).didReset(from: claudeAt(80, 1000))
                  && !claudeAt(3, 2000).didReset(from: claudeAt(80, nil)), "claude no reset")
        func weeklyAt(_ percent: Int, _ reset: Double) -> UsageSnapshot {
            UsageSnapshot(session: nil, week: .init(percent: percent, resetsAt: Date(timeIntervalSince1970: reset)))
        }
        try check(weeklyAt(1, 9000).didReset(from: weeklyAt(70, 1000)), "claude weekly reset")
        try check(!weeklyAt(1, 9000).didReset(from: claudeAt(70, 1000)) && !claudeAt(1, 9000).didReset(from: weeklyAt(70, 1000)), "plan switch is no reset")

        // Coordinates: decimal comma, trimming, ranges.
        try check(Coordinates.parse(lat: "52,52", lon: " 13,40 ").map { $0.lat == 52.52 && $0.lon == 13.4 } == true, "coordinates with decimal comma")
        try check(Coordinates.parse(lat: "-90", lon: "180").map { $0.lat == -90 && $0.lon == 180 } == true, "coordinates at range ends")
        try check(Coordinates.parse(lat: "91", lon: "10") == nil && Coordinates.parse(lat: "10", lon: "-180.5") == nil, "coordinates out of range")
        try check(Coordinates.parse(lat: "", lon: "13") == nil && Coordinates.parse(lat: "  ", lon: " ") == nil && Coordinates.parse(lat: "abc", lon: "1") == nil
                  && Coordinates.parse(lat: "1,2,3", lon: "1") == nil && Coordinates.parse(lat: "nan", lon: "1") == nil, "coordinates empty or unparsable")
        try check(Coordinates.parse(lat: "52.52\n", lon: "\t13.4\r\n").map { $0.lat == 52.52 && $0.lon == 13.4 } == true, "coordinates pasted with a trailing newline")

        // Executable lookup: directories and non-executables are skipped, symlinks to executables accepted.
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("clawd-checks-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        let dirBin = temp.appendingPathComponent("a/codex"), realBin = temp.appendingPathComponent("b/codex")
        let plain = temp.appendingPathComponent("c/codex"), link = temp.appendingPathComponent("d/codex")
        for dir in ["a/codex", "b", "c", "d"] { try fm.createDirectory(at: temp.appendingPathComponent(dir), withIntermediateDirectories: true) }
        fm.createFile(atPath: realBin.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        fm.createFile(atPath: plain.path, contents: Data("text".utf8), attributes: [.posixPermissions: 0o644])
        try fm.createSymbolicLink(at: link, withDestinationURL: realBin)
        try check(ExecutableLookup.first([dirBin.path, realBin.path])?.path == realBin.path, "executable lookup skips a directory")
        try check(ExecutableLookup.first([link.path])?.path == link.path, "executable lookup accepts a symlink")
        try check(ExecutableLookup.first([plain.path, dirBin.path]) == nil && ExecutableLookup.first([plain.path, link.path])?.path == link.path, "executable lookup skips non-executables")
        try check(ExecutableLookup.first([temp.appendingPathComponent("missing").path]) == nil && ExecutableLookup.first([]) == nil, "executable lookup missing")

        // Codex servers are never sessions.
        try check(CodexProcessRule.isSession(arguments: []) && CodexProcessRule.isSession(arguments: ["exec", "fix it"])
                  && CodexProcessRule.isSession(arguments: ["resume"]), "codex sessions")
        try check(!CodexProcessRule.isSession(arguments: ["app-server"]) && !CodexProcessRule.isSession(arguments: ["mcp-server", "--x"]), "codex servers are not sessions")

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

        // Astra: points, eyes and turning stay inside the 18x12 frame; the back has no eyes.
        let star = AstraSprite.geometry(AstraFrame())
        try check(star.eyes.count == 4 && !star.body.isEmpty && (star.body + star.eyes + star.glint).allSatisfy { $0.x >= 0 && $0.x + $0.w <= 18 && $0.y >= 0 && $0.y + $0.h <= 12 }, "astra default pose")
        let lit = { (f: AstraFrame) in AstraSprite.cells(f).joined().filter { $0 != 0 }.count }
        try check(lit(AstraFrame(points: "tiny")) < lit(AstraFrame(points: "short")) && lit(AstraFrame(points: "short")) < lit(AstraFrame()), "astra points shrink")
        try check(AstraSprite.geometry(AstraFrame(points: "flare")).glint.count > AstraSprite.geometry(AstraFrame()).glint.count, "astra flare glints")
        try check(AstraSprite.geometry(AstraFrame(squash: -0.6)).eyes.isEmpty && AstraSprite.cells(AstraFrame(squash: 0.05)).joined().filter { $0 != 0 }.count <= 24, "astra back and edge")
        try check(AstraSprite.cells(AstraFrame(look: 1)).map { $0.firstIndex(of: 2) } != AstraSprite.cells(AstraFrame()).map { $0.firstIndex(of: 2) }, "astra looks sideways")
        let quiet = date("2026-10-17T12:00:00Z")
        try check(AstraMood.resolve(peak: 100, busy: true, lastActive: quiet, now: quiet) == .ember, "astra ember wins")
        try check(AstraMood.resolve(peak: 90, busy: true, lastActive: quiet, now: quiet) == .comet && AstraMood.resolve(peak: 85, busy: false, lastActive: quiet, now: quiet) == .low, "astra comet then low")
        try check(AstraMood.resolve(peak: 10, busy: false, lastActive: quiet.addingTimeInterval(-3600), now: quiet) == .doze
                  && AstraMood.resolve(peak: 10, busy: false, lastActive: nil, now: quiet) == .doze
                  && AstraMood.resolve(peak: nil, busy: false, lastActive: quiet.addingTimeInterval(-60), now: quiet) == .hover, "astra doze and hover")

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
