import AppKit
import QuartzCore

// Wake-up scene ("daddy's home"): arc-reactor rings, radar, boot log, clock — then it flies into the orb.

enum SysInfo {
    static func memory() -> (used: Double, total: Double) {
        var st = vm_statistics64()
        var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &st) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n) } }
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        guard kr == KERN_SUCCESS else { return (0, total) }
        let page = Double(vm_kernel_page_size)
        let used = Double(UInt64(st.active_count) + UInt64(st.wire_count) + UInt64(st.compressor_page_count)) * page / 1_073_741_824
        return (used, total)
    }
    static func model() -> String {
        var size = 0; sysctlbyname("hw.model", nil, &size, nil, 0)
        var b = [CChar](repeating: 0, count: max(size, 1)); sysctlbyname("hw.model", &b, &size, nil, 0)
        return String(cString: b) + " · " + ProcessInfo.processInfo.operatingSystemVersionString
    }
    static func diskFreeGB() -> Double {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Double(v?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000
    }
}

final class BootScene {
    static var window: NSPanel?
    static var sound: NSSound?

    /// Built-in boot sound when no voice/boot.* file exists: a rising sweep + two bright pings.
    static func synthChime() {
        let rate = 44100.0, dur = 2.4
        var s = [Float](repeating: 0, count: Int(rate * dur))
        for i in 0..<s.count {
            let t = Double(i) / rate
            let sweepF = 90 + 520 * pow(min(t / 1.4, 1), 2)
            let env = t < 1.4 ? t / 1.4 : max(0, 1 - (t - 1.4) / 0.4)
            var v = 0.22 * sin(2 * .pi * sweepF * t) * env + 0.08 * sin(4 * .pi * sweepF * t) * env
            for (start, f) in [(1.45, 1318.5), (1.7, 1975.5)] where t > start {
                let dt = t - start
                v += 0.18 * sin(2 * .pi * f * dt) * exp(-dt * 4)
            }
            s[i] = Float(v)
        }
        sound = NSSound(data: Whisper.wav(s, rate: Int(rate)))
        Sound.play(sound)
    }

    static func ring(_ host: CALayer, _ c: CGPoint, _ rad: CGFloat, width: CGFloat, dash: [NSNumber]?, alpha: CGFloat,
                     spin: Double, delay: Double, arc: CGFloat = 1) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.frame = host.bounds
        let p = CGMutablePath()
        p.addArc(center: c, radius: rad, startAngle: 0, endAngle: .pi * 2 * arc, clockwise: false)
        l.path = p
        l.fillColor = nil; l.strokeColor = cyan.withAlphaComponent(alpha).cgColor
        l.lineWidth = width; l.lineDashPattern = dash; l.lineCap = .butt
        l.shadowColor = cyan.cgColor; l.shadowRadius = 8; l.shadowOpacity = 0.9; l.shadowOffset = .zero
        l.strokeEnd = 0
        host.addSublayer(l)
        let now = CACurrentMediaTime()
        let draw = CABasicAnimation(keyPath: "strokeEnd"); draw.fromValue = 0; draw.toValue = 1
        draw.duration = 0.8; draw.beginTime = now + delay; draw.fillMode = .forwards; draw.isRemovedOnCompletion = false
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.add(draw, forKey: "draw")
        if spin != 0 {
            let s = CABasicAnimation(keyPath: "transform.rotation.z")
            s.toValue = (spin > 0 ? 1.0 : -1.0) * Double.pi * 2; s.duration = abs(spin); s.repeatCount = .infinity
            l.add(s, forKey: "spin")
        }
        return l
    }
    static func ticks(_ host: CALayer, _ c: CGPoint, rad: CGFloat, count: Int, len: CGFloat, width: CGFloat, alpha: CGFloat, delay: Double) {
        let rep = CAReplicatorLayer()
        rep.frame = host.bounds
        rep.instanceCount = count
        rep.instanceTransform = CATransform3DMakeRotation(.pi * 2 / CGFloat(count), 0, 0, 1)
        let t = CALayer()
        t.frame = CGRect(x: c.x - width / 2, y: c.y + rad, width: width, height: len)
        t.backgroundColor = cyan.withAlphaComponent(alpha).cgColor
        rep.addSublayer(t)
        rep.opacity = 0
        host.addSublayer(rep)
        let f = CABasicAnimation(keyPath: "opacity"); f.fromValue = 0; f.toValue = 1
        f.duration = 0.5; f.beginTime = CACurrentMediaTime() + delay; f.fillMode = .forwards; f.isRemovedOnCompletion = false
        rep.add(f, forKey: "in")
    }
    static func label(_ v: NSView, _ s: String, font: NSFont, color: NSColor, frame: NSRect, align: NSTextAlignment = .left) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = font; l.textColor = color; l.alignment = align; l.frame = frame
        let sh = NSShadow(); sh.shadowColor = cyan.withAlphaComponent(0.8); sh.shadowBlurRadius = 10; l.shadow = sh
        v.addSubview(l); return l
    }
    static func type(_ l: NSTextField, _ s: String, at: Double, speed: Double = 0.025) {
        let chars = Array(s)
        for i in 0...chars.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + at + Double(i) * speed) { l.stringValue = String(chars[0..<i]) }
        }
    }

    struct Text { var title: String; var subtitle: String; var hello: String; var strings: Strings; var locale: String }

    /// calm: just the backdrop, a soft orb with two rings, the name and the greeting (no grid, radar, boot log or clock).
    static func play(target: CGPoint, text: Text, sound: URL?, calm: Bool = false, done: @escaping () -> Void) {
        let scr = NSScreen.main!.frame
        let win = NSPanel(contentRect: scr, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.level = .screenSaver; win.isOpaque = false; win.backgroundColor = .clear; win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window = win
        let v = NSView(frame: NSRect(origin: .zero, size: scr.size)); v.wantsLayer = true
        win.contentView = v
        let root = v.layer!
        let W = scr.width, H = scr.height
        let c = CGPoint(x: W / 2, y: H / 2 + 40)

        // Backdrop: translucent so the desktop shows through, plus a faint grid
        let bg = CAGradientLayer(); bg.type = .radial; bg.frame = root.bounds
        bg.startPoint = CGPoint(x: 0.5, y: 0.53); bg.endPoint = CGPoint(x: 1.1, y: 1.1)
        bg.colors = [NSColor(calibratedRed: 0.02, green: 0.10, blue: 0.16, alpha: 0.55).cgColor, NSColor(calibratedWhite: 0, alpha: 0.62).cgColor]
        root.addSublayer(bg)
        let grid = CAReplicatorLayer(); grid.frame = root.bounds; grid.instanceCount = Int(H / 48) + 1
        grid.instanceTransform = CATransform3DMakeTranslation(0, 48, 0)
        let gl = CALayer(); gl.frame = CGRect(x: 0, y: 0, width: W, height: 1); gl.backgroundColor = cyan.withAlphaComponent(0.05).cgColor
        grid.addSublayer(gl); if !calm { root.addSublayer(grid) }
        let gridV = CAReplicatorLayer(); gridV.frame = root.bounds; gridV.instanceCount = Int(W / 48) + 1
        gridV.instanceTransform = CATransform3DMakeTranslation(48, 0, 0)
        let gv = CALayer(); gv.frame = CGRect(x: 0, y: 0, width: 1, height: H); gv.backgroundColor = cyan.withAlphaComponent(0.05).cgColor
        gridV.addSublayer(gv); if !calm { root.addSublayer(gridV) }
        // Scan line sweeping down
        let scan = CAGradientLayer(); scan.frame = CGRect(x: 0, y: H, width: W, height: 140)
        scan.colors = [cyan.withAlphaComponent(0).cgColor, cyan.withAlphaComponent(0.18).cgColor, cyan.withAlphaComponent(0).cgColor]
        if !calm { root.addSublayer(scan) }
        let sm = CABasicAnimation(keyPath: "position.y"); sm.fromValue = H + 70; sm.toValue = -70; sm.duration = 1.6
        sm.fillMode = .forwards; sm.isRemovedOnCompletion = false
        scan.add(sm, forKey: "scan")

        // Arc reactor (everything inside `reactor` flies to the orb at the end)
        let R: CGFloat = 330
        let reactor = CALayer(); reactor.frame = CGRect(x: c.x - R - 40, y: c.y - R - 40, width: 2 * R + 80, height: 2 * R + 80)
        root.addSublayer(reactor)
        let rc = CGPoint(x: reactor.bounds.midX, y: reactor.bounds.midY)
        // Radar sweep
        let radar = CAGradientLayer(); radar.type = .conic
        radar.frame = CGRect(x: rc.x - R + 20, y: rc.y - R + 20, width: 2 * R - 40, height: 2 * R - 40)
        radar.startPoint = CGPoint(x: 0.5, y: 0.5); radar.endPoint = CGPoint(x: 0.5, y: 0)
        radar.colors = [cyan.withAlphaComponent(0.35).cgColor, cyan.withAlphaComponent(0.0).cgColor, cyan.withAlphaComponent(0.0).cgColor]
        radar.locations = [0, 0.18, 1]
        let rmask = CAShapeLayer(); rmask.path = CGPath(ellipseIn: radar.bounds, transform: nil); radar.mask = rmask
        radar.opacity = 0
        if !calm { reactor.addSublayer(radar) }
        let rs = CABasicAnimation(keyPath: "transform.rotation.z"); rs.toValue = -Double.pi * 2; rs.duration = 2.2; rs.repeatCount = .infinity
        radar.add(rs, forKey: "spin")
        let rf = CABasicAnimation(keyPath: "opacity"); rf.fromValue = 0; rf.toValue = 1; rf.beginTime = CACurrentMediaTime() + 0.5
        rf.duration = 0.6; rf.fillMode = .forwards; rf.isRemovedOnCompletion = false
        radar.add(rf, forKey: "in")

        if !calm {
            ticks(reactor, rc, rad: R - 6, count: 120, len: 10, width: 2, alpha: 0.55, delay: 0.15)
            ticks(reactor, rc, rad: R - 14, count: 12, len: 22, width: 4, alpha: 0.95, delay: 0.3)
            _ = ring(reactor, rc, R + 18, width: 1.5, dash: nil, alpha: 0.5, spin: 0, delay: 0.0)
            _ = ring(reactor, rc, R - 40, width: 14, dash: [90, 18, 30, 18], alpha: 0.75, spin: 7, delay: 0.25)
            _ = ring(reactor, rc, R - 72, width: 2, dash: [4, 6], alpha: 0.8, spin: -12, delay: 0.4)
            _ = ring(reactor, rc, R - 100, width: 26, dash: nil, alpha: 0.35, spin: -5, delay: 0.55, arc: 0.28)
            _ = ring(reactor, rc, R - 100, width: 26, dash: nil, alpha: 0.35, spin: -5, delay: 0.6, arc: 0.12)
        }
        _ = ring(reactor, rc, R - 140, width: 3, dash: [60, 10, 6, 10], alpha: 0.9, spin: 4, delay: 0.7)
        if !calm { _ = ring(reactor, rc, R - 175, width: 8, dash: [2, 9], alpha: 0.9, spin: -3, delay: 0.85) }
        _ = ring(reactor, rc, R - 205, width: 1.5, dash: nil, alpha: 0.9, spin: 0, delay: 0.95)
        // Core
        let core = CAGradientLayer(); core.type = .radial
        let cr: CGFloat = 105
        core.frame = CGRect(x: rc.x - cr, y: rc.y - cr, width: cr * 2, height: cr * 2); core.cornerRadius = cr
        core.startPoint = CGPoint(x: 0.5, y: 0.5); core.endPoint = CGPoint(x: 1, y: 1)
        core.colors = [NSColor.white.cgColor, cyan.cgColor, cyan.withAlphaComponent(0).cgColor]
        core.locations = [0, 0.35, 1]
        core.shadowColor = cyan.cgColor; core.shadowRadius = 40; core.shadowOpacity = 1
        core.transform = CATransform3DMakeScale(0.01, 0.01, 1)
        reactor.addSublayer(core)
        let pop = CASpringAnimation(keyPath: "transform.scale"); pop.fromValue = 0.01; pop.toValue = 1
        pop.damping = 9; pop.duration = 1.2; pop.beginTime = CACurrentMediaTime() + 0.9
        pop.fillMode = .forwards; pop.isRemovedOnCompletion = false
        core.add(pop, forKey: "pop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
            core.removeAnimation(forKey: "pop"); core.transform = CATransform3DIdentity
            let pulse = CABasicAnimation(keyPath: "transform.scale"); pulse.fromValue = 0.92; pulse.toValue = 1.08
            pulse.duration = 0.7; pulse.autoreverses = true; pulse.repeatCount = .infinity
            core.add(pulse, forKey: "pulse")
        }

        if !calm {
            // Left: boot log with real numbers
            let mem = SysInfo.memory(), disk = SysInfo.diskFreeGB()
            let mono = NSFont.monospacedSystemFont(ofSize: 23, weight: .medium)
            let log: [String] = [text.title.replacingOccurrences(of: "   ", with: "\u{1}").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{1}", with: " ") + " · BOOT SEQUENCE", "────────────────────────────────"] + text.strings.bootLines + [
                String(format: text.strings.bootMemory, mem.used, mem.total),
                String(format: text.strings.bootDisk, disk),
                "> " + SysInfo.model(),
                text.strings.bootAllGood]
            for (i, s) in log.enumerated() {
                let l = label(v, "", font: mono, color: i == 0 ? .white : cyan, frame: NSRect(x: 90, y: H - 230 - CGFloat(i) * 44, width: 820, height: 34))
                type(l, s, at: 0.35 + Double(i) * 0.24, speed: 0.012)
            }
            // Right: clock
            let f = DateFormatter(); f.locale = Locale(identifier: text.locale)
            f.dateFormat = "HH:mm"; let hm = f.string(from: Date())
            f.dateFormat = "yyyy.MM.dd  EEEE"; let ymd = f.string(from: Date())
            let clock = label(v, hm, font: .monospacedSystemFont(ofSize: 110, weight: .thin), color: .white, frame: NSRect(x: W - 520, y: H - 330, width: 430, height: 130), align: .right)
            let date = label(v, ymd, font: .monospacedSystemFont(ofSize: 24, weight: .regular), color: cyan, frame: NSRect(x: W - 620, y: H - 380, width: 530, height: 32), align: .right)
            let nominal = label(v, "", font: .monospacedSystemFont(ofSize: 18, weight: .bold), color: lime, frame: NSRect(x: W - 620, y: H - 420, width: 530, height: 26), align: .right)
            type(nominal, "● ALL SYSTEMS NOMINAL", at: 2.6)
            clock.alphaValue = 0; date.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSAnimationContext.runAnimationGroup { $0.duration = 0.6; clock.animator().alphaValue = 1; date.animator().alphaValue = 1 }
            }
        }
        // Bottom: name + greeting
        let title = label(v, "", font: calm ? .systemFont(ofSize: 64, weight: .bold) : .monospacedSystemFont(ofSize: 76, weight: .heavy), color: calm ? .white : cyan, frame: NSRect(x: 0, y: c.y - R - 150, width: W, height: 80), align: .center)
        type(title, text.title, at: 1.0, speed: 0.045)
        let sub = label(v, "", font: calm ? .systemFont(ofSize: 24, weight: .medium) : .monospacedSystemFont(ofSize: 24, weight: .medium), color: NSColor(calibratedWhite: 0.85, alpha: 1), frame: NSRect(x: 0, y: c.y - R - 190, width: W, height: 30), align: .center)
        type(sub, text.subtitle, at: 1.9, speed: 0.03)
        let hello = label(v, "", font: .systemFont(ofSize: 56, weight: .bold), color: .white, frame: NSRect(x: 0, y: c.y - R - 285, width: W, height: 72), align: .center)
        type(hello, text.hello, at: 2.4, speed: 0.06)

        if let sound { Sound.file(sound) } else { BootScene.synthChime() }
        win.alphaValue = 0; win.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; win.animator().alphaValue = 1 }

        // Finish: the reactor flies into the HUD orb, everything else fades
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.6) {
            for sub in v.subviews { NSAnimationContext.runAnimationGroup { $0.duration = 0.35; sub.animator().alphaValue = 0 } }
            let to = CGPoint(x: target.x - scr.minX, y: target.y - scr.minY)
            let move = CABasicAnimation(keyPath: "position"); move.toValue = NSValue(point: to)
            let shrink = CABasicAnimation(keyPath: "transform.scale"); shrink.toValue = 128 / (2 * R + 80)
            let g = CAAnimationGroup(); g.animations = [move, shrink]; g.duration = 0.7
            g.timingFunction = CAMediaTimingFunction(name: .easeIn); g.fillMode = .forwards; g.isRemovedOnCompletion = false
            reactor.add(g, forKey: "fly")
            for l in [bg, grid, gridV] {
                let fo = CABasicAnimation(keyPath: "opacity"); fo.toValue = 0; fo.duration = 0.6
                fo.fillMode = .forwards; fo.isRemovedOnCompletion = false; l.add(fo, forKey: "out")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) { done() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; win.animator().alphaValue = 0 }) { win.orderOut(nil); window = nil }
            }
        }
    }
}
