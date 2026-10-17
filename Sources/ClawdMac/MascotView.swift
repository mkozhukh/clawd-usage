import AppKit
import SwiftUI
import ClawdCore

// Clawd's behaviour, ported from the Windows widget's lib/mascot-step.ps1 (MIT,
// see THIRD_PARTY_NOTICES). Nothing running: burrows into the sand and sleeps
// with only the eyes out. Sessions idle: wanders, looks around, dozes after ten
// quiet minutes. Something working: runs edge to edge. A session awaits input:
// hops with "?". Session limit used up: lies legs up. One-shot animations play
// on top; health (hearts) sets the pace.

let mascotPx = 2.0, mascotPy = 2.2
let mascotW = Double(ClawdSprite.width) * mascotPx          // 36
let mascotH = Double(ClawdSprite.height) * mascotPy         // 26.4
let mascotSink = 2 * mascotPy                                // the empty lower half-row sits below the ground
let mascotAreaHeight = 43.0                                  // usage row (40) plus the 3 px the area hangs below it

struct MascotScene {
    var geometry = ClawdGeometry()
    var x = 0.0
    var lift = 0.0
    var z: (x: Double, bottom: Double, size: Double, opacity: Double)?
    var bubble: (text: String, color: RGBA, x: Double, bottom: Double)?
    var sweat: (x: Double, top: Double, opacity: Double)?
    var dust: [(x: Double, bottom: Double, opacity: Double)] = []
    var confetti: [(x: Double, bottom: Double, width: Double, color: RGBA)] = []
    var love: (x: Double, bottom: Double, opacity: Double)?
    var tag = ""
    var intervalMs = 90
}

@MainActor
final class MascotEngine: ObservableObject {
    @Published private(set) var scene = MascotScene()
    // Inputs, set by the view each tick.
    var areaWidth = 0.0
    var mood: Mood = .sleep
    var forced: Mood?
    var percent: Int?
    var mouseLook: Int?          // -1/0/1 while the cursor is over the mascot row, else nil
    var hovering = false         // cursor anywhere over the widget: keeps him awake

    private struct Confetti { var x = 0.0, y = 0.0, v = 0.0, d = 0.0 }
    static let confettiColors = ["#FFF87171", "#FFFBBF24", "#FF4ADE80", "#FF60A5FA", "#FFA78BFA", "#FFD77757"].map(RGBA.init)

    private var rng = SystemRandomNumberGenerator()
    private var x = -1.0, dir = 1.0, target: Double?, look = 0
    private var tick = 0, blinkAt = 30
    private var cur = "idle", idleSince = Date()
    private var act: String?, actT = 0
    private var buried = false
    private var loveT = -1, noteT = -1, confT = -1
    private var confetti = Array(repeating: Confetti(), count: 12)
    private var lastFinished = Date.distantPast, lastCelebration = Date.distantPast
    private var entered = false

    /// Lying legs up with the limit used up: plays no animations.
    private var dead: Bool { (forced ?? mood) == .dead }

    private func rnd(_ n: Int) -> Int { Int.random(in: 0..<n, using: &rng) }
    private func rnd() -> Double { Double.random(in: 0..<1, using: &rng) }

    func start(_ name: String) {
        act = name; actT = 0
        if name == "celebrate" { startConfetti() }
    }

    /// Click: a random Claude Code animation and a heart, if he is free.
    func click() {
        if dead { return }
        loveT = 0
        if buried && cur == "sleep" { if act == nil { start("stir") }; return }
        if act != nil { return }
        start(ClawdSprite.clickActs[rnd(ClawdSprite.clickActs.count)])
    }

    /// One-shot events from the model: a session finished (jump), the window reset (celebrate).
    func notice(finished: Date, celebration: Date) {
        if finished > lastFinished { lastFinished = finished; if act == nil && !dead { start("jump") } }
        if celebration > lastCelebration { lastCelebration = celebration; start("celebrate") }
    }

    private func startConfetti() {
        for i in confetti.indices {
            confetti[i] = Confetti(x: x - 12 + rnd() * (mascotW + 24), y: 34 + rnd() * 12, v: 0.9 + rnd() * 1.2, d: (rnd() - 0.5) * 0.8)
        }
        confT = 0
    }

    private func stepAct(_ f: inout ClawdFrame) -> String {
        guard let name = act else { return "" }
        let t = actT
        var bubble = ""
        if let seq = ClawdSprite.sequences[name] {
            // Claude Code animations frame by frame; the pose itself sets the gaze.
            let fr = seq[min(t, seq.count - 1)]
            f.eyes = fr.eyes; f.arms = fr.arms; f.feet = fr.feet; f.off = fr.off; f.x = fr.x
            f.facing = fr.facing; f.poof = fr.poof; f.shadow = fr.shadow; f.look = 0
            if name == "celebrate" { bubble = "!" }
        } else {
            switch name {
            case "wave":
                f.look = 0; f.eyes = "happy"; f.arms = (t / 4) % 2 == 1 ? "down" : "right"
            case "stretch":
                if t >= 4 && t < 18 { f.arms = "up"; f.eyes = "closed"; f.lift = 1.5 }
            case "yawn":
                f.look = 0; f.eyes = t >= 3 && t < 17 ? "yawn" : "closed"
            case "stumble":
                // Flops down (crouched, legs hidden), then gets up and stares, stunned.
                if t < 12 { f.off = 1; f.eyes = "closed" } else { f.eyes = "wide" }
                f.look = 0
            case "burrow":
                // Looks around, digs with its legs sinking into the sand, and closes its eyes.
                if t < 4 { f.look = t < 2 ? -1 : 1 }
                else if t < 24 {
                    f.look = 0; f.eyes = "focus"
                    f.dig = min(ClawdSprite.burrowDig, Int(floor(Double(t - 4) / 3.5)))
                    f.feet = (t / 2) % 2 == 1 ? "left" : "right"
                    f.arms = (t / 2) % 2 == 1 ? "up" : "down"
                    f.spray = t % 3 + 1
                } else { f.look = 0; f.dig = ClawdSprite.burrowDig; f.eyes = t < 27 ? "blink" : "closed" }
            case "unburrow":
                // Eyes wide, jumps out of the sand and shakes itself off.
                f.look = 0
                if t < 3 { f.dig = ClawdSprite.burrowDig; f.eyes = "wide" }
                else if t < 9 {
                    f.dig = max(0, ClawdSprite.burrowDig - (t - 3)); f.eyes = "wide"; f.arms = "up"; f.spray = t % 3 + 1
                    if t == 8 { f.lift = 2 }
                } else if t < 21 {
                    f.eyes = "closed"
                    f.look = (t / 2) % 2 == 1 ? -1 : 1
                    f.feet = (t / 2) % 2 == 1 ? "left" : "right"
                    if t < 15 { f.spray = t % 3 + 1 }
                } else if t < 23 { f.eyes = "blink" }
            case "stir":
                // Rises in the burrow, looks around and sinks back into the sand.
                f.dig = t < 15 ? ClawdSprite.burrowDig - 1 : ClawdSprite.burrowDig
                if t < 3 { f.eyes = "wide"; f.look = 0 }
                else if t < 13 { f.look = t < 8 ? -1 : 1 }
                else if t < 17 { f.eyes = "blink"; f.look = 0 }
                else { f.eyes = "closed"; f.look = 0 }
            default: break
            }
        }
        actT += 1
        if actT >= ClawdSprite.actLength(name) { act = nil }
        return bubble
    }

    func step() {
        tick += 1
        if !entered {   // entrance on widget start, once the mood is known
            entered = true
            if !dead { start(ClawdSprite.entranceActs.randomElement(using: &rng) ?? "jump") }
        }
        let span = max(0, areaWidth - mascotW)
        if x < 0 { x = span / 2 }
        if x > span { x = span }

        var mood = (forced ?? self.mood).rawValue
        let halves: Int? = forced == .dead ? 0 : percent.map { Mood.heartHalves(percent: $0) }
        let tierN = halves ?? 5
        let tier = HealthTier.tier(halves: tierN)
        let perky = tier.speed >= 0.9
        let crit = percent.map { $0 >= 85 } ?? false
        let now = Date()
        if hovering { idleSince = now }
        if mood == "idle" && forced == nil && now.timeIntervalSince(idleSince) >= 600 { mood = "doze" }

        // Falling asleep: burrows once the current animation finishes; waking: climbs out at once.
        if mood == "sleep" {
            if !buried && act == nil { buried = true; start("burrow") }
        } else if buried { buried = false; start("unburrow") }

        var f = ClawdFrame()
        f.look = look
        cur = mood
        var bubble = "", zzz = false, canBlink = true, dust = false

        if act != nil {
            bubble = stepAct(&f)
            canBlink = false
        } else {
            switch mood {
            case "sleep":
                f.dig = ClawdSprite.burrowDig; f.eyes = "closed"; f.look = 0; zzz = true
            case "doze":
                // Nods off, and sometimes startles and goggles.
                f.look = 0
                let p = tick % 70
                if p < 6 { f.eyes = "wide"; if p < 2 { f.lift = 1.5 } } else { f.eyes = "blink"; zzz = true }
            case "dead":
                f.flip = true; f.eyes = "x"; f.look = 0
                let p = tick % 50
                if p < 6 { f.feet = p % 2 == 1 ? "left" : "right" }   // occasionally twitches his legs
            case "wait":
                bubble = "?"; f.eyes = "wide"
                f.look = mouseLook ?? 0
                // Jumps and waves: hey, someone is waiting for you.
                let p = tick % 40
                if p < 8 { let k = Double(p) / 7; f.lift = 12 * k * (1 - k); f.arms = "right" }
            default:
                let speed: Double
                if mood == "work" {
                    speed = 1.6 * tier.speed
                    if target == nil { target = dir > 0 ? span : 0 }   // runs from edge to edge
                } else {
                    speed = 0.6 * tier.speed
                    if target == nil {
                        if rnd(70) == 0 { target = rnd() * span }
                        else if rnd(45) == 0 { look = rnd(3) - 1 }
                        else if rnd(400) == 0 { start(["wave", "stretch", "look"][rnd(3)]) }
                    }
                }
                var walking = false
                if let tg = target {
                    let d = tg - x
                    if abs(d) <= speed {
                        x = tg; target = nil
                        if mood == "work" { dir = -dir }
                    } else {
                        dir = d < 0 ? -1 : 1
                        x += speed * dir
                        look = Int(dir)
                        walking = true
                    }
                }
                if walking {
                    // The less energy, the slower the steps.
                    var step = mood == "work" ? 2 : 3
                    if tier.speed < 0.8 { step += 1 }
                    if tier.speed < 0.5 { step += 1 }
                    f.feet = (tick / step) % 2 == 1 ? "left" : "right"
                    if mood == "work" {
                        if f.feet == "left" && perky { f.lift = 1 }
                        dust = true
                        if perky && rnd(150) == 0 { start("jump") }
                    } else if perky && noteT < 0 && rnd(80) == 0 { noteT = 0 }   // whistles while walking
                    if tier.stumble > 0 && rnd(tier.stumble) == 0 { start("stumble") }
                } else if crit {
                    look = (tick / 5) % 2 == 1 ? -1 : 1   // limit running out: eyes dart nervously
                } else if let ml = mouseLook { look = ml }   // standing: follows the cursor
                f.look = look
                if mood == "work" { f.eyes = "focus" }
                // Full of energy: jumps for joy; tired: yawns.
                if act == nil {
                    if tier.hop > 0 && rnd(tier.hop) == 0 { start("jump") }
                    if tier.yawn > 0 && rnd(tier.yawn) == 0 { start("yawn") }
                }
            }
        }

        // Tired eyes on top of the normal and working ones.
        if !tier.eyes.isEmpty && act == nil && (f.eyes == "open" || f.eyes == "focus") { f.eyes = tier.eyes }
        // Petted: pleased.
        if loveT >= 0 && act == nil && f.eyes == "open" { f.eyes = "happy" }
        // Whistling: notes, if there are no other bubbles.
        if noteT >= 0 {
            if bubble.isEmpty && mood == "idle" { bubble = "♪" }
            noteT += 1
            if noteT >= 30 { noteT = -1 }
        }
        if canBlink && f.eyes == "open" && tick >= blinkAt {
            f.eyes = "blink"
            if tick >= blinkAt + 1 { blinkAt = tick + 25 + rnd(45) }
        }

        var s = MascotScene()
        s.geometry = ClawdSprite.geometry(f)
        // Claude Code animations run at their pace, 60 ms per frame; everything else 90 ms.
        s.intervalMs = act.map { ClawdSprite.sequences[$0] != nil } ?? false ? ClawdSprite.frameMs : 90
        var rx = x
        if tier.stagger && mood != "sleep" && mood != "dead" { rx += 1.5 * sin(Double(tick) / 3) }   // barely alive: sways
        s.x = rx.rounded()
        s.lift = f.lift

        // Sleep: a "z" floats up from behind the head and fades.
        if zzz {
            let p = Double(tick % 30) / 30
            let zb: Double = f.dig > 0 ? 9 : f.off > 0 ? 12 : 19
            s.z = (x + 28 + 3 * sin(p * 2 * .pi), zb + 14 * p, 7 + 4 * p, 1 - p)
        }
        // Bubble over the head: "?" a session awaits a reply, "!" celebration.
        if !bubble.isEmpty {
            let c = bubble == "?" ? RGBA("#FFFBBF24") : bubble == "!" ? RGBA("#FF4ADE80") : RGBA("#FF93C5FD")
            s.bubble = (bubble, c, x + mascotW / 2 - 6, 22 + f.lift + 1.5 * sin(Double(tick) / 3))
        }
        // Session limit almost used up: sweats.
        if (crit || tier.sweat) && mood != "sleep" && mood != "dead" {
            let p = Double(tick % 20) / 20
            s.sweat = (f.look < 0 ? 31 : 2, -2 + 6 * p - f.lift, 1 - p)
        }
        // Dust from under the feet while running.
        if dust {
            for i in 0..<3 {
                let p = Double((tick + i * 3) % 9) / 9
                let dx = dir > 0 ? 4 - 8 * p - 2 * Double(i) : mascotW - 6 + 8 * p + 2 * Double(i)
                s.dust.append((x + dx, 4 * p, 0.7 * (1 - p)))
            }
        }
        // Confetti: falls, drifts sideways and shimmers as it flips.
        if confT >= 0 {
            for i in confetti.indices {
                confetti[i].y -= confetti[i].v; confetti[i].x += confetti[i].d
                if confetti[i].y > 0 {
                    s.confetti.append((confetti[i].x, confetti[i].y, ((tick + i) / 2) % 2 == 1 ? 2.5 : 1.2, Self.confettiColors[i % Self.confettiColors.count]))
                }
            }
            confT += 1
            if confT >= 45 { confT = -1 }
        }
        // Petted (click): a heart floats up.
        if loveT >= 0 {
            let k = Double(loveT) / 20
            s.love = (x + mascotW / 2 - 5 + 2 * sin(k * 6), 23 + f.lift + 14 * k, 1 - k)
            loveT += 1
            if loveT >= 20 { loveT = -1 }
        }
        // Developer caption: what is being shown now.
        if forced != nil { s.tag = "dev · " + (act ?? mood) }
        scene = s
    }
}

struct MascotView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: MascotEngine
    @ObservedObject var sky: SkyEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let heart = pixelRects([".##.##.", "#######", "#######", ".#####.", "..###..", "...#..."])
    static let heartPx = 1.4

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let s = engine.scene
                let h = size.height
                let top = h + mascotSink - s.lift - mascotH
                func fill(_ rects: [PixelRect], _ hex: String) {
                    var path = Path()
                    for r in rects { path.addRect(CGRect(x: s.x + r.x * mascotPx, y: top + r.y * mascotPy, width: r.w * mascotPx, height: r.h * mascotPy)) }
                    context.fill(path, with: .color(color(RGBA(hex))))
                }
                fill(s.geometry.body, "#FFD77757")
                fill(s.geometry.eyes, "#FF141416")
                fill(s.geometry.fx, "#FF6B7280")
                fill(s.geometry.sand, "#FFB8955E")
                if let sw = s.sweat {
                    context.fill(Path(CGRect(x: s.x + sw.x, y: top + sw.top, width: 3, height: 4.5)), with: .color(color(RGBA("#FF7DD3FC").opacity(sw.opacity))))
                }
                for d in s.dust { context.fill(Path(CGRect(x: d.x, y: h - d.bottom - 2, width: 2, height: 2)), with: .color(color(RGBA("#FF8B8B94").opacity(d.opacity)))) }
                for c in s.confetti { context.fill(Path(CGRect(x: c.x, y: h - c.bottom - 2.5, width: c.width, height: 2.5)), with: .color(color(c.color))) }
                if let love = s.love {
                    var path = Path()
                    for r in Self.heart { path.addRect(CGRect(x: love.x + r.x * Self.heartPx, y: h - love.bottom - 6 * Self.heartPx + r.y * Self.heartPx, width: r.w * Self.heartPx, height: Self.heartPx)) }
                    context.fill(path, with: .color(color(RGBA("#FFF87171").opacity(love.opacity))))
                }
                if let z = s.z {
                    context.draw(Text("z").font(.system(size: z.size, weight: .semibold)).foregroundColor(color(RGBA("#FF8B8B94").opacity(z.opacity))),
                                 at: CGPoint(x: z.x, y: h - z.bottom), anchor: .bottomLeading)
                }
                if let b = s.bubble {
                    context.draw(Text(b.text).font(.system(size: 11, weight: .bold)).foregroundColor(color(b.color)),
                                 at: CGPoint(x: b.x + 6, y: h - b.bottom), anchor: .bottom)
                }
                if !s.tag.isEmpty {
                    context.draw(Text(s.tag).font(.system(size: 8)).foregroundColor(color(RGBA("#FF6B7280"))), at: .zero, anchor: .topLeading)
                }
            }
            .onAppear { engine.areaWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { _, width in engine.areaWidth = width }
        }
        .contentShape(Rectangle())
        .onTapGesture { engine.click() }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let cx = engine.scene.x + mascotW / 2
                engine.mouseLook = point.x > cx + 10 ? 1 : point.x < cx - 10 ? -1 : 0
            case .ended: engine.mouseLook = nil
            }
        }
        .accessibilityLabel("Clawd is \(model.mood.rawValue)")
        .help("Click Clawd to say hello. Right-click to preview a mood, the sky or the weather.")
        .task(id: reduceMotion) { await run() }
    }

    /// Mascot timer: 90 ms, 60 ms during Claude Code animations; paused while hidden.
    /// With Reduce Motion Clawd stands still and the sky is redrawn once a second, without motion.
    private func run() async {
        while !Task.isCancelled {
            guard model.visible else { try? await Task.sleep(for: .milliseconds(250)); continue }
            if !reduceMotion {
                engine.mood = model.mood
                engine.forced = model.forcedMood
                engine.percent = model.usage?.session.percent
                engine.hovering = model.hovering
                engine.notice(finished: model.sessionFinished, celebration: model.celebration)
                engine.step()
            }
            if model.showSky {
                sky.forcePhase = model.forcedPhase
                sky.forceWeather = model.forcedWeather
                sky.step(width: model.skyWidth, height: mascotAreaHeight, now: .now, sun: model.weather.sunTimes(),
                         weather: model.weather.current, latitude: model.weather.place?.lat ?? 50, animate: !reduceMotion)
            }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 1000 : engine.scene.intervalMs))
        }
    }
}

/// Right-click on Clawd or the sky: developer mode, as in the Windows widget's
/// lib/mascot-menu.ps1. A choice holds until "Auto". An AppKit menu built once per
/// click: a SwiftUI context menu is rebuilt on every animation frame, which keeps
/// closing its submenus.
@MainActor
enum DevMenu {
    static func menu(_ model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionItem("Auto", on: model.forcedMood == nil && model.forcedPhase == nil && model.forcedWeather == nil) {
            model.forcedMood = nil; model.forcedPhase = nil; model.forcedWeather = nil
        })
        menu.addItem(.separator())
        menu.addItem(submenu("Mood", [("Live", model.forcedMood == nil, { model.forcedMood = nil })]
            + Mood.allCases.map { mood in (mood.rawValue.capitalized, model.forcedMood == mood, { model.forcedMood = mood }) }))
        let phase = submenu("Time of day", [("By the clock", model.forcedPhase == nil, { model.forcedPhase = nil })]
            + SkyPhase.allCases.map { phase in (phase.rawValue.capitalized, model.forcedPhase == phase, { model.forcedPhase = phase }) })
        let weather = submenu("Weather", [("Live", model.forcedWeather == nil, { model.forcedWeather = nil })]
            + WeatherKind.previewCodes.map { item in (item.name.capitalized, model.forcedWeather == item.code, { model.forcedWeather = item.code }) })
        phase.isEnabled = model.showSky; weather.isEnabled = model.showSky
        menu.addItem(phase); menu.addItem(weather)
        return menu
    }

    private static func submenu(_ title: String, _ items: [(String, Bool, () -> Void)]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (name, on, action) in items { sub.addItem(ActionItem(name, on: on, action)) }
        item.submenu = sub
        return item
    }

    private final class ActionItem: NSMenuItem {
        private let run: () -> Void
        init(_ title: String, on: Bool, _ run: @escaping () -> Void) {
            self.run = run
            super.init(title: title, action: #selector(fire), keyEquivalent: "")
            target = self
            state = on ? .on : .off
        }
        required init(coder: NSCoder) { fatalError("not used") }
        @objc private func fire() { run() }
    }
}

/// Catches only right-clicks (and control-clicks) and shows the menu; every other
/// event falls through to the views below, so clicks on Clawd and hover still work.
struct RightClickMenu: NSViewRepresentable {
    var menu: () -> NSMenu

    func makeNSView(context: Context) -> Catcher { Catcher() }
    func updateNSView(_ view: Catcher, context: Context) { view.build = menu }

    final class Catcher: NSView {
        var build: (() -> NSMenu)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            let wanted = e.type == .rightMouseDown || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
            return wanted ? super.hitTest(point) : nil
        }
        override func rightMouseDown(with event: NSEvent) { show(event) }
        override func mouseDown(with event: NSEvent) { show(event) }
        private func show(_ event: NSEvent) {
            guard let menu = build?() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}
