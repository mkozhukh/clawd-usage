import Foundation

public struct UsageLimit: Codable, Sendable, Equatable {
    public var percent: Int
    public var resetsAt: Date?
    public init(percent: Int, resetsAt: Date? = nil) {
        self.percent = min(100, max(0, percent))
        self.resetsAt = resetsAt
    }
}

public struct UsageSnapshot: Codable, Sendable, Equatable {
    /// The five-hour window; nil on plans that have only weekly limits.
    public var session: UsageLimit?
    public var week: UsageLimit?
    public var extraWeeks: [String: UsageLimit]
    public var statistics: String
    public var fetchedAt: Date
    public init(session: UsageLimit?, week: UsageLimit? = nil,
                extraWeeks: [String: UsageLimit] = [:], statistics: String = "", fetchedAt: Date = .now) {
        self.session = session
        self.week = week
        self.extraWeeks = extraWeeks
        self.statistics = statistics
        self.fetchedAt = fetchedAt
    }
}

extension UsageSnapshot {
    /// Plans without a five-hour window lead with the weekly (all models) limit.
    public var isWeekly: Bool { session == nil }

    /// The limit that leads: the session window, else the weekly one.
    public var main: UsageLimit? { session ?? week }

    /// The leading window started over since `old`: reset moved later and usage dropped.
    /// A switch between session and weekly mode does not count.
    public func didReset(from old: UsageSnapshot) -> Bool {
        guard isWeekly == old.isWeekly, let now = main, let before = old.main,
              let oldReset = before.resetsAt, let newReset = now.resetsAt else { return false }
        return newReset > oldReset && now.percent < before.percent
    }
}

public struct Session: Codable, Sendable, Identifiable, Equatable {
    public var pid: Int32
    public var sessionId: String?
    public var cwd: String
    public var name: String?
    public var status: String?
    public var waitingFor: String?
    public var id: Int32 { pid }
    public var displayName: String { name ?? URL(fileURLWithPath: cwd).lastPathComponent }
    public init(pid: Int32, cwd: String, name: String? = nil, status: String? = nil, waitingFor: String? = nil) {
        self.pid = pid; self.cwd = cwd; self.name = name; self.status = status; self.waitingFor = waitingFor
    }
}

public enum Mood: String, CaseIterable, Sendable {
    case sleep, idle, work, wait, dead
    public static func resolve(percent: Int?, sessions: [Session]) -> Mood {
        if let percent, percent >= 100 { return .dead }
        if sessions.contains(where: { $0.status == "waiting" }) { return .wait }
        if sessions.contains(where: { $0.status == "busy" }) { return .work }
        return sessions.isEmpty ? .sleep : .idle
    }
    public static func heartHalves(percent: Int) -> Int {
        Int(ceil(Double(max(0, 100 - min(100, max(0, percent)))) * 6 / 100))
    }
}

public enum UsageParser {
    public enum ParseError: Error, LocalizedError {
        case missingSession
        public var errorDescription: String? {
            "Claude returned no recognizable usage data. Check that this CLI version supports headless /usage."
        }
    }

    public static func parse(_ text: String, now: Date = .now, timeZone: TimeZone = .current) throws -> UsageSnapshot {
        let clean = text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        var session: UsageLimit?
        var week: UsageLimit?
        var extras: [String: UsageLimit] = [:]
        for line in clean.components(separatedBy: .newlines) {
            guard let match = captures(#"^\s*Current (session|week \(([^)]+)\)):\s*(\d+)%([^\r\n]*)"#, line),
                  let percent = Int(match[3]) else { continue }
            let resetText = match[4].range(of: "resets ").map { String(match[4][$0.upperBound...]) }
            let limit = UsageLimit(percent: percent, resetsAt: resetText.flatMap { parseReset($0, now: now, timeZone: timeZone) })
            if match[1] == "session" { session = limit }
            else if match[2] == "all models" { week = limit }
            else { extras[match[2]] = limit }
        }
        // Some plans report only weekly limits; either the session or the all-models week must be there.
        guard session != nil || week != nil else { throw ParseError.missingSession }
        let stats = clean.range(of: "What's contributing").map { String(clean[$0.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return UsageSnapshot(session: session, week: week, extraWeeks: extras, statistics: stats, fetchedAt: now)
    }

    public static func parseReset(_ text: String, now: Date, timeZone: TimeZone) -> Date? {
        // "Oct 17, 5:19am (Europe/Moscow)", "Sep 21, 6am" or, in newer CLI versions, "Oct 17 at 7:09pm (Europe/Warsaw)".
        guard let m = captures(#"([A-Za-z]{3})\s+(\d{1,2})(?:,|\s+at)?\s*(\d{1,2})(?::(\d{2}))?\s*([ap]m)"#, text),
              let month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].firstIndex(of: m[1]),
              let day = Int(m[2]), let hour = Int(m[3]), (1...12).contains(hour) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        let zoneName = captures(#"\(([^)]+)\)"#, text)?[1]
        calendar.timeZone = zoneName.flatMap(TimeZone.init(identifier:)) ?? timeZone
        var components = DateComponents(year: calendar.component(.year, from: now), month: month + 1,
                                        day: day, hour: hour % 12 + (m[5] == "pm" ? 12 : 0), minute: Int(m[4]) ?? 0)
        guard let date = calendar.date(from: components) else { return nil }
        if date < calendar.date(byAdding: .month, value: -1, to: now)! {
            components.year! += 1
            return calendar.date(from: components)
        }
        return date
    }

    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

/// One Codex rate-limit window, e.g. the five-hour or the weekly one.
public struct CodexLimit: Codable, Sendable, Equatable {
    /// Caption such as "5H" or "WEEK", prefixed with the limit's name for a model-specific limit.
    public var title: String
    public var limit: UsageLimit
    public init(title: String, limit: UsageLimit) { self.title = title; self.limit = limit }
}

public struct CodexUsage: Codable, Sendable, Equatable {
    public var limits: [CodexLimit]
    public var plan: String?
    public var fetchedAt: Date
    public init(limits: [CodexLimit], plan: String? = nil, fetchedAt: Date = .now) {
        self.limits = limits; self.plan = plan; self.fetchedAt = fetchedAt
    }
}

/// Reads the reply to `account/rateLimits/read` from `codex app-server`.
public enum CodexUsageParser {
    public enum ParseError: Error, LocalizedError {
        case server(String)
        case missingLimits
        public var errorDescription: String? {
            switch self {
            case .server(let message): "Codex: \(message)"
            case .missingLimits: "Codex returned no recognizable rate limits. Check that you are signed in to Codex."
            }
        }
    }

    private struct Reply: Decodable {
        var result: Result?
        var error: Failure?
    }
    private struct Failure: Decodable { var message: String? }
    private struct Result: Decodable {
        var rateLimits: Limits?
        var rateLimitsByLimitId: [String: Limits]?
    }
    private struct Limits: Decodable {
        var limitId: String?
        var limitName: String?
        var primary: Window?
        var secondary: Window?
        var planType: String?
    }
    private struct Window: Decodable {
        var usedPercent: Double
        var windowDurationMins: Int?
        var resetsAt: Double?
    }

    public static func parse(_ data: Data, now: Date = .now) throws -> CodexUsage {
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        if let error = reply.error { throw ParseError.server(error.message ?? "request failed") }
        guard let main = reply.result?.rateLimits else { throw ParseError.missingLimits }
        // The main limit first, then any other (model-specific) ones under their names.
        let others = (reply.result?.rateLimitsByLimitId ?? [:])
            .filter { $0.key != main.limitId }
            .sorted { $0.key < $1.key }
            .map { $0.value }
        var limits: [CodexLimit] = []
        for (index, entry) in ([main] + others).enumerated() {
            let prefix = index == 0 ? "" : (entry.limitName ?? entry.limitId ?? "other").uppercased() + " · "
            for window in [entry.primary, entry.secondary].compactMap({ $0 }) {
                limits.append(CodexLimit(title: prefix + windowTitle(minutes: window.windowDurationMins),
                                         limit: UsageLimit(percent: Int(min(100, max(0, window.usedPercent)).rounded(.down)),
                                                           resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) })))
            }
        }
        guard !limits.isEmpty else { throw ParseError.missingLimits }
        return CodexUsage(limits: limits, plan: main.planType, fetchedAt: now)
    }

    /// "5H", "DAY", "WEEK", "30D"; plans differ in which windows they have.
    public static func windowTitle(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "LIMIT" }
        switch minutes {
        case 1440: return "DAY"
        case 10080: return "WEEK"
        case let m where m % 1440 == 0: return "\(m / 1440)D"
        case let m where m % 60 == 0: return "\(m / 60)H"
        default: return "\(minutes)M"
        }
    }
}

extension CodexUsage {
    /// The fullest window; 100 means some Codex limit is exhausted.
    public var peak: Int { limits.map(\.limit.percent).max() ?? 0 }

    /// Some window started over since `old`: its reset moved later and its usage dropped.
    /// Windows are matched by title, so a window that appeared or vanished does not count.
    public func didReset(from old: CodexUsage) -> Bool {
        limits.contains { entry in
            guard let before = old.limits.first(where: { $0.title == entry.title }),
                  let oldReset = before.limit.resetsAt, let newReset = entry.limit.resetsAt else { return false }
            return newReset > oldReset && entry.limit.percent < before.limit.percent
        }
    }
}

/// One Codex session log (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`), folded line by line.
/// Only task and turn events are decoded; the log format is Codex's own and may change, so
/// anything unrecognized is skipped.
public struct CodexRollout: Sendable, Equatable {
    /// Turns that started and have neither completed nor been aborted.
    public var openTurns: Set<String> = []
    /// Model of the latest turn.
    public var model: String?
    public var lastFinished: Date?
    public init() {}

    // Cheap prefilter: most lines are messages and tool calls, which are never decoded.
    private static let markers = ["task_started", "task_complete", "turn_aborted", "turn_context", "session_meta"].map { Data($0.utf8) }

    public mutating func apply(_ line: Data) {
        guard Self.markers.contains(where: { line.range(of: $0) != nil }),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }
        let turn = payload["turn_id"] as? String ?? ""
        switch (object["type"] as? String, payload["type"] as? String) {
        case ("turn_context", _):
            if let name = payload["model"] as? String { model = name }
        case ("session_meta", _):
            if model == nil, let name = payload["model"] as? String { model = name }
        case ("event_msg", "task_started"):
            openTurns.insert(turn)
        case ("event_msg", "task_complete"):
            openTurns.remove(turn)
            let stamp = (object["timestamp"] as? String).flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }
            if let at = (payload["completed_at"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? stamp {
                lastFinished = max(lastFinished ?? at, at)
            }
        case ("event_msg", "turn_aborted"):
            if turn.isEmpty { openTurns.removeAll() } else { openTurns.remove(turn) }
        default: break
        }
    }

    /// Applies the complete lines in `data` and returns how many bytes they took. A line still
    /// being written has no newline yet and is left for the next read.
    public mutating func feed(_ data: Data) -> Int {
        guard let last = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        for line in data[data.startIndex..<last].split(separator: UInt8(ascii: "\n")) { apply(Data(line)) }
        return last - data.startIndex + 1
    }
}

/// What Codex is doing, combined from its recent session logs.
public struct CodexActivity: Sendable, Equatable {
    /// Sessions with a task in progress.
    public var busy: Int
    /// Model of the most recently written session, else the default from config.toml.
    public var model: String?
    /// When any session log was last written.
    public var lastActive: Date?
    /// When the latest task finished.
    public var lastFinished: Date?
    /// Running Codex sessions, for the session list: "busy" with a task in progress, else "idle".
    public var sessions: [Session] = []
    public init(busy: Int = 0, model: String? = nil, lastActive: Date? = nil, lastFinished: Date? = nil, sessions: [Session] = []) {
        self.busy = busy; self.model = model; self.lastActive = lastActive; self.lastFinished = lastFinished; self.sessions = sessions
    }

    /// Takes the running Codex processes, each with the log it holds open (none before its first
    /// turn). A process that is running is a better sign of life than a recent log, so the busy
    /// count then comes from these sessions alone.
    public mutating func apply(live: [(pid: Int32, cwd: String, rollout: CodexRollout?)]) {
        sessions = live.map { Session(pid: $0.pid, cwd: $0.cwd, status: $0.rollout?.openTurns.isEmpty == false ? "busy" : "idle") }
            .sorted { $0.pid < $1.pid }
        busy = sessions.filter { $0.status == "busy" }.count
    }

    /// An open turn in a log untouched for `staleAfter` belongs to a session that crashed or was
    /// killed mid-task, so it does not count as busy. Long tool runs write nothing for a while,
    /// hence the generous default.
    public static func resolve(_ logs: [(rollout: CodexRollout, modified: Date)], configuredModel: String?,
                               now: Date = .now, staleAfter: TimeInterval = 900) -> CodexActivity {
        let recent = logs.sorted { $0.modified > $1.modified }
        return CodexActivity(
            busy: recent.filter { !$0.rollout.openTurns.isEmpty && now.timeIntervalSince($0.modified) < staleAfter }.count,
            model: recent.lazy.compactMap(\.rollout.model).first ?? configuredModel,
            lastActive: recent.first?.modified,
            lastFinished: recent.compactMap(\.rollout.lastFinished).max())
    }
}

public enum CodexConfig {
    /// The top-level `model = "..."` of `~/.codex/config.toml`. Keys under a [table] belong to
    /// profiles and providers, not to the default.
    public static func model(toml: String) -> String? {
        for raw in toml.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil }
            if let match = line.wholeMatch(of: /model\s*=\s*"([^"]+)"\s*(#.*)?/) { return String(match.1) }
        }
        return nil
    }
}

/// The Codex mascot, picked by model name: "gpt-6-astra" is Astra. Unknown or missing models get Astra.
public enum CodexFamily: String, CaseIterable, Sendable {
    case astra, sol, luna, tera
    public static func resolve(model: String?) -> CodexFamily {
        let words = (model ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.reversed().lazy.compactMap { CodexFamily(rawValue: String($0)) }.first ?? .astra
    }
}

/// Weather coordinates typed in Settings.
public enum Coordinates {
    /// nil for empty, unparsable or out-of-range input. Spaces and newlines are trimmed and a decimal comma is accepted.
    public static func parse(lat: String, lon: String) -> (lat: Double, lon: Double)? {
        func number(_ text: String) -> Double? {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
            guard !clean.isEmpty, let value = Double(clean), value.isFinite else { return nil }
            return value
        }
        guard let la = number(lat), let lo = number(lon), (-90...90).contains(la), (-180...180).contains(lo) else { return nil }
        return (la, lo)
    }
}

public enum ExecutableLookup {
    /// The first candidate that is an executable regular file (or a symlink to one); directories are skipped.
    public static func first(_ candidates: [String]) -> URL? {
        candidates.first { path in
            var isDirectory: ObjCBool = false
            // fileExists follows symlinks, so a link to a directory is skipped too.
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }.map(URL.init(fileURLWithPath:))
    }
}

public enum CodexProcessRule {
    /// Whether a running `codex` process counts as a session: false when its first
    /// argument (after the executable) is `app-server` or `mcp-server`.
    public static func isSession(arguments: [String]) -> Bool {
        guard let first = arguments.first else { return true }
        return first != "app-server" && first != "mcp-server"
    }
}
