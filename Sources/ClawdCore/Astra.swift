import Foundation

// Astra, the Codex mascot: a four-point star on Clawd's grid, 18 by 12 pixels, so it
// shares Clawd's scale and eye size. Poses follow the Astra motion sheet: the points
// grow and shrink (tiny, short, long, flare with glints), and turning squashes the
// sprite around its centre, as Clawd's facing frames do; the back shows no eyes.

/// One drawn pose of Astra.
public struct AstraFrame: Hashable, Sendable {
    public var points = "long"   // tiny, short, long, flare
    public var eyes = "open"     // open, closed, happy, wide, down
    public var look = 0          // -1 left, 1 right
    public var squash = 1.0      // horizontal scale while turning; negative is the back
    public init(points: String = "long", eyes: String = "open", look: Int = 0, squash: Double = 1) {
        self.points = points; self.eyes = eyes; self.look = look; self.squash = squash
    }
}

public struct AstraGeometry: Sendable {
    public var body: [PixelRect] = []
    public var eyes: [PixelRect] = []
    /// Lighter pixels: the glints of the flare and the shine on the upper left of the core.
    public var glint: [PixelRect] = []
    public init() {}
}

public enum AstraSprite {
    public static let width = 18
    public static let height = 12

    static let long = [
        "........##........",
        "........##........",
        ".......####.......",
        "......######......",
        "....##########....",
        "##################",
        "##################",
        "....##########....",
        "......######......",
        ".......####.......",
        "........##........",
        "........##........"]
    // Left-eye pixels; the right eye mirrors them around the centre (x → 17 - x), then both shift by `look`.
    static let eyeShapes: [String: [(Int, Int)]] = [
        "open": [(6, 4), (6, 5)], "closed": [(5, 5), (6, 5)], "happy": [(5, 5), (6, 4), (7, 5)],
        "wide": [(6, 4), (7, 4), (6, 5), (7, 5)], "down": [(6, 5), (6, 6)]
    ]
    static let glints = [(3, 1), (4, 2), (14, 1), (13, 2), (3, 10), (4, 9), (14, 10), (13, 9)]
    static let shine = [(7, 3), (8, 2)]

    nonisolated(unsafe) private static var cache: [String: AstraGeometry] = [:]
    private static let lock = NSLock()

    public static func geometry(_ f: AstraFrame) -> AstraGeometry {
        let key = "\(f.points)|\(f.eyes)|\(f.look)|\(Int((f.squash * 100).rounded()))"
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let geo = build(f)
        if cache.count > 200 { cache.removeAll() }
        cache[key] = geo
        return geo
    }

    /// The pose as a grid of rows: 0 empty, 1 body, 2 eye, 3 glint or shine.
    public static func cells(_ f: AstraFrame) -> [[Int]] {
        var g = long.map { $0.map { $0 == "#" ? 1 : 0 } }
        func clear(_ rows: [Int], _ cols: [Int]) { for y in rows { for x in cols { g[y][x] = 0 } } }
        if f.points == "short" || f.points == "tiny" { g[0] = Array(repeating: 0, count: width); g[11] = g[0]; clear([5, 6], [0, 1, 16, 17]) }
        if f.points == "tiny" { g[1] = Array(repeating: 0, count: width); g[10] = g[1]; clear([5, 6], [2, 3, 14, 15]) }
        if f.points == "flare" { for (x, y) in glints { g[y][x] = 3 } }
        let plain = f.squash == 1
        if plain { for (x, y) in shine where g[y][x] == 1 { g[y][x] = 3 } }
        for (x, y) in eyeShapes[f.eyes] ?? eyeShapes["open"]! {
            for xx in [x + f.look, 17 - x + f.look] where xx >= 0 && xx < width && g[y][xx] != 0 { g[y][xx] = 2 }
        }
        if plain { return g }
        // Turning: each column samples the unsquashed pose; the back hides the eyes.
        var s = f.squash
        if abs(s) < 0.12 { s = s < 0 ? -0.12 : 0.12 }
        return g.map { row in
            (0..<width).map { x in
                let sx = Int(((Double(x) + 0.5 - 9) / s + 9 - 0.5).rounded())
                let v = sx >= 0 && sx < width ? row[sx] : 0
                return s < 0 && v == 2 ? 1 : v
            }
        }
    }

    private static func build(_ f: AstraFrame) -> AstraGeometry {
        var geo = AstraGeometry()
        for (y, row) in cells(f).enumerated() {
            var x = 0
            while x < width {
                let c = row[x]
                if c == 0 { x += 1; continue }
                let x0 = x
                while x < width && row[x] == c { x += 1 }
                let rect = PixelRect(Double(x0), Double(y), Double(x - x0), 1)
                switch c { case 2: geo.eyes.append(rect); case 3: geo.glint.append(rect); default: geo.body.append(rect) }
            }
        }
        return geo
    }
}

/// What Astra shows for the Codex state, before one-shot animations: an exhausted limit
/// wins, then work, then a limit running low, then a long quiet spell.
public enum AstraMood: String, CaseIterable, Sendable {
    case hover, low, ember, doze, comet
    public static func resolve(peak: Int?, busy: Bool, lastActive: Date?, now: Date, dozeAfter: TimeInterval = 1800) -> AstraMood {
        if let peak, peak >= 100 { return .ember }
        if busy { return .comet }
        if let peak, peak >= 80 { return .low }
        // No session log in the last hours counts as quiet too.
        guard let lastActive else { return .doze }
        return now.timeIntervalSince(lastActive) >= dozeAfter ? .doze : .hover
    }
}
