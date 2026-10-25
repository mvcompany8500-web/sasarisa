// jax — press buttons / links / text fields of the frontmost app by name, without moving the mouse (Accessibility).
//   jax list [filter]            list pressable things (role | name)
//   jax tap "name" [n]           press the n-th (default 1) element whose name contains the text
//   jax field "field name" "text"  focus a text field and type into it (visibly, via Sasarisa)
//   jax key cmd+t | enter | esc …  press a key / shortcut
//   jax front                      frontmost app, window title, and (browsers) the address bar
//   jax volume 0-100               set the output volume
//   jax open-app "Name"            open an app            jax open-url https://…   open a web page
//   jax screenshot                 → /tmp/macbutler/screen.png (1280 px wide) for the assistant to look at
//   jax click X Y                  press whatever is at that point (pointer snaps back)
//   jax kind "button name"         (tests) send / pay / post / delete, or - — those buttons wait for the user's yes
// With MACBUTLER_SAFE=1 (set by Sasarisa's brain in safe mode) nothing is pressed, typed or opened in
// protected apps: terminals, code editors, Claude, System Settings, Keychain, password managers, permission prompts.
import AppKit
import ApplicationServices

/// Sends "<cmd>\n<text>" to the running Sasarisa over its private socket (~/.macbutler/butler.sock) and returns its
/// one-line answer ("ok", or "yes"/"ask" for confirm), or nil when Sasarisa isn't running.
@discardableResult func butlerSend(_ cmd: String, _ text: String) -> String? {
    let p = butlerHome + "/butler.sock"
    let s = socket(AF_UNIX, SOCK_STREAM, 0)
    guard s >= 0 else { return nil }
    defer { close(s) }
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(p.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = b }; raw[bytes.count] = 0 }
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard ok == 0 else { return nil }
    let msg = Array((cmd + "\n" + text).utf8)
    _ = msg.withUnsafeBytes { write(s, $0.baseAddress, msg.count) }
    shutdown(s, SHUT_WR)
    var b = [UInt8](repeating: 0, count: 64); let n = read(s, &b, 64)
    return n > 0 ? String(decoding: b[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""
}
let butlerHome = ProcessInfo.processInfo.environment["MACBUTLER_HOME"].map { ($0 as NSString).expandingTildeInPath } ?? (NSHomeDirectory() + "/.macbutler")

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func frame(_ e: AXUIElement) -> CGRect? {
    var p = CGPoint.zero, s = CGSize.zero
    guard let pv = attr(e, "AXPosition"), let sv = attr(e, "AXSize") else { return nil }
    AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}
func label(_ e: AXUIElement) -> String {
    for k in ["AXTitle", "AXDescription", "AXValue", "AXPlaceholderValue", "AXHelp"] {
        if let s = attr(e, k) as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    // text inside a link
    var out = ""
    for c in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] {
        if let s = attr(c, "AXValue") as? String ?? attr(c, "AXTitle") as? String { out += s + " " }
        if out.count > 80 { break }
    }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}
let safe = ProcessInfo.processInfo.environment["MACBUTLER_SAFE"] == "1"
let protectedApps: Set<String> = [
    "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
    "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby",
    "com.apple.ScriptEditor2", "com.apple.Automator", "com.apple.shortcuts", "com.apple.systempreferences",
    "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.SecurityAgent", "com.apple.UserNotificationCenter",
    "com.apple.coreservices.uiagent", "com.apple.installer", "com.apple.dt.Xcode", "com.apple.Console",
    "com.anthropic.claudefordesktop", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
    "com.1password.1password", "com.bitwarden.desktop"]
func guardApp(_ bundle: String?, _ name: String?) {
    let own = ProcessInfo.processInfo.environment["MACBUTLER_BUNDLE"]
    if safe, let b = bundle, protectedApps.contains(b) || b == own {
        print("blocked: \(name ?? b) is protected in safe mode — ask the user to do this, or delegate to a Claude session"); exit(3)
    }
}
/// Everything it presses, types or opens goes into ~/.macbutler/logs/actions.log (owner-only) — "what did it do today".
func record(_ what: String) {
    let dir = butlerHome + "/logs", path = dir + "/actions.log"
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date()))  \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")  \(what)\n"
    if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 2_000_000,
       let old = try? String(contentsOfFile: path, encoding: .utf8) { try? String(old.suffix(500_000)).write(toFile: path, atomically: true, encoding: .utf8) }
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
    }
}

/// Buttons that can't be taken back: sending, paying, posting, deleting. In safe mode the brain can't press them on its
/// own, whatever model it is: Sasarisa checks that the user asked for exactly that ("카톡 보내", "결제해") and
/// otherwise asks out loud, then presses it itself after a yes.
let irreversible: [(kind: String, words: [String])] = [
    ("send", ["보내기", "보내", "전송", "send"]),
    ("pay", ["결제", "구매", "구입", "주문하기", "송금", "이체", "pay", "buy", "purchase", "checkout", "placeorder"]),
    ("post", ["게시", "올리기", "업로드", "post", "publish", "upload", "tweet"]),
    ("delete", ["삭제", "지우기", "휴지통비우기", "delete", "emptytrash"])]
let browsing = ["게시판", "게시물", "게시글", "주문내역", "구매내역", "결제내역", "결제수단", "보낸편지함", "보낸메일", "보낸항목", "sent", "posts"]
func irreversibleKind(_ name: String) -> String? {
    let n = name.lowercased().filter { $0.isLetter || $0.isNumber }
    guard !n.isEmpty, n.count <= 24, !browsing.contains(where: n.contains) else { return nil }
    return irreversible.first { $0.words.contains(where: n.contains) }?.kind
}
/// In these apps Enter sends the message.
let messengers: Set<String> = ["com.kakao.KakaoTalkMac", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "ru.keepcoder.Telegram",
    "org.telegram.desktop", "com.hnc.Discord", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "jp.naver.line.mac", "com.facebook.archon",
    "com.microsoft.teams2", "com.apple.mail", "com.microsoft.Outlook"]
func confirmIrreversible(_ kind: String, _ what: String, replay: [String]) {
    guard safe, ProcessInfo.processInfo.environment["MACBUTLER_CONFIRMED"] != "1" else { return }
    let b = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    let answer = butlerSend("confirm", ([kind, b, what] + replay).joined(separator: "\u{1F}"))
    if answer == "yes" { return }
    record("held for a yes: \(what)")
    print("waiting: \(what) is a \(kind) action, so Sasarisa is asking the user first. Answer with ONE short question " +
          "(e.g. 「보낼까요?」 / \"Send it?\"). If they say yes, Sasarisa presses it itself — don't press it again.")
    exit(4)
}
func appBundle(pid: pid_t) -> (String?, String?) { let a = NSRunningApplication(processIdentifier: pid); return (a?.bundleIdentifier, a?.localizedName) }

let clickable: Set<String> = ["AXButton", "AXLink", "AXMenuItem", "AXTab", "AXRadioButton", "AXCheckBox", "AXPopUpButton", "AXCell", "AXRow", "AXMenuButton", "AXDisclosureTriangle"]
let fields: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser", "org.mozilla.firefox",
    "com.naver.Whale", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"]
/// Keys send and submit too: Enter in a messenger, ⌘/⌃+Enter anywhere (Gmail, Slack…), ⌘⇧D in Mail, Enter in a browser
/// field that isn't a search or address box (it submits the form), and Enter/Space on a focused send/pay/post/delete button.
func keyKind(_ code: CGKeyCode, _ flags: CGEventFlags, _ k: String, _ app: NSRunningApplication?) -> (kind: String, what: String)? {
    let b = app?.bundleIdentifier ?? "", name = app?.localizedName ?? b
    if b == "com.apple.mail", k == "cmd+shift+d" { return ("send", "\(k) in Mail (sends the mail)") }
    guard code == 36 || code == 76 || code == 49 else { return nil }          // return, keypad enter, space
    let enter = code != 49
    var f: CFTypeRef?
    if let app { AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute as CFString, &f) }
    let fe = f.map { $0 as! AXUIElement }
    let role = fe.flatMap { attr($0, "AXRole") as? String } ?? ""
    if let fe, clickable.contains(role), let kind = irreversibleKind(label(fe)) { return (kind, "\(k) on \"\(label(fe).prefix(40))\" in \(name)") }
    guard enter else { return nil }
    if messengers.contains(b) { return ("send", "\(k) in \(name) (sends the message)") }
    if flags.contains(.maskCommand) || flags.contains(.maskControl) { return ("send", "\(k) in \(name) (usually sends)") }
    if browsers.contains(b), let fe, fields.contains(role) {
        let about = ["AXDescription", "AXPlaceholderValue", "AXTitle", "AXHelp", "AXSubrole", "AXRoleDescription"]
            .compactMap { attr(fe, $0) as? String }.joined(separator: " ").lowercased()
        let searchy = role == "AXSearchField" || ["검색", "search", "주소", "address", "url", "찾기", "find"].contains(where: about.contains)
        if !searchy { return ("send", "\(k) in a form field in \(name) (submits it)") }
    }
    return nil
}

guard let front = NSWorkspace.shared.frontmostApplication else { print("no frontmost app"); exit(1) }
/// After an action: what's in front now — so the brain sees the result without a screenshot.
/// e.g. "now: Safari — \"터틀메이커 - YouTube\" (was Safari — \"YouTube\")"
func nowLine(was: String) -> String {
    usleep(450_000)
    guard let fa = NSWorkspace.shared.frontmostApplication else { return "" }
    let ax = AXUIElementCreateApplication(fa.processIdentifier)
    var w: CFTypeRef?; AXUIElementCopyAttributeValue(ax, "AXFocusedWindow" as CFString, &w)
    var t: CFTypeRef?; if let w { AXUIElementCopyAttributeValue(w as! AXUIElement, "AXTitle" as CFString, &t) }
    let now = "\(fa.localizedName ?? "?") — \"\(((t as? String) ?? "").prefix(80))\""
    return now == was ? "\nnow: unchanged (\(now))" : "\nnow: \(now) (was \(was))"
}
func frontNow() -> String {
    guard let fa = NSWorkspace.shared.frontmostApplication else { return "" }
    let ax = AXUIElementCreateApplication(fa.processIdentifier)
    var w: CFTypeRef?; AXUIElementCopyAttributeValue(ax, "AXFocusedWindow" as CFString, &w)
    var t: CFTypeRef?; if let w { AXUIElementCopyAttributeValue(w as! AXUIElement, "AXTitle" as CFString, &t) }
    return "\(fa.localizedName ?? "?") — \"\(((t as? String) ?? "").prefix(80))\""
}

// Commands that don't need the element tree
let args0 = Array(CommandLine.arguments.dropFirst())
if args0.first == "kind", args0.count >= 2 { print(irreversibleKind(args0[1]) ?? "-"); exit(0) }   // for tests: is this button irreversible?
if args0.first == "open-url", args0.count >= 2 {
    guard let u = URL(string: args0[1]), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { print("only http(s) URLs"); exit(2) }
    NSWorkspace.shared.open(u); record("open-url \(u.absoluteString)"); print("opened \(u.absoluteString)"); exit(0)
}
if args0.first == "open-app", args0.count >= 2 {
    let want = args0.dropFirst().joined(separator: " ").lowercased().replacingOccurrences(of: ".app", with: "")
    var found: URL?
    for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities", NSHomeDirectory() + "/Applications"] {
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".app") {
            let u = URL(fileURLWithPath: dir).appendingPathComponent(f)
            let names = [String(f.dropLast(4)), FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")].map { $0.lowercased() }
            if names.contains(want) { found = u; break }
        }
        if found != nil { break }
    }
    guard let app = found else { print("app not found: \(want)"); exit(2) }
    // Bringing the Claude app to the front is fine (10/25: 「독의 클로드 눌러」 was refused) — pressing or typing inside it stays blocked.
    if Bundle(url: app)?.bundleIdentifier != "com.anthropic.claudefordesktop" { guardApp(Bundle(url: app)?.bundleIdentifier, app.lastPathComponent) }
    let sem = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in sem.signal() }
    _ = sem.wait(timeout: .now() + 5); record("open-app \(app.lastPathComponent)"); print("opened \(app.lastPathComponent)"); exit(0)
}
if args0.first == "screenshot" {
    let dir = "/tmp/macbutler"; try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let f = dir + "/screen.png"
    for (tool, args) in [("/usr/sbin/screencapture", ["-x", f]), ("/usr/bin/sips", ["-Z", "1280", f])] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; try? p.run(); p.waitUntilExit()
    }
    let w = NSScreen.main?.frame.width ?? 1280
    print("\(f)  (1 px = \(String(format: "%.2f", w / 1280)) pt; multiply image x/y by that for jax click)"); exit(0)
}
if args0.first == "click", args0.count >= 3, let x = Double(args0[1]), let y = Double(args0[2]) {
    var el: AXUIElement?
    AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(x), Float(y), &el)
    var pid: pid_t = 0
    if let el { AXUIElementGetPid(el, &pid) }
    let (b, n) = appBundle(pid: pid); guardApp(b, n)
    if let el, let k = irreversibleKind(label(el)) { confirmIrreversible(k, "\"\(label(el).prefix(40))\" in \(n ?? "?")", replay: args0) }
    record("click \(Int(x)),\(Int(y)) \(el.map { label($0).prefix(40) } ?? "")")
    if let el, AXUIElementPerformAction(el, kAXPressAction as CFString) == .success { print("pressed at \(Int(x)),\(Int(y)) in \(n ?? "?")"); exit(0) }
    let c = Process(); c.executableURL = URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/cliclick") ? "/opt/homebrew/bin/cliclick" : "/usr/local/bin/cliclick")
    c.arguments = ["-r", "c:\(Int(x)),\(Int(y))"]; try? c.run(); c.waitUntilExit(); print("clicked \(Int(x)),\(Int(y)) in \(n ?? "?")"); exit(0)
}
if args0.first == "key", args0.count >= 2 {
    let fa = NSWorkspace.shared.frontmostApplication; guardApp(fa?.bundleIdentifier, fa?.localizedName)
    let names: [String: CGKeyCode] = ["enter": 36, "return": 36, "tab": 48, "space": 49, "delete": 51, "esc": 53, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126, "pageup": 116, "pagedown": 121, "home": 115, "end": 119,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, ",": 43, ".": 47, "/": 44, "[": 33, "]": 30, "=": 24, "-": 27]
    var flags: CGEventFlags = []; var code: CGKeyCode?
    for part in args0[1].lowercased().split(separator: "+").map(String.init) {
        switch part {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt", "option", "alt": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        default: code = names[part]
        }
    }
    guard let code else { print("unknown key: \(args0[1])"); exit(2) }
    let k = args0[1].lowercased()
    if let g = keyKind(code, flags, k, fa) { confirmIrreversible(g.kind, g.what, replay: args0) }
    record("key \(k)")
    let was = frontNow()
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] { let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down); e?.flags = flags; e?.post(tap: .cghidEventTap) }
    print("pressed \(args0[1])" + nowLine(was: was)); exit(0)
}
if args0.first == "volume", args0.count >= 2, let v = Int(args0[1]), (0...100).contains(v) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = ["-e", "set volume output volume \(v)"]
    try? p.run(); p.waitUntilExit(); record("volume \(v)"); print("volume \(v)"); exit(0)
}
let app = AXUIElementCreateApplication(front.processIdentifier)
AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
usleep(120_000)
guard let w = attr(app, "AXFocusedWindow") ?? (attr(app, "AXWindows") as? [AXUIElement])?.first as AnyObject? else { print("no window"); exit(1) }
let win = w as! AXUIElement

var items: [(AXUIElement, String, String, CGRect)] = []
var n = 0
// A chat window with thousands of bubbles took over 25 s and the call failed (KakaoTalk, 10/25): 4 s, then work with what's found.
let walkUntil = Date().addingTimeInterval(4)
var walkCut = false
func walk(_ e: AXUIElement, _ d: Int) {
    n += 1
    if d > 60 || n > 15000 { return }
    if Date() > walkUntil { walkCut = true; return }
    let role = attr(e, "AXRole") as? String ?? ""
    if clickable.contains(role) || fields.contains(role), let f = frame(e), f.width > 2, f.height > 2 {
        let l = label(e)
        if !l.isEmpty || fields.contains(role) { items.append((e, role, l, f)) }
    }
    for c in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] { walk(c, d + 1) }
}
walk(win, 0)

func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
func pick(_ q: String, _ idx: Int, _ pool: [(AXUIElement, String, String, CGRect)]) -> (AXUIElement, String, String, CGRect)? {
    let w = norm(q)
    let exact = pool.filter { norm($0.2) == w }
    let pre = pool.filter { norm($0.2).hasPrefix(w) && norm($0.2) != w }
    let has = pool.filter { norm($0.2).contains(w) && !norm($0.2).hasPrefix(w) }
    let all = exact + pre + has
    return idx - 1 < all.count ? all[idx - 1] : nil
}
func press(_ e: AXUIElement, _ f: CGRect) -> Bool {
    if AXUIElementPerformAction(e, kAXPressAction as CFString) == .success { return true }
    // Only if AXPress is unsupported: click and put the pointer straight back (barely visible)
    let c = Process(); c.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/cliclick")
    c.arguments = ["-r", "c:\(Int(f.midX)),\(Int(f.midY))"]; try? c.run(); c.waitUntilExit()
    return true
}

let a = Array(CommandLine.arguments.dropFirst())
switch a.first ?? "list" {
case "front":
    let title = attr(win, "AXTitle") as? String ?? ""
    let url = items.first { fields.contains($0.1) && ($0.2.lowercased().contains("address") || $0.2.contains("주소") || $0.2.contains("검색")) }
    print("app: \(front.localizedName ?? "")\nwindow: \(title)" + (url.map { "\naddress: " + ((attr($0.0, "AXValue") as? String) ?? "") } ?? ""))
case "tap":
    guardApp(front.bundleIdentifier, front.localizedName)
    guard a.count >= 2 else { print("jax tap \"name\" [n]"); exit(1) }
    let pool = items.filter { clickable.contains($0.1) }
    guard let hit = pick(a[1], a.count >= 3 ? Int(a[2]) ?? 1 : 1, pool) else { print("not found: \(a[1]) (\(pool.count) candidates — try jax list)"); exit(2) }
    if let k = irreversibleKind(hit.2) { confirmIrreversible(k, "\"\(hit.2.prefix(40))\" in \(front.localizedName ?? "?")", replay: a) }
    record("tap \(hit.1.replacingOccurrences(of: "AX", with: "")) \"\(hit.2.prefix(60))\"")
    let was = frontNow()
    _ = press(hit.0, hit.3)
    print("pressed: \(hit.1) \"\(hit.2.prefix(60))\"" + nowLine(was: was))
case "field":
    guardApp(front.bundleIdentifier, front.localizedName)
    guard a.count >= 3 else { print("jax field \"field name\" \"text\""); exit(1) }
    let pool = items.filter { fields.contains($0.1) }
    let hit = a[1].isEmpty ? pool.first : (pick(a[1], 1, pool) ?? pool.first)
    guard let hit else { print("no text field"); exit(2) }
    if safe, (attr(hit.0, "AXSubrole") as? String) == "AXSecureTextField" {
        print("blocked: that's a password field — passwords are filled by the browser or Keychain, never typed by the assistant"); exit(3)
    }
    record("field \"\(hit.2.prefix(40))\" ← \(a[2].count) chars")
    AXUIElementSetAttributeValue(hit.0, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(150_000)
    let text = a[2]
    _ = butlerSend("type", text)
    usleep(useconds_t(min(Double(text.count) * 0.03 + 0.3, 6) * 1_000_000))
    print("typed \(text.count) chars into \"\(hit.2.prefix(40))\"")
default:
    let f = a.count >= 2 ? norm(a[1]) : ""
    let shown = items.filter { f.isEmpty || norm($0.2).contains(f) }.prefix(f.isEmpty ? 80 : 150)
    print("\(front.localizedName ?? "") · \(items.count) elements (showing \(shown.count))" + (walkCut ? " — big window: stopped reading after 4 s, so some may be missing (try a filter, or screenshot)" : ""))
    for (i, it) in shown.enumerated() { print("\(i + 1). \(it.1.replacingOccurrences(of: "AX", with: "")) | \(it.2.prefix(70))") }
}
