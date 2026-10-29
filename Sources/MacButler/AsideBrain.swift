// Aside as the brain (aside.com, a browser rebuilt for agents) through its CLI: `aside "<task>"` runs one browser-agent
// task in your Aside app (https://docs.aside.com/help/developers). Quick commands (volume, apps, timers, YouTube …) still
// run in Sasarisa itself; what would go to Claude goes to Aside instead — good for web errands.
// Aside acts in its own browser with its own safeguards; Sasarisa's tool box guards don't reach inside it, so every
// task starts with the same rule the other brains get: never pay, send, post or delete without asking first.
// Set-up once: install the CLI (Aside → Settings → Developer, or its install script) and `aside login`.
import AppKit

final class AsideBrain: Thinker {
    private let cfg: Config
    private let strings: Strings
    private var proc: Process?
    private var out = Data(), err = Data()
    private var step: ((String) -> Void)?
    private var done: ((String) -> Void)?
    private var timeout: DispatchWorkItem?
    private var session: String?          // continue the same Aside session for follow-ups within 10 minutes
    private var lastUse = Date.distantPast
    private(set) var lastCommands: [String] = []     // Aside's steps aren't Sasarisa tool calls — nothing to learn
    init(cfg: Config) { self.cfg = cfg; self.strings = Strings(ko: cfg.ko, name: cfg.displayName) }
    var busy: Bool { done != nil }
    var installed: Bool { AsideBrain.binary != nil }

    /// The `aside` CLI: MACBUTLER_ASIDE_BIN (a custom install place), the usual install places, then Sasarisa's PATH.
    static var binary: String? {
        if let e = ProcessInfo.processInfo.environment["MACBUTLER_ASIDE_BIN"], FileManager.default.isExecutableFile(atPath: e) { return e }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fixed = ["\(home)/.aside/bin/aside", "\(home)/.local/bin/aside", "/usr/local/bin/aside", "/opt/homebrew/bin/aside",
                     "/Applications/Aside.app/Contents/MacOS/aside", "/Applications/Aside.app/Contents/Resources/bin/aside"]
        let onPath = Paths.envPath.split(separator: ":").map { "\($0)/aside" }
        return (fixed + onPath).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func warm() {}          // one process per task; nothing to keep warm

    func ask(_ command: String, live: String, frontApp: String, context: String, step: @escaping (String) -> Void, done: @escaping (String) -> Void) {
        guard let bin = AsideBrain.binary else {
            done(cfg.ko ? "Aside 명령줄 도구가 없어요. Aside 설정의 개발자 메뉴에서 설치하고 aside login 을 한 번 해 주세요."
                        : "The Aside CLI isn't installed. Install it from Aside's developer settings, then run aside login once.")
            return
        }
        let rule = cfg.ko
            ? "[맥 음성 비서 사사리사가 맡긴 일] 결제·구매·메시지 보내기·게시·지우기는 하지 말고 그 직전에 멈춰서 물어본다. 끝나면 한국어로 소리 내어 읽을 1~3문장만 답한다."
            : "[A task from Sasarisa, a voice assistant] Never pay, buy, send a message, post or delete — stop right before and ask. When done, answer in 1–3 short sentences to be read aloud."
        let task = rule + "\n" + Brain.turnText(cfg, command, live: live, frontApp: frontApp, context: context)
        var args = [String]()
        if let s = session, Date().timeIntervalSince(lastUse) < 600 { args += ["--session", s] }
        args.append(task)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.currentDirectoryURL = Paths.home.appendingPathComponent("work")
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Paths.envPath; env["NO_COLOR"] = "1"
        p.environment = env
        let o = Pipe(), e = Pipe()
        p.standardInput = FileHandle.nullDevice; p.standardOutput = o; p.standardError = e
        out = Data(); err = Data()
        o.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }   // end of output: stop, or it is called again and again (10/29: a busy loop after every turn)
            DispatchQueue.main.async { self?.feed(d) }
        }
        e.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }   // end of output: stop, or it is called again and again (10/29: a busy loop after every turn)
            DispatchQueue.main.async { self?.err.append(d) }
        }
        p.terminationHandler = { [weak self] dead in
            DispatchQueue.main.async {
                guard let self, self.proc === dead else { return }
                self.proc = nil
                self.finish(code: dead.terminationStatus)
            }
        }
        self.step = step; self.done = done; lastCommands = []
        do { try p.run() } catch { log("aside failed to start: \(error)"); self.step = nil; self.done = nil; done(strings.failed); return }
        proc = p
        step(cfg.ko ? "Aside가 하는 중" : "Aside is on it")
        // A browser errand can take a while, but never forever.
        let t = DispatchWorkItem { [weak self] in
            guard let self, self.done != nil else { return }
            log("aside timed out"); self.proc?.terminate()
        }
        timeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 360, execute: t)
        log("aside ← \(command)")
    }

    /// Progress lines from the CLI show on the HUD as they come.
    private func feed(_ d: Data) {
        out.append(d)
        guard let s = String(data: d, encoding: .utf8) else { return }
        for line in s.split(whereSeparator: \.isNewline).map({ AsideBrain.clean(String($0)) }) where !line.isEmpty {
            if let id = AsideBrain.sessionID(line) { session = id }
            step?(String(line.prefix(60)))
        }
    }

    private func finish(code: Int32) {
        timeout?.cancel(); timeout = nil
        guard let d = done else { return }
        done = nil; step = nil; lastUse = Date()
        let text = AsideBrain.clean(String(data: out, encoding: .utf8) ?? "")
        if let id = AsideBrain.sessionID(text) { session = id }
        let answer = AsideBrain.answer(text)
        if !answer.isEmpty { d(answer); return }
        let why = (String(data: err, encoding: .utf8) ?? "").lowercased()
        log("aside exit \(code): \(why.prefix(300))")
        if why.contains("login") || why.contains("sign in") || why.contains("auth") || why.contains("unauthorized") {
            d(cfg.ko ? "Aside 로그인이 필요해요. 터미널에서 aside login 을 한 번 해 주세요." : "Aside needs you to sign in — run aside login once in Terminal.")
        } else {
            d(strings.failed)
        }
    }

    /// The part to read aloud: the last paragraph of what the CLI printed, without session/status lines.
    static func answer(_ text: String) -> String {
        let blocks = text.components(separatedBy: "\n\n").map { block in
            block.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("session") }
        }.filter { !$0.isEmpty }
        let s = (blocks.last ?? []).joined(separator: " ")
        return s.count > 400 ? String(s.prefix(400)) + "…" : s
    }
    /// ANSI colors and spinner characters out.
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\u{2800}-\u{28FF}]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// "session: abc123" / "Session ID abc123" / "--session abc123" → abc123
    static func sessionID(_ s: String) -> String? {
        guard let r = s.range(of: #"(?i)session(?:[ _-]?id)?[:=\s]+([A-Za-z0-9_-]{6,})"#, options: .regularExpression) else { return nil }
        let m = String(s[r])
        return m.range(of: #"[A-Za-z0-9_-]{6,}$"#, options: .regularExpression).map { String(m[$0]) }
    }

    func stop() { proc?.terminate(); proc = nil }
    func cancel(silently: Bool) {
        guard done != nil else { return }
        if silently { done = nil; step = nil }
        timeout?.cancel(); timeout = nil
        let p = proc; proc = nil; p?.terminate()
        if let d = done { done = nil; step = nil; d(strings.stopped) }
    }
}
