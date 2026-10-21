import SwiftUI
import ClawdCore

// The sky spans the whole usage row behind the percentage and the mascot, as
// in the Windows widget's lib/sky.ps1: colour follows the real sunrise and
// sunset, the sun and the moon (in its real phase) travel an arc, stars
// twinkle at night, and the weather brings clouds, fog, rain, snow and storms.

struct SkyScene {
    struct Star { var x: Double; var y: Double; var opacity: Double }
    struct Cloud { var shape: Int; var x: Double; var y: Double; var opacity: Double }
    struct Fog { var x: Double; var y: Double; var w: Double; var opacity: Double }
    struct Body { var x: Double; var y: Double; var opacity: Double }
    var top = RGBA("#00304A8C"), bottom = RGBA("#1A304A8C")
    var stars: [Star] = []
    var sun: Body?, sunColor = SkyPalette.sunHigh, glow: Body?
    var moon: Body?, moonLit: [PixelRect] = [], moonDark: [PixelRect] = []
    var clouds: [Cloud] = [], cloudColor = SkyPalette.cloudDay
    var fog: [Fog] = []
    var drops: [CGPoint] = [], flakes: [CGPoint] = []
    var ground: RGBA?
    var flash = 0.0
}

@MainActor
final class SkyEngine: ObservableObject {
    @Published private(set) var scene = SkyScene()
    var forcePhase: SkyPhase?
    var forceWeather: Int?

    static let cloudShapes: [[PixelRect]] = [
        pixelRects(["....###.....", "..#######...", ".##########.", "############"]),
        pixelRects(["..###...", ".######.", "########"]),
        pixelRects(["...##.##..", ".########.", "##########"])
    ]
    static let cloudWidths: [Double] = [24, 16, 20]
    static let sunBody = pixelRects(["..###..", ".#####.", "#######", "#######", "#######", ".#####.", "..###.."])

    private struct Star { var fx: Double; var fy: Double }
    private struct Cloud { var x = -1.0; var fy: Double; var v: Double; var fade = 0.0 }
    private struct Fog { var x: Double; var fy: Double }
    private struct Drop { var x = 0.0; var y = -99.0; var v = 0.0; var ph = 0.0 }

    private var rng = SystemRandomNumberGenerator()
    private var stars: [Star] = (0..<20).map { _ in Star(fx: .random(in: 0..<1), fy: .random(in: 0..<0.6)) }
    private var clouds: [Cloud] = (0..<9).map { _ in Cloud(fy: 0.05 + 0.3 * .random(in: 0..<1), v: 0.7 + 0.6 * .random(in: 0..<1)) }
    private var fog: [Fog] = (0..<3).map { Fog(x: .random(in: 0..<1), fy: 0.42 + 0.2 * Double($0)) }
    private var drops = Array(repeating: Drop(), count: 40)
    private var flakes = Array(repeating: Drop(), count: 34)
    private var tick = 0, flash = 0
    private var w = 0.0, h = 0.0
    private var key = "", moonKey = ""
    private var light = 0.0, starOp = 0.0
    private var kind = WeatherKind.resolve(code: 0)
    private var nClouds = 0, nRain = 0, nSnow = 0

    private func rnd() -> Double { Double.random(in: 0..<1, using: &rng) }

    /// animate false (Reduce Motion): colours, sun and moon follow the clock, but nothing moves.
    func step(width: Double, height: Double, now: Date, sun: (sr: Double, ss: Double), weather: WeatherReport?, latitude: Double, animate: Bool = true) {
        if animate { tick += 1 }
        let motion = animate ? 1.0 : 0.0
        guard width > 0, height > 0 else { return }
        if width != w || height != h { w = width; h = height; key = "" }
        var s = scene
        let cal = Calendar.current
        var t = Double(cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)) + Double(cal.component(.second, from: now)) / 60
        if let forcePhase { t = SkyPalette.minute(for: forcePhase, sunrise: sun.sr, sunset: sun.ss) }
        let code = forceWeather ?? weather?.code ?? 0
        let wind = forceWeather != nil ? 12.0 : weather?.wind ?? 8.0

        // Recompute colours once a minute or when the weather changes.
        let k = "\(Int(t))|\(code)|\(w)|\(h)"
        if k != key {
            key = k
            kind = WeatherKind.resolve(code: code)
            let blend = SkyPalette.blend(minute: t, sunrise: sun.sr, sunset: sun.ss, cover: kind.cover)
            light = blend.light
            s.top = blend.top; s.bottom = blend.bottom
            // Snow has settled: a thin white strip underfoot.
            s.ground = kind.snow > 0 ? RGBA.mix(SkyPalette.snowNight, SkyPalette.snowDay, light) : nil
            var cc = RGBA.mix(SkyPalette.cloudNight, SkyPalette.cloudDay, light)
            if kind.rain > 0 || kind.storm { cc = RGBA.mix(cc, SkyPalette.cloudRain, 0.55) }
            s.cloudColor = cc

            // Sun: by day along the arc from sunrise to sunset, orange near the horizon.
            let vis = max(0, 1 - kind.cover * 1.15)
            let p = (t - sun.sr) / (sun.ss - sun.sr)
            s.sun = nil; s.glow = nil
            if vis > 0, let body = onArc(p, half: 4.9, opacity: vis) {
                s.sun = body
                s.glow = onArc(p, half: 10, opacity: vis)
                s.sunColor = RGBA.mix(SkyPalette.sunLow, SkyPalette.sunHigh, sin(.pi * p) * 1.6)
            }
            // Moon: at night, from sunset to the next sunrise, in its real phase.
            let age = MoonPhase.age(at: now)
            let mk = "\(Int((age * 2).rounded()))|\(latitude < 0)"
            if mk != moonKey {
                moonKey = mk
                let px = MoonPhase.pixels(age: age, southern: latitude < 0)
                s.moonLit = pixelRects(px.lit); s.moonDark = pixelRects(px.dark)
            }
            let q = ((t - sun.ss + 1440).truncatingRemainder(dividingBy: 1440)) / (sun.sr + 1440 - sun.ss)
            s.moon = vis > 0 ? onArc(q, half: 4.55, opacity: vis) : nil

            starOp = (1 - light * 2) * max(0, 1 - kind.cover * 1.4)
            // Weather counts are tuned for a ~140px strip; a wider sky gets more.
            let dens = max(1.0, w / 140)
            nClouds = min(clouds.count, Int((kind.cover * 5 * dens).rounded()))
            nRain = min(drops.count, Int((Double(kind.rain) * dens).rounded()))
            nSnow = min(flakes.count, Int((Double(kind.snow) * dens).rounded()))
            for i in clouds.indices where clouds[i].x < 0 { clouds[i].x = rnd() * w }
        }

        // Stars twinkle.
        s.stars = starOp <= 0 ? [] : stars.enumerated().map { i, st in
            SkyScene.Star(x: (st.fx * (w - 2)).rounded(), y: (2 + st.fy * h).rounded(),
                          opacity: starOp * (0.55 + 0.45 * sin(Double(tick) / 7 + Double(i) * 1.7)))
        }
        // Clouds drift with the wind, extra ones fade out, needed ones fade in.
        let drift = (0.04 + wind / 350) * motion
        s.clouds = []
        for i in clouds.indices {
            let want = i < nClouds ? 1.0 : 0.0
            clouds[i].fade = animate ? clouds[i].fade + max(-0.03, min(0.03, want - clouds[i].fade)) : want
            if clouds[i].fade <= 0 { continue }
            clouds[i].x += drift * clouds[i].v
            let shape = i % Self.cloudShapes.count
            if clouds[i].x > w { clouds[i].x = -Self.cloudWidths[shape]; clouds[i].fy = 0.05 + 0.3 * rnd() }
            s.clouds.append(.init(shape: shape, x: clouds[i].x.rounded(), y: (clouds[i].fy * h).rounded(), opacity: 0.65 * clouds[i].fade))
        }
        // Fog: translucent bands, crawling slowly.
        s.fog = []
        if kind.fog {
            for i in fog.indices {
                fog[i].x = (fog[i].x + 0.0015 * motion).truncatingRemainder(dividingBy: 1.6)
                s.fog.append(.init(x: (fog[i].x - 0.6) * w, y: fog[i].fy * h, w: w * 0.6,
                                   opacity: 0.14 + 0.05 * sin(Double(tick) / 20 + fog[i].fy * 10)))
            }
        }
        // Rain slants with the wind.
        let slant = min(1.2, wind / 25) * motion
        s.drops = []
        for i in drops.indices {
            if i >= nRain { drops[i].y = -99; continue }
            if drops[i].y < -50 || drops[i].y > h {
                drops[i].x = rnd() * (w + 10) - 10
                drops[i].y = drops[i].y < -50 ? rnd() * h : -4
                drops[i].v = 3.5 + 1.5 * rnd()
            }
            drops[i].y += drops[i].v * motion; drops[i].x += slant
            s.drops.append(CGPoint(x: drops[i].x, y: drops[i].y))
        }
        // Snow falls slowly and sways.
        s.flakes = []
        for i in flakes.indices {
            if i >= nSnow { flakes[i].y = -99; continue }
            if flakes[i].y < -50 || flakes[i].y > h {
                flakes[i].x = rnd() * w
                flakes[i].y = flakes[i].y < -50 ? rnd() * h : -2
                flakes[i].v = 0.3 + 0.35 * rnd()
                flakes[i].ph = rnd() * 6.28
            }
            flakes[i].y += flakes[i].v * motion
            s.flakes.append(CGPoint(x: flakes[i].x + 1.5 * sin(Double(tick) / 9 + flakes[i].ph) + slant * flakes[i].y / 4, y: flakes[i].y))
        }
        // Thunderstorm: now and then the sky flashes, sometimes twice in a row.
        if animate && kind.storm && flash <= 0 && Int.random(in: 0..<140, using: &rng) == 0 { flash = 7 }
        if flash > 0 { s.flash = [0, 0.18, 0.05, 0, 0.25, 0.1, 0.04][flash - 1]; flash -= 1 } else { s.flash = 0 }
        scene = s
    }

    /// Position of a celestial body on the arc: p 0..1 from horizon to horizon.
    private func onArc(_ p: Double, half: Double, opacity: Double) -> SkyScene.Body? {
        if p < -0.06 || p > 1.06 { return nil }
        let alt = sin(.pi * p)
        return .init(x: 7 + p * (w - 14) - half, y: h + 3 - alt * (h - 12) - half, opacity: opacity)
    }
}

struct SkyView: View {
    @ObservedObject var engine: SkyEngine

    var body: some View {
        Canvas { context, size in
            let s = engine.scene
            let w = size.width, h = size.height
            // The sky fades out at both edges.
            context.clipToLayer { mask in
                mask.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                    Gradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                                     .init(color: .black, location: 0.9), .init(color: .clear, location: 1)]),
                    startPoint: .zero, endPoint: CGPoint(x: w, y: 0)))
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [color(s.top), color(s.bottom)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            context.opacity = 0.7
            for st in s.stars { context.fill(Path(CGRect(x: st.x, y: st.y, width: 1.2, height: 1.2)), with: .color(color(RGBA("#FFF8FAFC").opacity(st.opacity)))) }
            if let glow = s.glow {
                context.fill(Path(ellipseIn: CGRect(x: glow.x, y: glow.y, width: 20, height: 20)), with: .radialGradient(
                    Gradient(colors: [color(RGBA("#40FDE68A").opacity(glow.opacity)), color(RGBA("#00FDE68A"))]),
                    center: CGPoint(x: glow.x + 10, y: glow.y + 10), startRadius: 0, endRadius: 10))
            }
            if let sun = s.sun { pixels(&context, Self.sunBody, at: sun, px: 1.4, color: s.sunColor.opacity(sun.opacity)) }
            if let moon = s.moon {
                pixels(&context, s.moonDark, at: moon, px: 1.3, color: RGBA("#2EE5E7EB").opacity(moon.opacity))
                pixels(&context, s.moonLit, at: moon, px: 1.3, color: RGBA("#FFF1F5F9").opacity(moon.opacity))
            }
            for c in s.clouds { pixels(&context, SkyEngine.cloudShapes[c.shape], at: .init(x: c.x, y: c.y, opacity: 1), px: 2, color: s.cloudColor.opacity(c.opacity)) }
            for f in s.fog {
                let band = Color(red: 0.898, green: 0.906, blue: 0.922)
                context.fill(Path(CGRect(x: f.x, y: f.y, width: f.w, height: 3)), with: .linearGradient(
                    Gradient(colors: [band.opacity(0), band.opacity(f.opacity), band.opacity(0)]),
                    startPoint: CGPoint(x: f.x, y: 0), endPoint: CGPoint(x: f.x + f.w, y: 0)))
            }
            for d in s.drops { context.fill(Path(CGRect(x: d.x, y: d.y, width: 1, height: 3.5)), with: .color(color(RGBA("#8093C5FD")))) }
            for f in s.flakes { context.fill(Path(CGRect(x: f.x, y: f.y, width: 1.6, height: 1.6)), with: .color(color(RGBA("#C0E4E4E7")))) }
            if let ground = s.ground { context.fill(Path(CGRect(x: 0, y: h - 1.5, width: w, height: 1.5)), with: .color(color(ground))) }
            if s.flash > 0 { context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color(RGBA("#FFF8FAFC").opacity(s.flash)))) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let sunBody = SkyEngine.sunBody

    private func pixels(_ context: inout GraphicsContext, _ rects: [PixelRect], at body: SkyScene.Body, px: Double, color c: RGBA) {
        var path = Path()
        for r in rects { path.addRect(CGRect(x: body.x + r.x * px, y: body.y + r.y * px, width: r.w * px, height: r.h * px)) }
        context.fill(path, with: .color(color(c)))
    }
}

func color(_ c: RGBA) -> Color { Color(red: c.r, green: c.g, blue: c.b, opacity: c.a) }
