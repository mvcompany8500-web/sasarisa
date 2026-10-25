import AppKit
import QuartzCore

// The face: a glowing orb + a card in the middle of the screen by default (or bottom center / bottom right / bottom left / top —
// config hudPosition, picked in Setup while watching it move). Click-through, on every Space.

let cyan = NSColor(calibratedRed: 0.30, green: 0.85, blue: 1.0, alpha: 1)
let amber = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.25, alpha: 1)
let lime = NSColor(calibratedRed: 0.45, green: 1.0, blue: 0.6, alpha: 1)

final class OrbView: NSView {
    private let core = CAGradientLayer()
    private var rings: [CAShapeLayer] = []
    private var color = cyan
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let b = bounds, c = CGPoint(x: b.midX, y: b.midY)
        let specs: [(CGFloat, CGFloat, [NSNumber], Double)] = [
            (0.48, 2.0, [6, 4], 9), (0.40, 1.2, [30, 8, 4, 8], -6), (0.33, 3.0, [2, 10], 4)]
        for (r, w, dash, speed) in specs {
            let l = CAShapeLayer()
            let rad = b.width * r
            l.bounds = b; l.position = c
            l.path = CGPath(ellipseIn: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2), transform: nil)
            l.fillColor = nil; l.lineWidth = w; l.lineDashPattern = dash
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0; a.toValue = speed > 0 ? Double.pi * 2 : -Double.pi * 2
            a.duration = abs(speed); a.repeatCount = .infinity
            l.add(a, forKey: "spin")
            layer!.addSublayer(l); rings.append(l)
        }
        let cr = b.width * 0.22
        core.type = .radial
        core.frame = CGRect(x: c.x - cr, y: c.y - cr, width: cr * 2, height: cr * 2)
        core.cornerRadius = cr
        core.startPoint = CGPoint(x: 0.5, y: 0.5); core.endPoint = CGPoint(x: 1, y: 1)
        layer!.addSublayer(core)
        setColor(cyan, bright: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setColor(_ c: NSColor, bright: Bool) {
        color = c
        let a: CGFloat = bright ? 1 : 0.45
        for r in rings { r.strokeColor = c.withAlphaComponent(a * 0.9).cgColor; r.shadowColor = c.cgColor; r.shadowRadius = 6; r.shadowOpacity = bright ? 0.9 : 0.2 }
        core.colors = [NSColor.white.withAlphaComponent(a).cgColor, c.withAlphaComponent(a).cgColor, c.withAlphaComponent(0).cgColor]
        core.shadowColor = c.cgColor; core.shadowRadius = 14; core.shadowOpacity = bright ? 1 : 0.3
    }
    func setSpeed(_ s: Float) { for r in rings { r.speed = s } }
    func level(_ v: Float) {
        let s = 1 + CGFloat(min(v * 18, 0.6))
        CATransaction.begin(); CATransaction.setAnimationDuration(0.08)
        core.transform = CATransform3DMakeScale(s, s, 1)
        CATransaction.commit()
    }
}

final class HUD {
    let panel: NSPanel
    let orb: OrbView
    let card = NSView()
    let status = NSTextField(labelWithString: "")
    let heard = NSTextField(labelWithString: "")
    let text = NSTextField(wrappingLabelWithString: "")
    var showIdleOrb = true
    var position = "top" { didSet { layout() } }
    let w: CGFloat = 980          // card width
    let m: CGFloat = 28           // room for the glow
    private var tone = cyan

    static var offscreen = false     // `--demo-frames`: build the views without showing the window
    var root: NSView? { panel.contentView }
    init() {
        let scr = NSScreen.main!.visibleFrame
        panel = NSPanel(contentRect: NSRect(x: scr.midX - (w + 2 * m) / 2, y: scr.maxY - 200, width: w + 2 * m, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let root = NSView(frame: panel.contentLayoutRect)
        card.wantsLayer = true
        let L = card.layer!
        L.backgroundColor = NSColor(calibratedRed: 0.02, green: 0.04, blue: 0.08, alpha: 0.95).cgColor
        L.cornerRadius = 28; L.borderWidth = 2
        L.shadowRadius = 22; L.shadowOpacity = 0.75; L.shadowOffset = .zero
        root.addSubview(card)
        orb = OrbView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        root.addSubview(orb)
        status.font = .monospacedSystemFont(ofSize: 17, weight: .bold)
        heard.font = .systemFont(ofSize: 20, weight: .medium)
        heard.textColor = NSColor(calibratedWhite: 0.78, alpha: 1)
        heard.lineBreakMode = .byTruncatingHead
        text.font = .systemFont(ofSize: 30, weight: .bold)
        text.textColor = .white
        text.maximumNumberOfLines = 6; text.lineBreakMode = .byWordWrapping
        let sh = NSShadow(); sh.shadowColor = NSColor.black; sh.shadowBlurRadius = 3; sh.shadowOffset = NSSize(width: 0, height: -1)
        text.shadow = sh
        for v in [status, heard, text] { root.addSubview(v) }
        panel.contentView = root
        layout()
        if !HUD.offscreen { panel.orderFrontRegardless() }
        idle()
    }

    // Grow with the text: at the top the top edge stays put, in a bottom corner the bottom edge does.
    private func layout() {
        let tw = w - 190
        let th = min(ceil((text.stringValue as NSString).boundingRect(with: NSSize(width: tw, height: 3000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: text.font!]).height) + 6, 6 * 38)
        let hasHeard = !heard.stringValue.isEmpty
        let ch = max(152, 20 + 26 + (hasHeard ? 30 : 0) + 8 + th + 22)
        let scr = NSScreen.main!.visibleFrame
        // grows from the bottom edge everywhere except at the top
        let bottom = position.hasPrefix("bottom") || position == "center", corner = position == "bottomRight" || position == "bottomLeft"
        let right = position != "bottomLeft" && position != "top"          // the orb's side
        let x = position == "bottomRight" ? scr.maxX - w - 2 * m + 10 : position == "bottomLeft" ? scr.minX - 10 : scr.midX - (w + 2 * m) / 2
        // Bottom corners sit at the very bottom of the screen (beside the Dock); bottom center sits just above the Dock.
        let floorY = (NSScreen.main?.frame.minY ?? scr.minY) - 10
        let y = corner ? floorY : position == "bottomCenter" ? scr.minY - m + 12 : position == "center" ? scr.midY - (ch + 2 * m) / 2 : scr.maxY - ch - 2 * m + 14
        panel.setFrame(NSRect(x: x, y: y, width: w + 2 * m, height: ch + 2 * m), display: true)
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: w + 2 * m, height: ch + 2 * m)
        card.frame = NSRect(x: m, y: m, width: w, height: ch)
        let top = m + ch
        // Orb sits in the corner nearest the screen edge; text on the other side.
        let tx = right ? m + 22 : m + 170
        orb.frame.origin = NSPoint(x: right ? m + w - 14 - 128 : m + 14, y: bottom ? m + 12 : top - 12 - 128)
        status.frame = NSRect(x: tx, y: top - 20 - 26, width: tw, height: 26)
        heard.frame = NSRect(x: tx, y: top - 20 - 26 - 30, width: tw, height: 28)
        text.frame = NSRect(x: tx, y: m + 20, width: tw, height: th)
    }
    /// The places it can sit, for Setup and Settings.
    static func positions(_ S: Strings) -> [(String, String)] {
        [("center", S.t("화면 가운데 (기본)", "Middle of the screen (default)")), ("bottomCenter", S.t("아래 가운데 (독 위)", "Bottom center (above the Dock)")),
         ("bottomRight", S.t("오른쪽 아래", "Bottom right")), ("bottomLeft", S.t("왼쪽 아래", "Bottom left")), ("top", S.t("위 가운데", "Top center"))]
    }
    var orbCenterOnScreen: CGPoint { CGPoint(x: panel.frame.minX + orb.frame.midX, y: panel.frame.minY + orb.frame.midY) }

    private func paint(_ c: NSColor) {
        tone = c
        card.layer?.borderColor = c.withAlphaComponent(0.85).cgColor
        card.layer?.shadowColor = c.cgColor
        status.textColor = c
    }
    private func expand(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            for v in [card, status, heard, text] { v.animator().alphaValue = on ? 1 : 0 }
            orb.animator().alphaValue = on ? 1 : (showIdleOrb && position != "center" ? 0.6 : 0)    // no resting orb in the middle of the screen
        }
    }
    func idle() {
        orb.setColor(cyan, bright: false); orb.setSpeed(0.6); expand(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.card.alphaValue < 0.5 else { return }
            self.heard.stringValue = ""; self.text.stringValue = ""; self.layout()
        }
    }
    /// heard: what the user said (small line). nil = keep, "" = clear.
    func show(_ state: String, _ body: String, heard h: String? = "", color: NSColor = cyan, speed: Float = 1) {
        status.stringValue = state; paint(color)
        text.stringValue = body.count > 220 ? "…" + String(body.suffix(220)) : body
        if let h { heard.stringValue = h.isEmpty ? "" : "🗣  " + h }
        orb.setColor(color, bright: true); orb.setSpeed(speed)
        layout(); expand(true)
    }
    func setStatus(_ state: String, color: NSColor = cyan) {
        status.stringValue = state; paint(color)
        orb.setColor(color, bright: true); orb.setSpeed(1); expand(true)
    }
    func body(_ s: String) { text.stringValue = s; layout() }
    func hideAll(_ hide: Bool) { panel.alphaValue = hide ? 0 : 1 }
}
