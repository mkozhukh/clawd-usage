import AppKit
import ClawdCore
import SwiftUI
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published var usage: UsageSnapshot?
    /// Codex limits; nil while Codex is off, not installed or not yet read.
    @Published var codex: CodexUsage?
    @Published var codexError: String?
    /// What Codex is doing, from its session logs; empty while Codex is off.
    @Published var codexActivity = CodexActivity()
    /// A Codex task finished, and a Codex limit window started over; distantPast until it happens.
    @Published var codexFinished = Date.distantPast
    @Published var codexReset = Date.distantPast
    @Published var sessions: [Session] = []
    @Published var error: String?
    @Published var storageError: String?
    @Published var refreshing = false
    @Published var visible = true
    @Published var now = Date()
    @Published var celebration = Date.distantPast
    @Published var sessionFinished = Date.distantPast
    @Published var forcedMood: Mood?
    /// Developer mode for Astra: a held mood, and one animation to play next tick.
    @Published var forcedCodexMood: AstraMood?
    /// Taking a snapshot for the README: the demo data without the DEMO badge.
    var snapshot = false
    @Published var codexDevAct: String?
    @Published var forcedPhase: SkyPhase?
    @Published var forcedWeather: Int?
    @Published var hovering = false
    /// The login item's state; re-read whenever Settings is shown, since System Settings can change it.
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    func refreshLaunchAtLogin() { launchAtLogin = SMAppService.mainApp.status == .enabled }
    var skyWidth = 0.0
    let weather = WeatherService()
    @Published var weatherLat: String { didSet { defaults.set(weatherLat, forKey: "weatherLat"); applyPlace() } }
    @Published var weatherLon: String { didSet { defaults.set(weatherLon, forKey: "weatherLon"); applyPlace() } }
    /// Name of the city the coordinates were picked from; empty for coordinates typed by hand.
    @Published var weatherCity: String { didSet { defaults.set(weatherCity, forKey: "weatherCity"); applyPlace() } }
    /// Height of the widget's content at zoom 1; the panel is resized to it.
    @Published var contentHeight = 0.0
    @Published var expanded: Bool { didSet { defaults.set(expanded, forKey: "expanded") } }
    @Published var topmost: Bool { didSet { defaults.set(topmost, forKey: "topmost"); onWindowPreferences?() } }
    @Published var allSpaces: Bool { didSet { defaults.set(allSpaces, forKey: "allSpaces"); onWindowPreferences?() } }
    @Published var showSky: Bool { didSet { defaults.set(showSky, forKey: "showSky") } }
    /// Only the header, the mascot row and the reset line.
    @Published var minimal: Bool { didSet { defaults.set(minimal, forKey: "minimal") } }
    @Published var zoom: Double { didSet { defaults.set(zoom, forKey: "zoom"); onWindowPreferences?() } }
    @Published var cliPath: String { didSet { defaults.set(cliPath, forKey: "cliPath"); detect() } }
    @Published var codexPath: String { didSet { defaults.set(codexPath, forKey: "codexPath"); detect() } }
    /// Per harness: shown in the widget (mascot and limit rows) and as its own menu bar item.
    @Published var claudeEnabled: Bool { didSet { defaults.set(claudeEnabled, forKey: "claudeEnabled"); harnessesChanged() } }
    @Published var claudeMenuBar: Bool { didSet { defaults.set(claudeMenuBar, forKey: "claudeMenuBar"); harnessesChanged() } }
    @Published var codexEnabled: Bool { didSet { defaults.set(codexEnabled, forKey: "codexEnabled"); harnessesChanged() } }
    @Published var codexMenuBar: Bool { didSet { defaults.set(codexMenuBar, forKey: "codexMenuBar"); harnessesChanged() } }
    /// Found at launch or after a path change. A harness without its executable counts as off
    /// everywhere, whatever its toggles say.
    @Published private(set) var claudeExecutable: URL? = nil
    @Published private(set) var codexExecutable: URL? = nil
    var onWindowPreferences: (() -> Void)?
    var onUsage: (() -> Void)?
    let demo: Bool
    private let defaults: UserDefaults
    private let storage = SnapshotStorage()
    private let codexStorage = CodexStorage()
    private let codexReader = CodexActivityReader()
    private var refreshingCodex = false
    /// Loaded from disk at launch: shown, but not a baseline for reset celebrations. Cleared by
    /// the first successful fetch; a failed fetch leaves it set.
    private var restored = (usage: false, codex: false)
    private var polling = (claude: false, codex: false)
    private var tasks: [Task<Void, Never>] = []

    init(demo: Bool) {
        self.demo = demo
        defaults = demo ? UserDefaults(suiteName: "ink.mono.clawd.demo")! : .standard
        defaults.register(defaults: ["topmost": true, "allSpaces": false, "showSky": true, "zoom": 1.0,
                                     "claudeEnabled": true, "claudeMenuBar": true, "codexEnabled": true, "codexMenuBar": false])
        expanded = defaults.bool(forKey: "expanded")
        topmost = defaults.bool(forKey: "topmost")
        allSpaces = defaults.bool(forKey: "allSpaces")
        showSky = defaults.bool(forKey: "showSky")
        minimal = defaults.bool(forKey: "minimal")
        zoom = [1.0, 1.2, 1.5].contains(defaults.double(forKey: "zoom")) ? defaults.double(forKey: "zoom") : 1.0
        cliPath = defaults.string(forKey: "cliPath") ?? ""
        codexPath = defaults.string(forKey: "codexPath") ?? ""
        claudeEnabled = defaults.bool(forKey: "claudeEnabled")
        claudeMenuBar = defaults.bool(forKey: "claudeMenuBar")
        codexEnabled = defaults.bool(forKey: "codexEnabled")
        codexMenuBar = defaults.bool(forKey: "codexMenuBar")
        weatherLat = defaults.string(forKey: "weatherLat") ?? ""
        weatherLon = defaults.string(forKey: "weatherLon") ?? ""
        weatherCity = defaults.string(forKey: "weatherCity") ?? ""
        applyPlace()
        if demo {
            claudeExecutable = URL(fileURLWithPath: "/demo/claude"); codexExecutable = URL(fileURLWithPath: "/demo/codex")
        } else {
            claudeExecutable = try? ClaudeCLI.executable(custom: cliPath); codexExecutable = CodexCLI.executable(custom: codexPath)
        }
        polling = (pollClaude, pollCodex)
    }

    var showClaude: Bool { claudeEnabled && claudeExecutable != nil }
    var showCodex: Bool { codexEnabled && codexExecutable != nil }
    var claudeInMenuBar: Bool { claudeMenuBar && claudeExecutable != nil }
    var codexInMenuBar: Bool { codexMenuBar && codexExecutable != nil }
    /// A harness is polled while the widget or the menu bar shows it.
    var pollClaude: Bool { showClaude || claudeInMenuBar }
    var pollCodex: Bool { showCodex || codexInMenuBar }

    enum Harness { case claude, codex }
    /// Whose numbers lead the widget: Claude when shown, else Codex; nil when neither is shown.
    var primary: Harness? { showClaude ? .claude : showCodex ? .codex : nil }
    /// The big percentage and the hearts: Claude's session (its week on weekly-only plans), or Codex's first window.
    var mainLimit: UsageLimit? {
        switch primary {
        case .claude: usage?.main
        case .codex: codex?.limits.first?.limit
        case nil: nil
        }
    }
    var mainFetchedAt: Date? { primary == .claude ? usage?.fetchedAt : primary == .codex ? codex?.fetchedAt : nil }

    /// A path was edited: look for the executables again.
    private func detect() {
        guard !demo else { return }
        claudeExecutable = try? ClaudeCLI.executable(custom: cliPath)
        codexExecutable = CodexCLI.executable(custom: codexPath)
        harnessesChanged()
    }

    /// Stops what is no longer shown anywhere and fetches what just appeared.
    private func harnessesChanged() {
        let was = polling
        polling = (pollClaude, pollCodex)
        if !pollClaude { error = nil }
        if !pollCodex { codex = nil; codexError = nil }
        if !showCodex { codexActivity = CodexActivity() }
        if !demo && pollClaude && !was.claude { Task { await refreshClaude() } }
        if !demo && pollCodex && !was.codex { Task { await refreshCodex() } }
        onUsage?()
    }

    /// Coordinates from the settings; empty means detect by IP.
    private func applyPlace() {
        if let place = Coordinates.parse(lat: weatherLat, lon: weatherLon) {
            weather.configured = WeatherPlace(lat: place.lat, lon: place.lon, city: weatherCity.isEmpty ? nil : weatherCity)
        } else { weather.configured = nil }
    }

    /// A city picked in Settings, or nil to go back to the location by IP.
    func setPlace(_ match: PlaceMatch?) {
        weatherCity = match?.name ?? ""
        weatherLat = match.map { String(format: "%.4f", $0.lat) } ?? ""
        weatherLon = match.map { String(format: "%.4f", $0.lon) } ?? ""
    }

    var skyTip: String {
        var force: [String] = []
        if let forcedPhase { force.append(forcedPhase.rawValue) }
        if let forcedWeather { force.append(WeatherKind.resolve(code: forcedWeather).name) }
        return weather.tip(force: force.isEmpty ? nil : force.joined(separator: ", "))
    }

    var mood: Mood { forcedMood ?? Mood.resolve(percent: usage?.main?.percent, sessions: sessions) }
    var stale: Bool { mainFetchedAt.map { now.timeIntervalSince($0) > 150 } ?? true }
    var codexFamily: CodexFamily { .resolve(model: codexActivity.model) }
    var busyCount: Int { sessions.filter { $0.status == "busy" }.count }
    var waitingCount: Int { sessions.filter { $0.status == "waiting" }.count }

    func start() {
        if demo {
            usage = UsageSnapshot(session: .init(percent: 36, resetsAt: .now.addingTimeInterval(10980)),
                                  week: .init(percent: 62, resetsAt: .now.addingTimeInterval(231000)),
                                  extraWeeks: ["Fable": .init(percent: 19)],
                                  statistics: "Last 24h · 128 requests · 8 sessions\n  23% of your usage was at >150k context\n  Top skills: /review 8%\n\nLast 7d · 814 requests · 32 sessions")
            sessions = [.init(pid: 1, cwd: "/Projects/clawd-usage", status: "busy"),
                        .init(pid: 2, cwd: "/Projects/website", status: "waiting", waitingFor: "permission")]
            if showCodex {
                codex = CodexUsage(limits: [.init(title: "5H", limit: .init(percent: 24, resetsAt: .now.addingTimeInterval(7400))),
                                            .init(title: "WEEK", limit: .init(percent: 41, resetsAt: .now.addingTimeInterval(352000)))],
                                   plan: "plus")
                codexActivity = CodexActivity(busy: 1, model: "gpt-6-astra", lastActive: .now,
                                              sessions: [.init(pid: 3, cwd: "/Projects/api-server", status: "busy"), .init(pid: 4, cwd: "/Projects/clawd-usage", status: "idle")])
            }
            weather.setDemo(WeatherReport(code: 2, temp: 14, wind: 12, sunrise: 430, sunset: 1110, at: .now),
                            place: WeatherPlace(lat: 52.5, lon: 13.4, city: "Demo"))
            onUsage?()
        } else {
            tasks.append(Task {
                do {
                    usage = try await storage.load()
                    restored.usage = usage != nil
                    onUsage?()
                } catch { storageError = "Could not load last usage: \(error.localizedDescription)" }
                if pollCodex {
                    codex = try? await codexStorage.load()
                    restored.codex = codex != nil
                }
                await refresh()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    if !Task.isCancelled { await refresh() }
                }
            })
            tasks.append(Task {
                while !Task.isCancelled {
                    // Claude's sessions feed only the widget (Clawd, the list); nothing to read while Claude is hidden there.
                    guard showClaude else {
                        if !sessions.isEmpty { sessions = [] }
                        try? await Task.sleep(for: .seconds(2)); continue
                    }
                    let previousBusy = busyCount
                    let previousWaiting = waitingCount
                    let next = await SessionReader.read()
                    if next != sessions { sessions = next }
                    // A session finished its reply (rather than stopping to wait for us): jump.
                    if previousBusy > 0 && busyCount < previousBusy && waitingCount <= previousWaiting { sessionFinished = .now }
                    try? await Task.sleep(for: .seconds(2))
                }
            })
            tasks.append(Task {
                // The first read after launch or after turning Codex on only sets the baseline,
                // so tasks that finished earlier are not reported as just finished.
                var baseline = false
                while !Task.isCancelled {
                    if showCodex {
                        let next = await codexReader.read()
                        if baseline, let finished = next.lastFinished, finished > (codexActivity.lastFinished ?? .distantPast) { codexFinished = .now }
                        baseline = true
                        if showCodex && next != codexActivity { codexActivity = next }
                    } else { baseline = false }
                    try? await Task.sleep(for: .seconds(2))
                }
            })
            tasks.append(Task {
                while !Task.isCancelled {
                    if showSky { await weather.poll() }
                    try? await Task.sleep(for: .seconds(15))
                }
            })
        }
        tasks.append(Task {
            while !Task.isCancelled {
                now = .now
                try? await Task.sleep(for: .seconds(1))
            }
        })
    }

    func stop() { tasks.forEach { $0.cancel() }; tasks.removeAll(); ChildProcesses.shared.terminateAll() }

    func refresh() async {
        async let claude: Void = refreshClaude()
        async let codex: Void = refreshCodex()
        _ = await (claude, codex)
    }

    private func refreshClaude() async {
        guard pollClaude, !refreshing, !demo else { return }
        refreshing = true
        defer { refreshing = false; onUsage?() }
        do {
            let output = try await ClaudeCLI.run(arguments: ["-p", "/usage", "--output-format", "text", "--no-session-persistence", "--strict-mcp-config"], custom: cliPath)
            let next = try UsageParser.parse(output)
            if !restored.usage, let old = usage, next.didReset(from: old) { celebration = .now }
            restored.usage = false
            usage = next
            error = nil
            do { try await storage.save(next); storageError = nil }
            catch { storageError = "Could not save last usage: \(error.localizedDescription)" }
        } catch { self.error = error.localizedDescription }
    }

    func refreshCodex() async {
        guard pollCodex, !refreshingCodex, !demo else { return }
        refreshingCodex = true
        defer { refreshingCodex = false; onUsage?() }
        do {
            let next = try CodexUsageParser.parse(try await CodexCLI.rateLimits(custom: codexPath))
            guard pollCodex else { return }
            if !restored.codex, let old = codex, next.didReset(from: old) { codexReset = .now }
            restored.codex = false
            codex = next
            codexError = nil
            try? await codexStorage.save(next)
        } catch CodexCLI.Failure.notInstalled {
            codex = nil
            codexError = nil
        } catch { if pollCodex { codexError = error.localizedDescription } }
    }
}
