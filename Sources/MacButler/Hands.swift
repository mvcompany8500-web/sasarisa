// Keyboard + Accessibility. Nothing here moves the mouse pointer.
import AppKit
import ApplicationServices

enum Hands {
    static let enter: CGKeyCode = 36
    static func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
    /// The keyboard's ⏯ key: pauses / resumes whatever is "Now Playing" (YouTube in Chrome or Safari, Music…),
    /// even when that window isn't in front.
    static func playPause() { mediaKey(16) }       // NX_KEYTYPE_PLAY
    /// A keyboard media key: 16 ⏯, 17 ⏭, 18 ⏮
    static func mediaKey(_ key: Int) {
        for down in [true, false] {
            let data1 = (key << 16) | ((down ? 0xa : 0xb) << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let old = pb.string(forType: .string)
        pb.clearContents(); pb.setString(text, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            key(9, .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let old { pb.clearContents(); pb.setString(old, forType: .string) }
            }
        }
    }
    /// Types character by character so it's visible on screen (works for Hangul without the IME).
    /// Long text is pasted instead. Call off the main thread.
    static func typeVisible(_ s: String, perChar: Double = 0.028) {
        if s.count > 160 { DispatchQueue.main.sync { paste(s) }; Thread.sleep(forTimeInterval: 0.4); return }
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in s {
            let u = Array(String(ch).utf16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                e?.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: perChar)
        }
    }
}

/// Accessibility helpers: find buttons / text boxes by name in ~0.1 s, press them without the mouse.
enum AX {
    static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
    static func app(_ bundle: String) -> AXUIElement? {
        guard let a = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return nil }
        let e = AXUIElementCreateApplication(a.processIdentifier)
        AXUIElementSetAttributeValue(e, "AXManualAccessibility" as CFString, kCFBooleanTrue)   // expose Electron content
        return e
    }
    static func frame(_ e: AXUIElement) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv = attr(e, "AXPosition"), let sv = attr(e, "AXSize") else { return nil }
        AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }
    static func walk(_ e: AXUIElement, depth: Int = 0, count: inout Int, until: Date = .distantFuture, intoCells: Bool = true, _ visit: (AXUIElement, String) -> Void) {
        count += 1
        if depth > 40 || count > 8000 || Date() > until { return }
        let role = attr(e, "AXRole") as? String ?? ""
        visit(e, role)
        if !intoCells, role == "AXRow" || role == "AXCell" { return }
        for c in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] { walk(c, depth: depth + 1, count: &count, until: until, intoCells: intoCells, visit) }
    }
    static func windows(_ app: AXUIElement) -> [AXUIElement] {
        var ws = (attr(app, "AXWindows") as? [AXUIElement]) ?? []
        if let f = attr(app, "AXFocusedWindow") { let fw = f as! AXUIElement; ws.removeAll { CFEqual($0, fw) }; ws.insert(fw, at: 0) }
        return ws
    }
    /// The focused text box is a password field (typing into it is refused in safe mode).
    static func focusedIsSecure() -> Bool {
        guard let f = attr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) else { return false }
        return (attr(f as! AXUIElement, "AXSubrole") as? String) == "AXSecureTextField"
    }
    static func press(_ e: AXUIElement) { AXUIElementPerformAction(e, kAXPressAction as CFString) }
    static func focus(_ e: AXUIElement) { AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
    static func button(in win: AXUIElement, titled titles: [String]) -> AXUIElement? {
        var hit: AXUIElement?, n = 0
        walk(win, count: &n) { e, role in
            if hit == nil, role == "AXButton", let t = attr(e, "AXTitle") as? String, titles.contains(t) { hit = e }
        }
        return hit
    }

    static func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "맥", with: "mac").filter { $0.isLetter || $0.isNumber } }
    /// Sidebar session whose title is closest to `want`.
    static func session(_ win: AXUIElement, _ want: String) -> (AXUIElement, Int)? {
        let w = norm(want)
        guard w.count >= 2 else { return nil }
        var best: (AXUIElement, Int)?, n = 0
        walk(win, count: &n) { e, role in
            guard role == "AXButton", let t = attr(e, "AXTitle") as? String, !t.isEmpty,
                  !["새 세션", "이름 바꾸기", "메시지 작업", "new session", "rename"].contains(where: { t.lowercased().contains($0) }) else { return }
            let h = norm(t)
            var score: Int
            if h == w { score = 200 } else if h.hasPrefix(w) || (w.count >= 3 && h.contains(w)) { score = 150 - abs(h.count - w.count) }
            else if h.count >= 3 && w.contains(h) { score = 120 }
            else { let common = Set(w).intersection(Set(h)).count; score = common * 100 / max(Set(w).count, 1) / 2 }
            if score > (best?.1 ?? 0) { best = (e, score) }
        }
        return best.flatMap { $0.1 >= 40 ? $0 : nil }
    }
    /// The chat input ("프롬프트"/"Prompt"), otherwise the lowest text box.
    static func composer(_ win: AXUIElement) -> AXUIElement? {
        var cands: [(AXUIElement, CGFloat, Bool)] = [], n = 0
        // the input box is never inside the chat log's rows — skipping them took KakaoTalk from 10+ s to a blink (10/25)
        walk(win, count: &n, until: Date().addingTimeInterval(3), intoCells: false) { e, role in
            guard role == "AXTextArea" || role == "AXTextField", let f = frame(e) else { return }
            let ph = ((attr(e, "AXPlaceholderValue") as? String ?? "") + (attr(e, "AXDescription") as? String ?? "")).lowercased()
            cands.append((e, f.maxY, ph.contains("프롬프트") || ph.contains("prompt")))
        }
        return (cands.first { $0.2 } ?? cands.max { $0.1 < $1.1 })?.0
    }
}
