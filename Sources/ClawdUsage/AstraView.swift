import SwiftUI
import ClawdCore

// Astra's behaviour, after the Astra motion sheet. Astra floats in the sky above the
// session bar while Clawd keeps to the ground. Codex working: flies edge to edge with a
// comet tail. A limit at 80%: flickers with shrunken points. A limit used up: falls and
// lies half-buried as a dim ember until the window resets, then re-ignites. Long quiet:
// dozes. One-shot animations play on top; they are timed in seconds, not in ticks, so
// they keep their pace whatever Clawd's frame rate is.

let astraPx = 1.8, astraPy = 1.9
let astraW = Double(AstraSprite.width) * astraPx      // 32.4
let astraH = Double(AstraSprite.height) * astraPy     // 22.8
/// Half-buried: the ember sinks five pixel rows below the ground.
let astraSunk = -5 * astraPy

struct AstraScene {
    var visible = false
    var geometry = AstraGeometry()
    var x = 0.0
    /// Height of the sprite's lower edge above the ground; negative while sunk.
    var bottom = 0.0
    /// 1 lit, 0 a cold ember; the glow scales the halo.
    var bright = 1.0, glow = 1.0
    /// Shrunk to a sky star (Codex turned off): 3 a small cross, 4 a dot, 5 a single pixel.
    var star: Int?
    var trail: [(x: Double, bottom: Double, size: Double, opacity: Double)] = []
    var specks: [(x: Double, bottom: Double, size: Double, color: RGBA, opacity: Double)] = []
    var z: (x: Double, bottom: Double, size: Double, opacity: Double)?
    var bubble: Double?
    var love: (x: Double, bottom: Double, opacity: Double)?
    var tag = ""
}

@MainActor
final class AstraEngine: ObservableObject {
    @Published private(set) var scene = AstraScene()
    // Inputs, set by the view each tick.
    var areaWidth = 0.0
    var shown = false
    var peak: Int?
    var busy = false
    var lastActive: Date?
    var hovering = false
    var mouseLook: Int?
    var forced: AstraMood?
    /// Clawd's centre while he is shown: Astra keeps to the other side and looks at him.
    var clawdCenter: Double?

    static let teal = RGBA("#FF2DD4BF"), tealHi = RGBA("#FFCCFBF1"), ember = RGBA("#FF41605C")
    static let eye = RGBA("#FF141416"), star = RGBA("#FFF8FAFC"), dust = RGBA("#FF8B8B94")
    static let durations: [String: Double] = ["twinkle": 1.2, "spin": 1.2, "done": 1.4, "fall": 0.8, "ignite": 2.5,
                                              "sparkle": 1.6, "duo": 2.8, "fade": 1.2, "grow": 0.9, "pulse": 0.6]
    static let twinkleFrames = ["long", "flare", "flare", "long", "short", "long", "flare", "long"]

    private var rng = SystemRandomNumberGenerator()
    private var act: String?, actStart = Date.distantPast
    private var present = false, settled = false
    private var mood: AstraMood = .hover
    private var x = -1.0, dir = 1.0, look = 0, side = 1.0
    private var from = (x: 0.0, bottom: 0.0), landX = 0.0, landedAt = Date.distantPast
    private var trail: [(x: Double, bottom: Double)] = []
    private var lastStep = Date()
    private var nextIdle = Date().addingTimeInterval(8)
    private var lastFinished = Date.distantPast, lastReset = Date.distantPast, lastCelebration = Date.distantPast
    private var wave = false

    private func rnd() -> Double { Double.random(in: 0..<1, using: &rng) }
    private var hoverBottom: Double { clawdCenter == nil ? 12 : 16 }

    func start(_ name: String, _ now: Date = .now) {
        act = name; actStart = now
        if name == "fall" { from = (x, scene.bottom); landX = min(max(0, areaWidth - astraW), x + 18 * dir) }
        if name == "duo" { wave = true }
    }

    /// Click: spin; an ember only glows up for a moment.
    func click() {
        guard present, act == nil else { return }
        start(mood == .ember ? "pulse" : "spin")
    }

    /// One-shot events: a Codex task finished, a Codex window reset, Claude's window reset.
    /// Both resets close together: Astra and Clawd greet each other.
    func notice(finished: Date, reset: Date, celebration: Date) {
        if finished > lastFinished { lastFinished = finished; if present && act == nil && mood != .ember { start("done") } }
        if reset > lastReset {
            lastReset = reset
            // An ember re-ignites when the mood leaves .ember on the same refresh.
            if present && mood != .ember { start(clawdCenter != nil && abs(reset.timeIntervalSince(lastCelebration)) < 300 ? "duo" : "sparkle") }
        }
        if celebration > lastCelebration {
            lastCelebration = celebration
            if present && act == nil && mood != .ember && clawdCenter != nil && abs(celebration.timeIntervalSince(lastReset)) < 300 { start("duo") }
        }
    }

    /// Astra asked Clawd to wave back; true once per greeting.
    func takeWave() -> Bool { defer { wave = false }; return wave }

    /// Whether a point in the mascot area lands on Astra.
    func contains(_ point: CGPoint, height: Double) -> Bool {
        guard scene.visible else { return false }
        let top = height - scene.bottom - astraH
        return CGRect(x: scene.x - 4, y: top - 4, width: astraW + 8, height: astraH + 8).contains(point)
    }

    func step(now: Date = .now, animate: Bool) {
        let dt = min(0.25, now.timeIntervalSince(lastStep)); lastStep = now
        let span = max(0, areaWidth - astraW)
        // Away from Clawd: it moves over only when he wanders well into its side, so it does
        // not cross back and forth while he walks around the middle. Alone it keeps to the middle.
        if let c = clawdCenter { if c > areaWidth * 0.65 { side = -1 } else if c < areaWidth * 0.35 { side = 1 } }
        let home = clawdCenter == nil ? span / 2 : side > 0 ? span * 0.8 : span * 0.2
        if x < 0 { x = home }
        x = min(x, span)

        // Codex turned on or off: grows out of a sky star, or shrinks back into one.
        if shown && !present { present = true; settled = false; start(animate ? "grow" : "none", now) }
        if !shown && present && act != "fade" { if animate { start("fade", now) } else { present = false } }
        guard present else { scene = AstraScene(); trail = []; return }

        var next = forced ?? AstraMood.resolve(peak: peak, busy: busy, lastActive: lastActive, now: now)
        if next == .doze && hovering && forced == nil { next = .hover }   // the cursor keeps Astra awake
        if !settled { settled = true; mood = next; if next == .ember { landX = x } }
        if next != mood && act != "fade" && act != "grow" {
            if next == .ember { if animate { start("fall", now) } else { landX = x } }
            else if mood == .ember { if animate { start("ignite", now) } else { x = home } }
        }
        mood = next
        if !animate && act != nil { act = nil }

        let t = now.timeIntervalSinceReferenceDate
        let bob = animate ? (1.5 * sin(t / 2.4 * 2 * .pi)).rounded() : 0
        let blink = animate && t.truncatingRemainder(dividingBy: 4.3) > 4.12
        var f = AstraFrame()
        var s = AstraScene()
        s.visible = true
        var bottom = hoverBottom + bob
        var flying = false

        switch mood {
        case .ember:
            x = landX; bottom = astraSunk
            f.points = "short"; f.eyes = "closed"; s.bright = 0; s.glow = 0.35 + (animate ? 0.2 * sin(t * 3) : 0)
        case .comet:
            flying = animate
            if animate {
                x += 48 * dt * dir
                if x >= span { x = span; dir = -1 } else if x <= 0 { x = 0; dir = 1 }
                bottom = hoverBottom + (2 * sin(t * 2)).rounded()
            }
            f.points = "short"; look = Int(dir); f.look = look
        default:
            // Drifts slowly around its place; after a flight it glides home.
            if animate { x += (home + 6 * sin(t / 9) - x) * min(1, 2 * dt) }
            if mood == .doze {
                bottom = hoverBottom + (animate ? (sin(t / 4 * 2 * .pi)).rounded() : 0)
                f.points = "short"; f.eyes = "closed"; s.bright = 0.55; s.glow = 0.6
                if animate {
                    let p = t.truncatingRemainder(dividingBy: 3) / 3
                    // Whole point sizes: each new size is a new font for the text system, every frame.
                    s.z = (x + astraW - 2 + 3 * sin(p * 2 * .pi), bottom + astraH - 4 + 12 * p, (7 + 3 * p).rounded(), 1 - p)
                }
            } else if mood == .low {
                f.eyes = blink ? "closed" : "down"
                if animate {
                    let frame = Int(t * 12)
                    s.bright = hash(frame) < 0.12 ? 0.2 : 0.6 + 0.4 * hash(frame + 99)
                    f.points = (peak ?? 0) >= 95 || Int(t * 2) % 2 == 1 ? "tiny" : "short"
                } else { s.bright = 0.7; f.points = "short" }
            } else {
                if animate && act == nil && now > nextIdle {
                    let r = rnd()
                    start(r < 0.15 && clawdCenter != nil ? "duo" : r < 0.4 ? "spin" : "twinkle", now)
                    nextIdle = now.addingTimeInterval(9 + rnd() * 9)
                } else if animate && rnd() < 0.01 { look = Int(rnd() * 3) - 1 }
                f.eyes = blink ? "closed" : "open"
                f.look = mouseLook ?? look
            }
        }

        if let name = act {
            let lt = now.timeIntervalSince(actStart)
            let center = (x: x + astraW / 2, bottom: bottom + astraH / 2)
            switch name {
            case "twinkle":
                f.points = Self.twinkleFrames[min(7, Int(lt / 0.15))]; f.eyes = f.points == "flare" ? "happy" : "open"
            case "spin":
                f.squash = cos(Double(Int(lt / 0.1)) / 12 * 2 * .pi); bottom += (4 * sin(.pi * min(1, lt / 1.2))).rounded()
            case "done":
                if lt < 0.5 { bottom += 6 * sin(.pi * lt / 0.5) }
                f.points = Int(lt / 0.1) % 2 == 1 ? "flare" : "long"; f.eyes = "happy"
                ring(&s, center, radius: 6 + lt * 26, opacity: 1 - lt / 1.4)
                if lt < 1.2 { s.bubble = bottom + astraH + 2 }
            case "fall":
                let p = min(1, lt / 0.8)
                x = from.x + (landX - from.x) * p; bottom = from.bottom + (astraSunk - from.bottom) * p * p
                f = AstraFrame(points: "long", eyes: "wide", squash: cos(Double(Int(p * 10)) / 10 * 3 * .pi))
                s.bright = 0.8; s.glow = 0.8; flying = true; landedAt = actStart.addingTimeInterval(0.8)
            case "ignite":
                if lt < 0.5 {
                    s.bright = lt * 0.6; s.glow = 0.3 + 0.3 * abs(sin(lt * 8))
                } else {
                    let p = min(1, (lt - 0.5) / 0.8), e = 1 - (1 - p) * (1 - p)
                    x = landX + (home - landX) * e; bottom = astraSunk + (hoverBottom + bob - astraSunk) * e
                    s.bright = 0.3 + 0.7 * p; s.glow = 1
                    f = lt < 1.3 ? AstraFrame(points: "flare", eyes: "happy") : twinkle(lt - 1.3)
                    sparks(&s, (landX + astraW / 2, astraSunk + astraH / 2), lt - 0.5)
                }
            case "sparkle":
                f = twinkle(lt.truncatingRemainder(dividingBy: 1.2)); sparks(&s, center, lt)
            case "duo":
                let toward = clawdCenter.map { $0 < center.x ? -1 : 1 } ?? 0
                if lt < 1.6 { f = AstraFrame(points: Int(lt / 0.3) % 2 == 1 ? "flare" : "long", eyes: "happy", look: toward) }
                else {
                    f.squash = cos(Double(Int((lt - 1.6) / 0.1)) / 12 * 2 * .pi)
                    let k = (lt - 1.6) / 1.2
                    let mid = ((clawdCenter ?? center.x) + center.x) / 2
                    s.love = (mid - 5, 16 + 14 * k, 1 - k)
                }
            case "pulse":
                s.glow = 0.4 + 0.6 * (1 - lt / 0.6); f.eyes = lt < 0.3 ? "wide" : "closed"
            case "fade", "grow":
                let i = name == "fade" ? min(5, Int(lt / 0.2)) : max(0, 5 - Int(lt / 0.15))
                if i < 3 { f.points = ["long", "short", "tiny"][i]; s.glow = 1 - Double(i) * 0.3 } else { s.star = i; s.glow = 0 }
            default: break
            }
            if lt >= Self.durations[name] ?? 0 {
                act = nil
                if name == "fade" { present = false; scene = AstraScene(); trail = []; return }
                if name == "ignite" { x = home }
            }
        }

        // Dust where the falling star hit the ground.
        let sinceLanding = now.timeIntervalSince(landedAt)
        if mood == .ember && sinceLanding >= 0 && sinceLanding < 0.6 {
            let d = sinceLanding / 0.6
            for i in 0..<8 {
                let side = i % 2 == 0 ? -1.0 : 1.0, sp = 0.6 + 0.6 * hash(i + 4)
                s.specks.append((landX + astraW / 2 + side * d * 20 * sp, d * (1 - d) * 26 * sp, 2, Self.dust, 1 - d))
            }
        }
        // Comet tail: where the centre was over the last ticks.
        if flying { trail.insert((x + astraW / 2 - 4 * dir, bottom + astraH / 2), at: 0); trail = Array(trail.prefix(10)) }
        else if !trail.isEmpty { trail.removeLast() }
        for (k, p) in trail.enumerated() where k > 0 {
            s.trail.append((p.x, p.bottom, k < 4 ? 3 : 2, 0.85 * (1 - Double(k) / Double(trail.count))))
        }

        s.geometry = AstraSprite.geometry(f)
        s.x = x.rounded()
        s.bottom = bottom.rounded()
        if forced != nil { s.tag = "codex · " + (act ?? mood.rawValue) }
        scene = s
    }

    private func twinkle(_ lt: Double) -> AstraFrame {
        let p = Self.twinkleFrames[min(7, max(0, Int(lt / 0.15)))]
        return AstraFrame(points: p, eyes: p == "flare" ? "happy" : "open")
    }
    /// Re-ignition and resets: 14 sparks in Clawd's confetti colours.
    private func sparks(_ s: inout AstraScene, _ c: (x: Double, bottom: Double), _ lt: Double) {
        guard lt >= 0 && lt < 1 else { return }
        for i in 0..<14 {
            let a = Double(i) / 14 * 2 * .pi + 0.2, r = lt * 34 * (0.65 + 0.35 * hash(i))
            s.specks.append((c.x + cos(a) * r, c.bottom + sin(a) * r * 0.7 - lt * lt * 8, 2,
                             MascotEngine.confettiColors[i % MascotEngine.confettiColors.count], 1 - lt))
        }
    }
    /// Task done: a ring of glints spreading out.
    private func ring(_ s: inout AstraScene, _ c: (x: Double, bottom: Double), radius: Double, opacity: Double) {
        for i in 0..<16 {
            let a = Double(i) / 16 * 2 * .pi
            s.specks.append((c.x + cos(a) * radius, c.bottom + sin(a) * radius * 0.6, 1.6, Self.tealHi, max(0, opacity)))
        }
    }
    private func hash(_ n: Int) -> Double { let v = sin(Double(n) * 127.1 + 311.7) * 43758.5453; return v - floor(v) }
}

/// Draws Astra into the mascot area's canvas, behind Clawd. `h` is the canvas height (the area
/// plus `mascotBleed` above it); the ground is its lower edge, which also hides the sunk part of the ember.
@MainActor func drawAstra(_ context: GraphicsContext, _ a: AstraScene, size: CGSize) {
    guard a.visible else { return }
    var context = context
    let h = size.height
    context.clip(to: Path(CGRect(origin: .zero, size: size)))
    let top = h - a.bottom - astraH
    let center = CGPoint(x: a.x + astraW / 2, y: top + astraH / 2)
    if a.glow > 0 {
        let r = 26.0, k = 0.28 * a.glow * max(a.bright, 0.3)
        context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                     with: .radialGradient(Gradient(colors: [color(AstraEngine.teal).opacity(k), color(AstraEngine.teal).opacity(0)]),
                                           center: center, startRadius: 0, endRadius: r))
    }
    for p in a.trail {
        context.fill(Path(CGRect(x: p.x - p.size / 2, y: h - p.bottom - p.size / 2, width: p.size, height: p.size)),
                     with: .color(color(AstraEngine.tealHi).opacity(p.opacity)))
    }
    if let star = a.star {
        // Becoming a sky star: whiter as it shrinks.
        let c = color(RGBA.mix(AstraEngine.teal, AstraEngine.star, Double(star - 2) / 3))
        var path = Path()
        switch star {
        case 3: path.addRect(CGRect(x: center.x - 1.5, y: center.y - 4.5, width: 3, height: 9)); path.addRect(CGRect(x: center.x - 4.5, y: center.y - 1.5, width: 9, height: 3))
        case 4: path.addRect(CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3))
        default: path.addRect(CGRect(x: center.x - 0.75, y: center.y - 0.75, width: 1.5, height: 1.5))
        }
        context.fill(path, with: .color(c))
    } else {
        func fill(_ rects: [PixelRect], _ c: RGBA) {
            var path = Path()
            for r in rects { path.addRect(CGRect(x: a.x + r.x * astraPx, y: top + r.y * astraPy, width: r.w * astraPx, height: r.h * astraPy)) }
            context.fill(path, with: .color(color(c)))
        }
        fill(a.geometry.body, RGBA.mix(AstraEngine.ember, AstraEngine.teal, a.bright))
        fill(a.geometry.glint, RGBA.mix(AstraEngine.ember, AstraEngine.tealHi, a.bright))
        fill(a.geometry.eyes, AstraEngine.eye)
    }
    for p in a.specks {
        context.fill(Path(CGRect(x: p.x - p.size / 2, y: h - p.bottom - p.size / 2, width: p.size, height: p.size)),
                     with: .color(color(p.color).opacity(p.opacity)))
    }
    if let z = a.z {
        context.draw(Text("z").font(.system(size: z.size, weight: .semibold)).foregroundColor(color(AstraEngine.dust).opacity(z.opacity)),
                     at: CGPoint(x: z.x, y: h - z.bottom), anchor: .bottomLeading)
    }
    if let b = a.bubble {
        context.draw(Text("!").font(.system(size: 11, weight: .bold)).foregroundColor(color(RGBA("#FF4ADE80"))),
                     at: CGPoint(x: center.x, y: h - b), anchor: .bottom)
    }
    if let love = a.love {
        var path = Path()
        for r in MascotView.heart { path.addRect(CGRect(x: love.x + r.x * MascotView.heartPx, y: h - love.bottom - 6 * MascotView.heartPx + r.y * MascotView.heartPx, width: r.w * MascotView.heartPx, height: MascotView.heartPx)) }
        context.fill(path, with: .color(color(RGBA("#FFF87171")).opacity(love.opacity)))
    }
    if !a.tag.isEmpty {
        context.draw(Text(a.tag).font(.system(size: 8)).foregroundColor(color(RGBA("#FF6B7280"))), at: CGPoint(x: size.width, y: mascotBleed), anchor: .topTrailing)
    }
}
