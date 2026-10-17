import Foundation

// Clawd from the Claude Code welcome screen, built from the same block glyphs as
// the terminal. Ported from the Windows widget's lib/mascot.ps1 (MIT, see
// THIRD_PARTY_NOTICES). 9 cells by 3 rows; each cell is 2x4 pixels so quadrant
// glyphs and the "lower quarter" eyelid map losslessly onto the grid.

public struct PixelRect: Hashable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

/// One drawn pose. Everything is in grid units: `off` in rows, `x` in cells,
/// `dig` in pixel rows sunk into the sand, `lift` in device pixels above ground.
public struct ClawdFrame: Hashable, Sendable {
    public var eyes = "open"
    public var arms = "down"
    public var feet = "both"
    public var look = 0
    public var flip = false
    public var lift = 0.0
    public var off = 0
    public var x = 0
    public var facing = ""
    public var poof = ""
    public var shadow = ""
    public var dig = 0
    public var spray = 0
    public init() {}
    public init(eyes: String = "open", arms: String = "down", feet: String = "both", off: Int = 0, x: Int = 0,
                facing: String = "", poof: String = "", shadow: String = "") {
        self.eyes = eyes; self.arms = arms; self.feet = feet; self.off = off; self.x = x
        self.facing = facing; self.poof = poof; self.shadow = shadow
    }
    /// Geometry key: everything except `lift`, which only moves the canvas.
    public var geometryKey: String {
        "\(eyes)|\(arms)|\(feet)|\(look)|\(flip)|\(off)|\(x)|\(facing)|\(poof)|\(shadow)|\(dig)|\(spray)"
    }
}

public struct ClawdGeometry: Sendable {
    public var body: [PixelRect] = []
    public var eyes: [PixelRect] = []
    public var fx: [PixelRect] = []
    public var sand: [PixelRect] = []
    public init() {}
}

public enum ClawdSprite {
    public static let cols = 9
    public static let rows = 3
    public static let width = 2 * cols      // 18 pixels
    public static let height = 4 * rows     // 12 pixels
    public static let burrowDig = 4

    // Glyph quadrants as bits: 1 top-left, 2 top-right, 4 bottom-left, 8 bottom-right.
    static let quad: [Character: Int] = [
        " ": 0, "█": 15, "▀": 3, "▄": 12, "▌": 5, "▐": 10, "▘": 1, "▝": 2, "▖": 4, "▗": 8,
        "▛": 7, "▜": 11, "▙": 13, "▟": 14
    ]
    // Arms: what sits left and right of the eyes (row 0) and of the chest (row 1).
    static let arms: [String: [String]] = [
        "down": [" ▐", "", "▝▜", "█▀"],
        "up": ["▗▟", "▄", " ▜", "█▘"],
        "right": [" ▐", "▄", "▝▜", "█▘"],
        "left": ["▗▟", "", " ▜", "█▀"]
    ]
    static let feet: [String: String] = ["both": " ▝▝   ▝▝ ", "left": " ▝▝      ", "right": "      ▝▝ "]
    // Turns in place: glyph rows and the columns from..to where the black face shows.
    static let facing: [String: [(String, Int, Int)]] = [
        "right-12": [(" ▐█▜██▛█ ", 2, 8), ("▝▜██████▀", 2, 7), (" ▝▝   ▝▝ ", 0, 0)],
        "right-30": [("  █▛██▛▌ ", 2, 7), (" ▝█████▛ ", 2, 7), ("  ▘▘  ▘▘ ", 0, 0)],
        "right-55": [("  ▐█▛█▜  ", 3, 7), ("  ▐████  ", 3, 7), ("  ▝▝ ▝▝  ", 0, 0)],
        "right-75": [("   ██▛▌  ", 3, 6), ("   ███▌  ", 3, 6), ("   ▘  ▘  ", 0, 0)],
        "edge": [("   ▐██   ", 4, 6), ("   ▐██   ", 4, 6), ("   ▝ ▝   ", 0, 0)],
        "back-105": [("   ███▌  ", 3, 6), ("   ███▌  ", 3, 6), ("   ▘  ▘  ", 0, 0)],
        "back-125": [("  ▐████  ", 3, 7), ("  ▐████  ", 3, 7), ("  ▝▝ ▝▝  ", 0, 0)],
        "back-150": [("  █████▌ ", 2, 7), (" ▝█████▛ ", 2, 7), ("  ▘▘  ▘▘ ", 0, 0)],
        "back": [(" ▐██████ ", 2, 8), ("▝▜██████▀", 2, 7), (" ▝▝   ▝▝ ", 0, 0)],
        "left-75": [("   ▛██▌  ", 3, 6), ("   ███▌  ", 3, 6), ("   ▘  ▘  ", 0, 0)],
        "left-55": [("  ▐▜▛██  ", 3, 7), ("  ▐████  ", 3, 7), ("  ▝▝ ▝▝  ", 0, 0)],
        "left-30": [("  ▛██▛█▌ ", 2, 7), (" ▝█████▛ ", 2, 7), ("  ▘▘  ▘▘ ", 0, 0)],
        "left-12": [(" ▐▛███▜█ ", 2, 8), ("▝▜██████▀", 2, 7), (" ▝▝   ▝▝ ", 0, 0)]
    ]
    // Eyes: black pixels "dx,dy" from the top-left of the eye cell; ";" separates left and right.
    // Looking sideways sits one pixel lower than in the terminal, so the pupils do not touch
    // the top edge of the head and merge with the dark background behind it.
    static let eyeShapes: [String: String] = [
        "open": "1,2 1,3", "left": "0,1 0,2", "right": "2,1 2,2", "closed": "0,3 1,3", "blink": "0,3 1,3",
        "wink": "1,2 1,3;0,3 1,3", "happy": "0,3 1,2 2,3", "focus": "1,3", "wide": "0,1 1,1 0,2 1,2 0,3 1,3",
        "x": "0,1 2,1 1,2 0,3 2,3", "yawn": "0,3 1,3", "gasp": "0,1 2,1 1,2 0,3 2,3"
    ]

    nonisolated(unsafe) private static var cache: [String: ClawdGeometry] = [:]
    private static let lock = NSLock()

    public static func geometry(_ f: ClawdFrame) -> ClawdGeometry {
        let key = f.geometryKey
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let geo = build(f)
        if cache.count > 400 { cache.removeAll() }
        cache[key] = geo
        return geo
    }

    private static func build(_ f: ClawdFrame) -> ClawdGeometry {
        let W = width, H = height
        // 0 empty, 1 body, 2 black (eyes and face).
        var g = Array(repeating: Array(repeating: 0, count: H), count: W)
        func paint(_ glyphs: String, _ col: Int, _ row: Int, _ mode: String) {
            for (i, c) in glyphs.enumerated() {
                let fg = mode == "lid" ? 2 : 1
                let bg = mode == "eyes" ? 2 : mode == "lid" ? 1 : 0
                for sy in 0..<4 { for sx in 0..<2 {
                    let on: Bool
                    if c == "▂" { on = sy == 3 } else {
                        let bit = (sy < 2 ? 1 : 4) * (sx == 1 ? 2 : 1)
                        on = (quad[c] ?? 0) & bit != 0
                    }
                    let v = on ? fg : bg
                    if v != 0 { g[2 * (col + i) + sx][4 * row + sy] = v }
                } }
            }
        }
        if !f.facing.isEmpty, let pose = facing[f.facing] {
            for r in 0..<3 {
                let (s, from, to) = pose[r]
                let chars = Array(s)
                paint(String(chars[0..<from]), 0, r, "")
                paint(String(chars[from..<to]), from, r, "eyes")
                paint(String(chars[to...]), to, r, "")
            }
        } else {
            let a = arms[f.arms] ?? arms["down"]!
            paint(a[0], 0, 0, ""); paint("██████", 2, 0, "eyes"); paint(a[1], 8, 0, "")
            paint(a[2], 0, 1, ""); paint("█████", 2, 1, "eyes"); paint(a[3], 7, 1, "")
            paint(feet[f.feet] ?? feet["both"]!, 0, 2, "")
            // Looking sideways with normal eyes uses the Claude Code poses; otherwise shift the pupils.
            var eyes = f.eyes, shift = 0
            if eyes == "open" && f.look < 0 { eyes = "left" }
            else if eyes == "open" && f.look > 0 { eyes = "right" }
            else if !["open", "left", "right", "wink"].contains(eyes) { shift = f.look }
            let shapes = (eyeShapes[eyes] ?? eyeShapes["open"]!).split(separator: ";").map(String.init)
            for (k, ex) in [4, 12].enumerated() {
                for pt in shapes[min(k, shapes.count - 1)].split(separator: " ") {
                    let d = pt.split(separator: ",").compactMap { Int($0) }
                    guard d.count == 2 else { continue }
                    let px = ex + d[0] + shift
                    if px >= 0 && px < W && d[1] >= 0 && d[1] < H { g[px][d[1]] = 2 }
                }
            }
            if eyes == "yawn" || eyes == "gasp" { for x in 8...10 { g[x][4] = 2; g[x][5] = 2 } }
        }

        var geo = ClawdGeometry()
        // Lowered by off rows and shifted by x cells; outside the frame is clipped.
        // What sank into the burrow is clipped at the ground: the edge of the empty lower half-row.
        let oy = 4 * f.off + f.dig, ox = 2 * f.x
        let lim = f.dig > 0 ? H - 2 : H
        for y in 0..<H {
            var sy = y
            if f.flip { if y >= H - 2 { continue } else { sy = H - 3 - y } }
            let yy = sy + oy
            if yy < 0 || yy >= lim { continue }
            var x = 0
            while x < W {
                let c = g[x][y]
                if c == 0 { x += 1; continue }
                let x0 = x
                while x < W && g[x][y] == c { x += 1 }
                let l = max(0, x0 + ox), rr = min(W, x + ox)
                if rr <= l { continue }
                let rect = PixelRect(Double(l), Double(yy), Double(rr - l), 1)
                if c == 2 { geo.eyes.append(rect) } else { geo.body.append(rect) }
            }
        }
        // Dust "·" and "~" at the edges of the bottom row while crouched.
        if !f.poof.isEmpty && f.off > 0 {
            for cx in [0.0, Double(W - 2)] {
                let pts: [[Double]] = f.poof == "dot" ? [[0.6, 9.4, 0.8, 0.9]]
                    : [[0, 9.6, 0.7, 0.6], [0.7, 9.1, 0.6, 0.6], [1.3, 9.6, 0.7, 0.6]]
                for p in pts { geo.fx.append(PixelRect(cx + p[0], p[1], p[2], p[3])) }
            }
        }
        // Shadow "▁" under the hopping coin.
        if !f.shadow.isEmpty {
            let (sc, sw) = f.shadow == "wide" ? (6.0, 6.0) : (8.0, 2.0)
            geo.fx.append(PixelRect(sc, Double(H) - 0.5, sw, 0.5))
        }
        // Sand mound over the burrow: a strip along the ground and piles where dug.
        let h = Double(H), w = Double(W)
        if f.dig >= 1 { geo.sand.append(PixelRect(-2, h - 3, w + 4, 1)) }
        if f.dig >= 2 { geo.sand.append(PixelRect(-1, h - 4, w + 2, 1)) }
        if f.dig >= 3 { geo.sand.append(PixelRect(-1, h - 5, 2, 1)); geo.sand.append(PixelRect(w - 1, h - 5, 2, 1)) }
        // Sand grains fly in an arc from under the legs to both sides.
        if f.spray > 0 {
            for k in 0...1 {
                let d = Double(f.spray + 2 * k)
                let sx = 1.5 + 0.9 * d, sy = (h - 4) - 0.9 * d * (5 - d) / 2
                geo.sand.append(PixelRect(-sx, sy, 0.8, 0.8))
                geo.sand.append(PixelRect(w - 0.8 + sx, sy, 0.8, 0.8))
            }
        }
        return geo
    }

    // MARK: animations from Claude Code (60 ms per frame)

    public static let frameMs = 60
    static let poses = ["default": "open/down/both", "arms-up": "open/up/both", "look-left": "left/down/both", "look-right": "right/down/both"]

    static func F(_ pose: String, _ n: Int = 1, off: Int = 0, x: Int = 0, poof: String = "", shadow: String = "") -> [ClawdFrame] {
        var fr = ClawdFrame(off: off, x: x, poof: poof, shadow: shadow)
        if pose.hasPrefix("face:") { fr.facing = String(pose.dropFirst(5)) }
        else {
            let parts = (poses[pose] ?? pose).split(separator: "/").map(String.init)
            fr.eyes = parts[0]; fr.arms = parts[1]; fr.feet = parts[2]
        }
        return Array(repeating: fr, count: n)
    }
    static func turn(_ list: [String], shadow: String = "") -> [ClawdFrame] { list.flatMap { F("face:\($0)", shadow: shadow) } }

    public static let sequences: [String: [ClawdFrame]] = {
        let cr = F("default", off: 1, poof: "dot") + F("default", off: 1, poof: "wave")   // crouch before the jump
        let bo = F("default")
        let ts = F("closed/down/both") + bo
        let jump = cr + F("arms-up", 3) + bo + cr + F("arms-up", 3) + bo
        var waddle = F("look-right", x: -9)
        for u in -6...(-1) { waddle += F("right/down/\(u % 2 == 0 ? "left" : "right")", 2, x: u) }
        return [
            "jump": jump,
            "look": F("look-right", 5) + F("look-left", 5) + bo,
            "celebrate": jump + F("default", 3, off: 1),
            "skip": F("default", off: 1, x: -9) + F("arms-up", 2, x: -6) + F("default", x: -6) +
                F("default", off: 1, x: -6) + F("arms-up", 2, x: -3) + F("default", x: -3) +
                F("default", off: 1, x: -3) + F("arms-up", 2) + cr + bo,
            "spin": F("look-left", 2) + F("look-right", 2) + F("look-left", 2) + F("arms-up", 3) + bo,
            "peekaboo": F("default", off: 3) + F("default", 3, off: 2) + F("look-right", 3, off: 2) +
                F("look-left", 3, off: 2) + F("default", 2, off: 2) + F("default", off: 1) +
                F("arms-up", 4) + F("default", 2) + ts,
            "drop": F("arms-up", off: -3) + F("arms-up", 2, off: -2) + F("arms-up", 2, off: -1) +
                F("arms-up") + cr + F("default", 3) + ts,
            "waddle": waddle + F("look-right", 2) + F("default", 2) + ts,
            "peek": F("look-right", x: -9) + F("look-right", 5, x: -6) + F("look-right", 3, x: -9) +
                F("look-right", 4, x: -5) + F("arms-up", 2, x: -3) + F("arms-up", 2) + cr + bo,
            "wink": F("wink/down/both", 5) + bo,
            "boop": F("closed/down/both", off: 1, poof: "dot") + F("closed/down/both", 2, off: 1, poof: "wave") +
                F("look-left", 4) + F("default", 2) + ts,
            "tap": F("open/down/left", 2) + F("open/down/right", 2) + F("open/down/left", 2) +
                F("open/down/right", 2) + F("open/down/left") + F("open/down/right") + F("arms-up", 3) + bo,
            "sneeze": F("closed/up/both", 4) + F("closed/down/both", 2, off: 1, poof: "wave") +
                F("closed/down/both", 2) + F("default", 2) + ts,
            "turn": turn(["right-12", "right-30", "right-55", "right-75", "edge"]) +
                turn(["back-105", "back-125", "back-150", "back", "back"]) +
                turn(["back-150", "back-125", "back-105", "edge"]) +
                turn(["left-75", "left-55", "left-30", "left-12"]) + bo,
            "coin-hop": F("default", 2, off: 1) + F("arms-up", shadow: "wide") +
                turn(["right-55", "edge", "back-125", "back"], shadow: "narrow") +
                turn(["back-125", "edge", "left-55"], shadow: "narrow") +
                F("arms-up", shadow: "wide") + cr + bo
        ]
    }()

    /// Lengths of the custom (non Claude Code) one-shot animations, in 90 ms ticks.
    public static let customActs: [String: Int] = [
        "wave": 24, "stretch": 22, "yawn": 22, "stumble": 20, "burrow": 30, "unburrow": 28, "stir": 22
    ]
    public static func actLength(_ name: String) -> Int { sequences[name]?.count ?? customActs[name] ?? 0 }
    /// On click, as in Claude Code: everything that starts in place (no slide-in).
    public static let clickActs: [String] = sequences.keys.sorted().filter { sequences[$0]![0].x == 0 && $0 != "celebrate" }
    public static let entranceActs: [String] = sequences.keys.sorted().filter { $0 != "celebrate" }
}

/// Health by number of heart halves: walking speed, tired eyes, yawns, sweat, swaying and stumbling.
public struct HealthTier: Sendable {
    public var speed: Double
    public var hop = 0
    public var yawn = 0
    public var eyes = ""
    public var sweat = false
    public var stagger = false
    public var stumble = 0
    public static func tier(halves: Int) -> HealthTier {
        switch halves {
        case 6: return .init(speed: 1.25, hop: 300)
        case 5: return .init(speed: 1.0)
        case 4: return .init(speed: 0.9, yawn: 350)
        case 3: return .init(speed: 0.75, yawn: 200, eyes: "focus")
        case 2: return .init(speed: 0.55, yawn: 160, eyes: "focus", sweat: true)
        case 1: return .init(speed: 0.35, eyes: "blink", sweat: true, stagger: true, stumble: 220)
        default: return .init(speed: 0)
        }
    }
}
