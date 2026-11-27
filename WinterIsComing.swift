// WinterIsComing — snow on your Mac desktop.
// Snow piles up on top of windows, the Dock and the bottom of the screen and flies off when you drag a
// window. Hover over the snow to roll snowballs, push them into each other, drag them with the mouse and
// stack three of them into a snowman. You and your beagle live on the snow too (see "Beagle & me" below).
// See README.md for the full list.
// Build: swiftc -O WinterIsComing.swift -o WinterIsComing
// Run:   ./WinterIsComing   (a ❄︎ icon appears in the menu bar: pause / snow amount / quit)

import Cocoa
import SpriteKit

// MARK: - Settings (feel free to tweak)

enum Cfg {
    static var targetFlakes = 260            // number of flakes falling at the same time
    static let colW: CGFloat = 3             // width of one column of the snow height map (px)
    static let windowPileMax: CGFloat = 16   // max snow height on top of a window
    static let groundPileMax: CGFloat = 56   // max snow height at the bottom of the screen
    static let groundStart: CGFloat = 0.45    // the ground starts this full (0...1) so there is snow right away
    static let gravity: CGFloat = 900        // gravity for snow sliding off
    static var pollInterval = 1.0 / 30.0     // how often window positions are checked (s); slower while napping
    static let maxClumps = 900               // max number of falling snow clumps at once
    static let dockPileMax: CGFloat = 18     // max snow height on the Dock
    static let dockPad: CGFloat = 4          // extra width of the Dock pile on each side of the icon area
    static let dockTopOffset: CGFloat = -1   // lower it if the snow floats above the Dock, raise it if it sinks in
    static let fallSpeed: CGFloat = 1.5      // falling speed multiplier (1 = original, bigger = faster)
    static let flakesInFront = true          // some of the smallest flakes fall in front of windows, so they can reach the Dock
    static let inFrontFraction: CGFloat = 0.4 // share of the smallest layer that falls in front (0...1)
    static let ballStartRadius: CGFloat = 3  // a new snowball starts this small
    static let ballMaxRadius: CGFloat = 28   // and stops growing at this size
    static let maxBalls = 20                 // oldest resting snowballs are removed beyond this
    static let lightSpacing: CGFloat = 22    // distance between fairy light bulbs
    static let lightSpan: CGFloat = 120      // distance between the points where the wire is "hooked"
    static let lightSag: CGFloat = 9         // how far the wire droops between hooks
    static let lightInset: CGFloat = 14      // keep clear of the window's rounded corners
    static let bulbGlow: CGFloat = 19        // size of a bulb's soft glow
    static let bulbCore: CGFloat = 5.5       // size of a bulb's bright center
    static let dockGain: CGFloat = 3.0       // snow landing on the Dock counts this many times more, so it builds up
}

/// Performance profiles (❄︎ menu → Performance): frame rate and how often window positions are checked
enum PerfProfile: Int, CaseIterable {
    case batterySaver, balanced, highQuality
    var title: String { ["Battery Saver", "Balanced", "High Quality"][rawValue] }
    var fps: Int { [20, 30, 60][rawValue] }
    var poll: Double { [1.0 / 6.0, 1.0 / 15.0, 1.0 / 30.0][rawValue] }
}

extension Cfg {
    static var profile = PerfProfile(rawValue: UserDefaults.standard.object(forKey: "perfProfile") as? Int ?? 1) ?? .balanced
    static var reduceMotion = UserDefaults.standard.bool(forKey: "reduceMotion")
    /// Frame rate while you're around, and while napping / in Low Power Mode
    static var activeFPS: Int { reduceMotion ? min(30, profile.fps) : profile.fps }
    static var ecoFPS: Int { max(15, activeFPS / 2) }
    static var activePoll: Double { profile.poll }
    static var ecoPoll: Double { max(profile.poll, 1.0 / 8.0) }
    /// Reduce Motion also thins out the snowfall
    static var flakeTarget: Int { reduceMotion ? min(targetFlakes, 120) : targetFlakes }
}

/// Wind moods, ported from 251701054/WINTER-IS-COMMING-VER2 (MIT): the wind drifts between a gentle breeze,
/// a moderate wind and short strong gusts. During a strong gust you and your pet bundle up.
enum WindRegime: String, CaseIterable {
    case gentleBreeze = "Gentle Breeze"
    case moderateWind = "Moderate Wind"
    case strongGust = "Strong Gust"

    var amplitudeScale: CGFloat {
        switch self {
        case .gentleBreeze: return 0.45
        case .moderateWind: return 1.00
        case .strongGust: return 2.15
        }
    }

    var steadyBiasRange: ClosedRange<CGFloat> {
        switch self {
        case .gentleBreeze: return -6...6
        case .moderateWind: return -18...18
        case .strongGust: return -42...42
        }
    }

    var verticalLiftFactor: CGFloat {
        switch self {
        case .gentleBreeze: return 0.0
        case .moderateWind: return 0.08
        case .strongGust: return 0.22
        }
    }

    var durationRange: ClosedRange<CGFloat> {
        switch self {
        case .gentleBreeze: return 10...18
        case .moderateWind: return 8...15
        case .strongGust: return 4...8
        }
    }
}

// MARK: - Find the Dock (needs Accessibility permission)

@MainActor final class DockTracker {
    private var trusted = false
    private var warned = false
    var lastError = ""

    init() {
        // On first run macOS shows a prompt asking you to grant the permission
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
    }

    /// Frame of the Dock icon area (global macOS coordinates, origin top-left); nil if unavailable
    func frame() -> CGRect? {
        if !trusted {
            trusted = AXIsProcessTrusted()
            if !trusted {
                if !warned {
                    warned = true
                    print("❄︎ For snow on the Dock: System Settings → Privacy & Security → Accessibility, enable Terminal (or whichever app you run this from), then restart.")
                }
                lastError = "no Accessibility permission"
                return nil
            }
        }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            lastError = "Dock process not found"
            return nil
        }
        let axApp = AXUIElementCreateApplication(dock.processIdentifier)
        var childrenRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &childrenRef)
        guard err == .success, let children = childrenRef as? [AXUIElement] else {
            lastError = "could not read Dock children (AXError \(err.rawValue))"
            return nil
        }
        var roles: [String] = []
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            let role = (roleRef as? String) ?? "?"
            roles.append(role)
            guard role == kAXListRole else { continue }
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let pv = posRef, let sv = sizeRef,
                  CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { continue }
            var pos = CGPoint.zero
            var sz = CGSize.zero
            AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sv as! AXValue, .cgSize, &sz)
            return CGRect(origin: pos, size: sz)
        }
        lastError = "no AXList among Dock children (roles: \(roles))"
        return nil
    }
}

// Three depth layers: far = small, faint, slow; near = big, bright, fast
struct Layer {
    let size: ClosedRange<CGFloat>
    let speed: ClosedRange<CGFloat>
    let alpha: ClosedRange<CGFloat>
    let sway: ClosedRange<CGFloat>
    let wind: CGFloat
    let z: CGFloat
}

let layers: [Layer] = [
    Layer(size: 1.8...3.0, speed: 22...38,  alpha: 0.30...0.50, sway: 5...10,  wind: 0.5, z: 1),
    Layer(size: 3.0...4.8, speed: 40...65,  alpha: 0.60...0.80, sway: 9...16,  wind: 0.8, z: 2),
    Layer(size: 4.8...7.5, speed: 70...105, alpha: 0.85...1.00, sway: 14...24, wind: 1.1, z: 7),
]

@inline(__always) func rnd(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a...b) }

// Soft round flake texture: solid center, fading edge
@MainActor func makeFlakeTexture() -> SKTexture {
    let s: CGFloat = 64
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let colors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 1.0),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.6),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
        ] as CFArray
        let locs: [CGFloat] = [0, 0.45, 1]
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locs) else { return false }
        let c = CGPoint(x: s / 2, y: s / 2)
        ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: s / 2, options: [])
        return true
    }
    return SKTexture(image: img)
}

// Snowball body: lit from the top-left, bluish shade at the bottom-right (this part never rotates)
@MainActor func makeSnowballTexture() -> SKTexture {
    let s: CGFloat = 128
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.addEllipse(in: CGRect(x: 1, y: 1, width: s - 2, height: s - 2))
        ctx.clip()
        let colors = [
            CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),
            CGColor(red: 0.94, green: 0.96, blue: 1.00, alpha: 1),
            CGColor(red: 0.68, green: 0.75, blue: 0.88, alpha: 1),
        ] as CFArray
        let locs: [CGFloat] = [0, 0.55, 1]
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locs) else { return false }
        ctx.drawRadialGradient(grad,
                               startCenter: CGPoint(x: s * 0.38, y: s * 0.64), startRadius: 0,
                               endCenter: CGPoint(x: s * 0.5, y: s * 0.5), endRadius: s * 0.55,
                               options: [.drawsAfterEndLocation])
        return true
    }
    return SKTexture(image: img)
}

// Little grey-blue specks on top of the body; this layer rotates so you can see the ball roll
@MainActor func makeSpeckTexture() -> SKTexture {
    let s: CGFloat = 128
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.addEllipse(in: CGRect(x: 6, y: 6, width: s - 12, height: s - 12))
        ctx.clip()
        for _ in 0..<30 {
            let d = rnd(3, 8)
            ctx.setFillColor(CGColor(red: 0.66, green: 0.73, blue: 0.87, alpha: rnd(0.25, 0.55)))
            ctx.fillEllipse(in: CGRect(x: rnd(6, s - 14), y: rnd(6, s - 14), width: d, height: d))
        }
        return true
    }
    return SKTexture(image: img)
}

// MARK: - Snowball

@MainActor final class Snowball {
    let node = SKNode()
    let body: SKSpriteNode
    let specks: SKSpriteNode
    var x: CGFloat = 0
    var y: CGFloat = 0
    var r: CGFloat = Cfg.ballStartRadius
    weak var pile: Pile?         // the surface it rests on (nil while falling, dragged or stacked)
    weak var below: Snowball?    // the ball it is stacked on (snowman), if any
    var falling = false
    var dragging = false
    var vel = CGVector.zero
    var decor: SKNode?           // snowman face / scarf / buttons drawn on this ball

    init(body bodyTex: SKTexture, specks speckTex: SKTexture) {
        body = SKSpriteNode(texture: bodyTex)
        specks = SKSpriteNode(texture: speckTex)
        specks.zPosition = 0.1
        specks.zRotation = rnd(0, 6.28)
        node.zPosition = 6.5
        node.addChild(body)
        node.addChild(specks)
    }

    func layout() {
        node.position = CGPoint(x: x, y: y)
        let d = CGSize(width: r * 2, height: r * 2)
        body.size = d
        specks.size = d
    }

    func drop(vel v: CGVector) {
        falling = true
        dragging = false
        pile = nil
        below = nil
        vel = v
    }
}

// MARK: - Flake

@MainActor final class Flake {
    let node: SKSpriteNode
    var vel = CGVector.zero
    var size: CGFloat = 4
    var swayAmp: CGFloat = 0
    var swayFreq: CGFloat = 1
    var phase: CGFloat = 0
    var windFactor: CGFloat = 1
    var inFront = false          // true = falls in front of windows (ignores them), lands on Dock / ground
    var isClump = false          // true = clump sliding off a surface (affected by gravity)
    var ignoreID = -1            // don't land right back on the surface it came from
    var ignoreUntil: CGFloat = 0

    init(texture: SKTexture) { node = SKSpriteNode(texture: texture) }
}

// MARK: - Snow pile (a height map drawn as a smooth white mound)

@MainActor final class Pile {
    var minX: CGFloat
    var topY: CGFloat
    let width: CGFloat
    let maxH: CGFloat
    var h: [CGFloat]
    var caps: [CGFloat]          // max height per column, tapering at both ends so it looks rounded
    var occ: [Bool]              // whether this column is hidden behind a window in front
    let body = SKShapeNode()
    let shade = SKShapeNode()
    var dirty = false

    init(minX: CGFloat, topY: CGFloat, width: CGFloat, maxH: CGFloat, parent: SKNode) {
        self.minX = minX
        self.topY = topY
        self.width = width
        self.maxH = maxH
        let n = max(1, Int((width / Cfg.colW).rounded(.up)))
        h = Array(repeating: 0, count: n)
        occ = Array(repeating: false, count: n)
        caps = (0..<n).map { i in
            let edgeDist = min(CGFloat(i) + 0.5, CGFloat(n - i) - 0.5) * Cfg.colW
            let t = min(1, edgeDist / (maxH * 2.2))
            return maxH * t.squareRoot()
        }
        body.fillColor = NSColor(calibratedWhite: 1, alpha: 0.97)
        body.strokeColor = .clear
        body.lineWidth = 0
        body.zPosition = 5
        // light blue-grey layer underneath, like a shadow
        shade.fillColor = NSColor(calibratedRed: 0.70, green: 0.78, blue: 0.92, alpha: 0.9)
        shade.strokeColor = .clear
        shade.lineWidth = 0
        shade.zPosition = 4
        shade.position = CGPoint(x: 0, y: -1.5)
        parent.addChild(shade)
        parent.addChild(body)
    }

    var count: Int { h.count }
    var total: CGFloat { h.reduce(0, +) }

    func col(at x: CGFloat) -> Int? {
        let c = Int((x - minX) / Cfg.colW)
        return (c >= 0 && c < count) ? c : nil
    }
    func colX(_ c: Int) -> CGFloat { minX + (CGFloat(c) + 0.5) * Cfg.colW }
    func surface(_ c: Int) -> CGFloat { topY + h[c] }

    func add(at c: Int, amount: CGFloat) {
        let spread: [(Int, CGFloat)] = [(0, 1), (-1, 0.75), (1, 0.75), (-2, 0.45), (2, 0.45), (-3, 0.2), (3, 0.2)]
        for (o, w) in spread {
            let i = c + o
            guard i >= 0, i < count, !occ[i] else { continue }
            h[i] = min(caps[i], h[i] + amount * w)
        }
        dirty = true
    }

    // let snow slump sideways where the slope is too steep
    func relax() -> Bool {
        guard count > 1 else { return false }
        var moved = false
        for i in 0..<(count - 1) where !occ[i] && !occ[i + 1] {
            let d = h[i] - h[i + 1]
            if abs(d) > 1.0 {
                let m = (abs(d) - 1.0) * 0.3 * (d > 0 ? 1 : -1)
                h[i] = max(0, min(caps[i], h[i] - m))
                h[i + 1] = max(0, min(caps[i + 1], h[i + 1] + m))
                if abs(m) > 0.02 { moved = true }
            }
        }
        return moved
    }

    func clear() {
        for i in 0..<count { h[i] = 0 }
        dirty = true
    }

    func redraw() {
        guard dirty else { return }
        dirty = relax()
        if total < 0.5 {
            body.path = nil
            shade.path = nil
            return
        }
        let p = CGMutablePath()
        p.move(to: CGPoint(x: minX, y: topY))
        for c in 0..<count { p.addLine(to: CGPoint(x: colX(c), y: topY + h[c])) }
        p.addLine(to: CGPoint(x: minX + width, y: topY))
        p.closeSubpath()
        body.path = p
        shade.path = p
    }

    func remove() {
        body.removeFromParent()
        shade.removeFromParent()
    }
}

// MARK: - Fairy lights

/// One glowing bulb: a soft colored glow with a brighter center that twinkles
@MainActor final class Bulb {
    let glow: SKSpriteNode
    let core: SKSpriteNode
    let phase = rnd(0, 6.28)
    let speed = rnd(1.2, 3.0)
    var pos = CGPoint.zero

    init(texture: SKTexture, color: NSColor) {
        glow = SKSpriteNode(texture: texture)
        glow.color = color
        glow.colorBlendFactor = 1
        glow.size = CGSize(width: Cfg.bulbGlow, height: Cfg.bulbGlow)
        core = SKSpriteNode(texture: texture)
        core.color = color.blended(withFraction: 0.2, of: .white) ?? color   // keep the center colorful
        core.colorBlendFactor = 1
        core.size = CGSize(width: Cfg.bulbCore, height: Cfg.bulbCore)
        core.zPosition = 0.1
    }

    /// reveal goes 0 → 1 as the bulb lights up after being hung
    func twinkle(_ t: CGFloat, reveal: CGFloat) {
        let k = 0.75 + 0.25 * sin(t * speed + phase)
        glow.alpha = 0.8 * k * reveal
        core.alpha = (0.85 + 0.15 * k) * reveal
    }
}

/// A string of fairy lights hanging just below the top edge of one window
@MainActor final class LightString {
    static let colors: [NSColor] = [
        NSColor(calibratedRed: 1.00, green: 0.10, blue: 0.12, alpha: 1),   // red
        NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.00, alpha: 1),   // amber
        NSColor(calibratedRed: 0.05, green: 0.95, blue: 0.20, alpha: 1),   // green
        NSColor(calibratedRed: 0.10, green: 0.42, blue: 1.00, alpha: 1),   // blue
        NSColor(calibratedRed: 1.00, green: 0.15, blue: 0.62, alpha: 1),   // pink
    ]
    let node = SKNode()
    let wire = SKShapeNode()
    var bulbs: [Bulb] = []
    var rect = CGRect.null
    var hungAt: CGFloat = 0      // when this string was hung up
    var swing: CGFloat = 0       // extra droop while it bounces
    var sway: CGFloat = 0        // sideways swing of the bulbs
    static let swingTime: CGFloat = 1.4

    func animating(_ t: CGFloat) -> Bool { t - hungAt < LightString.swingTime }

    /// Just after being hung, the string bounces and the bulbs swing, then settle down (a damped wobble)
    func updateSwing(_ t: CGFloat) {
        let tau = t - hungAt
        guard tau < LightString.swingTime else { swing = 0; sway = 0; return }
        let e = exp(-4.0 * tau)
        swing = 0.9 * e * sin(13 * tau)
        sway = 3.5 * e * sin(9.5 * tau)
    }

    /// Bulbs light up one after another from left to right as the string is hung
    func reveal(_ i: Int, _ t: CGFloat) -> CGFloat {
        max(0, min(1, (t - hungAt - CGFloat(i) * 0.015) / 0.08))
    }

    init(parent: SKNode) {
        wire.strokeColor = NSColor(calibratedWhite: 0.12, alpha: 0.85)
        wire.lineWidth = 1.2
        node.zPosition = 5.5
        node.addChild(wire)
        parent.addChild(node)
    }

    /// Height of the wire at x: it droops between hooks like a real string of lights
    func wireY(_ x: CGFloat) -> CGFloat {
        let x0 = rect.minX + Cfg.lightInset
        let w = max(1, rect.width - 2 * Cfg.lightInset)
        let span = w / max(1, (w / Cfg.lightSpan).rounded())
        let f = max(0, min(1, ((x - x0) / span).truncatingRemainder(dividingBy: 1)))
        return rect.maxY - 3 - Cfg.lightSag * (1 + swing) * sin(.pi * f)
    }

    /// Follow the window; new bulbs are only made when its width changes
    func place(in r: CGRect, texture: SKTexture) {
        let w = max(0, r.width - 2 * Cfg.lightInset)
        let count = max(2, Int(w / Cfg.lightSpacing))
        rect = r
        if bulbs.count != count {
            for b in bulbs { b.glow.removeFromParent(); b.core.removeFromParent() }
            bulbs = (0..<count).map { Bulb(texture: texture, color: LightString.colors[$0 % LightString.colors.count]) }
            for b in bulbs { node.addChild(b.glow); node.addChild(b.core) }
        }
        for (i, b) in bulbs.enumerated() {
            let x = r.minX + Cfg.lightInset + (CGFloat(i) + 0.5) * w / CGFloat(bulbs.count)
            let dx = sway * (0.6 + 0.4 * sin(b.phase))      // each bulb swings a little differently
            b.pos = CGPoint(x: x + dx, y: wireY(x) - 4)     // bulbs hang just under the wire
            b.glow.position = b.pos
            b.core.position = b.pos
        }
    }

    /// Redraw the wire and hide the parts that are behind a window in front
    func applyVisibility(hidden: (CGPoint) -> Bool) {
        let p = CGMutablePath()
        var pen = false
        var x = rect.minX + Cfg.lightInset * 0.5
        while x <= rect.maxX - Cfg.lightInset * 0.5 {
            let pt = CGPoint(x: x, y: wireY(x))
            if hidden(pt) { pen = false }
            else if pen { p.addLine(to: pt) }
            else { p.move(to: pt); pen = true }
            x += 4
        }
        wire.path = p
        for b in bulbs {
            let h = hidden(b.pos)
            b.glow.isHidden = h
            b.core.isHidden = h
        }
    }

    func remove() { node.removeFromParent() }
}

// MARK: - Pet & me
//
// You and your pet live on the snow at the bottom of the screen. The app draws both of you itself from a
// "recipe" (colors and options, see PalsRecipe), so there are no image files to ship and anyone can swap in
// themselves and their own pet. What happens:
//   • click the pet to pet it; click it again quickly and it howls
//   • click yourself and you call the pet over for a cuddle
//   • every so often you throw a snowball and the pet fetches it
//   • throw a snowball with the mouse and the pet chases it
//   • build a snowman and, after a few seconds, the pet knocks it over
//   • leave the mouse alone for a minute and you both nap; the whole app then runs at a lower frame rate
// Turn it all on or off from the ❄︎ menu → Pet & Me.

enum Pals {
    static let outline: CGFloat = 1.5         // outline thickness (points)
    static let renderScale: CGFloat = 3       // parts are drawn at 3x so they stay smooth on any display
    static let dogWalk: CGFloat = 55          // beagle trotting speed (points per second)
    static let dogRun: CGFloat = 170          // beagle running speed
    static let meWalk: CGFloat = 36           // your walking speed
    static let sink: CGFloat = 2.5            // how deep feet sink into the snow
    static let snowmanGrace: CGFloat = 6      // seconds to admire a snowman before the beagle knocks it over
    static let howlWindow: CGFloat = 0.45     // a second click on the beagle within this time makes it howl
    static let napAfter: CGFloat = 60         // no mouse movement for this long: nap + lower frame rate
    static let fetchEvery: ClosedRange<CGFloat> = 35...70   // seconds between your snowball throws
}

/// What you and your pet look like. Colors are hex strings ("#RRGGBB").
struct PalsRecipe {
    var meName = "Buncy"
    var skin = "#805038"
    var hair = "#1E1816"
    var hat = "#84868C"          // beanie
    var jacket = "#F6F7F9"
    var collar = "#B82E36"
    var pants = "#3E4252"
    var boots = "#4A362A"

    var petName = ""             // e.g. "Max": shown in the speech bubbles when set
    var coat = "#FCFAF5"         // main fur: body, legs, muzzle
    var markings = "#CC843E"     // head, thigh and shoulder patches, tail
    var ears = "#AA642A"
    var saddle = "#42342C"       // the dark patch on the back
    var blaze = true             // light stripe down the middle of the face
}

func palsColor(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    let v = UInt32(s, radix: 16) ?? 0x888888
    return CGColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                   blue: CGFloat(v & 255) / 255, alpha: alpha)
}

func palsRGB(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Multiply a color's channels (used to derive shades from the recipe colors)
func palsTint(_ c: CGColor, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    let k = c.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components ?? [0.5, 0.5, 0.5, 1]
    guard k.count >= 3 else { return c }
    return CGColor(red: min(1, k[0] * r), green: min(1, k[1] * g), blue: min(1, k[2] * b), alpha: k.count > 3 ? k[3] : 1)
}

/// Every color used in the drawings, derived from a recipe
struct PalsInk {
    let line, white, wshade, tan, tandark, saddle, nose, blush, tongue, freckle, shine: CGColor
    let skin, skinShade, hair, beanie, beanieDark, pom, rib, jacket, jshade, collar, pants, pantsBack, boots, zip, mouth: CGColor

    init(_ r: PalsRecipe) {
        line = palsRGB(61, 43, 34)
        let coat = palsColor(r.coat)
        white = coat
        wshade = palsTint(coat, 0.893, 0.880, 0.861)
        tan = palsColor(r.markings)
        tandark = palsColor(r.ears)
        saddle = palsColor(r.saddle)
        nose = palsRGB(38, 30, 28)
        blush = palsRGB(244, 150, 158, 0.75)
        tongue = palsRGB(236, 120, 135)
        freckle = palsRGB(150, 110, 90)
        shine = palsRGB(255, 255, 255)
        let skinColor = palsColor(r.skin)
        skin = skinColor
        skinShade = palsTint(skinColor, 0.83, 0.80, 0.79)
        hair = palsColor(r.hair)
        let hat = palsColor(r.hat)
        beanie = hat
        beanieDark = palsTint(hat, 0.82, 0.82, 0.836)
        pom = palsTint(hat, 1.106, 1.105, 1.10)
        rib = palsTint(hat, 0.70, 0.70, 0.714)
        let coatColor = palsColor(r.jacket)
        jacket = coatColor
        jshade = palsTint(coatColor, 0.862, 0.883, 0.908)
        collar = palsColor(r.collar)
        let trousers = palsColor(r.pants)
        pants = trousers
        pantsBack = palsTint(trousers, 0.85, 0.85, 0.85)
        boots = palsColor(r.boots)
        zip = palsRGB(160, 162, 168)
        mouth = palsRGB(70, 30, 30)
    }
}

extension CGMutablePath {
    func m(_ x: CGFloat, _ y: CGFloat) { move(to: CGPoint(x: x, y: y)) }
    func l(_ x: CGFloat, _ y: CGFloat) { addLine(to: CGPoint(x: x, y: y)) }
    func c(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
    }
    func z() { closeSubpath() }
}

/// Draws shapes in "design" coordinates (points, y pointing DOWN, ground at y = 0, facing right).
/// The first pass (no context) only measures how big the drawing is; the second pass paints it.
final class PalsPainter {
    let ctx: CGContext?
    let ink: PalsInk
    var bounds = CGRect.null

    init(ctx: CGContext?, ink: PalsInk) { self.ctx = ctx; self.ink = ink }

    /// Fill shapes as one silhouette with a single outline around the outside
    func blob(_ shapes: [CGPath], _ fill: CGColor, outline: Bool = true) {
        guard let c = ctx else {
            let pad = outline ? Pals.outline : 0
            for s in shapes { bounds = bounds.union(s.boundingBoxOfPath.insetBy(dx: -pad, dy: -pad)) }
            return
        }
        if outline {
            for s in shapes { c.addPath(s) }
            c.setStrokeColor(ink.line)
            c.setLineWidth(Pals.outline * 2)
            c.setLineJoin(.round)
            c.strokePath()
        }
        for s in shapes { c.addPath(s) }
        c.setFillColor(fill)
        c.fillPath()
    }

    /// Paint shapes, but only inside the clip shapes (markings, shading)
    func clipped(_ clip: [CGPath], _ shapes: [CGPath], _ color: CGColor) {
        guard let c = ctx else { return }
        c.saveGState()
        for s in clip { c.addPath(s) }
        c.clip()
        for s in shapes { c.addPath(s) }
        c.setFillColor(color)
        c.fillPath()
        c.restoreGState()
    }

    func stroke(_ p: CGPath, _ color: CGColor, _ width: CGFloat) {
        guard let c = ctx else {
            bounds = bounds.union(p.boundingBoxOfPath.insetBy(dx: -width / 2, dy: -width / 2))
            return
        }
        c.addPath(p)
        c.setStrokeColor(color)
        c.setLineWidth(width)
        c.setLineCap(.round)
        c.setLineJoin(.round)
        c.strokePath()
    }

    func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: CGColor) {
        let rect = CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)
        guard let c = ctx else { bounds = bounds.union(rect); return }
        c.setFillColor(color)
        c.fillEllipse(in: rect)
    }

    /// A soft round glow (campfire light)
    func glow(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ color: CGColor, _ alpha: CGFloat) {
        let rect = CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)
        guard let c = ctx else { bounds = bounds.union(rect); return }
        let center = color.copy(alpha: alpha) ?? color
        let edge = color.copy(alpha: 0) ?? color
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [center, edge] as CFArray,
                                 locations: [0, 1]) else { return }
        c.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                             endCenter: CGPoint(x: x, y: y), endRadius: radius, options: [])
    }

    /// Eyes: "open" (dot with a shine), "happy" (^ ^) or "closed" (sleepy curve)
    func clippedStroke(_ clip: [CGPath], _ p: CGPath, _ color: CGColor, _ width: CGFloat) {
        guard let c = ctx else { return }
        c.saveGState()
        for s in clip { c.addPath(s) }
        c.clip()
        c.addPath(p)
        c.setStrokeColor(color)
        c.setLineWidth(width)
        c.setLineCap(.round)
        c.strokePath()
        c.restoreGState()
    }

    func eyes(_ pts: [(CGFloat, CGFloat)], _ kind: String, r: CGFloat) {
        for (x, y) in pts {
            switch kind {
            case "open":
                dot(x, y, r, ink.line)
                dot(x + 0.6, y - 0.7, r * 0.35, ink.shine)
            case "happy":
                stroke(PalsShape.path { $0.m(x - 2.2, y + 0.8); $0.c(x - 1.2, y - 1.6, x + 1.2, y - 1.6, x + 2.2, y + 0.8) }, ink.line, 1.2)
            default:
                stroke(PalsShape.path { $0.m(x - 2.2, y - 0.3); $0.c(x - 1.2, y + 1.3, x + 1.2, y + 1.3, x + 2.2, y - 0.3) }, ink.line, 1.2)
            }
        }
    }
}

/// One drawn body part: its texture, size in points, the joint it turns around, and where that joint sits
struct PalsPart {
    let tex: SKTexture
    let size: CGSize
    let anchor: CGPoint
    let base: CGPoint     // joint position relative to the character's feet (SpriteKit coordinates, y up)
}

/// Basic shapes in design coordinates
enum PalsShape {
    static func ell(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ rot: CGFloat = 0) -> CGPath {
        var t = CGAffineTransform(translationX: cx, y: cy).rotated(by: rot)
        return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry), transform: &t)
    }

    static func rr(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ r: CGFloat) -> CGPath {
        let w = x1 - x0, h = y1 - y0
        let k = max(0, min(r, w / 2 - 0.001, h / 2 - 0.001))
        return CGPath(roundedRect: CGRect(x: x0, y: y0, width: w, height: h), cornerWidth: k, cornerHeight: k, transform: nil)
    }

    static func path(_ build: (CGMutablePath) -> Void) -> CGPath {
        let p = CGMutablePath()
        build(p)
        return p
    }
}

@MainActor enum PalsArt {
    static func ell(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ rot: CGFloat = 0) -> CGPath { PalsShape.ell(cx, cy, rx, ry, rot) }
    static func rr(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ r: CGFloat) -> CGPath { PalsShape.rr(x0, y0, x1, y1, r) }
    static func path(_ build: (CGMutablePath) -> Void) -> CGPath { PalsShape.path(build) }

    /// Measure, then paint one part into a texture. `k` enlarges the drawing (it is redrawn bigger, not stretched).
    static func render(pivot: CGPoint, ink: PalsInk, scale k: CGFloat = 1, _ draw: (PalsPainter) -> Void) -> PalsPart {
        let measure = PalsPainter(ctx: nil, ink: ink)
        draw(measure)
        let b = measure.bounds.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : measure.bounds
        let x0 = floor(b.minX) - 1, y0 = floor(b.minY) - 1
        let w = ceil(b.maxX) + 1 - x0, h = ceil(b.maxY) + 1 - y0
        let S = (k > 1 ? 2 : Pals.renderScale) * k        // big drawings only need 2x to look sharp
        let pw = Int(w * S), ph = Int(h * S)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return PalsPart(tex: SKTexture(), size: CGSize(width: 1, height: 1), anchor: .zero, base: .zero)
        }
        // Flip so the design coordinates (y down) map straight onto the image
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: S, y: -S)
        ctx.translateBy(x: -x0, y: -y0)
        draw(PalsPainter(ctx: ctx, ink: ink))
        guard let img = ctx.makeImage() else {
            return PalsPart(tex: SKTexture(), size: CGSize(width: 1, height: 1), anchor: .zero, base: .zero)
        }
        return PalsPart(tex: SKTexture(cgImage: img), size: CGSize(width: w * k, height: h * k),
                        anchor: CGPoint(x: (pivot.x - x0) / w, y: 1 - (pivot.y - y0) / h),
                        base: CGPoint(x: pivot.x * k, y: -pivot.y * k))
    }

    // MARK: Pet (faces right)

    static let hipY: CGFloat = -16
    static let tailPivot = CGPoint(x: -23, y: -30)
    static let neck = CGPoint(x: 20, y: -35)

    static func dogLeg(_ p: PalsPainter, _ x: CGFloat, far: Bool) {
        p.blob([rr(x - 3.6, hipY - 2, x + 3.6, -1.5, 3.4), ell(x + 1.2, -2.2, 4.6, 2.6)], far ? p.ink.wshade : p.ink.white)
    }

    static func dogBody(_ p: PalsPainter) {
        let k = p.ink
        let sh = [ell(0, -24, 24, 11.5), ell(15, -23, 11.5, 11), ell(-16, -23, 10.5, 10.5)]
        p.blob(sh, k.white)
        p.clipped(sh, [ell(-17, -23, 9, 8.5)], k.tan)          // rear thigh
        p.clipped(sh, [ell(-3, -34, 19, 9.5)], k.saddle)       // dark saddle
        p.clipped(sh, [ell(19, -31, 7, 5.5)], k.tan)           // shoulder patch
        p.clipped(sh, [ell(1, -11.5, 20, 3)], k.wshade)        // belly shadow
    }

    static func dogTail(_ p: PalsPainter) {
        let k = p.ink
        let t = path { $0.m(-23, -30); $0.c(-29, -38, -31, -46, -28, -54) }
        p.stroke(t, k.line, 5 + Pals.outline * 2)
        p.stroke(t, k.tan, 5)
        p.stroke(path { $0.m(-30.2, -47); $0.c(-30, -50, -29.3, -52.5, -28, -54) }, k.white, 5)
    }

    /// kind: open, happy, sleep, howl, bark
    static func dogHead(_ p: PalsPainter, _ kind: String, blaze: Bool) {
        let k = p.ink
        // far ear peeks out behind the head on the right
        p.blob([path { $0.m(36, -55); $0.c(42, -54, 45, -46, 44, -38); $0.c(43, -34, 40, -34, 38, -38); $0.z() }], k.tandark)
        let hs = [ell(27, -45, 15, 13)]
        p.blob(hs, k.tan)
        if blaze {
            p.clipped(hs, [path { $0.m(28, -60); $0.l(32, -60); $0.c(33, -52, 35, -48, 37, -43)
                                  $0.l(25, -43); $0.c(27, -48, 28, -52, 28, -60); $0.z() }], k.white)
        }
        let muzzle = ell(31.5, -38.2, 9.5, 6.5)
        p.blob([muzzle], k.white)
        p.clipped([muzzle], [ell(31.5, -32.5, 9, 2.5)], k.wshade)
        // near ear hangs in front, on the left of the face
        p.blob([path { $0.m(18, -55); $0.c(11, -52, 8.5, -41, 11, -33); $0.c(13, -28, 19, -29, 20.5, -34)
                       $0.c(21.5, -40, 21, -49, 18, -55); $0.z() }], k.tandark)
        // nose and mouth
        p.dot(34.5, -41.6, 3.3, k.nose)
        p.dot(33.5, -42.6, 0.9, palsRGB(255, 255, 255, 0.8))
        if kind == "howl" || kind == "bark" {
            p.blob([ell(33.5, -35.8, 2.4, kind == "howl" ? 2.6 : 1.9)], k.nose, outline: false)
            p.dot(33.5, -35.0, 1.2, k.tongue)
        } else {
            p.stroke(path { $0.m(34.5, -38.6); $0.c(34.3, -36.8, 32.4, -36.4, 31.4, -37.4) }, k.line, 1.1)
            p.stroke(path { $0.m(34.5, -38.6); $0.c(34.7, -36.8, 36.6, -36.4, 37.6, -37.4) }, k.line, 1.1)
            if kind == "happy" { p.blob([ell(34.5, -35.6, 1.5, 1.8)], k.tongue, outline: false) }
        }
        for (fx, fy) in [(27.5, -39.0), (28.6, -37.4), (39.6, -39.6)] as [(CGFloat, CGFloat)] {
            p.dot(fx, fy, 0.45, k.freckle)                                   // freckles
        }
        let eyeKind = kind == "open" || kind == "bark" ? "open" : (kind == "happy" ? "happy" : "closed")
        p.eyes([(26.5, -46.5), (36.8, -46.5)], eyeKind, r: 1.8)
        p.dot(24.2, -41.6, 1.9, k.blush)
        p.dot(40.2, -41.6, 1.6, k.blush)
    }

    static func dogSit(_ p: PalsPainter) {
        let k = p.ink
        let sh = [ell(-6, -12.5, 13, 12.5), ell(9, -24, 11.5, 15), ell(-1, -18, 12, 12)]
        p.blob([rr(14.5, -16, 21, -1.5, 3.2), ell(19, -2.2, 4.3, 2.4)], k.wshade)   // far front leg
        p.blob(sh, k.white)
        p.clipped(sh, [ell(-8, -14, 9.5, 9)], k.tan)
        p.clipped(sh, [ell(-4, -27, 9, 13, -0.5)], k.saddle)
        p.clipped(sh, [ell(13, -33, 6, 5)], k.tan)
        p.blob([ell(1, -2.4, 8, 2.8)], k.white)                                   // hind paw
        p.blob([rr(8.5, -18, 15, -1.5, 3.2), ell(13, -2.2, 4.3, 2.4)], k.white)    // near front leg
    }

    static func dogSleep(_ p: PalsPainter, blaze: Bool) {
        let k = p.ink
        let tail = path { $0.m(-24, -8); $0.c(-30, -3, -20, 1.5, -6, 0.5) }
        p.stroke(tail, k.line, 5 + Pals.outline * 2)
        p.stroke(tail, k.tan, 5)
        p.stroke(path { $0.m(-12, 1.2); $0.c(-9, 1.2, -7.5, 0.9, -6, 0.5) }, k.white, 5)
        let sh = [ell(-2, -11, 25, 10.5)]
        p.blob(sh, k.white)
        p.clipped(sh, [ell(-6, -20, 20, 8)], k.saddle)
        p.clipped(sh, [ell(-19, -10, 8, 7)], k.tan)
        p.blob([ell(18, -2.4, 12, 2.6)], k.white)                                 // paws stretched forward
        let hs = [ell(21, -12, 12.5, 10)]
        p.blob(hs, k.tan)
        if blaze { p.clipped(hs, [path { $0.m(22, -22); $0.l(25, -22); $0.l(30, -9); $0.l(18, -9); $0.z() }], k.white) }
        p.blob([ell(26.5, -7.5, 7.5, 5)], k.white)
        p.dot(29.5, -10, 2.6, k.nose)
        p.blob([path { $0.m(13, -19); $0.c(8, -16, 8, -6, 12, -2.5); $0.c(15, -1, 18, -4, 17, -9); $0.z() }], k.tandark)
        p.eyes([(21, -13.5), (29, -13.5)], "closed", r: 1.6)
        p.dot(19.5, -9.5, 1.6, k.blush)
    }

    // MARK: You (faces right, head turned three-quarters toward the viewer)

    static let meHipY: CGFloat = -21
    static let shoulderBack = CGPoint(x: -7, y: -42)
    static let shoulderFront = CGPoint(x: 1, y: -42)
    static let meNeck = CGPoint(x: 2, y: -48)

    static func meLeg(_ p: PalsPainter, _ x: CGFloat, back: Bool) {
        let k = p.ink
        p.blob([rr(x - 4.4, meHipY - 2, x + 4.4, -3, 3.5), ell(x + 1.8, -3.2, 5.8, 3.4)], back ? k.pantsBack : k.pants)
        p.clipped([ell(x + 1.8, -3.2, 5.8, 3.4)], [rr(x - 6, -6.5, x + 9, 2, 1)], k.boots)
    }

    static func meTorso(_ p: PalsPainter) {
        let k = p.ink
        let sh = [rr(-12.5, -47, 12.5, -16, 8.5)]
        p.blob(sh, k.jacket)
        for y in [-38.0, -28.5] as [CGFloat] { p.clipped(sh, [rr(-14, y, 14, y + 1.3, 0.6)], k.jshade) }   // puffer seams
        p.clipped(sh, [rr(-14, -19.5, 14, -15, 1)], k.jshade)
        p.stroke(path { $0.m(6, -46); $0.l(6, -17) }, k.jshade, 1.1)                                        // zip
        p.dot(6, -40, 0.9, k.zip)
        p.blob([rr(-7.5, -51, 11, -44.5, 3)], k.collar)
    }

    static func meArm(_ p: PalsPainter, _ s: CGPoint, front: Bool) {
        let k = p.ink
        let sleeve = rr(s.x - 4.4, s.y - 3, s.x + 4.4, s.y + 17, 4.2)
        p.blob([ell(s.x, s.y + 19, 3.7, 3.7)], k.skin)                         // hand
        p.blob([sleeve], front ? k.jacket : k.jshade)
        p.clipped([sleeve], [rr(s.x - 6, s.y + 7, s.x + 6, s.y + 8.2, 0.5)], k.jshade)
    }

    /// kind: open, happy, sleep, call
    static func meHead(_ p: PalsPainter, _ kind: String) {
        let k = p.ink
        // curly hair behind the face
        var hair = [ell(-3, -62, 14.5, 13)]
        for (dx, dy) in [(0.0, 0.0), (1.5, 5.0), (4.5, 8.5), (-0.5, -5.0)] as [(CGFloat, CGFloat)] {
            hair.append(ell(-14.5 + dx, -57 + dy, 3.6, 3.6))
        }
        p.blob(hair, k.hair)
        let face = [ell(4.5, -61, 13.5, 13.5)]
        p.blob(face, k.skin)
        p.clipped(face, [ell(-7, -61, 6, 14)], k.skinShade)
        p.blob([ell(-6.5, -60.5, 2.6, 3.6)], k.skin)                            // ear
        // beanie: pompom, dome, ribbed cuff
        p.blob([ell(3, -84.5, 5.6, 5.3)], k.pom)
        for a in stride(from: 0.0, to: 360.0, by: 45.0) {
            let r = CGFloat(a) * .pi / 180
            p.dot(3 + 3 * cos(r), -84.5 + 3 * sin(r), 0.8, k.beanieDark)
        }
        let dome = [path { $0.m(-12, -68); $0.c(-12, -83, 18, -83, 18, -68); $0.z() }]
        p.blob(dome, k.beanie)
        for x in stride(from: -9.0, to: 18.0, by: 3.0) { p.clipped(dome, [rr(CGFloat(x), -82, CGFloat(x) + 0.9, -66, 0.4)], k.beanieDark) }
        let cuff = [rr(-13.5, -71.5, 19.5, -63.5, 3.8)]
        p.blob(cuff, k.beanieDark)
        for x in stride(from: -11.0, to: 19.0, by: 2.0) { p.clipped(cuff, [rr(CGFloat(x), -72, CGFloat(x) + 0.8, -63, 0.3)], k.rib) }
        // face
        let eyeKind = kind == "open" || kind == "call" ? "open" : (kind == "happy" ? "happy" : "closed")
        p.eyes([(5.5, -57.5), (13.8, -57.5)], eyeKind, r: 1.8)
        switch kind {
        case "call": p.blob([ell(9.8, -51.8, 1.8, 2)], k.mouth, outline: false)
        case "sleep": p.stroke(path { $0.m(8.8, -52); $0.l(10.8, -52) }, k.line, 1.1)
        default: p.stroke(path { $0.m(7.6, -53); $0.c(8.6, -50.8, 11, -50.8, 12, -53) }, k.line, 1.2)
        }
    }

    static func meSitLegs(_ p: PalsPainter) {
        let k = p.ink
        p.blob([rr(-6, -12, 18, -3, 4.2)], k.pantsBack)
        p.blob([rr(-6, -10, 19, -0.5, 4.5)], k.pants)
        p.blob([ell(20.5, -6.5, 3.6, 6.2)], k.boots)
    }

    /// Draw every part for a recipe (takes a few milliseconds; done at launch and when the recipe changes)
    static func build(_ r: PalsRecipe) -> [String: PalsPart] {
        let ink = PalsInk(r)
        var parts: [String: PalsPart] = [:]
        func add(_ name: String, _ pivot: CGPoint, _ draw: (PalsPainter) -> Void) {
            parts[name] = render(pivot: pivot, ink: ink, draw)
        }
        let legs: [(String, CGFloat, Bool)] = [("dog_far_back", -10, true), ("dog_far_front", 17, true),
                                               ("dog_near_back", -15, false), ("dog_near_front", 12, false)]
        for (name, x, far) in legs { add(name, CGPoint(x: x, y: hipY)) { dogLeg($0, x, far: far) } }
        add("dog_body", .zero) { dogBody($0) }
        add("dog_tail", tailPivot) { dogTail($0) }
        for kind in ["open", "happy", "sleep", "howl", "bark"] { add("dog_head_" + kind, neck) { dogHead($0, kind, blaze: r.blaze) } }
        add("dog_sit", .zero) { dogSit($0) }
        add("dog_sleep", .zero) { dogSleep($0, blaze: r.blaze) }
        add("me_back_leg", CGPoint(x: -3.5, y: meHipY)) { meLeg($0, -3.5, back: true) }
        add("me_front_leg", CGPoint(x: 3.5, y: meHipY)) { meLeg($0, 3.5, back: false) }
        add("me_torso", .zero) { meTorso($0) }
        add("me_arm_back", shoulderBack) { meArm($0, shoulderBack, front: false) }
        add("me_arm_front", shoulderFront) { meArm($0, shoulderFront, front: true) }
        for kind in ["open", "happy", "sleep", "call"] { add("me_head_" + kind, meNeck) { meHead($0, kind) } }
        add("me_sit_legs", .zero) { meSitLegs($0) }
        // windy-day outfits
        add("me_scarf", .zero) { meScarf($0) }
        add("me_scarf_tail", CGPoint(x: -6, y: -44.5)) { meScarfTail($0) }
        add("dog_body_sweater", .zero) { dogBodySweater($0) }
        add("dog_sit_sweater", .zero) { dogSitSweater($0) }
        add("dog_sleep_sweater", .zero) { dogSleepSweater($0, blaze: r.blaze) }
        return parts
    }
}

/// A character made of parts that turn around their joints. Each frame, a pose puts the parts it needs;
/// parts that weren't put are hidden.
@MainActor final class PalsRig {
    let root = SKNode()
    var parts: [String: PalsPart]
    private var slots: [String: SKSpriteNode] = [:]
    private var used = Set<String>()

    init(parts: [String: PalsPart], slots order: [String]) {
        self.parts = parts
        for (i, name) in order.enumerated() {
            let n = SKSpriteNode()
            n.zPosition = CGFloat(i) * 0.01
            n.isHidden = true
            slots[name] = n
            root.addChild(n)
        }
    }

    func begin() { used.removeAll() }

    /// Show `part` in `slot` at its joint position + (dx, dy), turned counter-clockwise by rot radians
    func put(_ slot: String, _ part: String, dx: CGFloat = 0, dy: CGFloat = 0, rot: CGFloat = 0, yScale: CGFloat = 1) {
        guard let n = slots[slot], let p = parts[part] else { return }
        if n.texture !== p.tex {
            n.texture = p.tex
            n.size = p.size
            n.anchorPoint = p.anchor
        }
        n.position = CGPoint(x: p.base.x + dx, y: p.base.y + dy)
        n.zRotation = rot
        n.yScale = yScale
        n.isHidden = false
        used.insert(slot)
    }

    func end() {
        for (name, n) in slots where !used.contains(name) { n.isHidden = true }
    }
}

/// Shows or hides something smoothly. A change only counts once it has lasted a moment, so the brief
/// window-list flips while you swipe between Spaces or full-screen apps don't make things flicker.
struct Presence {
    var shown = true
    var alpha: CGFloat = 1
    var changeSince: CGFloat = -1

    @MainActor mutating func update(_ node: SKNode, want: Bool, t: CGFloat, dt: CGFloat, frozen: Bool) {
        if want != shown {
            if changeSince < 0 { changeSince = t }
            // coming back is quick; going away waits a little longer so brief flips don't cause flicker
            if t - changeSince > (want ? 0.1 : 0.35) && !frozen {
                shown = want
                changeSince = -1
            }
        } else {
            changeSince = -1
        }
        let target: CGFloat = shown ? 1 : 0
        alpha += max(-dt * 6, min(dt * 6, target - alpha))
        node.alpha = alpha
        node.isHidden = alpha < 0.01
    }
}

@MainActor final class Companions {
    enum DogMode { case wander, sit, follow, chase, fetchBack, comeToMe, cuddle, petted, howl, wreck, bark, nap, toFire, byFire }
    enum MeMode { case idle, walk, sit, wave, throwBall, pet, nap, toFire, byFire }

    unowned let scene: SnowScene
    var recipe = PalsRecipe()
    let dog: PalsRig
    let me: PalsRig
    private(set) var enabled = UserDefaults.standard.object(forKey: "pals") as? Bool ?? true

    // the beagle
    var dogX: CGFloat = 0, dogY: CGFloat = 0, dogFacing: CGFloat = 1, dogPh: CGFloat = 0
    var dogMode = DogMode.wander
    var dogTarget: CGFloat = 0
    var dogUntil: CGFloat = 0          // when a timed mode ends
    var dogRunning = false
    var jumpUntil: CGFloat = 0
    var lastDogClick: CGFloat = -10
    var dogStepAcc: CGFloat = 0

    // you
    var meX: CGFloat = 0, meY: CGFloat = 0, meFacing: CGFloat = 1, mePh: CGFloat = 0
    var meMode = MeMode.idle
    var meTarget: CGFloat = 0
    var meUntil: CGFloat = 0
    var blinkUntil: CGFloat = 0
    var meStepAcc: CGFloat = 0

    // fetch, chasing and snowmen
    var toy: SKSpriteNode?
    var toyVel = CGVector.zero
    var toyFlying = false
    var toyHeld = false
    var throwAt: CGFloat = -1
    var nextFetch: CGFloat = 0
    weak var chaseBall: Snowball?
    var chaseX: CGFloat = 0
    weak var snowmanBase: Snowball?
    var snowmanAt: CGFloat = 0
    var knockAt: CGFloat = -1

    // napping / eco frame rate
    var lastMouse = CGPoint.zero
    var lastActive: CGFloat = 0
    var napping = false
    var eco = false
    var powerCheck: CGFloat = 0
    var lowPower = false
    var nextZ: CGFloat = 0

    // campfire and Christmas tree
    let fireNode = SKNode()
    let treeNode = SKNode()
    var flames: [SKSpriteNode] = []
    var fireGlow = SKSpriteNode()
    var embers: [SKSpriteNode] = []
    var treeLights: [SKSpriteNode] = []
    var starGlow = SKSpriteNode()
    var treeStar = SKSpriteNode()
    var sparkle = SKSpriteNode()
    var lightCores: [SKSpriteNode] = []
    var lightPhase: [CGFloat] = []
    var lightSpeed: [CGFloat] = []
    var treeScale: CGFloat = 1
    var treePresence = Presence()
    var firePresence = Presence()
    var dogPresence = Presence()
    var mePresence = Presence()
    var holdUntil: CGFloat = 0           // right after switching Spaces: hold everything where it is
    var treeCoveredSince: CGFloat = -1
    var fireCoveredSince: CGFloat = -1
    var lastSceneryT: CGFloat = 0
    var fireX: CGFloat = 0
    var treeX: CGFloat = 0
    var fireOn = UserDefaults.standard.object(forKey: "campfire") as? Bool ?? true
    var treeOn = UserDefaults.standard.object(forKey: "xmasTree") as? Bool ?? true
    var propsCheck: CGFloat = 0
    var meltAt: CGFloat = 0
    var fireDim: CGFloat = 1
    var inCampfire = false
    var nextCampfire: CGFloat = 0
    var campfireEnds: CGFloat = 0
    var dogFireSince: CGFloat = 0
    var fireSide: CGFloat = 1            // which side of the fire you sit on (the beagle takes the other)
    var bundled = false                  // scarf and sweater on (during strong gusts)
    var calmSince: CGFloat = -1

    init(scene: SnowScene) {
        self.scene = scene
        let parts = PalsArt.build(PalsRecipe())
        dog = PalsRig(parts: parts, slots: ["farBack", "farFront", "tail", "body", "nearBack", "nearFront", "head"])
        me = PalsRig(parts: parts, slots: ["scarfTail", "armBack", "legBack", "legFront", "torso", "scarf", "head", "armFront"])
        dog.root.zPosition = 6.6
        me.root.zPosition = 6.55
        scene.world.addChild(me.root)
        scene.world.addChild(dog.root)
        let w = scene.size.width
        meX = openSpot(near: w * 0.18, range: w * 0.15)
        dogX = openSpot(near: meX + 60, range: 40)
        dogTarget = dogX
        meTarget = meX
        nextFetch = scene.t + 20
        lastMouse = NSEvent.mouseLocation
        lastActive = scene.t
        setEnabled(enabled)
        setupScenery()
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "pals")
        dog.root.isHidden = !on
        me.root.isHidden = !on
        if !on { dropToy() }
    }

    /// Redraw both characters, e.g. after the recipe changed
    func applyRecipe(_ r: PalsRecipe) {
        recipe = r
        let parts = PalsArt.build(r)
        dog.parts = parts
        me.parts = parts
    }

    // MARK: Ground

    func groundY(_ x: CGFloat) -> CGFloat {
        guard let g = scene.ground, let c = g.col(at: x) else { return 0 }
        var y = max(0, g.topY + g.h[c] - Pals.sink)
        // if the Dock pops up underneath, ride up and stand on its snow
        if let d = scene.dockPile, let dc = d.col(at: x) { y = max(y, d.surface(dc) - Pals.sink) }
        return y
    }

    /// Somewhere on the ground that isn't behind a window or the Dock
    func visible(_ x: CGFloat) -> Bool {
        guard let g = scene.ground, let c = g.col(at: x), !g.occ[c] else { return false }
        if let d = scene.dockRect ?? scene.dockZone, x > d.minX - 10, x < d.maxX + 10 { return false }
        return true
    }

    /// Not covered by a window (they are hidden while walking behind one)
    func onOpenGround(_ x: CGFloat) -> Bool {
        guard let g = scene.ground, let c = g.col(at: x) else { return false }
        return !g.occ[c]
    }

    func clampX(_ x: CGFloat) -> CGFloat { min(scene.size.width - 30, max(30, x)) }

    func openSpot(near x: CGFloat, range: CGFloat) -> CGFloat {
        for _ in 0..<12 {
            let c = clampX(x + rnd(-range, range))
            if visible(c) { return c }
        }
        return clampX(x)
    }

    /// Leave footprints: press the snow down a little every few steps
    func footprint(_ x: CGFloat, _ acc: inout CGFloat, _ moved: CGFloat, every: CGFloat) {
        acc += moved
        guard acc >= every, let g = scene.ground, let c = g.col(at: x) else { return }
        acc = 0
        if !g.occ[c] && g.h[c] > 3 {
            g.h[c] -= 0.6
            g.dirty = true
        }
    }

    /// Walk x toward target; returns true once there
    static func step(_ x: inout CGFloat, to target: CGFloat, speed: CGFloat, dt: CGFloat,
                     facing: inout CGFloat, ph: inout CGFloat, stride: CGFloat) -> CGFloat? {
        let d = target - x
        if abs(d) < 2 { return nil }
        let mv = min(abs(d), speed * dt) * (d > 0 ? 1 : -1)
        x += mv
        facing = d > 0 ? 1 : -1
        ph += abs(mv) / stride
        return abs(mv)
    }

    // MARK: Per-frame update

    func update(_ dt: CGFloat) {
        let t = scene.t
        checkActivity(t)
        guard scene.ground != nil else { return }
        updateScenery(t)
        guard enabled else { return }
        meX = clampX(meX)          // the screen may have changed size
        dogX = clampX(dogX)
        updateToy(dt, t)
        updateMe(dt, t)
        updateDog(dt, t)
        checkSnowman(t)
        checkCampfire(t)
        updateOutfits(t)
        // settle onto the snow surface
        dogY += (groundY(dogX) - dogY) * min(1, dt * 10)
        meY += (groundY(meX) - meY) * min(1, dt * 10)
        poseDog(t)
        poseMe(t)
        dog.root.position = CGPoint(x: dogX, y: dogY)
        dog.root.xScale = dogFacing
        dogPresence.update(dog.root, want: onOpenGround(dogX), t: t, dt: dt, frozen: t < holdUntil)
        me.root.position = CGPoint(x: meX, y: meY)
        me.root.xScale = meFacing
        mePresence.update(me.root, want: onOpenGround(meX), t: t, dt: dt, frozen: t < holdUntil)
        if napping && t > nextZ {
            nextZ = t + 3
            float("z", at: CGPoint(x: meX + meFacing * 14, y: meY + 70), size: 12)
        }
    }

    // MARK: You

    func updateMe(_ dt: CGFloat, _ t: CGFloat) {
        if throwAt > 0 && t >= throwAt { throwAt = -1; launchToy() }
        switch meMode {
        case .idle, .sit:
            if t > meUntil {
                if meMode == .sit { meMode = .idle; meUntil = t + rnd(1, 3); break }
                let r = CGFloat.random(in: 0...1)
                if r < 0.6 {
                    meTarget = openSpot(near: meX, range: 220)
                    meMode = .walk
                } else if r < 0.8 {
                    meMode = .sit
                    meUntil = t + rnd(8, 16)
                } else {
                    meUntil = t + rnd(3, 7)
                }
            }
            if t > nextFetch && toy == nil && dogFree && !napping { startThrow(t) }
        case .walk:
            if let moved = Companions.step(&meX, to: meTarget, speed: Pals.meWalk, dt: dt, facing: &meFacing, ph: &mePh, stride: 7) {
                footprint(meX, &meStepAcc, moved, every: 11)
            } else {
                meMode = .idle
                meUntil = t + rnd(3, 8)
            }
        case .wave, .throwBall, .pet:
            if t > meUntil {
                if inCampfire {
                    meMode = .toFire                    // back to the fire
                    meTarget = clampX(fireX + fireSide * 34)
                } else {
                    meMode = .idle
                    meUntil = t + rnd(2, 5)
                }
            }
        case .toFire:
            if let moved = Companions.step(&meX, to: meTarget, speed: Pals.meWalk, dt: dt, facing: &meFacing, ph: &mePh, stride: 7) {
                footprint(meX, &meStepAcc, moved, every: 11)
            } else {
                meMode = .byFire
                meFacing = fireX > meX ? 1 : -1
            }
        case .byFire:
            break
        case .nap:
            break
        }
    }

    var dogFree: Bool { [.wander, .sit, .follow].contains(dogMode) }

    func startThrow(_ t: CGFloat) {
        // throw toward whichever side has more room
        let w = scene.size.width
        meFacing = meX < w / 2 ? 1 : -1
        meMode = .throwBall
        meUntil = t + 0.7
        throwAt = t + 0.3
        nextFetch = t + rnd(Pals.fetchEvery.lowerBound, Pals.fetchEvery.upperBound)
    }

    // MARK: The Pet

    func updateDog(_ dt: CGFloat, _ t: CGFloat) {
        var speed = Pals.dogWalk
        dogRunning = false
        switch dogMode {
        case .wander:
            if dogRunningZoomies { speed = Pals.dogRun; dogRunning = true }
            if moveDog(dt, speed) == nil {
                dogRunningZoomies = false
                pickDogIdle(t)
            }
        case .sit:
            if t > dogUntil { newWanderTarget() }
        case .follow:
            dogTarget = clampX(meX + (dogX < meX ? -34 : 34))
            if moveDog(dt, speed) == nil {
                dogMode = .sit
                dogFacing = meX > dogX ? 1 : -1
                dogUntil = t + rnd(5, 10)
            }
        case .chase:
            dogRunning = true
            if let toy = toy, !toyHeld {
                let side: CGFloat = dogX < toy.position.x ? -1 : 1
                dogTarget = clampX(toy.position.x + side * 30)
                if abs(dogTarget - dogX) < 2 { dogFacing = toy.position.x > dogX ? 1 : -1 }
                let mouthX = dogX + dogFacing * 34
                if abs(toy.position.x - mouthX) < 12 && toy.position.y < dogY + 48 {
                    toyHeld = true
                    toyFlying = false
                    if toy.position.y > dogY + 20 { jumpUntil = t + 0.35 }   // caught it in the air
                    dogMode = .fetchBack
                }
            } else if let b = chaseBall {
                chaseX = b.x
                dogTarget = clampX(b.x)
            } else {
                dogTarget = clampX(chaseX)
            }
            if moveDog(dt, Pals.dogRun) == nil && toy == nil && chaseBall == nil {
                dogMode = .sit
                dogUntil = t + 2.5
                say("*sniff sniff*", over: .dog)
            }
        case .fetchBack:
            dogRunning = true
            dogTarget = clampX(meX + (dogX < meX ? -30 : 30))
            if moveDog(dt, Pals.dogRun) == nil {
                dropToy()
                dogFacing = meX > dogX ? 1 : -1
                cuddle(t, 1.8)
            }
        case .comeToMe:
            dogRunning = true
            dogTarget = clampX(meX + (dogX < meX ? -30 : 30))
            if moveDog(dt, Pals.dogRun) == nil {
                dogFacing = meX > dogX ? 1 : -1
                jumpUntil = t + 0.4
                cuddle(t, 2.4)
            }
        case .cuddle, .petted:
            if t > dogUntil { newWanderTarget() }
        case .howl:
            if t > dogUntil { newWanderTarget() }
        case .wreck:
            dogRunning = true
            guard let st = snowmanStack() else { snowmanBase = nil; newWanderTarget(); break }
            let base = st[0]
            let onGround = base.pile === scene.ground
            if onGround {
                let side: CGFloat = dogX < base.x ? -1 : 1
                dogTarget = clampX(base.x + side * (base.r + 24))
            } else {
                dogTarget = clampX(base.x)
            }
            if moveDog(dt, Pals.dogRun) == nil {
                dogFacing = base.x > dogX ? 1 : -1
                if onGround {
                    jumpUntil = t + 0.35
                    knockAt = t + 0.25
                    dogMode = .petted
                    dogUntil = t + 1.6
                } else {
                    dogMode = .bark
                    dogUntil = t + 1.8
                    knockAt = t + 1.6
                    say("Woof! Woof!", over: .dog)
                }
            }
        case .bark:
            if t > dogUntil { newWanderTarget() }
        case .toFire, .byFire:
            break                                   // handled below
        case .nap:
            dogTarget = clampX(meX + (dogX < meX ? -38 : 38))
            if moveDog(dt, Pals.dogWalk) == nil { dogFacing = meX > dogX ? 1 : -1 }
        }
        if dogMode == .toFire {
            if moveDog(dt, Pals.dogWalk) == nil {
                dogMode = .byFire
                dogFireSince = t
                dogFacing = fireX > dogX ? 1 : -1
            }
        }
        if knockAt > 0 && t >= knockAt {
            knockAt = -1
            knockSnowman()
        }
    }

    var dogRunningZoomies = false

    @discardableResult
    func moveDog(_ dt: CGFloat, _ speed: CGFloat) -> CGFloat? {
        let moved = Companions.step(&dogX, to: dogTarget, speed: speed, dt: dt, facing: &dogFacing, ph: &dogPh,
                                    stride: speed > Pals.dogWalk ? 9 : 6)
        if let m = moved { footprint(dogX, &dogStepAcc, m, every: 8) }
        return moved
    }

    func pickDogIdle(_ t: CGFloat) {
        let r = CGFloat.random(in: 0...1)
        if r < 0.35 {
            dogMode = .sit
            dogUntil = t + rnd(4, 9)
        } else if r < 0.65 {
            dogMode = .follow
        } else {
            newWanderTarget()
            dogRunningZoomies = !Cfg.reduceMotion && CGFloat.random(in: 0...1) < 0.2   // no zoomies with Reduce Motion
        }
    }

    func newWanderTarget() {
        if inCampfire && fireOn {
            dogMode = .toFire                       // go back to the campfire
            dogTarget = clampX(fireX - fireSide * 42)
            return
        }
        dogMode = .wander
        dogTarget = openSpot(near: dogX, range: 260)
    }

    func cuddle(_ t: CGFloat, _ time: CGFloat) {
        dogMode = .cuddle
        dogUntil = t + time
        meMode = .pet
        meUntil = t + time
        meFacing = dogX > meX ? 1 : -1
        hearts(at: CGPoint(x: (dogX + meX) / 2, y: max(dogY, meY) + 60))
    }

    // MARK: Fetch toy

    func launchToy() {
        guard toy == nil, let tex = scene.ballTex else { return }
        let n = SKSpriteNode(texture: tex)
        n.size = CGSize(width: 9, height: 9)
        n.zPosition = 6.7
        n.position = CGPoint(x: meX - meFacing * 10, y: meY + 62)
        scene.world.addChild(n)
        toy = n
        toyVel = CGVector(dx: meFacing * rnd(170, 250), dy: rnd(230, 300))
        toyFlying = true
        toyHeld = false
        if dogFree {
            dogMode = .chase
            chaseBall = nil
        }
    }

    func updateToy(_ dt: CGFloat, _ t: CGFloat) {
        guard let n = toy else { return }
        if toyHeld {
            n.position = CGPoint(x: dogX + dogFacing * 33, y: dogY + 33)
            return
        }
        guard toyFlying else { return }
        toyVel.dy -= Cfg.gravity * 0.8 * dt
        var p = n.position
        p.x += toyVel.dx * dt
        p.y += toyVel.dy * dt
        let floor = groundY(p.x) + 4.5
        if toyVel.dy < 0 && p.y <= floor {
            p.y = floor
            toyFlying = false        // resting on the snow until the beagle picks it up
        }
        n.position = p
        if p.x < -20 || p.x > scene.size.width + 20 {
            dropToy()
            if dogMode == .chase { newWanderTarget() }
        }
    }

    func dropToy() {
        guard let n = toy else { return }
        for _ in 0..<5 {
            scene.spawnClump(at: n.position, vel: CGVector(dx: rnd(-60, 60), dy: rnd(40, 120)), sourceID: -3)
        }
        n.removeFromParent()
        toy = nil
        toyHeld = false
        toyFlying = false
    }

    // MARK: Snowballs and snowmen (called by the scene)

    func ballThrown(_ b: Snowball) {
        guard enabled, !napping, ![.howl, .cuddle, .wreck, .fetchBack].contains(dogMode) else { return }
        dropToy()
        chaseBall = b
        chaseX = b.x
        dogMode = .chase
    }

    func snowmanBuilt(_ base: Snowball) {
        snowmanBase = base
        snowmanAt = scene.t
    }

    func snowmanStack() -> [Snowball]? {
        guard let b = snowmanBase, scene.balls.contains(where: { $0 === b }), !b.falling, !b.dragging else { return nil }
        let st = scene.stack(from: b)
        guard st.count == 3, st[2].decor != nil else { return nil }
        return st
    }

    func checkSnowman(_ t: CGFloat) {
        guard snowmanBase != nil, dogMode != .wreck, t - snowmanAt > Pals.snowmanGrace, dogFree, !napping else { return }
        if snowmanStack() == nil { snowmanBase = nil; return }
        dogMode = .wreck
    }

    func knockSnowman() {
        guard let st = snowmanStack() else { snowmanBase = nil; return }
        let dir: CGFloat = st[0].x > dogX ? 1 : -1
        for (i, b) in st.enumerated() {
            b.drop(vel: CGVector(dx: dir * rnd(60, 150), dy: rnd(80, 160) + CGFloat(i) * 40))
        }
        snowmanBase = nil
        say("Oops!", over: .dog)
    }

    // MARK: Clicks (called by the scene)

    func dogRect() -> CGRect {
        CGRect(x: dogX - (dogFacing > 0 ? 30 : 46), y: dogY, width: 76, height: 58)
    }

    func meRect() -> CGRect {
        CGRect(x: meX - 17, y: meY, width: 36, height: 92)
    }

    func hit(_ m: CGPoint) -> Bool {
        enabled && ((!dog.root.isHidden && dogRect().contains(m)) || (!me.root.isHidden && meRect().contains(m))
                    || fireClickable(m))
    }

    /// Returns true if the click was on one of you (so the scene doesn't treat it as grabbing a snowball)
    func mouseDown(at m: CGPoint) -> Bool {
        guard enabled else { return false }
        let t = scene.t
        if !dog.root.isHidden && dogRect().contains(m) {
            wake(t)
            if toyHeld { dropToy() }
            chaseBall = nil
            if t - lastDogClick < Pals.howlWindow {
                dogMode = .howl
                dogUntil = t + 2.4
                lastDogClick = -10
                say("Awoooo! 🎶", over: .dog)
                howlSound?.stop()
                howlSound?.play()
            } else {
                dogMode = .petted
                dogUntil = t + 1.6
                lastDogClick = t
                hearts(at: CGPoint(x: dogX + dogFacing * 18, y: dogY + 58))
            }
            return true
        }
        if !me.root.isHidden && meRect().contains(m) {
            wake(t)
            meMode = .wave
            meUntil = t + 1.4
            meFacing = dogX > meX ? 1 : -1
            say(recipe.petName.isEmpty ? "Come here, buddy!" : "Come here, \(recipe.petName)!", over: .me)
            if dogMode != .howl {
                if toyHeld { dropToy() }
                chaseBall = nil
                dogMode = .comeToMe
            }
            return true
        }
        if fireClickable(m) {
            wake(t)
            if !inCampfire { startCampfire(t) }     // click the fire: campfire time right now
            return true
        }
        return false
    }

    lazy var howlSound: NSSound? = {
        // Optional: put a short howl.m4a / .mp3 / .wav in assets/ (or the app's Resources) to hear it
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r) }
        dirs.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("assets"))
        for d in dirs {
            for name in ["howl.m4a", "howl.mp3", "howl.wav", "howl.aiff"] {
                let u = d.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: u.path) { return NSSound(contentsOf: u, byReference: true) }
            }
        }
        return nil
    }()

    // MARK: Napping and the eco frame rate

    func checkActivity(_ t: CGFloat) {
        let m = NSEvent.mouseLocation
        if m != lastMouse {
            lastMouse = m
            lastActive = t
            if napping { wake(t) }
        } else if !napping && t - lastActive > Pals.napAfter {
            napping = true
            if enabled { startNap(t) }
        }
        if t > powerCheck {
            powerCheck = t + 5
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        // Frame rate and window checks follow the Performance menu, lower while napping or in Low Power Mode
        eco = napping || lowPower
        let fps = eco ? Cfg.ecoFPS : Cfg.activeFPS
        if let v = scene.view, v.preferredFramesPerSecond != fps { v.preferredFramesPerSecond = fps }
        let poll = eco ? Cfg.ecoPoll : Cfg.activePoll
        if Cfg.pollInterval != poll { Cfg.pollInterval = poll }
    }

    /// A strong gust: you put on your scarf and your pet gets its sweater; off again once it has been calm a while
    func updateOutfits(_ t: CGFloat) {
        if scene.windRegime == .strongGust {
            calmSince = -1
            if !bundled {
                bundled = true
                if !napping { say("Brrr! 🧣", over: .me) }
            }
        } else if bundled {
            if calmSince < 0 { calmSince = t } else if t - calmSince > 20 { bundled = false }
        }
    }

    func startNap(_ t: CGFloat) {
        dropToy()
        chaseBall = nil
        meMode = .nap
        dogMode = .nap
        nextZ = t + 2
    }

    func wake(_ t: CGFloat) {
        lastActive = t
        guard napping else { return }
        napping = false
        if meMode == .nap {
            if inCampfire {
                meMode = .toFire
                meTarget = clampX(fireX + fireSide * 34)
            } else {
                meMode = .idle
                meUntil = t + rnd(1, 3)
            }
        }
        if dogMode == .nap {
            dogMode = .petted        // a happy stretch and wag before wandering off
            dogUntil = t + 1.2
        }
    }

    // MARK: Poses

    func poseDog(_ t: CGFloat) {
        let r = dog
        r.begin()
        let s = sin(dogPh)
        let jumping = t < jumpUntil
        switch dogMode {
        case .nap where abs(dogTarget - dogX) < 2:
            r.put("body", bundled ? "dog_sleep_sweater" : "dog_sleep", yScale: 1 + 0.025 * sin(t * 2.2))
        case .byFire where t - dogFireSince > 10:
            r.put("body", bundled ? "dog_sleep_sweater" : "dog_sleep", yScale: 1 + 0.025 * sin(t * 2.2))    // dozing off by the fire
        case .sit, .howl, .byFire:
            let howl = dogMode == .howl
            r.put("tail", "dog_tail", dx: 6, dy: -16, rot: 1.25 + (howl ? 0 : 0.12 * sin(t * 5)))
            r.put("body", bundled ? "dog_sit_sweater" : "dog_sit")
            r.put("head", howl ? "dog_head_howl" : "dog_head_open", dx: -7, dy: 6,
                  rot: howl ? 0.55 + 0.04 * sin(t * 9) : 0.04 * sin(t * 1.3))
        default:
            let moving = abs(dogTarget - dogX) >= 2 && [.wander, .follow, .chase, .fetchBack, .comeToMe, .wreck, .nap, .toFire].contains(dogMode)
            let run = moving && (dogRunning || dogRunningZoomies)
            let amp: CGFloat = moving ? (run ? 0.55 : 0.3) : 0
            let ss = moving ? s : 0
            var bob = abs(ss) * (run ? 2.5 : 0.8)
            if jumping {
                let k = (jumpUntil - t) / 0.4
                bob += 14 * sin(.pi * min(1, max(0, 1 - k)))
            }
            let happy = [.petted, .cuddle].contains(dogMode)
            let wag: CGFloat = happy ? 0.35 * sin(t * 18) : 0.25 * sin(run ? t * 10 : t * 4)
            let tuck: CGFloat = jumping ? 0.5 : 0
            r.put("farBack", "dog_far_back", dy: bob, rot: -ss * amp - tuck)
            r.put("farFront", "dog_far_front", dy: bob, rot: ss * amp + tuck)
            r.put("tail", "dog_tail", dy: bob, rot: wag)
            r.put("body", bundled ? "dog_body_sweater" : "dog_body", dy: bob)
            r.put("nearBack", "dog_near_back", dy: bob, rot: ss * amp - tuck)
            r.put("nearFront", "dog_near_front", dy: bob, rot: -ss * amp + tuck)
            let head: String
            if dogMode == .bark { head = sin(t * 14) > 0 ? "dog_head_bark" : "dog_head_open" }
            else if happy || run { head = "dog_head_happy" }
            else { head = "dog_head_open" }
            r.put("head", head, dy: bob, rot: moving ? 0.05 * ss : 0.05 * sin(t * 1.1))
        }
        r.end()
    }

    func poseMe(_ t: CGFloat) {
        let r = me
        r.begin()
        let s = sin(mePh)
        if t > blinkUntil + 3.5 && CGFloat.random(in: 0...1) < 0.01 { blinkUntil = t + 0.13 }
        let blink = t < blinkUntil
        switch meMode {
        case .sit, .nap, .byFire:
            let asleep = meMode == .nap
            r.put("armBack", "me_arm_back", dy: -14, rot: 0.5)
            r.put("legBack", "me_sit_legs")
            r.put("torso", "me_torso", dy: -14 + (asleep ? 0.4 * sin(t * 2) : 0))
            if bundled {
                r.put("scarfTail", "me_scarf_tail", dy: -14, rot: scarfFlap(t))
                r.put("scarf", "me_scarf", dy: -14)
            }
            r.put("head", asleep || blink ? "me_head_sleep" : "me_head_open", dy: -14, rot: asleep ? -0.12 : 0)
            r.put("armFront", "me_arm_front", dy: -14, rot: 0.9)
        default:
            let walking = meMode == .walk || meMode == .toFire
            let amp: CGFloat = walking ? 0.45 : 0
            let ss = walking ? s : 0
            let bob = abs(ss) * 1.2
            var armBack = -ss * amp * 0.8, armFront = ss * amp * 0.8
            var head = blink ? "me_head_sleep" : "me_head_open"
            switch meMode {
            case .wave:
                armBack = 0.3
                armFront = 1.75 + 0.25 * sin(t * 14)
                head = "me_head_call"
            case .throwBall:
                armBack = throwAt > 0 ? -2.2 : 0.6     // wind up, then follow through
                armFront = 0.5
            case .pet:
                armBack = 0.2
                armFront = 1.25 + 0.15 * sin(t * 6)
                head = "me_head_happy"
            default: break
            }
            r.put("armBack", "me_arm_back", dy: bob, rot: armBack)
            r.put("legBack", "me_back_leg", rot: -ss * amp)
            r.put("legFront", "me_front_leg", rot: ss * amp)
            r.put("torso", "me_torso", dy: bob)
            if bundled {
                r.put("scarfTail", "me_scarf_tail", dy: bob, rot: scarfFlap(t))
                r.put("scarf", "me_scarf", dy: bob)
            }
            r.put("head", head, dy: bob, rot: walking ? 0.03 * ss : 0)
            r.put("armFront", "me_arm_front", dy: bob, rot: armFront)
        }
        r.end()
    }

    /// The scarf's tail flapping in the wind
    func scarfFlap(_ t: CGFloat) -> CGFloat {
        let k: CGFloat = Cfg.reduceMotion ? 0.35 : 1
        return k * (0.12 * sin(t * 11) + 0.05 * sin(t * 17 + 1))
    }

    // MARK: Speech bubbles and hearts

    enum Who { case dog, me }

    func say(_ text: String, over who: Who) {
        let p = who == .dog ? CGPoint(x: dogX + dogFacing * 16, y: dogY + 74) : CGPoint(x: meX, y: meY + 104)
        let label = SKLabelNode(text: text)
        label.fontName = "HelveticaNeue-Bold"
        label.fontSize = 12
        label.fontColor = NSColor(calibratedRed: 0.24, green: 0.17, blue: 0.13, alpha: 1)
        label.verticalAlignmentMode = .center
        label.zPosition = 0.1
        let w = label.frame.width + 16
        let bubble = SKShapeNode(rect: CGRect(x: -w / 2, y: -10, width: w, height: 20), cornerRadius: 10)
        bubble.fillColor = NSColor(calibratedWhite: 1, alpha: 0.94)
        bubble.strokeColor = NSColor(calibratedRed: 0.24, green: 0.17, blue: 0.13, alpha: 0.7)
        bubble.lineWidth = 1
        bubble.addChild(label)
        bubble.position = CGPoint(x: min(scene.size.width - w / 2 - 4, max(w / 2 + 4, p.x)), y: p.y)
        bubble.zPosition = 9
        scene.world.addChild(bubble)
        bubble.run(.sequence([.wait(forDuration: 1.4),
                              .group([.moveBy(x: 0, y: 12, duration: 0.5), .fadeOut(withDuration: 0.5)]),
                              .removeFromParent()]))
    }

    func float(_ text: String, at p: CGPoint, size: CGFloat) {
        let l = SKLabelNode(text: text)
        l.fontName = "HelveticaNeue-Bold"
        l.fontSize = size
        l.fontColor = NSColor(calibratedRed: 0.45, green: 0.52, blue: 0.68, alpha: 1)
        l.position = p
        l.zPosition = 9
        scene.world.addChild(l)
        l.run(.sequence([.group([.moveBy(x: 8, y: 26, duration: 1.6), .fadeOut(withDuration: 1.6)]), .removeFromParent()]))
    }

    func hearts(at p: CGPoint) {
        for i in 0..<3 {
            let l = SKLabelNode(text: "❤️")
            l.fontSize = 11 + CGFloat(i) * 2
            l.position = CGPoint(x: p.x + rnd(-10, 10), y: p.y)
            l.zPosition = 9
            l.alpha = 0
            scene.world.addChild(l)
            l.run(.sequence([.wait(forDuration: Double(i) * 0.18),
                             .group([.fadeIn(withDuration: 0.15), .moveBy(x: rnd(-8, 8), y: 30, duration: 1.1)]),
                             .fadeOut(withDuration: 0.3),
                             .removeFromParent()]))
        }
    }
}

// MARK: - Campfire and Christmas tree artwork (same sticker style as the characters)

extension PalsArt {
    static let treeLights: [(CGFloat, CGFloat)] = [(-24, -14), (-10, -19), (6, -18), (22, -13), (-17, -39), (-3, -42),
                                                   (13, -40), (-11, -63), (4, -65), (12, -60), (-6, -84), (5, -82)]

    /// A path moved to (tx, ty) and turned by rot
    static func moved(_ p: CGPath, _ tx: CGFloat, _ ty: CGFloat, _ rot: CGFloat) -> CGPath {
        var t = CGAffineTransform(translationX: tx, y: ty).rotated(by: rot)
        return p.copy(using: &t) ?? p
    }

    static func fireBase(_ p: PalsPainter) {
        let stone = palsRGB(150, 154, 162), stoneDark = palsRGB(118, 122, 132)
        let log = palsRGB(122, 78, 46), logEnd = palsRGB(196, 150, 104), ring = palsRGB(150, 104, 66)
        for x in [-19.0, -9.0, 9.0, 19.0] as [CGFloat] {
            let s = ell(x, -2.6, 6, 3.6)
            p.blob([s], stone)
            p.clipped([s], [ell(x + 1, -0.2, 6, 2)], stoneDark)
        }
        for (a, x) in [(-0.32, -2.0), (0.32, 2.0)] as [(CGFloat, CGFloat)] {
            p.blob([moved(rr(-15, -3.4, 15, 3.4, 3.4), x, -5, a)], log)
            p.stroke(moved(path { $0.m(-9, -0.6); $0.l(6, -0.6) }, x, -5, a), ring, 0.9)
            let e: CGFloat = a < 0 ? 15 : -15
            p.blob([moved(ell(e, 0, 2.4, 3.4), x, -5, a)], logEnd)
            p.stroke(moved(ell(e, 0, 1.2, 1.8), x, -5, a), ring, 0.6)
        }
    }

    /// One flame layer; it flickers by being stretched and swayed around its base at (0, -6)
    static func flame(_ p: PalsPainter, w: CGFloat, h: CGFloat, _ color: CGColor, outline: Bool) {
        let f = path { $0.m(0, -6); $0.c(-w * 1.15, -6, -w, -6 - h * 0.45, -w * 0.15, -6 - h)
                       $0.c(-w * 0.1, -6 - h * 0.7, w * 0.55, -6 - h * 0.6, w * 0.45, -6 - h * 0.78)
                       $0.c(w * 1.2, -6 - h * 0.4, w * 1.1, -6, 0, -6); $0.z() }
        p.blob([f], color, outline: outline)
    }

    static func starPath(_ cx: CGFloat, _ cy: CGFloat, _ R: CGFloat, _ r: CGFloat) -> CGPath {
        path { pth in
            for i in 0..<10 {
                let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                let rad = i % 2 == 0 ? R : r
                let pt = CGPoint(x: cx + rad * cos(a), y: cy + rad * sin(a))
                if i == 0 { pth.move(to: pt) } else { pth.addLine(to: pt) }
            }
            pth.closeSubpath()
        }
    }

    static func tier(_ b: CGFloat, _ t: CGFloat, _ w: CGFloat) -> CGPath {
        path { $0.m(0, t); $0.c(w * 0.35, t + (b - t) * 0.3, w * 0.8, b - 7, w, b)
               $0.c(w * 0.55, b + 5, -w * 0.55, b + 5, -w, b)
               $0.c(-w * 0.8, b - 7, -w * 0.35, t + (b - t) * 0.3, 0, t); $0.z() }
    }

    static func tree(_ p: PalsPainter) {
        let green = palsRGB(58, 150, 92), greenDark = palsRGB(38, 116, 70), snow = palsRGB(252, 252, 255)
        p.blob([rr(-5, -16, 5, 0, 2)], palsRGB(122, 78, 46))                                    // trunk
        for (b, t, w) in [(-12.0, -50.0, 30.0), (-36.0, -72.0, 24.0), (-58.0, -92.0, 17.0)] as [(CGFloat, CGFloat, CGFloat)] {
            let sh = [tier(b, t, w)]
            p.blob(sh, green)
            p.clipped(sh, [ell(0, b + 2, w * 1.1, 6)], greenDark)
            p.clipped(sh, [ell(-w * 0.45, t + (b - t) * 0.55, w * 0.32, 2.2, 0.5),
                           ell(w * 0.5, t + (b - t) * 0.62, w * 0.28, 2, -0.5)], snow)        // snow on the branches
        }
        let red = palsRGB(214, 52, 62), gold = palsRGB(242, 192, 62), blue = palsRGB(80, 142, 230)
        let baubles: [(CGFloat, CGFloat, CGColor)] = [(-16, -20, red), (12, -24, gold), (-4, -34, blue), (18, -16, blue),
                                                      (-12, -45, gold), (9, -49, red), (-2, -62, red), (8, -70, blue), (-7, -76, gold)]
        for (x, y, col) in baubles {
            p.blob([ell(x, y, 2.4, 2.4)], col)
            p.dot(x - 0.8, y - 0.8, 0.7, palsRGB(255, 255, 255, 0.85))
        }
    }

    static func treeStar(_ p: PalsPainter) {
        p.blob([starPath(0, -96, 8.5, 3.8)], palsRGB(255, 206, 64))
        p.dot(-2.2, -98.5, 1.2, palsRGB(255, 255, 255, 0.8))
    }

    /// A four-pointed glint that flashes on the star
    static func sparkle(_ p: PalsPainter) {
        let pts: [(CGFloat, CGFloat)] = [(0, -7), (1.3, -1.3), (7, 0), (1.3, 1.3), (0, 7), (-1.3, 1.3), (-7, 0), (-1.3, -1.3)]
        p.blob([path { pth in
            for (i, (x, y)) in pts.enumerated() { if i == 0 { pth.m(x, y) } else { pth.l(x, y) } }
            pth.z()
        }], palsRGB(255, 255, 240), outline: false)
    }

    static func buildScenery() -> [String: PalsPart] {
        let ink = PalsInk(PalsRecipe())
        var parts: [String: PalsPart] = [:]
        parts["fire_base"] = render(pivot: .zero, ink: ink) { fireBase($0) }
        parts["flame_outer"] = render(pivot: CGPoint(x: 0, y: -6), ink: ink) { flame($0, w: 11, h: 30, palsRGB(242, 122, 40), outline: true) }
        parts["flame_mid"] = render(pivot: CGPoint(x: 0, y: -6), ink: ink) { flame($0, w: 7.5, h: 21, palsRGB(255, 190, 60), outline: false) }
        parts["flame_core"] = render(pivot: CGPoint(x: 0, y: -6), ink: ink) { flame($0, w: 4.2, h: 12, palsRGB(255, 238, 160), outline: false) }
        parts["fire_glow"] = render(pivot: CGPoint(x: 0, y: -14), ink: ink) { $0.glow(0, -14, 40, palsRGB(255, 178, 76), 0.35) }
        return parts
    }

    /// The tree, drawn k times bigger than its design size (about 104 points tall)
    static func buildTree(scale k: CGFloat) -> [String: PalsPart] {
        let ink = PalsInk(PalsRecipe())
        var parts: [String: PalsPart] = [:]
        parts["tree"] = render(pivot: .zero, ink: ink, scale: k) { tree($0) }
        parts["tree_star"] = render(pivot: CGPoint(x: 0, y: -96), ink: ink, scale: k) { treeStar($0) }
        parts["sparkle"] = render(pivot: .zero, ink: ink, scale: k) { sparkle($0) }
        return parts
    }
}

// MARK: - Campfire and Christmas tree on the ground

extension Companions {
    func setupScenery() {
        let parts = PalsArt.buildScenery()
        func sprite(_ name: String) -> SKSpriteNode {
            let n = SKSpriteNode()
            if let p = parts[name] {
                n.texture = p.tex
                n.size = p.size
                n.anchorPoint = p.anchor
                n.position = p.base
            }
            return n
        }
        fireGlow = sprite("fire_glow")
        fireGlow.zPosition = -0.3
        fireNode.addChild(fireGlow)
        for (i, name) in ["flame_outer", "flame_mid", "flame_core"].enumerated() {
            let f = sprite(name)
            f.zPosition = CGFloat(i) * 0.01
            flames.append(f)
            fireNode.addChild(f)
        }
        let logs = sprite("fire_base")
        logs.zPosition = 0.05
        fireNode.addChild(logs)
        if let tex = scene.tex {
            for _ in 0..<3 {
                let e = SKSpriteNode(texture: tex)
                e.size = CGSize(width: 4, height: 4)
                e.color = NSColor(calibratedRed: 1, green: 0.6, blue: 0.25, alpha: 1)
                e.colorBlendFactor = 1
                e.zPosition = 0.1
                embers.append(e)
                fireNode.addChild(e)
            }
        }
        buildTree()
        fireNode.zPosition = 6.58      // between you and the beagle
        treeNode.zPosition = 6.45      // behind everyone
        scene.world.addChild(fireNode)
        scene.world.addChild(treeNode)
        let w = scene.size.width
        treeX = openSpot(near: w * 0.85, range: w * 0.1)
        fireX = openSpot(near: w * 0.6, range: w * 0.12)
        nextCampfire = scene.t + rnd(60, 120)        // the first campfire comes soon so you get to see it
        setFire(fireOn)
        setTree(treeOn)
    }

    /// (Re)build the tree a third of the screen tall, with its lights, star and sparkle
    func buildTree() {
        let k = max(1, scene.size.height / 3 / 104)
        treeScale = k
        treeNode.removeAllChildren()
        treeLights.removeAll()
        lightCores.removeAll()
        lightPhase.removeAll()
        lightSpeed.removeAll()
        let parts = PalsArt.buildTree(scale: k)
        func sprite(_ name: String) -> SKSpriteNode {
            let n = SKSpriteNode()
            if let p = parts[name] {
                n.texture = p.tex
                n.size = p.size
                n.anchorPoint = p.anchor
                n.position = p.base
            }
            return n
        }
        treeNode.addChild(sprite("tree"))
        guard let tex = scene.tex else { return }
        starGlow = SKSpriteNode(texture: tex)
        starGlow.size = CGSize(width: 46 * k, height: 46 * k)
        starGlow.color = NSColor(calibratedRed: 1, green: 0.85, blue: 0.3, alpha: 1)
        starGlow.colorBlendFactor = 1
        starGlow.position = CGPoint(x: 0, y: 96 * k)
        starGlow.zPosition = -0.05
        treeNode.addChild(starGlow)
        treeStar = sprite("tree_star")
        treeStar.zPosition = 0.2
        treeNode.addChild(treeStar)
        sparkle = sprite("sparkle")
        sparkle.position = CGPoint(x: 5 * k, y: 101 * k)
        sparkle.zPosition = 0.3
        sparkle.alpha = 0
        treeNode.addChild(sparkle)
        for (i, (x, y)) in PalsArt.treeLights.enumerated() {
            let color = LightString.colors[i % LightString.colors.count]
            let glow = SKSpriteNode(texture: tex)
            glow.size = CGSize(width: 12 * k, height: 12 * k)
            glow.color = color
            glow.colorBlendFactor = 1
            glow.position = CGPoint(x: x * k, y: -y * k)
            glow.zPosition = 0.1
            let core = SKSpriteNode(texture: tex)
            core.size = CGSize(width: 3.6 * k, height: 3.6 * k)
            core.color = color.blended(withFraction: 0.55, of: .white) ?? color
            core.colorBlendFactor = 1
            core.position = glow.position
            core.zPosition = 0.11
            treeLights.append(glow)
            lightCores.append(core)
            lightPhase.append(rnd(0, 6.28))
            lightSpeed.append(rnd(1.6, 3.4))
            treeNode.addChild(glow)
            treeNode.addChild(core)
        }
    }

    func setFire(_ on: Bool) {
        fireOn = on
        UserDefaults.standard.set(on, forKey: "campfire")
        fireNode.isHidden = !on
        firePresence = Presence(shown: on, alpha: on ? 1 : 0)
        if !on && inCampfire { endCampfire(scene.t) }
    }

    func setTree(_ on: Bool) {
        treeOn = on
        UserDefaults.standard.set(on, forKey: "xmasTree")
        treeNode.isHidden = !on
        treePresence = Presence(shown: on, alpha: on ? 1 : 0)
    }

    func updateScenery(_ t: CGFloat) {
        let w = scene.size.width
        let dt = min(0.1, max(0, t - lastSceneryT))
        lastSceneryT = t
        if t > propsCheck && t > holdUntil {
            propsCheck = t + 1
            // Move them only if their spot has stayed covered (by a window or the Dock) for a while and
            // there is open ground elsewhere. In a full-screen app they just wait, hidden, until you come back.
            let open = openGroundShare() > 0.15
            treeCoveredSince = visible(treeX) ? -1 : (treeCoveredSince < 0 ? t : treeCoveredSince)
            if treeCoveredSince >= 0 && t - treeCoveredSince > 4 && open {
                treeX = openSpot(near: w * 0.85, range: w * 0.4)
                treeCoveredSince = -1
            }
            let gap = 40 + 32 * treeScale             // keep the fire clear of the tree
            fireCoveredSince = visible(fireX) ? -1 : (fireCoveredSince < 0 ? t : fireCoveredSince)
            if (fireCoveredSince >= 0 && t - fireCoveredSince > 4 && open) || abs(fireX - treeX) < gap {
                let nx = openSpot(near: w * 0.6, range: w * 0.35)
                if visible(nx) && abs(nx - treeX) >= gap {
                    fireX = nx
                    fireCoveredSince = -1
                    if inCampfire { endCampfire(t) }
                }
            }
        }
        if treeOn {
            let k = max(1, scene.size.height / 3 / 104)
            if abs(k - treeScale) > 0.01 { buildTree() }   // the screen changed size
            treeX = min(max(treeX, 34 * treeScale), w - 34 * treeScale)   // keep the whole tree on screen
            treeNode.position = CGPoint(x: treeX, y: groundY(treeX))
            treePresence.update(treeNode, want: onOpenGround(treeX), t: t, dt: dt, frozen: t < holdUntil)
            if !treeNode.isHidden {
                // each bulb twinkles at its own pace: dim → bright, with a little pulse
                for i in 0..<treeLights.count {
                    let k = 0.5 + 0.5 * sin(t * lightSpeed[i] * (Cfg.reduceMotion ? 0.4 : 1) + lightPhase[i])
                    let b = k * k
                    treeLights[i].alpha = 0.12 + 0.88 * b
                    treeLights[i].setScale(0.75 + 0.45 * b)
                    lightCores[i].alpha = 0.3 + 0.7 * b
                }
                // the star breathes and now and then a sparkle flashes on it
                let tw = 0.5 + 0.5 * sin(t * 2.4)
                treeStar.setScale(1 + 0.08 * tw)
                starGlow.alpha = 0.25 + 0.6 * tw
                starGlow.setScale(0.8 + 0.35 * tw)
                let flash = pow(max(0, sin(t * 1.9)), 10)
                sparkle.alpha = flash
                sparkle.setScale(0.5 + 0.7 * flash)
                sparkle.zRotation = t * 0.8
            }
        }
        guard fireOn else { return }
        fireNode.position = CGPoint(x: fireX, y: groundY(fireX))
        firePresence.update(fireNode, want: onOpenGround(fireX), t: t, dt: dt, frozen: t < holdUntil)
        guard !fireNode.isHidden, flames.count == 3 else { return }
        // flicker: each flame layer sways and stretches at its own pace; it burns low while you nap
        fireDim += ((napping ? 0.55 : 1) - fireDim) * 0.03
        let calm: CGFloat = Cfg.reduceMotion ? 0.4 : 1
        let s1 = sin(t * 7.3 * calm) * calm, s2 = sin(t * 11.1 * calm + 1) * calm, s3 = sin(t * 9.4 * calm + 2) * calm
        flames[0].zRotation = 0.07 * s1
        flames[0].yScale = fireDim * (1 + 0.08 * s2)
        flames[0].xScale = fireDim * (1 - 0.03 * s2)
        flames[1].zRotation = -0.08 * s2
        flames[1].yScale = fireDim * (1 + 0.10 * s3)
        flames[1].xScale = fireDim
        flames[2].zRotation = 0.09 * s3
        flames[2].yScale = fireDim * (1 + 0.12 * s1)
        flames[2].xScale = fireDim
        fireGlow.alpha = (0.75 + 0.15 * sin(t * 5.2)) * fireDim
        for (i, e) in embers.enumerated() {
            let k = (t * 0.45 + CGFloat(i) / 3).truncatingRemainder(dividingBy: 1)
            e.position = CGPoint(x: 6 * sin(t * 1.3 + CGFloat(i) * 2) + CGFloat(i - 1) * 4, y: 26 + k * 40)
            e.alpha = (1 - k) * fireDim
        }
        // the fire melts the snow around it, and any snowball that rolls into it
        if t > meltAt {
            meltAt = t + 0.4
            if let g = scene.ground, let c0 = g.col(at: fireX - 26), let c1 = g.col(at: fireX + 26), c0 <= c1 {
                for c in c0...c1 where g.h[c] > 1.5 {
                    g.h[c] = max(1.5, g.h[c] - 3)
                    g.dirty = true
                }
            }
        }
        for b in scene.balls where !b.falling && !b.dragging && b.pile === scene.ground && abs(b.x - fireX) < b.r + 16 {
            meltBall(b)
            break
        }
    }

    /// How much of the ground (0...1) isn't covered by windows
    func openGroundShare() -> CGFloat {
        guard let g = scene.ground, g.count > 0 else { return 0 }
        var open = 0
        for c in stride(from: 0, to: g.count, by: 4) where !g.occ[c] { open += 1 }
        return CGFloat(open) / CGFloat((g.count + 3) / 4)
    }

    func meltBall(_ b: Snowball) {
        for _ in 0..<6 {
            scene.spawnClump(at: CGPoint(x: b.x + rnd(-b.r, b.r), y: b.y), vel: CGVector(dx: rnd(-50, 50), dy: rnd(60, 140)), sourceID: -3)
        }
        b.node.removeFromParent()
        scene.balls.removeAll { $0 === b }
    }

    func fireRect() -> CGRect { CGRect(x: fireX - 24, y: fireNode.position.y, width: 48, height: 46) }

    func fireClickable(_ m: CGPoint) -> Bool { fireOn && !fireNode.isHidden && fireRect().contains(m) }

    // Campfire time: you both walk over, sit on either side, the beagle curls up, then you wander off again

    func checkCampfire(_ t: CGFloat) {
        if inCampfire {
            if t > campfireEnds || !fireOn { endCampfire(t) }
            return
        }
        guard fireOn, t > nextCampfire, !napping, dogFree, toy == nil, onOpenGround(fireX),
              meMode == .idle || meMode == .sit || meMode == .walk else { return }
        startCampfire(t)
    }

    func startCampfire(_ t: CGFloat) {
        dropToy()
        chaseBall = nil
        inCampfire = true
        campfireEnds = t + rnd(120, 180)
        fireSide = meX < fireX ? -1 : 1
        meMode = .toFire
        meTarget = clampX(fireX + fireSide * 34)
        dogMode = .toFire
        dogTarget = clampX(fireX - fireSide * 42)
    }

    func endCampfire(_ t: CGFloat) {
        inCampfire = false
        nextCampfire = t + rnd(600, 1200)
        if meMode == .toFire || meMode == .byFire { meMode = .idle; meUntil = t + rnd(2, 4) }
        if dogMode == .toFire || dogMode == .byFire { newWanderTarget() }
    }
}

// MARK: - Gust outfits and snowman styles (same sticker style)

/// The snowman looks a new snowman can get (one is picked at random)
enum SnowmanStyle: CaseIterable { case classic, cozy, earmuffs, santa, cap, wizard }

extension PalsArt {
    // --- you: a striped scarf for windy days, its tail flaps in the wind
    static let scarfRed = palsRGB(200, 44, 52), scarfStripe = palsRGB(250, 246, 240)

    static func meScarf(_ p: PalsPainter) {
        let sh = [rr(-8.5, -48.6, 12, -42.6, 3)]
        p.blob(sh, scarfRed)
        for x in [-5.0, 0.0, 5.0, 10.0] as [CGFloat] { p.clipped(sh, [rr(x, -50, x + 1.6, -42, 0.5)], scarfStripe) }
    }

    static func meScarfTail(_ p: PalsPainter) {
        let t = path { $0.m(-6, -46.5); $0.c(-12, -46.5, -16, -44.5, -24, -45.5); $0.l(-24.5, -41)
                       $0.c(-16, -40, -12, -42, -6, -42.5); $0.z() }
        p.blob([t], scarfRed)
        for k in [0.35, 0.7] as [CGFloat] {
            let x = -6 - 18 * k
            p.clipped([t], [rr(x - 0.8, -52, x + 0.8, -38, 0.4)], scarfStripe)
        }
    }

    // --- the beagle: a red knit sweater with green stripes and little snowflakes
    static func sweater(_ p: PalsPainter, clip: [CGPath], x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat,
                        stripes: [CGFloat], flakeY: CGFloat, flakeXs: [CGFloat], edges: [CGFloat], band: CGPath) {
        let knit = palsRGB(186, 36, 46), green = palsRGB(36, 120, 64), white = palsRGB(250, 246, 240)
        p.clipped(clip, [rr(x0, y0, x1, y1, 2)], knit)
        for y in stripes { p.clipped(clip, [rr(x0, y, x1, y + 2.2, 0.8)], green) }
        for x in flakeXs {
            for k in 0..<6 {
                let a = CGFloat(k) * .pi / 3
                p.stroke(path { $0.m(x, flakeY); $0.l(x + 2.6 * cos(a), flakeY + 2.6 * sin(a)) }, white, 0.7)
            }
            p.dot(x, flakeY, 0.7, white)
        }
        for x in edges { p.clippedStroke(clip, path { $0.m(x, y0 - 3); $0.l(x, y1 + 3) }, p.ink.line, 1.2) }
        p.blob([band], green)
    }

    static func dogBodySweater(_ p: PalsPainter) {
        dogBody(p)
        sweater(p, clip: [ell(0, -24, 24, 11.5), ell(15, -23, 11.5, 11), ell(-16, -23, 10.5, 10.5)],
                x0: -9, x1: 21, y0: -37, y1: -12, stripes: [-31, -17], flakeY: -24, flakeXs: [-2, 6, 14],
                edges: [-9], band: rr(18.5, -37.5, 22.5, -13, 2))
    }

    static func dogSitSweater(_ p: PalsPainter) {
        dogSit(p)
        sweater(p, clip: [ell(-6, -12.5, 13, 12.5), ell(9, -24, 11.5, 15), ell(-1, -18, 12, 12)],
                x0: -8, x1: 17, y0: -40, y1: -19, stripes: [-35, -24], flakeY: -29.5, flakeXs: [-2, 6, 13],
                edges: [-8], band: rr(15, -40, 19, -19, 2))
    }

    static func dogSleepSweater(_ p: PalsPainter, blaze: Bool) {
        dogSleep(p, blaze: blaze)
        sweater(p, clip: [ell(-2, -11, 25, 10.5)],
                x0: -14, x1: 5, y0: -22, y1: -4, stripes: [-18, -9], flakeY: -13.5, flakeXs: [-8, 0],
                edges: [-14], band: rr(3.5, -22, 7, -4, 1.5))
    }

    // --- snowmen: drawn around the ball's center for a head of radius 12.5 / body of radius 16,
    //     then redrawn at the real size
    static let smR: CGFloat = 12.5, smB: CGFloat = 16
    static let coal = palsRGB(30, 28, 30), carrot = palsRGB(246, 133, 33), twig = palsRGB(107, 71, 41)
    static let smRed = palsRGB(209, 41, 46), smBlack = palsRGB(42, 40, 46), smBand = palsRGB(196, 40, 52)
    static let smGold = palsRGB(242, 192, 62), smGreen = palsRGB(48, 140, 84), smBlue = palsRGB(70, 124, 204)
    static let smCream = palsRGB(250, 244, 228), smPink = palsRGB(240, 130, 160), smPurple = palsRGB(112, 76, 176)
    static let smBrown = palsRGB(150, 98, 52), smWhite = palsRGB(252, 252, 255), smGrey = palsRGB(130, 132, 140)
    static let smYellow = palsRGB(250, 214, 70)

    /// mood: smile, grin, o, none · eyes: coal, wink, happy
    static func smFace(_ p: PalsPainter, mood: String, eyes: String) {
        let R = smR
        switch eyes {
        case "wink":
            p.dot(-R * 0.3, -R * 0.22, R * 0.09, coal)
            p.stroke(path { $0.m(R * 0.2, -R * 0.2); $0.c(R * 0.27, -R * 0.3, R * 0.36, -R * 0.3, R * 0.42, -R * 0.2) }, coal, 1.1)
        case "happy":
            for sx in [-1.0, 1.0] as [CGFloat] {
                let x = sx * R * 0.3
                p.stroke(path { $0.m(x - R * 0.11, -R * 0.17); $0.c(x - R * 0.05, -R * 0.3, x + R * 0.05, -R * 0.3, x + R * 0.11, -R * 0.17) }, coal, 1.1)
            }
        default:
            for sx in [-1.0, 1.0] as [CGFloat] { p.dot(sx * R * 0.3, -R * 0.22, R * 0.09, coal) }
        }
        p.blob([path { $0.m(0, -R * 0.06); $0.l(R * 0.72, R * 0.03); $0.l(0, R * 0.13); $0.z() }], carrot)
        switch mood {
        case "smile":
            for k in 0..<5 {
                let a = CGFloat.pi * (0.2 + 0.15 * CGFloat(k))
                p.dot(cos(a) * R * 0.42, sin(a) * R * 0.42 + R * 0.05, R * 0.05, coal)
            }
        case "grin":
            p.blob([path { $0.m(-R * 0.32, R * 0.3); $0.c(-R * 0.2, R * 0.62, R * 0.2, R * 0.62, R * 0.32, R * 0.3); $0.z() }], coal, outline: false)
            p.blob([ell(0, R * 0.46, R * 0.14, R * 0.07)], smPink, outline: false)
        case "o":
            p.blob([ell(0, R * 0.42, R * 0.1, R * 0.13)], coal, outline: false)
        default: break
        }
    }

    static func smScarf(_ p: PalsPainter, _ col: CGColor, stripe: CGColor? = nil) {
        let R = smR
        let sh = [rr(-R * 0.85, R * 0.7, R * 0.85, R * 1.0, R * 0.12)]
        p.blob(sh, col)
        p.blob([rr(R * 0.3, R * 0.85, R * 0.58, R * 1.6, R * 0.08)], col)
        if let s = stripe {
            for k in -2...2 {
                let x = CGFloat(k) * R * 0.32
                p.clipped(sh, [rr(x - 0.6, R * 0.6, x + 0.6, R * 1.1, 0.3)], s)
            }
        }
    }

    static func snowmanHead(_ p: PalsPainter, _ style: SnowmanStyle) {
        let R = smR
        switch style {
        case .classic:
            smScarf(p, smRed)
            smFace(p, mood: "smile", eyes: "coal")
            p.blob([rr(-R * 0.95, -R * 0.95, R * 0.95, -R * 0.75, R * 0.08)], smBlack)
            let crown = rr(-R * 0.6, -R * 1.9, R * 0.6, -R * 0.85, R * 0.1)
            p.blob([crown], smBlack)
            p.clipped([crown], [rr(-R, -R * 1.12, R, -R * 0.95, 0)], smBand)
        case .cozy:
            smScarf(p, smGreen, stripe: smCream)
            smFace(p, mood: "smile", eyes: "happy")
            p.blob([ell(0, -R * 1.5, R * 0.35, R * 0.33)], smCream)
            p.blob([path { $0.m(-R * 0.95, -R * 0.5); $0.c(-R * 0.95, -R * 1.65, R * 0.95, -R * 1.65, R * 0.95, -R * 0.5); $0.z() }], smRed)
            p.blob([rr(-R, -R * 0.75, R, -R * 0.4, R * 0.15)], smCream)
        case .earmuffs:
            smScarf(p, smBlue, stripe: smWhite)
            smFace(p, mood: "o", eyes: "coal")
            p.stroke(path { $0.m(-R * 0.95, -R * 0.1); $0.c(-R * 0.9, -R * 1.4, R * 0.9, -R * 1.4, R * 0.95, -R * 0.1) }, smGrey, 1.4)
            for sx in [-1.0, 1.0] as [CGFloat] { p.blob([ell(sx * R * 0.95, -R * 0.1, R * 0.28, R * 0.34)], smPink) }
        case .santa:
            p.blob([path { $0.m(-R * 0.75, R * 0.15); $0.c(-R * 0.6, R * 1.2, R * 0.6, R * 1.2, R * 0.75, R * 0.15); $0.z() }], smCream)
            smFace(p, mood: "none", eyes: "happy")
            p.blob([path { $0.m(-R * 0.9, -R * 0.55); $0.c(-R * 0.6, -R * 1.7, R * 0.5, -R * 1.9, R * 1.3, -R * 1.3)
                           $0.l(R * 0.9, -R * 0.55); $0.z() }], smRed)
            p.blob([ell(R * 1.35, -R * 1.25, R * 0.22, R * 0.22)], smCream)
            p.blob([rr(-R, -R * 0.75, R, -R * 0.4, R * 0.15)], smCream)
        case .cap:
            smScarf(p, smYellow)
            smFace(p, mood: "grin", eyes: "wink")
            p.blob([ell(-R * 1.05, -R * 0.62, R * 0.55, R * 0.16)], smBlue)                 // brim, worn backwards
            p.blob([path { $0.m(-R * 0.9, -R * 0.55); $0.c(-R * 0.9, -R * 1.45, R * 0.9, -R * 1.45, R * 0.9, -R * 0.55); $0.z() }], smBlue)
            p.dot(0, -R * 1.2, R * 0.08, smWhite)
        case .wizard:
            smFace(p, mood: "o", eyes: "happy")
            p.blob([path { $0.m(-R * 1.1, -R * 0.6); $0.l(R * 0.3, -R * 2.6); $0.l(R * 1.1, -R * 0.6); $0.z() }], smPurple)
            p.blob([ell(0, -R * 0.62, R * 1.25, R * 0.2)], smPurple)
            p.blob([starPath(-R * 0.05, -R * 1.2, R * 0.25, R * 0.11), starPath(R * 0.35, -R * 1.85, R * 0.18, R * 0.08)], smGold)
        }
    }

    static func snowmanBody(_ p: PalsPainter, _ style: SnowmanStyle) {
        let B = smB
        let hands: (String, String) = style == .cozy ? ("mitten", "mitten") : (style == .wizard ? ("stick", "broom") : ("stick", "stick"))
        for (sx, kind) in [(-1.0, hands.0), (1.0, hands.1)] as [(CGFloat, String)] {
            let x1 = sx * B * 1.75, y1 = -B * 0.65
            p.stroke(path { $0.m(sx * B * 0.85, -B * 0.15); $0.l(x1, y1) }, twig, max(1.2, B * 0.09))
            p.stroke(path { $0.m(sx * B * 1.4, -B * 0.45); $0.l(sx * B * 1.55, -B * 0.85) }, twig, max(1.2, B * 0.09))
            if kind == "mitten" {
                p.blob([ell(x1, y1, B * 0.2, B * 0.17)], smRed)
                p.blob([ell(x1 - sx * B * 0.12, y1 - B * 0.12, B * 0.08, B * 0.1)], smRed)
            } else if kind == "broom" {
                p.stroke(path { $0.m(x1, y1 + B * 0.6); $0.l(x1, y1 - B * 1.1) }, smBrown, 1.6)
                p.blob([path { $0.m(x1 - B * 0.3, y1 - B * 1.1); $0.l(x1 + B * 0.3, y1 - B * 1.1)
                               $0.l(x1 + B * 0.45, y1 - B * 1.7); $0.l(x1 - B * 0.45, y1 - B * 1.7); $0.z() }], smYellow)
            }
        }
        let goldButtons = style == .santa || style == .wizard
        for k in 0..<3 {
            let y = -B * (0.35 - 0.33 * CGFloat(k))
            if goldButtons { p.blob([ell(0, y, B * 0.08, B * 0.08)], smGold) } else { p.dot(0, y, B * 0.07, coal) }
        }
    }

    /// The decoration for one ball of a snowman, drawn at that ball's real size
    static func snowmanDecor(_ style: SnowmanStyle, head: Bool, radius r: CGFloat) -> SKSpriteNode {
        let ink = PalsInk(PalsRecipe())
        let part = render(pivot: .zero, ink: ink, scale: r / (head ? smR : smB)) { p in
            if head { snowmanHead(p, style) } else { snowmanBody(p, style) }
        }
        let n = SKSpriteNode(texture: part.tex)
        n.size = part.size
        n.anchorPoint = part.anchor
        return n
    }
}

// MARK: - Scene

final class SnowScene: SKScene {
    var flakes: [Flake] = []
    var pool: [Flake] = []
    var piles: [Int: Pile] = [:]                 // window number -> snow on top of it
    var lastRect: [Int: CGRect] = [:]
    var order: [(id: Int, rect: CGRect)] = []    // windows from front to back
    var ground: Pile?
    var tex: SKTexture?
    var lastT: TimeInterval = 0
    var pollAcc: CGFloat = 0
    var t: CGFloat = 0
    let myPID = getpid()
    let world = SKNode()
    let dockTracker = DockTracker()
    var dockPile: Pile?
    var dockRect: CGRect?
    var dockZone: CGRect?                        // where the Dock sits, remembered even while it is auto-hidden
    var savedDockSnow: [CGFloat]?                // the Dock's snow while it is hidden, restored when it pops up
    var dockAcc: CGFloat = 1
    var lastDockStatus = ""
    var lights: [Int: LightString] = [:]
    var lightsOn = UserDefaults.standard.bool(forKey: "fairyLights")   // off by default, remembered between launches
    var balls: [Snowball] = []
    weak var activeBall: Snowball?
    var lastMouse = NSEvent.mouseLocation
    var ballTex: SKTexture?
    var dragBall: Snowball?
    var dragTarget = CGPoint.zero
    var dragOffset = CGPoint.zero
    var dragVel = CGVector.zero
    var speckTex: SKTexture?
    static let dockID = -2
    var pals: Companions?                        // you and your beagle
    // wind moods
    var windRegime: WindRegime = .moderateWind
    var windTimer: CGFloat = 10
    var currentWindScale: CGFloat = 1.0
    var targetWindScale: CGFloat = 1.0
    var currentWindBias: CGFloat = 0.0
    var targetWindBias: CGFloat = 0.0
    var currentWindLift: CGFloat = 0.0
    var targetWindLift: CGFloat = 0.0

    // The menu reaches the companions through these, like it does for the fairy lights
    /// Called when you switch Spaces or swipe between full-screen apps
    func spaceChanged() { pals?.holdUntil = t + 0.5 }

    var palsEnabled: Bool { pals?.enabled ?? true }
    func setPals(_ on: Bool) { pals?.setEnabled(on) }
    var campfireOn: Bool { pals?.fireOn ?? false }
    func setCampfire(_ on: Bool) { pals?.setFire(on) }
    var xmasTreeOn: Bool { pals?.treeOn ?? false }
    func setXmasTree(_ on: Bool) { pals?.setTree(on) }

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        tex = makeFlakeTexture()
        ballTex = makeSnowballTexture()
        speckTex = makeSpeckTexture()
        addChild(world)
        resetGround()
        for _ in 0..<Cfg.targetFlakes { spawnFlake(y: rnd(0, size.height)) }
        pals = Companions(scene: self)
    }

    override func didChangeSize(_ oldSize: CGSize) {
        guard tex != nil else { return }
        resetGround()
    }

    func resetGround() {
        for b in balls where b.pile === ground { b.drop(vel: .zero) }
        ground?.remove()
        ground = Pile(minX: 0, topY: 0, width: size.width, maxH: Cfg.groundPileMax, parent: world)
        if let g = ground {
            for c in 0..<g.count { g.h[c] = g.caps[c] * Cfg.groundStart * (0.85 + 0.15 * sin(CGFloat(c) * 0.07)) }
            g.dirty = true
        }
    }

    func clearAll() {
        for p in piles.values { p.clear(); p.redraw() }
        dockPile?.clear()
        dockPile?.redraw()
        ground?.clear()
        ground?.redraw()
        for b in balls { b.node.removeFromParent() }
        balls.removeAll()
    }

    // MARK: Flake pool

    func obtain() -> Flake {
        let f = pool.popLast() ?? Flake(texture: tex!)
        world.addChild(f.node)
        flakes.append(f)
        return f
    }

    func recycle(at i: Int) {
        let f = flakes[i]
        f.node.removeFromParent()
        flakes.swapAt(i, flakes.count - 1)
        flakes.removeLast()
        pool.append(f)
    }

    func spawnFlake(y: CGFloat? = nil) {
        let f = obtain()
        let r = CGFloat.random(in: 0...1)
        let li = r < 0.40 ? 0 : (r < 0.68 ? 1 : 2)   // 40% far, 28% middle, 32% near
        let L = layers[li]
        f.inFront = Cfg.flakesInFront && li == 0 && CGFloat.random(in: 0...1) < Cfg.inFrontFraction
        f.isClump = false
        f.ignoreID = -1
        f.size = CGFloat.random(in: L.size)
        f.vel = CGVector(dx: 0, dy: -CGFloat.random(in: L.speed) * Cfg.fallSpeed)
        f.swayAmp = CGFloat.random(in: L.sway)
        f.swayFreq = rnd(0.6, 1.6)
        f.phase = rnd(0, 6.28)
        f.windFactor = L.wind
        f.node.alpha = CGFloat.random(in: L.alpha)
        f.node.size = CGSize(width: f.size * 2.2, height: f.size * 2.2)
        f.node.zPosition = L.z
        f.node.position = CGPoint(x: rnd(-40, size.width + 40), y: y ?? size.height + rnd(2, 30))
    }

    func spawnClump(at p: CGPoint, vel: CGVector, sourceID: Int) {
        let f = obtain()
        f.isClump = true
        f.inFront = false
        f.size = rnd(2.5, 5)
        f.vel = vel
        f.ignoreID = sourceID
        f.ignoreUntil = t + 0.35
        f.node.alpha = 0.95
        f.node.size = CGSize(width: f.size * 2.2, height: f.size * 2.2)
        f.node.zPosition = 6
        f.node.position = p
    }

    // Turn a pile into falling clumps; vel is the window's velocity, so faster drags fling snow farther
    func release(_ p: Pile, vel: CGVector, id: Int) {
        let fling = CGVector(dx: max(-900, min(900, vel.dx * 0.5)),
                             dy: max(-300, min(500, vel.dy * 0.4)))
        // Snowballs sitting on this surface get flung off too
        for b in balls where b.pile === p {
            b.drop(vel: CGVector(dx: fling.dx + rnd(-30, 30), dy: fling.dy + rnd(20, 80)))
        }
        let total = p.total
        guard total > 0.5 else { p.clear(); return }
        let budget = CGFloat(max(0, Cfg.maxClumps - flakes.count + Cfg.targetFlakes))
        let k = min(1, budget / max(1, total / 3.5))
        for c in 0..<p.count where p.h[c] > 0.6 {
            var amount = p.h[c] / 3.5 * k
            while amount > 0 {
                if amount < 1 && CGFloat.random(in: 0...1) > amount { break }
                spawnClump(at: CGPoint(x: p.colX(c) + rnd(-1.5, 1.5), y: p.topY + rnd(0, p.h[c])),
                           vel: CGVector(dx: fling.dx + rnd(-40, 40), dy: fling.dy + rnd(10, 80)),
                           sourceID: id)
                amount -= 1
            }
        }
        p.clear()
    }

    // MARK: Per-frame update

    override func update(_ currentTime: TimeInterval) {
        if lastT == 0 { lastT = currentTime }
        let dt = CGFloat(min(currentTime - lastT, 1.0 / 12.0))   // allows the low frame rates of Battery Saver / napping
        lastT = currentTime
        t += dt
        pollAcc += dt
        if Double(pollAcc) >= Cfg.pollInterval {
            pollWindows(dt: pollAcc)
            pollAcc = 0
        }
        stepFlakes(dt)
        updateMouseCapture()
        if let b = dragBall { stepDrag(b, dt) } else { updateRolling() }
        stepBalls(dt)
        pals?.update(dt)
        if lightsOn {
            if lights.values.contains(where: { $0.animating(t) }) { updateLights() }   // smooth swing, every frame
            for s in lights.values {
                for (i, b) in s.bulbs.enumerated() { b.twinkle(t, reveal: s.reveal(i, t)) }
            }
        }
    }

    // MARK: Fairy lights

    func setLights(_ on: Bool) {
        lightsOn = on
        UserDefaults.standard.set(on, forKey: "fairyLights")
        updateLights()
    }

    /// Hang a string of lights on every window, following it when it moves
    func updateLights() {
        guard lightsOn, let tex = tex else {
            for s in lights.values { s.remove() }
            lights.removeAll()
            return
        }
        var alive = Set<Int>()
        for (i, item) in order.enumerated() {
            alive.insert(item.id)
            let s: LightString
            if let existing = lights[item.id] { s = existing } else {
                s = LightString(parent: world)
                s.hungAt = t
                lights[item.id] = s
            }
            if s.rect != item.rect || s.animating(t) {
                s.updateSwing(t)
                s.place(in: item.rect, texture: tex)
            }
            s.applyVisibility { pt in
                if pt.y > self.size.height { return true }
                for j in 0..<i where self.order[j].rect.contains(pt) { return true }
                return false
            }
        }
        for (id, s) in lights where !alive.contains(id) {
            s.remove()
            lights[id] = nil
        }
    }

    // MARK: Dragging & snowmen

    /// The overlay normally lets every click through. Only while the mouse is over a snowball (or dragging one)
    /// does it catch clicks, so you can grab the ball without clicking the window underneath.
    func updateMouseCapture() {
        guard let w = view?.window else { return }
        let m = NSEvent.mouseLocation
        let capture = dragBall != nil || ballAt(m) != nil || (pals?.hit(m) ?? false)
        if w.ignoresMouseEvents == capture { w.ignoresMouseEvents = !capture }
    }

    /// The visible, resting snowball under a point (top of a stack first)
    func ballAt(_ m: CGPoint) -> Snowball? {
        var best: Snowball?
        for b in balls where !b.falling && !b.node.isHidden {
            let dx = m.x - b.x, dy = m.y - b.y
            if dx * dx + dy * dy <= (b.r + 2) * (b.r + 2), best == nil || b.y > best!.y { best = b }
        }
        return best
    }

    func above(_ b: Snowball) -> Snowball? { balls.first { $0.below === b } }

    func base(of b: Snowball) -> Snowball {
        var x = b
        while let y = x.below { x = y }
        return x
    }

    /// Balls in a stack from the bottom up
    func stack(from base: Snowball) -> [Snowball] {
        var out = [base]
        while let a = above(out.last!), out.count < 10 { out.append(a) }
        return out
    }

    override func mouseDown(with event: NSEvent) {
        let m = event.location(in: self)
        if pals?.mouseDown(at: m) == true { return }     // petting / calling comes first
        guard let b = ballAt(m) else { return }
        // Anything stacked on top of the grabbed ball tumbles off
        var a = above(b)
        while let x = a {
            a = above(x)
            x.drop(vel: CGVector(dx: rnd(-50, 50), dy: rnd(40, 100)))
        }
        removeDecor(stackOf: b)
        b.pile = nil
        b.below = nil
        b.dragging = true
        b.node.zPosition = 8                 // in front while dragging
        dragBall = b
        activeBall = nil
        dragOffset = CGPoint(x: b.x - m.x, y: b.y - m.y)
        dragTarget = m
        dragVel = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        dragTarget = event.location(in: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard let b = dragBall else { return }
        dragBall = nil
        b.dragging = false
        if let target = stackTarget(for: b) {
            b.below = target
            b.vel = .zero
            let st = stack(from: base(of: b))
            for (i, x) in st.enumerated() { x.node.zPosition = 6.5 + CGFloat(i) * 0.3 }
            if st.count == 3 { makeSnowman(st) }
        } else {
            b.node.zPosition = 6.5
            // Let go: it falls (with a bit of the throw) and lands on whatever is below
            b.drop(vel: CGVector(dx: max(-600, min(600, dragVel.dx * 0.5)),
                                 dy: max(-400, min(400, dragVel.dy * 0.5))))
            pals?.ballThrown(b)                 // the beagle chases it
        }
    }

    func stepDrag(_ b: Snowball, _ dt: CGFloat) {
        let target = CGPoint(x: dragTarget.x + dragOffset.x, y: dragTarget.y + dragOffset.y)
        if dt > 0 {
            let v = CGVector(dx: (target.x - b.x) / dt, dy: (target.y - b.y) / dt)
            dragVel = CGVector(dx: dragVel.dx * 0.7 + v.dx * 0.3, dy: dragVel.dy * 0.7 + v.dy * 0.3)
        }
        b.specks.zRotation -= (target.x - b.x) / b.r
        b.x = target.x
        b.y = target.y
        lastMouse = NSEvent.mouseLocation
    }

    /// A ball dropped just above another ball (that isn't already a full snowman) gets stacked on it
    func stackTarget(for b: Snowball) -> Snowball? {
        var best: Snowball?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for c in balls where c !== b && !c.falling && !c.dragging && !c.node.isHidden {
            guard above(c) == nil, stack(from: base(of: c)).count < 3 else { continue }
            let dx = abs(b.x - c.x), dy = b.y - c.y
            guard dx < c.r * 0.9 + b.r * 0.3, dy > 0, dy < c.r + b.r + 30 else { continue }
            if dx < bestDist { best = c; bestDist = dx }
        }
        return best
    }

    func removeDecor(stackOf b: Snowball) {
        for x in stack(from: base(of: b)) {
            x.decor?.removeFromParent()
            x.decor = nil
        }
    }

    /// Three stacked balls become a snowman, dressed in one of the styles at random
    func makeSnowman(_ st: [Snowball]) {
        let body = st[1], head = st[2]
        removeDecor(stackOf: head)
        let style = SnowmanStyle.allCases.randomElement() ?? .classic
        let h = PalsArt.snowmanDecor(style, head: true, radius: head.r)
        h.zPosition = 0.5
        head.node.addChild(h)
        head.decor = h
        let bd = PalsArt.snowmanDecor(style, head: false, radius: body.r)
        bd.zPosition = 0.5
        body.node.addChild(bd)
        body.decor = bd
        pals?.snowmanBuilt(st[0])               // ...the beagle has plans for it
    }

    // MARK: Snowballs

    /// Is the mouse inside the snow band of this pile (a bit below the edge up to a bit above the snow)?
    func mouseOver(_ p: Pile, _ m: CGPoint) -> Bool {
        guard let c = p.col(at: m.x), !p.occ[c] else { return false }
        return m.y >= p.topY - 6 && m.y <= p.topY + p.h[c] + 14
    }

    /// Which snow surface is the mouse hovering over? Dock first, then windows front to back, then the ground.
    func surfaceUnderMouse(_ m: CGPoint) -> Pile? {
        // Hovering over a snowball counts as hovering over the snow it sits on. Without this, a big ball
        // stops rolling as soon as the cursor rises above the thin snow band, which makes pushing jerky.
        for b in balls where !b.falling && !b.dragging && !b.node.isHidden && b.below == nil {
            guard let p = b.pile, abs(m.x - b.x) < b.r + 8 else { continue }
            if m.y >= p.topY - 6 && m.y <= p.topY + 2 * b.r + 8 { return p }
        }
        if let d = dockPile, mouseOver(d, m) { return d }
        if let dr = dockRect, dr.contains(m) { return nil }
        for item in order {
            if let p = piles[item.id], mouseOver(p, m) { return p }
            if item.rect.contains(m) { return nil }      // over a window's content
        }
        if let g = ground, mouseOver(g, m) { return g }
        return nil
    }

    func updateRolling() {
        let m = NSEvent.mouseLocation     // same coordinates as the scene (origin bottom-left of main screen)
        let dx = m.x - lastMouse.x
        lastMouse = m
        guard let p = surfaceUnderMouse(m) else { activeBall = nil; return }
        guard abs(dx) > 0.2 else { return }

        // Keep rolling the current ball, pick up a resting one under the mouse, or start a new one
        if let b = activeBall, b.pile === p, above(b) == nil, abs(b.x - (m.x - dx)) < b.r + 25 {   // ball was at the previous mouse x
            // keep it
        } else if let b = balls.first(where: { !$0.falling && $0.pile === p && abs($0.x - m.x) < $0.r + 10 }) {
            guard above(b) == nil else { activeBall = nil; return }   // don't roll the bottom of a snowman
            activeBall = b
        } else if let c = p.col(at: m.x), p.h[c] > 1.5 {
            let b = Snowball(body: ballTex!, specks: speckTex!)
            b.x = m.x
            b.pile = p
            b.y = p.topY + b.r - 1.5
            b.layout()
            world.addChild(b.node)
            balls.append(b)
            activeBall = b
            trimBalls()
        } else {
            activeBall = nil
            return
        }
        guard let b = activeBall else { return }

        // Move the ball to the mouse, staying on the surface
        let lo = p.minX + b.r, hi = p.minX + p.width - b.r
        let newX = lo < hi ? min(max(m.x, lo), hi) : b.x
        let moved = newX - b.x
        guard abs(moved) > 0.01 else { return }
        let oldX = b.x
        roll(b, on: p, to: newX)
        push(from: b, oldX: oldX, dir: moved > 0 ? 1 : -1, on: p)
    }

    /// Roll a ball to newX: it picks up snow from the columns it passes over and grows
    func roll(_ b: Snowball, on p: Pile, to newX: CGFloat) {
        let moved = newX - b.x
        guard abs(moved) > 0.01 else { return }
        if b.r < Cfg.ballMaxRadius {
            var collected: CGFloat = 0
            let from = min(b.x, newX) - b.r * 0.8
            let to = max(b.x, newX) + b.r * 0.8
            let frac = min(0.6, 0.6 * abs(moved) / (1.6 * b.r))
            if let c0 = p.col(at: max(from, p.minX)), let c1 = p.col(at: min(to, p.minX + p.width - 0.1)), c0 <= c1 {
                for c in c0...c1 where !p.occ[c] {
                    let take = p.h[c] * frac
                    p.h[c] -= take
                    collected += take
                }
                p.dirty = true
            }
            // Ball area grows by the snow area it picked up
            let area = CGFloat.pi * b.r * b.r + collected * Cfg.colW * 0.8
            b.r = min(Cfg.ballMaxRadius, (area / .pi).squareRoot())
        }
        b.x = newX
        b.specks.zRotation -= moved / b.r     // roll
    }

    /// The moving ball pushes any ball it touches in front of it; that ball can push the next one, and so on.
    /// A ball pushed past the end of a surface falls off.
    func push(from b: Snowball, oldX: CGFloat, dir: CGFloat, on p: Pile) {
        // Look for balls ahead of where the pusher *was*: after a fast mouse move it may already have
        // jumped past a ball, and that ball must still be pushed instead of being passed through.
        let ahead = balls
            .filter { $0 !== b && !$0.falling && !$0.dragging && $0.pile === p && ($0.x - oldX) * dir > 0 }
            .sorted { abs($0.x - oldX) < abs($1.x - oldX) }
        var pusher = b
        for o in ahead {
            let need = pusher.x + dir * (pusher.r + o.r)     // where o must be to just touch the pusher
            guard (need - o.x) * dir > 0 else { break }       // not touching: the chain stops here
            let lo = p.minX + o.r, hi = p.minX + p.width - o.r
            if need < lo || need > hi {
                o.x = need
                o.drop(vel: CGVector(dx: dir * 140, dy: 40))  // pushed off the edge
            } else {
                roll(o, on: p, to: need)
            }
            pusher = o
        }
    }

    func trimBalls() {
        while balls.count > Cfg.maxBalls,
              let i = balls.firstIndex(where: { !$0.falling && !$0.dragging && $0.decor == nil && $0 !== activeBall }) {
            balls[i].node.removeFromParent()
            balls.remove(at: i)
        }
    }

    func stepBalls(_ dt: CGFloat) {
        var i = balls.count - 1
        while i >= 0 {
            let b = balls[i]
            var gone = false
            if b.falling {
                if b.decor != nil { b.decor?.removeFromParent(); b.decor = nil }
                b.node.zPosition = 6.5
                let prevBottom = b.y - b.r
                b.vel.dy -= Cfg.gravity * dt
                b.x += b.vel.dx * dt
                b.y += b.vel.dy * dt
                b.specks.zRotation -= b.vel.dx * dt / b.r
                if b.vel.dy < 0, let p = landingSurface(x: b.x, from: prevBottom, to: b.y - b.r) {
                    splat(b, on: p)                  // falling snowballs burst into a heap of snow
                    gone = true
                } else if b.y < -b.r * 2 || b.x < -100 || b.x > size.width + 100 {
                    gone = true
                }
            } else if b.dragging {
                // position is set by stepDrag
            } else if let under = b.below {
                if under.falling || under.dragging {
                    b.drop(vel: CGVector(dx: under.vel.dx + rnd(-40, 40), dy: max(under.vel.dy, 0) + rnd(30, 80)))
                } else {
                    b.x = under.x
                    b.y = under.y + under.r + b.r * 0.82   // sits slightly sunk into the ball below
                    b.node.isHidden = under.node.isHidden
                }
            } else if let p = b.pile {
                if let c = p.col(at: b.x) {
                    b.node.isHidden = p.occ[c]     // hidden behind a window in front
                } else {
                    b.node.isHidden = true
                }
                b.y = p.topY + b.r - 1.5           // sits slightly sunk into the snow
            } else {
                b.drop(vel: .zero)                 // lost its support (e.g. the ball below was removed)
            }
            if gone {
                b.node.removeFromParent()
                balls.remove(at: i)
            } else {
                b.layout()
            }
            i -= 1
        }
    }

    /// First surface a falling ball hits between two heights: the Dock, then window tops (front to back),
    /// then the bottom of the screen. Returns nil if it hits nothing this frame.
    func landingSurface(x: CGFloat, from top: CGFloat, to bottom: CGFloat) -> Pile? {
        func crosses(_ p: Pile) -> Bool {
            guard let c = p.col(at: x), !p.occ[c] else { return false }
            let s = p.surface(c)
            return top >= s && bottom < s
        }
        if let d = dockPile, crosses(d) { return d }
        for item in order {
            if let p = piles[item.id], crosses(p) { return p }
        }
        // The ground catches everything that reaches the bottom, even where a window covers it
        if let g = ground, let c = g.col(at: x), bottom < g.surface(c) { return g }
        return nil
    }

    /// A falling ball bursts where it lands: its snow becomes a mound on that surface, plus a puff of powder
    func splat(_ b: Snowball, on p: Pile) {
        if let c0 = p.col(at: b.x) {
            let snow = CGFloat.pi * b.r * b.r * 0.7 / Cfg.colW     // ball area -> total column height
            let half = max(2, Int(b.r * 1.4 / Cfg.colW))
            var sum: CGFloat = 0
            for o in -half...half { sum += 1 - abs(CGFloat(o)) / CGFloat(half + 1) }
            for o in -half...half {
                let i = c0 + o
                guard i >= 0, i < p.count, !p.occ[i] else { continue }
                let w = (1 - abs(CGFloat(o)) / CGFloat(half + 1)) / sum
                p.h[i] = min(p.caps[i], p.h[i] + snow * w)
            }
            p.dirty = true
        }
        for _ in 0..<min(14, Int(b.r * 0.6) + 2) {
            spawnClump(at: CGPoint(x: b.x + rnd(-b.r, b.r), y: b.y - b.r * 0.5 + rnd(0, b.r * 0.5)),
                       vel: CGVector(dx: b.vel.dx * 0.2 + rnd(-90, 90), dy: rnd(60, 180)),
                       sourceID: -3)
        }
    }

    /// A falling ball comes to rest on a surface and can be rolled again from there (currently unused)
    func land(_ b: Snowball, on p: Pile) {
        b.falling = false
        b.vel = .zero
        b.pile = p
        let lo = p.minX + b.r, hi = p.minX + p.width - b.r
        if lo < hi { b.x = min(max(b.x, lo), hi) }
        b.y = p.topY + b.r - 1.5
    }

    /// A falling snowball bursts into loose snow when it hits the ground
    func poof(_ b: Snowball) {
        let n = min(40, Int(b.r * 1.6))
        for _ in 0..<n {
            spawnClump(at: CGPoint(x: b.x + rnd(-b.r, b.r), y: b.y + rnd(-b.r * 0.5, b.r * 0.5)),
                       vel: CGVector(dx: b.vel.dx * 0.3 + rnd(-90, 90), dy: rnd(40, 170)),
                       sourceID: -3)
        }
    }

    // Read all window frames (macOS origin is top-left, SpriteKit is bottom-left, so flip y)
    func pollWindows(dt: CGFloat) {
        let H = size.height
        var newOrder: [(id: Int, rect: CGRect)] = []
        if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in info {
                guard let layerN = w[kCGWindowLayer as String] as? NSNumber, layerN.intValue == 0,
                      let pidN = w[kCGWindowOwnerPID as String] as? NSNumber, pidN.int32Value != myPID,
                      let numN = w[kCGWindowNumber as String] as? NSNumber,
                      let bd = w[kCGWindowBounds as String] as? NSDictionary,
                      let b = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
                let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
                if alpha < 0.05 || b.width < 80 || b.height < 40 { continue }
                newOrder.append((id: numN.intValue,
                                 rect: CGRect(x: b.minX, y: H - b.maxY, width: b.width, height: b.height)))
            }
        }

        // Closed / minimized windows: their snow just falls
        let alive = Set(newOrder.map { $0.id })
        for (id, pile) in piles where !alive.contains(id) {
            release(pile, vel: .zero, id: id)
            pile.remove()
            piles[id] = nil
            lastRect[id] = nil
        }

        for item in newOrder {
            let id = item.id, r = item.rect
            if let pile = piles[id], let old = lastRect[id] {
                if abs(old.width - r.width) > 0.5 {
                    // Width changed: drop the snow and start a new pile
                    release(pile, vel: .zero, id: id)
                    pile.remove()
                    piles[id] = Pile(minX: r.minX, topY: r.maxY, width: r.width, maxH: Cfg.windowPileMax, parent: world)
                } else if abs(old.minX - r.minX) > 0.3 || abs(old.maxY - r.maxY) > 0.3 {
                    // Window dragged: fling the snow off
                    let v = CGVector(dx: (r.minX - old.minX) / dt, dy: (r.maxY - old.maxY) / dt)
                    pile.minX = r.minX
                    pile.topY = r.maxY
                    release(pile, vel: v, id: id)
                }
            } else {
                piles[id] = Pile(minX: r.minX, topY: r.maxY, width: r.width, maxH: Cfg.windowPileMax, parent: world)
            }
            lastRect[id] = r
        }
        order = newOrder

        // The Dock rarely changes; checking every 0.5 s is enough, except while the mouse is near the
        // bottom edge, where an auto-hidden Dock pops up
        dockAcc += dt
        if dockAcc >= (NSEvent.mouseLocation.y < 40 ? 0.1 : 0.5) {
            dockAcc = 0
            updateDock()
        }

        computeOcclusion()
        updateLights()
        for p in piles.values { p.redraw() }
        dockPile?.redraw()
        ground?.redraw()
    }

    func updateDock() {
        var r: CGRect? = nil
        var status: String
        if let f = dockTracker.frame() {
            var s = CGRect(x: f.minX - Cfg.dockPad, y: size.height - f.maxY,
                           width: f.width + 2 * Cfg.dockPad, height: f.height)
            if f.width > f.height { dockZone = CGRect(x: s.minX, y: 0, width: s.width, height: max(s.height, 40)) }
            // The AX frame can reach a bit above the visible Dock shelf. When the Dock is always
            // shown, the space macOS reserves for it (bottom of visibleFrame) is a better top edge.
            if let screen = NSScreen.screens.first {
                let reserved = screen.visibleFrame.minY - screen.frame.minY
                if reserved > 10 && reserved < s.maxY { s.size.height = reserved - s.minY }
            }
            // Only handle a Dock that sits at the bottom of the screen and is currently on screen.
            // With auto-hide, a hidden Dock is reported below the screen edge, so it fails this check.
            if s.width > s.height && s.minY < 40 && s.maxY > 8 {
                r = s
                status = "found at x=\(Int(s.minX)) width=\(Int(s.width)) top=\(Int(s.maxY)) (AX top \(Int(size.height - f.minY)), screen \(Int(size.width))x\(Int(size.height)))"
            } else {
                status = "ignored (not at bottom or hidden), AX frame = \(f)"
            }
        } else {
            status = "not found: \(dockTracker.lastError)"
        }
        // Log only problems, and only when the status changes, so the terminal stays quiet
        let key = status.components(separatedBy: " at ").first ?? status
        if key != lastDockStatus {
            if r == nil { print("❄︎ Dock " + status) }
            lastDockStatus = key
        }
        if let old = dockRect, let r = r,
           abs(old.minX - r.minX) < 0.5, abs(old.width - r.width) < 0.5, abs(old.maxY - r.maxY) < 0.5 {
            return
        }
        if let p = dockPile {
            if r == nil {
                // The Dock slid away (auto-hide): keep its snow for when it pops up again
                savedDockSnow = p.h
            } else {
                // Dock resized (new app opened, magnification): drop its snow and start again
                release(p, vel: .zero, id: SnowScene.dockID)
            }
            p.remove()
            dockPile = nil
        }
        dockRect = r
        if let r = r {
            let p = Pile(minX: r.minX, topY: r.maxY + Cfg.dockTopOffset, width: r.width,
                         maxH: Cfg.dockPileMax, parent: world)
            // Bring back the snow it had (stretched if the Dock changed width), and never show up bare
            let saved = savedDockSnow ?? []
            for c in 0..<p.count {
                let old = saved.isEmpty ? 0 : saved[min(saved.count - 1, c * saved.count / max(1, p.count))]
                p.h[c] = min(p.caps[c], max(old, p.caps[c] * 0.5))
            }
            p.dirty = true
            p.redraw()
            savedDockSnow = nil
            dockPile = p
        }
    }

    // Parts of a window top hidden behind a front window get no snow and aren't drawn
    func computeOcclusion() {
        for (i, item) in order.enumerated() {
            guard let p = piles[item.id] else { continue }
            for c in 0..<p.count {
                let pt = CGPoint(x: p.colX(c), y: p.topY + 1)
                var o = pt.x < 0 || pt.x > size.width || pt.y > size.height
                if !o {
                    for j in 0..<i where order[j].rect.contains(pt) { o = true; break }
                }
                if o != p.occ[c] {
                    p.occ[c] = o
                    if o { p.h[c] = 0 }
                    p.dirty = true
                }
            }
        }
        if let g = ground {
            for c in 0..<g.count {
                let pt = CGPoint(x: g.colX(c), y: 1)
                var o = false
                for item in order where item.rect.contains(pt) { o = true; break }
                if o != g.occ[c] {
                    g.occ[c] = o
                    if o { g.h[c] = 0 }
                    g.dirty = true
                }
            }
        }
    }

    /// The wind drifts between moods and blends smoothly from one to the next (from WINTER-IS-COMMING-VER2)
    func stepWind(_ dt: CGFloat) -> (wind: CGFloat, lift: CGFloat) {
        windTimer -= dt
        if windTimer <= 0 {
            let roll = CGFloat.random(in: 0...1)
            var next: WindRegime = roll < 0.40 ? .gentleBreeze : (roll < 0.78 ? .moderateWind : .strongGust)
            if Cfg.reduceMotion { next = .gentleBreeze }
            windRegime = next
            windTimer = CGFloat.random(in: next.durationRange)
            targetWindScale = next.amplitudeScale
            targetWindBias = CGFloat.random(in: next.steadyBiasRange)
            targetWindLift = next.verticalLiftFactor
        }
        let blend = min(1, dt * 0.45)
        currentWindScale += (targetWindScale - currentWindScale) * blend
        currentWindBias += (targetWindBias - currentWindBias) * blend
        currentWindLift += (targetWindLift - currentWindLift) * blend
        // A few sines at different frequencies add up to gusty wind
        let baseWave = 14 * sin(t * 0.11) + 9 * sin(t * 0.37 + 1.3) + 6 * sin(t * 0.9 + 0.4)
        let gustRipple = 8 * sin(t * 1.45 + 0.7) * max(0, currentWindScale - 1.0)
        return (baseWave * currentWindScale + currentWindBias + gustRipple, currentWindLift)
    }

    func stepFlakes(_ dt: CGFloat) {
        let (wind, windLift) = stepWind(dt)
        var normal = 0
        var i = flakes.count - 1
        while i >= 0 {
            let f = flakes[i]
            var p = f.node.position
            let prevY = p.y

            if f.isClump {
                f.vel.dy -= Cfg.gravity * dt
                f.vel.dx *= max(0, 1 - 1.2 * dt)
                p.x += f.vel.dx * dt
                p.y += f.vel.dy * dt
            } else {
                let sway = sin(t * f.swayFreq + f.phase) * f.swayAmp
                p.x += (wind * f.windFactor + sway) * dt
                let gustSlowdown = 1.0 - min(0.30, windLift * f.windFactor * min(1.0, abs(wind) / 60.0))
                p.y += (f.vel.dy * gustSlowdown) * dt   // strong gusts hold the flakes up a little
                if p.x < -40 { p.x += size.width + 80 } else if p.x > size.width + 40 { p.x -= size.width + 80 }
            }

            var gone = false
            if p.y < prevY {
                // The Dock is always in front of every window, so check it first
                if let d = dockPile, let c = d.col(at: p.x),
                   !(f.isClump && f.ignoreID == SnowScene.dockID && t < f.ignoreUntil) {
                    let s = d.surface(c)
                    if prevY >= s && p.y < s {
                        d.add(at: c, amount: (f.isClump ? 1.6 : f.size * 0.16) * Cfg.dockGain)
                        gone = true
                    }
                }
                // Then check window tops, front to back
                if !gone && !f.inFront { for item in order {
                    guard let pile = piles[item.id] else { continue }
                    if f.isClump && item.id == f.ignoreID && t < f.ignoreUntil { continue }
                    guard let c = pile.col(at: p.x), !pile.occ[c] else { continue }
                    let s = pile.surface(c)
                    if prevY >= s && p.y < s {
                        pile.add(at: c, amount: f.isClump ? 1.6 : f.size * 0.16)
                        gone = true
                        break
                    }
                } }
                // Finally the bottom of the screen
                if !gone, let g = ground, let c = g.col(at: p.x), p.y < g.surface(c) {
                    if !g.occ[c] { g.add(at: c, amount: f.isClump ? 1.6 : f.size * 0.2) }
                    gone = true
                }
            }
            if !gone {
                // Flakes that fall "behind" a window disappear
                if !f.inFront {
                    for item in order where item.rect.contains(p) { gone = true; break }
                }
                if p.y < -20 { gone = true }
                if f.isClump && (p.x < -80 || p.x > size.width + 80) { gone = true }
            }

            if gone {
                recycle(at: i)
            } else {
                f.node.position = p
                if !f.isClump { normal += 1 }
            }
            i -= 1
        }

        // Top up flakes (max 6 per frame so they don't appear in a row)
        let deficit = min(6, Cfg.flakeTarget - normal)
        if deficit > 0 { for _ in 0..<deficit { spawnFlake() } }
    }
}

// MARK: - Transparent full-screen window + menu bar icon

/// Lets the very first click reach the scene even though this app is never the active app
final class OverlaySKView: SKView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class OverlayWindow: NSPanel {
    // Stop macOS from pushing the window below the menu bar
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: OverlayWindow!
    var scene: SnowScene!
    var statusItem: NSStatusItem!
    var pauseItem: NSMenuItem!
    var lightsItem: NSMenuItem!
    var palsItem: NSMenuItem!
    var perfItems: [NSMenuItem] = []
    var reduceItem: NSMenuItem!
    var fireItem: NSMenuItem!
    var treeItem: NSMenuItem!
    var amountItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first else { return }
        // A non-activating panel can take a click (to grab a snowball) without stealing focus from your apps
        window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true          // clicks pass straight through
        window.level = .floating                  // above normal windows, below the Dock and menu bar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = OverlaySKView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.allowsTransparency = true
        view.preferredFramesPerSecond = 60
        view.ignoresSiblingOrder = true
        scene = SnowScene(size: screen.frame.size)
        scene.scaleMode = .resizeFill
        view.presentScene(scene)
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()

        setupMenu()
        // Show the how-to-play tips once, the very first time the app opens
        if !UserDefaults.standard.bool(forKey: "seenGuide") {
            UserDefaults.standard.set(true, forKey: "seenGuide")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.showGuide() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Stop rendering while the display sleeps or the screen is locked; otherwise SpriteKit
        // logs "no drawables available" because nothing is being shown.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(self, selector: #selector(suspendRendering), name: name, object: nil)
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(self, selector: #selector(resumeRendering), name: name, object: nil)
        }
        // Swiping between Spaces / full-screen apps: let the companions and scenery hold still for a moment
        ws.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    @objc func spaceChanged() { scene.spaceChanged() }

    @objc func suspendRendering() {
        (window.contentView as? SKView)?.isPaused = true
    }

    @objc func resumeRendering() {
        // Stay paused if the user paused snow from the menu
        guard !scene.isPaused else { return }
        (window.contentView as? SKView)?.isPaused = false
    }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Apple's own snowflake symbol, so it matches the size and weight of the other menu bar icons
        // (it adapts to light and dark menu bars); falls back to the text snowflake if unavailable
        if let img = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "WinterIsComing") {
            let sized = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)) ?? img
            sized.isTemplate = true
            statusItem.button?.image = sized
        } else {
            statusItem.button?.title = "❄︎"
        }
        let menu = NSMenu()

        pauseItem = NSMenuItem(title: "Pause Snow", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let amount = NSMenuItem(title: "Snow Amount", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, n) in [("None", 0), ("Light", 120), ("Medium", 260), ("Heavy", 500)] {
            let it = NSMenuItem(title: title, action: #selector(setAmount(_:)), keyEquivalent: "")
            it.target = self
            it.tag = n
            it.state = (n == Cfg.targetFlakes) ? .on : .off
            sub.addItem(it)
            amountItems.append(it)
        }
        amount.submenu = sub
        menu.addItem(amount)

        let perf = NSMenuItem(title: "Performance", action: nil, keyEquivalent: "")
        let psub = NSMenu()
        for prof in PerfProfile.allCases {
            let it = NSMenuItem(title: prof.title, action: #selector(setProfile(_:)), keyEquivalent: "")
            it.target = self
            it.tag = prof.rawValue
            it.state = prof == Cfg.profile ? .on : .off
            psub.addItem(it)
            perfItems.append(it)
        }
        perf.submenu = psub
        menu.addItem(perf)

        reduceItem = NSMenuItem(title: "Reduce Motion", action: #selector(toggleReduceMotion), keyEquivalent: "")
        reduceItem.target = self
        reduceItem.state = Cfg.reduceMotion ? .on : .off
        menu.addItem(reduceItem)
        menu.addItem(.separator())

        palsItem = NSMenuItem(title: "Pet & Me 🐶", action: #selector(togglePals), keyEquivalent: "b")
        palsItem.target = self
        palsItem.state = scene.palsEnabled ? .on : .off
        menu.addItem(palsItem)

        fireItem = NSMenuItem(title: "Campfire 🔥", action: #selector(toggleCampfire), keyEquivalent: "")
        fireItem.target = self
        fireItem.state = scene.campfireOn ? .on : .off
        menu.addItem(fireItem)

        treeItem = NSMenuItem(title: "Christmas Tree 🎄", action: #selector(toggleTree), keyEquivalent: "")
        treeItem.target = self
        treeItem.state = scene.xmasTreeOn ? .on : .off
        menu.addItem(treeItem)

        lightsItem = NSMenuItem(title: "Fairy Lights ✨", action: #selector(toggleLights), keyEquivalent: "l")
        lightsItem.target = self
        lightsItem.state = scene.lightsOn ? .on : .off
        menu.addItem(lightsItem)

        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Snow", action: #selector(clearSnow), keyEquivalent: "c")
        clear.target = self
        menu.addItem(clear)

        let guide = NSMenuItem(title: "How to Play ❔", action: #selector(showGuide), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func togglePause() {
        scene.isPaused.toggle()
        if scene.isPaused {
            window.orderOut(nil)
            pauseItem.title = "Resume Snow"
        } else {
            window.orderFrontRegardless()
            pauseItem.title = "Pause Snow"
        }
    }

    @objc func setProfile(_ sender: NSMenuItem) {
        Cfg.profile = PerfProfile(rawValue: sender.tag) ?? .balanced
        UserDefaults.standard.set(sender.tag, forKey: "perfProfile")
        for it in perfItems { it.state = (it === sender) ? .on : .off }
    }

    @objc func toggleReduceMotion() {
        Cfg.reduceMotion.toggle()
        UserDefaults.standard.set(Cfg.reduceMotion, forKey: "reduceMotion")
        reduceItem.state = Cfg.reduceMotion ? .on : .off
    }

    @objc func setAmount(_ sender: NSMenuItem) {
        Cfg.targetFlakes = sender.tag
        for it in amountItems { it.state = (it === sender) ? .on : .off }
    }

    @objc func clearSnow() { scene.clearAll() }

    /// A small how-to-play note: the app has no window or Dock icon, so this is where people learn the tricks
    @objc func showGuide() {
        let alert = NSAlert()
        alert.messageText = "Welcome to WinterIsComing ❄️"
        alert.informativeText = """
        It's snowing on your desktop! Here's what you can do:

        ⚪  Roll a snowball: slide your mouse sideways over snow
        🎳  Push it: roll one snowball into another
        🖐️  Carry it: hold the left mouse button on a snowball and drag
        ⛄  Build a snowman: stack three snowballs
        🪟  Make snow fly: drag a window
        ✨  Hang fairy lights: ❄︎ menu → Fairy Lights
        🐶  Pet your pet: click it (click twice quickly to make it howl)
        🙋  Call your pet over: click yourself
        🔥  Campfire time: click the fire and you both come sit by it
        ⛄  Watch out: your pet can't resist a fresh snowman

        Find everything under the ❄︎ in your menu bar. To get snow on the Dock too, allow this app in System Settings → Privacy & Security → Accessibility.
        """
        alert.addButton(withTitle: "Let it snow!")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func togglePals() {
        scene.setPals(!scene.palsEnabled)
        palsItem.state = scene.palsEnabled ? .on : .off
    }

    @objc func toggleCampfire() {
        scene.setCampfire(!scene.campfireOn)
        fireItem.state = scene.campfireOn ? .on : .off
    }

    @objc func toggleTree() {
        scene.setXmasTree(!scene.xmasTreeOn)
        treeItem.state = scene.xmasTreeOn ? .on : .off
    }

    @objc func toggleLights() {
        scene.setLights(!scene.lightsOn)
        lightsItem.state = scene.lightsOn ? .on : .off
    }

    @objc func screensChanged() {
        guard let screen = NSScreen.screens.first else { return }
        window.setFrame(screen.frame, display: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon
app.run()
