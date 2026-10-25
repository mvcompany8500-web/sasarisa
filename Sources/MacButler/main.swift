// Sasarisa — an always-listening voice assistant for macOS, powered by Claude Code.
// The assistant answers to its name, 「사사리사」 / "Sasarisa", by default (configurable: assistantName / wakeWords).
// Say the wake word, then talk. It types, clicks, opens things, and hands bigger jobs to Claude.
import AppKit
import AVFoundation
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var butler: Butler?
    var item: NSStatusItem!
    var cfg = Config()
    var statusItems: [NSMenuItem] = []
    var usageItem: NSMenuItem?
    var growthItem: NSMenuItem?
    func applicationDidFinishLaunching(_ n: Notification) {
        cfg = Config.load()
        let cfg = self.cfg
        let S = Strings(ko: cfg.ko, name: cfg.displayName)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◉" + String(cfg.assistantName.prefix(1)).uppercased()
        let menu = NSMenu()
        menu.addItem(withTitle: S.menuToggle(), action: #selector(toggle), keyEquivalent: "")
        menu.addItem(withTitle: S.menuGreet(), action: #selector(greet), keyEquivalent: "")
        menu.addItem(withTitle: S.t("설정…", "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: S.t("준비 화면…", "Setup…"), action: #selector(openSetup), keyEquivalent: "")
        menu.addItem(withTitle: S.menuFolder(), action: #selector(openFolder), keyEquivalent: "")
        menu.addItem(.separator())
        let head = NSMenuItem(title: S.menuStatus, action: nil, keyEquivalent: ""); head.isEnabled = false
        menu.addItem(head)
        for (i, _) in AppDelegate.checks.enumerated() {
            let it = NSMenuItem(title: "", action: #selector(fixPermission(_:)), keyEquivalent: ""); it.tag = i; it.target = self
            menu.addItem(it); statusItems.append(it)
        }
        if cfg.hotkey != "none" {
            let hk = NSMenuItem(title: S.hotkeyHint(cfg.hotkey == "rightCommand" ? "오른쪽 ⌘ / right ⌘" : "오른쪽 ⌥ / right ⌥"), action: nil, keyEquivalent: ""); hk.isEnabled = false
            menu.addItem(hk)
        }
        menu.addItem(.separator())
        let gi = NSMenuItem(title: "", action: nil, keyEquivalent: ""); gi.isEnabled = false; menu.addItem(gi); growthItem = gi
        let ui = NSMenuItem(title: "", action: nil, keyEquivalent: ""); ui.isEnabled = false; menu.addItem(ui); usageItem = ui
        menu.addItem(withTitle: S.t("배운 명령 모두 지우기", "Forget learned commands"), action: #selector(forgetLearned), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: S.menuQuit(), action: #selector(quit), keyEquivalent: "q")
        for i in menu.items where i.action != nil { i.target = self }
        menu.delegate = self
        item.menu = menu
        installHotkey()

        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            SFSpeechRecognizer.requestAuthorization { st in
                DispatchQueue.main.async {
                    log("permissions: mic=\(ok) speech=\(st.rawValue) accessibility=\(AXIsProcessTrusted()) screen=\(CGPreflightScreenCaptureAccess())")
                    let j = Butler(cfg: cfg)
                    self.butler = j
                    j.start()
                    SetupWindow.showIfNeeded(cfg: cfg)
                }
            }
        }
    }
    // MARK: status checklist (refreshed every time the menu opens)

    static let checks: [(key: String, pane: String)] = [
        ("mic", "Privacy_Microphone"), ("speech", "Privacy_SpeechRecognition"), ("ax", "Privacy_Accessibility"),
        ("screen", "Privacy_ScreenCapture"), ("claude", ""), ("whisper", "")]
    func menuWillOpen(_ menu: NSMenu) {
        let S = Strings(ko: cfg.ko, name: cfg.displayName)
        let ok: [Bool] = [
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            SFSpeechRecognizer.authorizationStatus() == .authorized,
            AXIsProcessTrusted(), CGPreflightScreenCaptureAccess(),
            cfg.claudeBinary != nil,
            FileManager.default.fileExists(atPath: cfg.whisperModelPath) && cfg.whisperBinary != nil]
        let names = [S.permMic, S.permSpeech, S.permAX, S.permScreen, S.depClaude, S.depWhisper]
        for (i, it) in statusItems.enumerated() { it.title = (ok[i] ? "✓  " : "✗  ") + names[i] }
        let u = Usage.today()
        growthItem?.title = S.t("📈 배운 명령 \(Learning.store.count)개 · 클로드 없이 바로 \(Growth.state.fastHits)번 · 익힌 낱말 \(Growth.state.wordsLearned.count)개",
                                "📈 \(Learning.store.count) learned · \(Growth.state.fastHits) done without Claude · \(Growth.state.wordsLearned.count) new words")
        usageItem?.title = S.t("오늘 클로드 \(u["calls"] ?? 0)번 · 토큰 \(((u["input"] ?? 0) + (u["cacheRead"] ?? 0) + (u["cacheWrite"] ?? 0) + (u["output"] ?? 0)) / 1000)천 · 배운 명령 \(Learning.store.count)개",
                               "Today: \(u["calls"] ?? 0) Claude calls · \(((u["input"] ?? 0) + (u["cacheRead"] ?? 0) + (u["cacheWrite"] ?? 0) + (u["output"] ?? 0)) / 1000)k tokens · \(Learning.store.count) learned")
    }
    @objc func fixPermission(_ sender: NSMenuItem) {
        let c = AppDelegate.checks[sender.tag]
        let url: String
        switch c.key {
        case "claude": url = "https://docs.claude.com/en/docs/claude-code/setup"
        case "whisper": NSWorkspace.shared.open(Paths.home.appendingPathComponent("models")); return
        default: url = "x-apple.systempreferences:com.apple.preference.security?" + c.pane
        }
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    /// Tap the right Option (or right Command) key alone to wake — for noisy rooms and meetings.
    /// Right ⌥ (or ⌘): tap = wake (like saying the name) · hold = push-to-talk like Handy (release runs it).
    var hotkeyDown: Date?
    var holdTimer: Timer?
    var holding = false
    func installHotkey() {
        let code: UInt16 = cfg.hotkey == "rightCommand" ? 54 : 61
        guard cfg.hotkey != "none" else { return }
        let handler: (NSEvent) -> Void = { [weak self] e in
            guard let self, e.keyCode == code else { return }
            let flag: NSEvent.ModifierFlags = code == 54 ? .command : .option
            DispatchQueue.main.async {
                if e.modifierFlags.contains(flag) {
                    self.hotkeyDown = Date()
                    self.holdTimer?.invalidate()
                    self.holdTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                        guard self.hotkeyDown != nil else { return }
                        self.holding = true; self.butler?.holdBegan()
                    }
                } else if self.hotkeyDown != nil {
                    self.hotkeyDown = nil; self.holdTimer?.invalidate()
                    if self.holding { self.holding = false; self.butler?.holdEnded() } else { self.butler?.manualWake() }
                }
            }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler)
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in   // ⌥+key combos don't count
            DispatchQueue.main.async {
                guard let self, self.hotkeyDown != nil else { return }
                self.hotkeyDown = nil; self.holdTimer?.invalidate()
                if self.holding { self.holding = false; self.butler?.holdCancelled() }
            }
        }
    }

    @objc func toggle() {
        guard let j = butler else { return }
        j.enabled.toggle()
        let ch = String(cfg.assistantName.prefix(1)).uppercased(); item.button?.title = (j.enabled ? "◉" : "○") + ch
        if !j.enabled { j.goIdle() }
    }
    @objc func greet() { butler?.greet() }
    @objc func forgetLearned() { Learning.store = [:]; Learning.save(); log("learned commands cleared") }
    @objc func openSetup() { SetupWindow.show(cfg: cfg) }
    @objc func openSettings() { SettingsWindow.show(cfg: cfg) }
    @objc func openFolder() { NSWorkspace.shared.open(Paths.home) }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ n: Notification) { butler?.shutdown() }
}

// `MacButler --echotest <file> <report>` checks that its own voice through the speakers isn't taken for yours.
if let i = CommandLine.arguments.firstIndex(of: "--echotest"), CommandLine.arguments.count > i + 2 {
    try? EchoTest.run(CommandLine.arguments[i + 1]).write(toFile: CommandLine.arguments[i + 2], atomically: true, encoding: .utf8); exit(0)
}
// `MacButler --say "text"` speaks with a fresh default config — what someone who just downloaded it hears.
if let i = CommandLine.arguments.firstIndex(of: "--say"), CommandLine.arguments.count > i + 1 {
    var c = Config(); c.language = ProcessInfo.processInfo.environment["MB_LANG"] ?? "ko"
    let v = Mouth.bestVoice(locale: c.locale)
    print("voice: \(v?.name ?? "none") · \(v?.identifier ?? "") · quality \(v?.quality.rawValue ?? 0)")
    let m = Mouth(cfg: c); var done = false; let t0 = Date()
    m.speak(CommandLine.arguments[i + 1]) { done = true }
    while !done, Date().timeIntervalSince(t0) < 30 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    print(String(format: "spoke: %@ in %.1f s", done ? "yes" : "NO", Date().timeIntervalSince(t0))); exit(done ? 0 : 1)
}
// `MacButler --route "말"` — what the fast router turns a sentence into (and how long it took).
if let i = CommandLine.arguments.firstIndex(of: "--route"), CommandLine.arguments.count > i + 1 {
    let r = Router(cfg: Config.load())
    for text in CommandLine.arguments.dropFirst(i + 1) {
        var out: String?? = .none; let t0 = Date()
        r.route(text, front: "Safari", timeout: 15) { out = .some($0) }
        while out == nil, Date().timeIntervalSince(t0) < 20 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        print(String(format: "%.1fs  %@  →  %@", Date().timeIntervalSince(t0), text, (out ?? nil) ?? "BRAIN"))
    }
    r.stop(); exit(0)
}
// `MacButler --misses` — sentences that went to Claude, grouped by verb (which quick rules to add next).
if CommandLine.arguments.contains("--misses") { print(Growth.missReport()); exit(0) }
// `MacButler --demo-frames <dir>` renders the README demo frames from the real HUD (see docs/make-demo.sh).
if let i = CommandLine.arguments.firstIndex(of: "--demo-frames"), CommandLine.arguments.count > i + 1 { DemoFrames.run(CommandLine.arguments[i + 1], en: CommandLine.arguments.dropFirst(i + 2).first == "en"); exit(0) }
// `MacButler --selftest` checks the command grammar without a microphone.
// `MacButler --settings-shot out.png` — the settings window drawn off screen, full height (to check the design).
if let i = CommandLine.arguments.firstIndex(of: "--settings-shot"), CommandLine.arguments.count > i + 1 { SettingsWindow.shot(CommandLine.arguments[i + 1]); exit(0) }
if let i = CommandLine.arguments.firstIndex(of: "--setup-shot"), CommandLine.arguments.count > i + 1 { SetupWindow.shot(CommandLine.arguments[i + 1]); exit(0) }
// `Sasarisa --polish "받아 적은 글"` tidies one line like dictation would (checks Apple Intelligence on this Mac).
if let i = CommandLine.arguments.firstIndex(of: "--polish"), CommandLine.arguments.count > i + 1 {
    let cfg = Config.load(); var out: String?
    print("available: \(Polish.available)")
    Polish.run(CommandLine.arguments[i + 1], ko: cfg.ko, words: cfg.customWords) { out = $0 }
    let t0 = Date(); while out == nil, Date().timeIntervalSince(t0) < 10 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    print(out ?? "(none)"); exit(0)
}
// `Sasarisa --hear a.wav [b.wav …]` — what the on-device recognizer writes for each file, without and with the name model.
if let i = CommandLine.arguments.firstIndex(of: "--hear"), CommandLine.arguments.count > i + 1 {
    let cfg = Config.load(), files = Array(CommandLine.arguments[(i + 1)...])
    let rec = SFSpeechRecognizer(locale: Locale(identifier: cfg.locale))!
    var model: Any?; var ready = false
    Task { model = await NameModel.prepare(names: [cfg.displayName, cfg.assistantName], locale: cfg.locale, ko: cfg.ko); ready = true }
    while !ready { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    func hear(_ f: String, _ m: Any?) -> String {
        let r = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: f)); r.requiresOnDeviceRecognition = true; r.contextualStrings = cfg.wakes
        if #available(macOS 14, *), let m = m as? SFSpeechLanguageModel.Configuration { r.customizedLanguageModel = m }
        var out: String?
        rec.recognitionTask(with: r) { res, err in if let res, res.isFinal { out = res.bestTranscription.formattedString } else if err != nil { out = "(error: \(err!.localizedDescription))" } }
        let t0 = Date(); while out == nil, Date().timeIntervalSince(t0) < 20 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        return out ?? "(none)"
    }
    print("speech auth: \(SFSpeechRecognizer.authorizationStatus().rawValue) · name model: \(model != nil)")
    for f in files { print("\(URL(fileURLWithPath: f).lastPathComponent): plain 「\(hear(f, nil))」 · with name 「\(hear(f, model))」") }
    exit(0)
}
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run() ? 0 : 1) }
// `MacButler --parse "말"` shows how a sentence would be understood (for testing the grammar).
if let i = CommandLine.arguments.firstIndex(of: "--parse") {
    let p = Parser(cfg: Config.load())
    for line in CommandLine.arguments.dropFirst(i + 1) { print("\(p.parse(p.stripWake(line), hasYouTubeList: true))  ⇐  \(line)") }
    exit(0)
}
// `MacButler --ask "말"` sends one request through the brain, no microphone — for checking a brain and its safety.
// Point MACBUTLER_HOME at a scratch folder so its tools can't reach a Sasarisa that is running.
if let i = CommandLine.arguments.firstIndex(of: "--ask"), CommandLine.arguments.count > i + 1 {
    let b = Brains.make(Config.load()); var answer: String?
    b.ask(CommandLine.arguments[i + 1], live: "", frontApp: NSWorkspace.shared.frontmostApplication?.localizedName ?? "?", context: "",
          step: { print("· \($0)") }, done: { answer = $0 })
    let t0 = Date()
    while answer == nil, Date().timeIntervalSince(t0) < 180 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    print("steps: \(b.lastCommands.joined(separator: " ; "))\n→ \(answer ?? "(no answer in 180 s)")")
    b.stop(); exit(answer == nil ? 1 : 0)
}
// `MacButler --set-key openai` stores an API key in the Keychain (read from stdin, so it never lands in shell history);
// `--forget-key openai` removes it. Providers: anthropic, openai, gemini, openrouter, groq, openai-compatible, elevenlabs.
if let i = CommandLine.arguments.firstIndex(where: { $0 == "--set-key" || $0 == "--forget-key" }), CommandLine.arguments.count > i + 1 {
    let account = CommandLine.arguments[i + 1].lowercased()
    if CommandLine.arguments[i] == "--forget-key" { Keys.remove(account); print("removed \(account)"); exit(0) }
    if isatty(0) != 0 { print("paste the \(account) key, then Enter: ", terminator: "") }
    guard let k = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { print("no key"); exit(1) }
    print(Keys.set(account, k) ? "saved \(account) (…\(k.suffix(4)))" : "couldn't save"); exit(0)
}
// `MacButler --devices` lists microphones and speakers (UIDs go into inputDevice / outputDevice).
if CommandLine.arguments.contains("--devices") {
    for d in AudioDevices.all() { print("\(d.input ? "🎤" : "  ")\(d.output ? "🔈" : "  ") \(d.name)  —  \(d.uid)") }
    exit(0)
}

// Started by Settings' restart: wait until the copy that started us has gone (it shuts its mic and Whisper first).
if let i = CommandLine.arguments.firstIndex(of: "--after"), CommandLine.arguments.count > i + 1, let old = pid_t(CommandLine.arguments[i + 1]) {
    let t0 = Date()
    while kill(old, 0) == 0, Date().timeIntervalSince(t0) < 10 { usleep(100_000) }
}

let delegate = AppDelegate()
signal(SIGTERM, SIG_IGN)   // stop Whisper / Claude children when launchd stops us
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { delegate.butler?.shutdown(); exit(0) }
termSource.resume()

let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
