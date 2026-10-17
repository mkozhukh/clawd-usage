import AppKit
import ClawdCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var usage: UsageSnapshot?
    @Published var sessions: [Session] = []
    @Published var error: String?
    @Published var storageError: String?
    @Published var refreshing = false
    @Published var visible = true
    @Published var now = Date()
    @Published var celebration = Date.distantPast
    @Published var sessionFinished = Date.distantPast
    @Published var forcedMood: Mood?
    @Published var forcedPhase: SkyPhase?
    @Published var forcedWeather: Int?
    @Published var hovering = false
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
    @Published var zoom: Double { didSet { defaults.set(zoom, forKey: "zoom"); onWindowPreferences?() } }
    @Published var cliPath: String { didSet { defaults.set(cliPath, forKey: "cliPath") } }
    var onWindowPreferences: (() -> Void)?
    var onUsage: (() -> Void)?
    let demo: Bool
    private let defaults: UserDefaults
    private let storage = SnapshotStorage()
    private var tasks: [Task<Void, Never>] = []

    init(demo: Bool) {
        self.demo = demo
        defaults = demo ? UserDefaults(suiteName: "dev.clawd.mac.demo")! : .standard
        defaults.register(defaults: ["topmost": true, "allSpaces": false, "showSky": true, "zoom": 1.0])
        expanded = defaults.bool(forKey: "expanded")
        topmost = defaults.bool(forKey: "topmost")
        allSpaces = defaults.bool(forKey: "allSpaces")
        showSky = defaults.bool(forKey: "showSky")
        zoom = [1.0, 1.2, 1.5].contains(defaults.double(forKey: "zoom")) ? defaults.double(forKey: "zoom") : 1.0
        cliPath = defaults.string(forKey: "cliPath") ?? ""
        weatherLat = defaults.string(forKey: "weatherLat") ?? ""
        weatherLon = defaults.string(forKey: "weatherLon") ?? ""
        weatherCity = defaults.string(forKey: "weatherCity") ?? ""
        applyPlace()
    }

    /// Coordinates from the settings; empty means detect by IP.
    private func applyPlace() {
        if let lat = Double(weatherLat.trimmingCharacters(in: .whitespaces)), let lon = Double(weatherLon.trimmingCharacters(in: .whitespaces)) {
            weather.configured = WeatherPlace(lat: lat, lon: lon, city: weatherCity.isEmpty ? nil : weatherCity)
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

    var mood: Mood { forcedMood ?? Mood.resolve(percent: usage?.session.percent, sessions: sessions) }
    var stale: Bool { usage.map { now.timeIntervalSince($0.fetchedAt) > 150 } ?? true }
    var busyCount: Int { sessions.filter { $0.status == "busy" }.count }
    var waitingCount: Int { sessions.filter { $0.status == "waiting" }.count }

    func start() {
        if demo {
            usage = UsageSnapshot(session: .init(percent: 36, resetsAt: .now.addingTimeInterval(10980)),
                                  week: .init(percent: 62, resetsAt: .now.addingTimeInterval(231000)),
                                  extraWeeks: ["Fable": .init(percent: 19)],
                                  statistics: "Last 24h · 128 requests · 8 sessions\n  23% of your usage was at >150k context\n  Top skills: /review 8%\n\nLast 7d · 814 requests · 32 sessions")
            sessions = [.init(pid: 1, cwd: "/Projects/clawd-mac", status: "busy"),
                        .init(pid: 2, cwd: "/Projects/website", status: "waiting", waitingFor: "permission")]
            weather.setDemo(WeatherReport(code: 2, temp: 14, wind: 12, sunrise: 430, sunset: 1110, at: .now),
                            place: WeatherPlace(lat: 52.5, lon: 13.4, city: "Demo"))
            onUsage?()
        } else {
            tasks.append(Task {
                do { usage = try await storage.load(); onUsage?() }
                catch { storageError = "Could not load last usage: \(error.localizedDescription)" }
                await refresh()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    if !Task.isCancelled { await refresh() }
                }
            })
            tasks.append(Task {
                while !Task.isCancelled {
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
        guard !refreshing, !demo else { return }
        refreshing = true
        defer { refreshing = false; onUsage?() }
        do {
            let output = try await ClaudeCLI.run(arguments: ["-p", "/usage", "--output-format", "text", "--no-session-persistence", "--strict-mcp-config"], custom: cliPath)
            let next = try UsageParser.parse(output)
            if let old = usage, let oldReset = old.session.resetsAt, let newReset = next.session.resetsAt,
               newReset > oldReset, next.session.percent < old.session.percent { celebration = .now }
            usage = next
            error = nil
            do { try await storage.save(next); storageError = nil }
            catch { storageError = "Could not save last usage: \(error.localizedDescription)" }
        } catch { self.error = error.localizedDescription }
    }

}
