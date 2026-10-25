// The brain: one long-lived Claude Code process (`claude -p` with stream-json in/out).
// Keeping it warm removes the 2–4 s start-up on every command.
import AppKit

final class Brain {
    private let cfg: Config
    private let strings: Strings
    private var proc: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var step: ((String) -> Void)?
    private var done: ((String) -> Void)?
    private var finalTimer: DispatchWorkItem?
    private var pendingText: String?
    private var sent = 0, received = 0
    private var lastUse = Date()
    private(set) var lastCommands: [String] = []     // tool steps of the last finished turn as jax lines (for learning)
    private var turnCommands: [String] = []
    init(cfg: Config) { self.cfg = cfg; self.strings = Strings(ko: cfg.ko, name: cfg.displayName) }
    var busy: Bool { done != nil }
    var installed: Bool { cfg.claudeBinary != nil }

    func systemPrompt() -> String { Brain.systemPrompt(cfg) }
    /// System prompt: ~/.macbutler/prompt.md if present, otherwise the bundled template for the language.
    static func systemPrompt(_ cfg: Config) -> String {
        let user = Paths.home.appendingPathComponent("prompt.md")
        let bundled = Paths.resources.appendingPathComponent("prompts/prompt.\(cfg.ko ? "ko" : "en").md")
        var s = (try? String(contentsOf: user, encoding: .utf8)) ?? (try? String(contentsOf: bundled, encoding: .utf8)) ?? "You are {assistant}, a voice assistant for {user}."
        if !cfg.ko, cfg.lang != "en" { s += "\n\nAlways answer in \(cfg.languageName) — the language {user} speaks." }
        // How boldly it acts: "never" (default) = do it right away, like a car assistant; otherwise ask when unsure.
        let instant = cfg.confirmDelegate == "never"
        let askRule = instant
            ? (cfg.ko ? "- **되묻지 말고 바로 한다.** 말이 짧거나 애매해도 지금 화면·방금 한 일에 비춰 가장 그럴듯한 뜻으로 실행하고, 한 일을 말한다. 틀렸으면 {user}이 「아니」 하고 바로잡는다. 되묻는 건 지우기·보내기·결제처럼 되돌릴 수 없는 일뿐."
                      : "- **Act, don't ask.** If the request is short or vague, do the most likely thing given the screen and what was just done, then say what you did — {user} will say \"no\" if it was wrong. Ask first only before something irreversible (deleting, sending, paying).")
            : (cfg.ko ? "- 뜻이 둘로 갈리면 실행하기 전에 질문 하나로 묻는다(물음표로 끝나면 바로 대답할 수 있다). 분명하면 바로 한다."
                      : "- If the request could mean two different things, ask one short question before acting. If it's clear, just do it.")
        // Hand-offs from the brain always wait for the user's yes (see Butler.delegateFromBrain), in every mode.
        let delegateRule = cfg.freeMode
            ? (cfg.ko ? "자유 모드라 이 명령은 바로 그 세션에 들어간다 — 「○○에 맡겼습니다」처럼 짧게 말한다." : "Free mode: it goes into that session right away — say briefly that you handed it over.")
            : cfg.ko ? "이 명령은 바로 넘기지 않고 {user}의 「응」을 기다린다 — 답은 「○○에 이렇게 맡길까요?」 질문 한 문장으로 하고, 맡겼다고 말하지 않는다."
                                  : "It is NOT sent yet — the assistant waits for {user} to say yes, so your answer must be one question like \"Shall I hand this to …?\" and never claim it was done."
        s = s.replacingOccurrences(of: "{askRule}", with: askRule).replacingOccurrences(of: "{delegateRule}", with: delegateRule)
        s += Memory.promptBlock(ko: cfg.ko)
        let scr = NSScreen.main?.frame.size ?? .zero
        s = s.replacingOccurrences(of: "{screen}", with: "\(Int(scr.width))×\(Int(scr.height))")
        return cfg.fill(s)
    }

    /// What the brain may do. A voice assistant hears TVs, videos and web pages, so by default it gets only Sasarisa's
    /// tool box (the `butler` MCP server: press/type/open/look, each one guarded) and web search. No shell at all, no file
    /// reads or writes, no fetching arbitrary URLs, no other MCP servers, and the user's own Claude settings (which may
    /// allow much more) are not loaded. Anything else is denied automatically.
    static func permissionArgs(_ access: String) -> [String] {
        let mcp = ["--strict-mcp-config", "--mcp-config", mcpConfig(safe: access != "full")]
        if access == "full" {
            return mcp + ["--tools", "Bash,Read,Glob,Grep,WebSearch,WebFetch", "--disable-slash-commands",
                    "--allowedTools", "mcp__butler,Bash,Read,Glob,Grep,WebSearch,WebFetch", "--disallowedTools", "SendMessage,ToolSearch,Task,Agent"]
        }
        let deny = ["Bash", "Read", "Write", "Edit", "NotebookEdit", "WebFetch", "Glob", "Grep", "SendMessage", "ToolSearch", "Task", "Agent"]
        // Only the tools it uses are even described to it (fewer tokens a turn, faster); no skill list.
        return mcp + ["--setting-sources", "project", "--permission-mode", "default",
                "--tools", "WebSearch", "--disable-slash-commands",
                "--allowedTools", "mcp__butler,WebSearch", "--disallowedTools", deny.joined(separator: ",")]
    }
    /// The tool box as an MCP server. The safe-mode flags are fixed here, where the brain can't change them.
    static func mcpConfig(safe: Bool) -> String {
        var env = ["MACBUTLER_HOME": Paths.home.path, "MACBUTLER_BUNDLE": Bundle.main.bundleIdentifier ?? "",
                   "MACBUTLER_VERSION": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""]
        if safe { env["MACBUTLER_SAFE"] = "1" }
        let cfg: [String: Any] = ["mcpServers": ["butler": ["type": "stdio", "command": Paths.tools.appendingPathComponent("butler-mcp").path, "args": [String](), "env": env]]]
        return (try? JSONSerialization.data(withJSONObject: cfg)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    /// A tool-box call written as the equivalent jax line, so learning and 「창 다 꺼」 bookkeeping work the same for every brain.
    static func commandLine(_ tool: String, _ a: [String: Any]) -> String {
        func q(_ k: String) -> String {
            let v = (a[k] as? String) ?? (a[k] as? NSNumber)?.stringValue ?? ""
            return v.contains("\"") ? "'\(v)'" : "\"\(v)\""
        }
        switch tool {
        case "tap": return "jax tap \(q("name"))" + (a["n"] != nil ? " \(q("n"))" : "")
        case "field": return "jax field \(q("field")) \(q("text"))"
        case "type": return "jtype \(q("text"))"
        case "key": return "jax key \(q("keys"))"
        case "volume": return "jax volume \(q("level"))"
        case "open_app": return "jax open-app \(q("name"))"
        case "open_url": return "jax open-url \(q("url"))"
        case "click": return "jax click \(q("x")) \(q("y"))"
        case "list", "front", "screenshot": return "jax \(tool)"
        case "now": return "date"
        default: return "butler \(tool)"          // delegate, switch_session: never learned
        }
    }
    func stepLabel(_ tool: String, _ a: [String: Any]) -> String { Brain.stepLabel(cfg, tool, a) }
    /// What the HUD shows while a tool runs.
    static func stepLabel(_ cfg: Config, _ tool: String, _ a: [String: Any]) -> String {
        let v = { (k: String) in ((a[k] as? String) ?? (a[k] as? NSNumber)?.stringValue ?? "").prefix(40) }
        let ko = cfg.ko
        switch tool {
        case "tap": return ko ? "「\(v("name"))」 누르는 중" : "Pressing “\(v("name"))”"
        case "field", "type": return ko ? "입력하는 중" : "Typing"
        case "key": return ko ? "\(v("keys")) 누르는 중" : "Pressing \(v("keys"))"
        case "open_app": return ko ? "\(v("name")) 여는 중" : "Opening \(v("name"))"
        case "open_url": return ko ? "\(URL(string: String(v("url")))?.host ?? "페이지") 여는 중" : "Opening \(URL(string: String(v("url")))?.host ?? "the page")"
        case "list", "front": return ko ? "화면 살펴보는 중" : "Looking at the screen"
        case "screenshot": return ko ? "화면 보는 중" : "Looking at the screen"
        case "click": return ko ? "누르는 중" : "Pressing"
        case "volume": return ko ? "소리 조절 중" : "Setting the volume"
        case "delegate": return ko ? "클로드에 맡기는 중" : "Handing to Claude"
        default: return Strings(ko: ko, name: cfg.displayName).working
        }
    }

    func warm() { ensure() }
    private func ensure() {
        // Fresh process before the context gets heavy: a turn at ~100k tokens took 32 s, at ~15k about 7 s.
        if let p = proc, p.isRunning, sent < 8, Usage.lastContext < 60_000, Date().timeIntervalSince(lastUse) < 1800 { return }
        if let p = proc, p.isRunning, done != nil { return }   // never swap while working
        proc?.terminate()
        guard let bin = cfg.claudeBinary else { log("claude not found"); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                       "--model", cfg.claudeModel, "--append-system-prompt", systemPrompt()] + Brain.permissionArgs(cfg.brainAccess)
        p.currentDirectoryURL = Paths.home.appendingPathComponent("work")
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Paths.envPath
        if cfg.brainAccess != "full" { env["MACBUTLER_SAFE"] = "1"; env["MACBUTLER_BUNDLE"] = Bundle.main.bundleIdentifier ?? "" }
        p.environment = env
        let inPipe = Pipe(), out = Pipe()
        p.standardInput = inPipe; p.standardOutput = out; p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { return }
            DispatchQueue.main.async { self?.feed(d) }
        }
        p.terminationHandler = { [weak self] dead in
            DispatchQueue.main.async {
                guard let self, self.proc === dead else { return }
                self.proc = nil
                if self.done != nil { self.finish(self.strings.failed) }
            }
        }
        do { try p.run() } catch { log("claude failed to start: \(error)"); return }
        proc = p; stdin = inPipe.fileHandleForWriting
        sent = 0; received = 0; buffer = Data()
        log("brain warm")
    }
    private func feed(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(obj) }
        }
    }
    private func handle(_ obj: [String: Any]) {
        let type = obj["type"] as? String
        if type == "rate_limit_event" { AIUsage.noteClaude(obj); return }
        if type == "result" {
            Usage.record(obj)
            received += 1
            if received == sent, done != nil { finish((obj["result"] as? String) ?? pendingText ?? "") }
            return
        }
        guard done != nil, received == sent - 1 else { return }   // ignore the tail of an older turn
        guard type == "assistant", let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
        let tools = content.filter { $0["type"] as? String == "tool_use" }
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        if !tools.isEmpty {
            finalTimer?.cancel(); pendingText = nil
            for c in tools {
                let inp = c["input"] as? [String: Any] ?? [:], name = c["name"] as? String ?? ""
                if name.hasPrefix("mcp__butler__") {
                    let t = String(name.dropFirst("mcp__butler__".count))
                    turnCommands.append(Brain.commandLine(t, inp)); log("brain(claude) tool: \(Brain.commandLine(t, inp).prefix(160))"); step?(stepLabel(t, inp)); continue
                }
                if name == "Bash", let cmd = inp["command"] as? String { turnCommands.append(cmd) }
                step?((inp["description"] as? String) ?? strings.toolNames[name] ?? strings.working)
            }
        } else if !text.isEmpty {
            // Text with no tool call is almost always the final answer — speak it now instead of
            // waiting 1–2 s for the turn summary. If a tool call follows within 0.35 s, cancel.
            pendingText = text
            finalTimer?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.finish(text) }
            finalTimer = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
        }
    }
    private func finish(_ r: String) {
        finalTimer?.cancel(); finalTimer = nil; pendingText = nil
        guard let d = done else { return }
        done = nil; step = nil; lastUse = Date()
        lastCommands = turnCommands; turnCommands = []
        let t = r.trimmingCharacters(in: .whitespacesAndNewlines)
        d(t.isEmpty ? strings.failed : t)
    }

    func ask(_ command: String, live: String = "", frontApp: String, context: String = "", step: @escaping (String) -> Void, done: @escaping (String) -> Void) {
        ensure()
        guard let stdin else { done(strings.noClaude); return }
        let text = Brain.turnText(cfg, command, live: live, frontApp: frontApp, context: context)
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        guard var data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        data.append(0x0A)
        self.step = step; self.done = done; sent += 1; turnCommands = []
        stdin.write(data)
        log("brain ← \(command)")
    }
    /// One turn's input: time, front app, screen context, what was said (and the live text when it differs).
    static func turnText(_ cfg: Config, _ command: String, live: String, frontApp: String, context: String) -> String {
        let now = DateFormatter(); now.locale = Locale(identifier: cfg.locale)
        now.dateFormat = cfg.ko ? "M월 d일 EEEE a h시 m분" : "EEEE, MMM d, h:mm a"
        let ctx = context.isEmpty ? "" : "\n" + context
        var text = cfg.ko ? "[지금 \(now.string(from: Date())) · 맨 앞 앱: \(frontApp)]\(ctx)\n\(cfg.user) 말: \(command)"
                          : "[Now \(now.string(from: Date())) · front app: \(frontApp)]\(ctx)\n\(cfg.user) says: \(command)"
        if !live.isEmpty, Parser.squash(live) != Parser.squash(command) {
            text += cfg.ko ? "\n(맥 실시간 인식으로는: \(live) — 두 받아쓰기가 다르면 문맥상 맞는 쪽을 따른다)"
                           : "\n(live recognition heard: \(live) — if the two differ, follow whichever makes sense)"
        }
        return text
    }
    func stop() { proc?.terminate(); proc = nil }
    /// silently: drop the answer instead of saying “stopped” (used when a new command takes over).
    func cancel(silently: Bool = false) {
        guard done != nil else { return }
        if silently { done = nil; step = nil }
        let p = proc; proc = nil; p?.terminate()
        finish(strings.stopped)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.ensure() }
    }
}
