import SwiftUI
import ServiceManagement
import ClawdCore

private let accent = Color(red: 0.843, green: 0.467, blue: 0.341)
private let muted = Color(red: 0.58, green: 0.61, blue: 0.65)

// Original widget palette (clawd-usage-winwidget): limit levels and bar colours.
private let levelOk = color(RGBA("#FF4ADE80")), levelWarn = color(RGBA("#FFFBBF24"))
private let levelCrit = color(RGBA("#FFF87171")), levelDead = color(RGBA("#FF6B7280"))
private let lineColor = color(RGBA("#FF8B8B94")), resetColor = color(RGBA("#FFD4D4D8"))
private let barWeek = color(RGBA("#FF60A5FA")), barModel = color(RGBA("#FFA78BFA"))
private let barCodex = color(RGBA("#FF2DD4BF"))
private let heartOff = color(RGBA("#FF3F3F46"))

struct WidgetView: View {
    @ObservedObject var model: AppModel
    var hide: () -> Void
    // @State, not @StateObject: owned here but not observed, so their per-frame scenes
    // redraw only MascotView and SkyView, not the whole widget.
    @State private var mascot = MascotEngine()
    @State private var astra = AstraEngine()
    @State private var sky = SkyEngine()
    @State private var listHeight = 0.0
    /// Taller session lists scroll.
    private let listMax = 240.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(model.primary == .codex ? "CODEX USAGE" : "CLAUDE USAGE").font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(0.4).foregroundStyle(muted)
                if model.demo && !model.snapshot { Text("DEMO").font(.system(size: 8, weight: .bold)).foregroundStyle(accent) }
                Spacer()
                if model.primary != nil { hearts }
                Button(action: hide) { Image(systemName: "xmark").foregroundStyle(muted).frame(width: 20, height: 20).contentShape(Rectangle()) }.help("Hide widget · reopen from the menu bar")
            }
            .buttonStyle(.plain)
            .padding(18)

            VStack(alignment: .leading, spacing: 14) {
                    // Laid out as in the original widget: sky across the whole row behind the
                    // percentage and the mascot, Clawd standing on the session bar, then the
                    // reset line and the fixed-colour WEEK and model rows.
                    VStack(alignment: .leading, spacing: 0) {
                        ZStack(alignment: .bottomLeading) {
                            if model.showSky { SkyView(engine: sky) }
                            HStack(alignment: .bottom, spacing: 0) {
                                if model.primary != nil {
                                    HStack(alignment: .bottom, spacing: 2) {
                                        Text(model.mainLimit.map { "\($0.percent)" } ?? "--")
                                            .font(.system(size: 30, weight: .light)).monospacedDigit()
                                            .foregroundStyle(levelColor(model.mainLimit?.percent))
                                        Text("%").font(.system(size: 14)).foregroundStyle(lineColor).padding(.bottom, 7)
                                    }.fixedSize().padding(.bottom, 3).padding(.trailing, 10)
                                }
                                // Always present: it also drives the sky. It draws Clawd only while Claude is shown.
                                MascotView(model: model, engine: mascot, astra: astra, sky: sky)
                            }
                        }
                        .frame(height: mascotAreaHeight)
                        .overlay(RightClickMenu { DevMenu.menu(model) })
                        .background(GeometryReader { geometry in
                            Color.clear.onAppear { model.skyWidth = geometry.size.width }
                                .onChange(of: geometry.size.width) { _, width in model.skyWidth = width }
                        })
                        .help(model.skyTip)
                        if model.primary != nil {
                            bar(model.mainLimit?.percent, color: levelColor(model.mainLimit?.percent), height: 6).padding(.top, 1)
                            Text(mainResetText).font(.system(size: 11)).foregroundStyle(resetColor).padding(.top, 7)
                        }
                        if model.showClaude && !model.minimal {
                            if let week = model.usage?.week { limitRow("WEEK", week, color: barWeek).padding(.top, 9) }
                            ForEach((model.usage?.extraWeeks ?? [:]).keys.sorted(), id: \.self) { key in
                                if let value = model.usage?.extraWeeks[key] { limitRow("\(key.uppercased()) · WEEK", value, color: barModel).padding(.top, 7) }
                            }
                        }
                        // Codex limits under their own windows; the first one is the big number when Codex leads.
                        if model.showCodex && !model.minimal {
                            ForEach(Array(codexRows.enumerated()), id: \.offset) { index, entry in
                                limitRow("CODEX · \(entry.title)", entry.limit, color: barCodex).padding(.top, index == 0 ? 11 : 7)
                            }
                        }
                    }
                    // Minimal mode stops at the reset line.
                    if !model.minimal {
                        if model.primary != nil { statusLine }

                        if model.showClaude, let error = model.error { errorView(error) }
                        if model.showClaude, let error = model.storageError { errorView(error) }
                        if model.showCodex, let error = model.codexError { errorView(error) }

                        if model.expanded { sessionList }
                    }
                }.padding(.horizontal, 18).padding(.bottom, 18)

            if model.primary != nil && !model.minimal { footer }
        }
        .foregroundStyle(Color(red: 0.91, green: 0.91, blue: 0.89))
        .background(Color(red: 0.09, green: 0.105, blue: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .frame(width: 340)
        // As tall as the content: the panel follows this height (see App.resizePanel).
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: Double.self) { $0.size.height } action: { model.contentHeight = $0 }
        // Zoom from the settings: everything is laid out in original units and scaled up,
        // as the Windows widget does with its LayoutTransform; the panel grows with it.
        .scaleEffect(model.zoom, anchor: .topLeading)
        .frame(width: 340 * model.zoom, height: model.contentHeight > 0 ? model.contentHeight * model.zoom : nil, alignment: .topLeading)
        .onHover { model.hovering = $0 }
        .preferredColorScheme(.dark)
    }

    private var codexRows: [CodexLimit] {
        let limits = model.codex?.limits ?? []
        return model.primary == .codex ? Array(limits.dropFirst()) : limits
    }

    /// LIVE/STALE and the session counts; a click opens the list.
    private var statusLine: some View {
        HStack {
            HStack(spacing: 5) {
                if model.refreshing && model.primary == .claude { ProgressView().controlSize(.mini) }
                else { Circle().fill(model.stale ? .orange : .green).frame(width: 5, height: 5) }
                Text(model.stale ? "STALE" : "LIVE").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(muted)
            }
            Spacer()
            // Sessions of every shown harness, counted together.
            let count = claudeSessions.count + codexSessions.count
            let working = claudeSessions.filter { $0.status == "busy" }.count + codexSessions.filter { $0.status == "busy" }.count
            let waiting = claudeSessions.filter { $0.status == "waiting" }.count
            HStack(spacing: 5) {
                Text("\(count) \(count == 1 ? "session" : "sessions")")
                Text("·")
                Text("\(working) working")
                if waiting > 0 {
                    Text("·")
                    Text("\(waiting) waiting").foregroundStyle(.yellow)
                }
                Image(systemName: model.expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).frame(width: 10)
            }
            .foregroundStyle(muted)
            .contentShape(Rectangle())
            .onTapGesture { model.expanded.toggle() }
            .help(model.expanded ? "Hide sessions" : "Show sessions")
        }
        .font(.system(size: 11))
    }

    private var footer: some View {
        HStack {
            Text(model.mainFetchedAt.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Waiting for first usage report")
            Spacer()
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).disabled(model.refreshing || model.demo).help("Refresh usage")
        }.foregroundStyle(muted)
        .font(.system(size: 10))
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(.black.opacity(0.15))
    }

    private var hearts: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { index in
                let remaining = Mood.heartHalves(percent: model.mainLimit?.percent ?? 100) - index * 2
                // A lost heart stays in dark grey; a half one is lit on its left half only.
                Image(systemName: "heart.fill").foregroundStyle(heartOff)
                    .overlay(alignment: .leading) {
                        Image(systemName: "heart.fill").foregroundStyle(model.mainLimit == nil ? muted : model.primary == .codex ? barCodex : accent)
                            .mask(alignment: .leading) {
                                GeometryReader { Rectangle().frame(width: $0.size.width * Double(min(2, max(0, remaining))) / 2) }
                            }
                    }
                    .font(.system(size: 10))
            }
        }.padding(.trailing, 8).accessibilityLabel("\(Mood.heartHalves(percent: model.mainLimit?.percent ?? 100)) of 6 health halves")
    }

    private var claudeSessions: [Session] { model.showClaude ? model.sessions : [] }
    private var codexSessions: [Session] { model.showCodex ? model.codexActivity.sessions : [] }

    /// Opened from the sessions line: every live session, scrolling past listMax. With both
    /// harnesses shown, each has its own heading; rows take the harness's colour.
    private var sessionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.showClaude { sessionGroup("CLAUDE", claudeSessions, empty: "No Claude Code sessions running.", tint: accent) }
                if model.showCodex { sessionGroup("CODEX", codexSessions, empty: "No Codex sessions running.", tint: barCodex) }
            }
            .onGeometryChange(for: Double.self) { $0.size.height } action: { listHeight = $0 }
        }
        .frame(height: min(listHeight, listMax))
        .scrollIndicators(listHeight > listMax ? .automatic : .never)
    }

    @ViewBuilder private func sessionGroup(_ title: String, _ sessions: [Session], empty: String, tint: Color) -> some View {
        if model.showClaude && model.showCodex { label(title).padding(.top, title == "CLAUDE" ? 0 : 4) }
        if sessions.isEmpty { Text(empty).font(.system(size: 11)).foregroundStyle(muted) }
        ForEach(sessions) { session in
            HStack(alignment: .top) {
                Image(systemName: session.status == "busy" ? "play.fill" : session.status == "waiting" ? "questionmark.circle" : "circle")
                    .foregroundStyle(session.status == "waiting" ? .yellow : tint)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName).lineLimit(1)
                    Text(session.waitingFor ?? session.cwd).font(.system(size: 9)).foregroundStyle(muted).lineLimit(2)
                }
                Spacer(minLength: 0)
            }.font(.system(size: 11)).help(session.cwd)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.3).foregroundStyle(muted)
    }
    /// Green below 60%, yellow from 60%, red from 85%; gray without data (original thresholds).
    private func levelColor(_ percent: Int?) -> Color {
        guard let percent else { return levelDead }
        return percent >= 85 ? levelCrit : percent >= 60 ? levelWarn : levelOk
    }
    private func bar(_ percent: Int?, color: Color, height: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: height / 2).fill(.white.opacity(0.15))
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: height / 2).fill(color)
                    .frame(width: geometry.size.width * Double(min(100, max(0, percent ?? 0))) / 100)
            }
        }.frame(height: height)
    }
    /// "WEEK" row as in the original: 9 pt caption, "23%  ·  2d 10h" on the right, a 4 px bar below.
    private func limitRow(_ title: String, _ value: UsageLimit, color: Color) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(muted)
                Spacer()
                Text("\(value.percent)%" + (value.resetsAt.flatMap { spanText(until: $0, now: model.now) }.map { "  ·  \($0)" } ?? ""))
                    .font(.system(size: 10)).foregroundStyle(lineColor)
            }.padding(.bottom, 4)
            bar(value.percent, color: color, height: 4)
        }
    }
    /// Under the big number. Codex names its window, since it may be the five-hour or the weekly one.
    private var mainResetText: String {
        let failed = model.primary == .claude ? model.error != nil : model.codexError != nil
        guard let limit = model.mainLimit else { return failed ? "no data" : "loading..." }
        let window = model.primary == .codex ? model.codex?.limits.first.map { "\($0.title.lowercased()) · " } ?? "" : ""
        guard let resetsAt = limit.resetsAt else { return window.isEmpty ? "" : String(window.dropLast(3)) }
        return window + (spanText(until: resetsAt, now: model.now).map { "resets in \($0)" } ?? "window closed")
    }
    private func errorView(_ message: String) -> some View {
        Text(message).font(.system(size: 10)).foregroundStyle(.orange).textSelection(.enabled)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Desktop") {
                Toggle("Keep widget on top", isOn: $model.topmost)
                Toggle("Show on all Spaces", isOn: $model.allSpaces)
                Toggle("Show sky and weather behind Clawd", isOn: $model.showSky)
                Toggle("Minimal widget", isOn: $model.minimal)
                Picker("Zoom", selection: $model.zoom) {
                    Text("1×").tag(1.0); Text("1.2×").tag(1.2); Text("1.5×").tag(1.5)
                }.pickerStyle(.segmented)
                CityField(model: model).disabled(!model.showSky)
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        model.refreshLaunchAtLogin()
                        loginError = SMAppService.mainApp.status == .requiresApproval ? "Allow Clawd in System Settings → General → Login Items." : nil
                    } catch { loginError = error.localizedDescription }
                })).disabled(model.demo)
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
            }
            Section("Claude") {
                executableField("claude", path: $model.cliPath, found: model.claudeExecutable,
                                missing: "Claude Code was not found. Install it or choose its executable; until then Claude stays off.")
                Toggle("Show in widget", isOn: available($model.claudeEnabled, model.claudeExecutable)).disabled(model.claudeExecutable == nil)
                Toggle("Show in menu bar", isOn: available($model.claudeMenuBar, model.claudeExecutable)).disabled(model.claudeExecutable == nil)
            }
            Section("Codex") {
                executableField("codex", path: $model.codexPath, found: model.codexExecutable,
                                missing: "Codex was not found. Install it or choose its executable; until then Codex stays off.")
                Toggle("Show in widget", isOn: available($model.codexEnabled, model.codexExecutable)).disabled(model.codexExecutable == nil)
                Toggle("Show in menu bar", isOn: available($model.codexMenuBar, model.codexExecutable)).disabled(model.codexExecutable == nil)
                Text("Limits are read from codex app-server with your Codex login; no model is run. Activity comes from the session logs in ~/.codex.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                Text("Clawd for Mac · \(AppVersion.current)")
                Text("A native companion for Claude Code. Not affiliated with Anthropic. Based on clawd-usage-winwidget.").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Link("Original project", destination: URL(string: "https://github.com/Enhed/clawd-usage-winwidget")!)
                    Link("Mac version", destination: URL(string: "https://github.com/mkozhukh/clawd-usage")!)
                }
            }
        }
        .formStyle(.grouped)
        // Tall enough for everything without scrolling when the screen allows; the window is
        // clamped to the screen and resizable, and the Form scrolls when it is shorter.
        // A grouped Form has no natural height to size by, hence the explicit ideal.
        .frame(width: 460)
        .frame(minHeight: 360, idealHeight: 850)
    }

    /// A path field with a file picker; empty means detect automatically. Below it, where the
    /// executable was found, or why the harness is off.
    private func executableField(_ name: String, path: Binding<String>, found: URL?, missing: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Executable") {
                HStack {
                    TextField(name, text: path, prompt: Text("Detect automatically")).labelsHidden()
                    Button("Choose…") {
                        let picker = NSOpenPanel()
                        picker.canChooseDirectories = false
                        picker.showsHiddenFiles = true
                        if picker.runModal() == .OK, let url = picker.url { path.wrappedValue = url.path }
                    }
                }
            }
            if let found { Text("Found at \(found.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            else { Text(missing).font(.caption).foregroundStyle(.orange) }
        }
    }

    /// Without its executable a harness counts as off: the toggle shows off and cannot be changed,
    /// while the saved choice comes back once the executable is found.
    private func available(_ setting: Binding<Bool>, _ executable: URL?) -> Binding<Bool> {
        Binding(get: { executable != nil && setting.wrappedValue }, set: { if executable != nil { setting.wrappedValue = $0 } })
    }
}

/// Where the weather is for: a city found by name, or empty for the location by IP.
/// Searches after a pause in typing, from three letters; a newer keystroke cancels
/// the pending search (see PlaceSearch).
struct CityField: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var matches: [PlaceMatch] = []
    @State private var searching = false
    @State private var failed = false
    @State private var coordinates = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Weather city", text: $query, prompt: Text("Automatic (by IP)"))
                .onSubmit { if let first = matches.first { pick(first) } }
            if searching { Text("Searching…").font(.caption).foregroundStyle(.secondary) }
            else if failed { Text("Could not reach the city search. Try again later.").font(.caption).foregroundStyle(.orange) }
            else if matches.isEmpty && searchable { Text("No places found.").font(.caption).foregroundStyle(.secondary) }
            ForEach(matches) { match in
                Button { pick(match) } label: {
                    HStack(spacing: 4) {
                        Text(match.name)
                        if !match.detail.isEmpty { Text(match.detail).foregroundStyle(.secondary) }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Coordinates", isExpanded: $coordinates) {
                HStack {
                    // Typed by hand: the city name no longer describes them.
                    TextField("Latitude", text: Binding(get: { model.weatherLat }, set: { query = ""; model.weatherCity = ""; model.weatherLat = $0 }))
                    TextField("Longitude", text: Binding(get: { model.weatherLon }, set: { query = ""; model.weatherCity = ""; model.weatherLon = $0 }))
                }
            }.font(.caption)
            Text("Weather from Open-Meteo (met.no as fallback), city search by Open-Meteo geocoding, location by IP via ipwho.is.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { query = model.weatherCity }
        .onChange(of: model.weatherCity) { _, city in if !city.isEmpty { query = city } }
        .task(id: query) { await search() }
    }

    /// Text that is not yet a chosen city and long enough to look up.
    private var searchable: Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.count >= PlaceSearch.minLength && text != model.weatherCity
    }

    private var status: String {
        if let place = model.weather.configured {
            let at = String(format: "%.2f, %.2f", place.lat, place.lon)
            return "Weather for \(place.city.map { "\($0) (\(at))" } ?? at)."
        }
        if let geo = model.weather.geo { return "Weather for \(geo.city ?? "your location") — found by IP." }
        return "Location will be found by IP."
    }

    private func search() async {
        failed = false
        let text = query.trimmingCharacters(in: .whitespaces)
        if text.isEmpty && !model.weatherCity.isEmpty { model.setPlace(nil) }   // cleared: back to the location by IP
        guard searchable else { matches = []; searching = false; return }
        try? await Task.sleep(for: .milliseconds(400))
        if Task.isCancelled { return }   // still typing
        searching = true
        let found = await PlaceSearch.find(text)
        if Task.isCancelled { return }
        searching = false
        matches = found ?? []
        failed = found == nil
    }

    private func pick(_ match: PlaceMatch) {
        model.setPlace(match)
        query = match.name
        matches = []
    }
}
