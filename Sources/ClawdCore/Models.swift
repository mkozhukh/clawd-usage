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
    public var session: UsageLimit
    public var week: UsageLimit?
    public var extraWeeks: [String: UsageLimit]
    public var statistics: String
    public var fetchedAt: Date
    public init(session: UsageLimit, week: UsageLimit? = nil,
                extraWeeks: [String: UsageLimit] = [:], statistics: String = "", fetchedAt: Date = .now) {
        self.session = session
        self.week = week
        self.extraWeeks = extraWeeks
        self.statistics = statistics
        self.fetchedAt = fetchedAt
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
        guard let session else { throw ParseError.missingSession }
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
