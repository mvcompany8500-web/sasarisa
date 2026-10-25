// `MacButler --demo-frames <dir>` — renders the README demo from the app's real HUD (orb + card), off-screen:
// each scene is "what you said" (caption) → the HUD listening → the HUD result. Nothing on your screen is captured.
// docs/make-demo.sh turns the frames into docs/demo.gif.
import AppKit

enum DemoFrames {
    struct Scene { let said: String; let state: String; let body: String; let color: NSColor; let window: String; var lead = "말하면"; var quoted = true }
    /// English README demo (10/25 owner: 「깃허브 영어로 해놔야 하는 거 아녀?」) — `--demo-frames <dir> en`.
    static let scenesEN: [Scene] = [
        Scene(said: "Sasarisa, play some lofi on YouTube", state: "▶ Playing on YouTube", body: "Rainy-night lofi radio for studying ☔", color: lime, window: "▶︎  YouTube", lead: "Say"),
        Scene(said: "Volume to 30", state: "✓ Volume", body: "30", color: lime, window: "Volume 30", lead: "Say"),
        Scene(said: "Three-minute timer", state: "✓ Timer", body: "I'll tell you in 3 minutes", color: lime, window: "3:00", lead: "Say"),
        Scene(said: "Make this more polite", state: "✓ Rewritten (⌘Z undoes)", body: "I'm sorry, I'll have to cancel tomorrow's meeting.", color: lime,
              window: "can't do tmrw mtg sry\n→ I'm sorry, I'll have to cancel tomorrow's meeting.", lead: "Say"),
        Scene(said: "Lofi on, volume down, screen off", state: "◉ Doing them in order", body: "play lofi → volume down → screen off", color: amber, window: "play → volume ↓ → screen off", lead: "Say"),
        Scene(said: "Tell Claude to fix the login bug", state: "✓ Sent to Claude", body: "Please fix the login bug.", color: lime, window: "Claude Code\n> Please fix the login bug.", lead: "Say"),
        Scene(said: "Sasarisa pauses by itself", state: "🎙 On a call · paused", body: "Back when it's over (the hotkey still works)", color: amber,
              window: "Handy · Zoom · FaceTime", lead: "When Handy or Zoom uses the mic", quoted: false),
    ]
    static let scenes: [Scene] = [
        Scene(said: "사사리사, 유튜브 로파이 틀어", state: "▶ 유튜브 재생", body: "비 오는 밤, 공부할 때 듣는 로파이 라디오 ☔", color: lime, window: "▶︎  YouTube"),
        Scene(said: "소리 30으로 해", state: "✓ 소리", body: "30", color: lime, window: "소리 30"),
        Scene(said: "라면 3분", state: "✓ 타이머", body: "라면 · 3분 뒤에 알려 드릴게요", color: lime, window: "3:00"),
        Scene(said: "이거 존댓말로 바꿔", state: "✓ 바꿈 (⌘Z 되돌리기)", body: "내일 미팅은 취소하겠습니다. 죄송합니다.", color: lime, window: "낼 미팅 취소할게 미안\n→ 내일 미팅은 취소하겠습니다. 죄송합니다."),
        Scene(said: "로파이 틀고 소리 줄이고 화면 꺼", state: "◉ 차례로 하는 중", body: "로파이 틀어 → 소리 줄여 → 화면 꺼", color: amber, window: "재생 → 소리 ↓ → 화면 끔"),
        Scene(said: "클로드한테 로그인 버그 고치라고 해", state: "✓ 클로드에 보냄", body: "로그인 버그 고치라고 해", color: lime, window: "Claude Code\n> 로그인 버그 고치라고 해"),
        Scene(said: "사사리사는 알아서 잠깐 쉬어요", state: "🎙 통화 중 · 잠시 쉼", body: "끝나면 다시 들어요 (단축키는 그대로 돼요)", color: amber,
              window: "Handy · Zoom · FaceTime", lead: "핸디나 줌이 마이크를 쓰면", quoted: false),
    ]

    static func run(_ dir: String, en: Bool = false) {
        english = en
        _ = NSApplication.shared
        HUD.offscreen = true
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let hud = HUD(); hud.position = "bottomRight"
        var n = 0
        func frame(_ caption: String, _ window: String = "", lead: String = "말하면", quoted: Bool = true) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))   // let the card settle
            guard let img = compose(hud: hud, caption: caption, window: window, lead: lead, quoted: quoted) else { return }
            let url = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "f%03d.png", n)); n += 1
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        }
        hud.idle(); frame("")
        for s in en ? scenesEN : scenes {
            if s.quoted { hud.show(en ? "● Listening" : "● 듣는 중", "…", heard: s.said, color: cyan) } else { hud.idle() }
            frame(s.said, lead: s.lead, quoted: s.quoted)
            hud.show(s.state, s.body, heard: s.quoted ? s.said : "", color: s.color); frame(s.said, s.window, lead: s.lead, quoted: s.quoted)
        }
        print("\(n) frames → \(dir)")
    }

    static var english = false
    /// 1280×720: a quiet desktop, the spoken sentence on top, the real HUD in the bottom-right corner.
    static func compose(hud: HUD, caption: String, window: String = "", lead: String = "말하면", quoted: Bool = true) -> NSImage? {
        guard let root = hud.root else { return nil }
        let W: CGFloat = 1280, H: CGFloat = 720
        // HUD views → bitmap (layer tree, including text)
        root.layoutSubtreeIfNeeded()
        func displayAll(_ v: NSView) { v.layer?.setNeedsDisplay(); v.layer?.displayIfNeeded(); v.subviews.forEach(displayAll) }
        displayAll(root)
        let size = root.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        ctx.cgContext.scaleBy(x: 2, y: 2)
        root.layer?.render(in: ctx.cgContext)
        let hudImg = NSImage(size: size); hudImg.addRepresentation(rep)

        let out = NSImage(size: NSSize(width: W, height: H))
        out.lockFocus()
        // desktop: deep blue gradient + a faint window
        NSGradient(colors: [NSColor(calibratedRed: 0.05, green: 0.08, blue: 0.16, alpha: 1), NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.30, alpha: 1)])!
            .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 60)
        let win = NSBezierPath(roundedRect: NSRect(x: 70, y: 150, width: 760, height: 420), xRadius: 14, yRadius: 14)
        NSColor(calibratedWhite: 1, alpha: 0.06).setFill(); win.fill()
        NSColor(calibratedWhite: 1, alpha: 0.10).setStroke(); win.lineWidth = 1; win.stroke()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.withAlphaComponent(0.55).setFill(); NSBezierPath(ovalIn: NSRect(x: 92 + CGFloat(i) * 22, y: 544, width: 12, height: 12)).fill()
        }
        // what happened, inside the window
        if !window.isEmpty {
            let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineSpacing = 10
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: window.count > 12 ? 30 : 64, weight: .semibold),
                                                    .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.85), .paragraphStyle: p]
            let str = NSAttributedString(string: window, attributes: a)
            let r = str.boundingRect(with: NSSize(width: 680, height: 300), options: [.usesLineFragmentOrigin])
            str.draw(in: NSRect(x: 110, y: 150 + (400 - r.height) / 2, width: 680, height: r.height + 4))
        }
        // what was said
        if !caption.isEmpty {
            let p = NSMutableParagraphStyle(); p.alignment = .left
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: p]
            let mic: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: cyan]
            NSAttributedString(string: lead, attributes: mic).draw(at: NSPoint(x: 72, y: H - 82))
            NSAttributedString(string: quoted ? (english ? "“\(caption)”" : "「\(caption)」") : caption, attributes: attrs).draw(in: NSRect(x: 64, y: H - 150, width: W - 120, height: 64))
        } else {
            let t: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40, weight: .bold), .foregroundColor: NSColor.white]
            NSAttributedString(string: english ? "Sasarisa — the AI assistant you just talk to" : "사사리사 — 말로 시키는 AI 비서", attributes: t).draw(at: NSPoint(x: 72, y: H - 110))
        }
        // the HUD, bottom-right, scaled to fit
        let scale = min(1.0, (W * 0.72) / size.width)
        let w = size.width * scale, h = size.height * scale
        hudImg.draw(in: NSRect(x: W - w + 6, y: -6, width: w, height: h))
        out.unlockFocus()
        return out
    }
}
