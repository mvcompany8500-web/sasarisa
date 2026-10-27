// GPT through the Codex CLI you're already signed in to (your ChatGPT plan) — like Claude Code, no API key.
// Each turn is one `codex exec` with the same hands as every other brain: Sasarisa's `butler-mcp` tool box with the
// safe-mode flags fixed here. Codex's own shell, file, browser, computer-use, plugin and app tools are switched off,
// your ~/.codex/config.toml (its MCP servers, sandbox, rules) is not loaded, the sandbox is read-only and nothing is
// saved to your Codex history (--ephemeral). Auth still comes from your Codex login.
import AppKit

final class CodexBrain: Thinker {
    private let cfg: Config
    private let strings: Strings
    private var proc: Process?
    private var buffer = Data(), err = Data()
    private var step: ((String) -> Void)?
    private var done: ((String) -> Void)?
    private var timeout: DispatchWorkItem?
    private var answer = ""
    private var turnCommands: [String] = []
    private var recent: [(said: String, answer: String)] = []   // the last few exchanges, for follow-ups (10 minutes)
    private var lastUse = Date.distantPast
    private(set) var lastCommands: [String] = []
    init(cfg: Config) { self.cfg = cfg; self.strings = Strings(ko: cfg.ko, name: cfg.displayName) }
    var busy: Bool { done != nil }
    var installed: Bool { CodexBrain.binary != nil }

    static var binary: String? {
        Paths.which("codex", extra: ["~/.local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"])
    }
    /// `brainModel` if you name one; otherwise Codex picks its default for your ChatGPT plan.
    /// (Not the `model` in ~/.codex/config.toml — that one may belong to another provider; 10/24 test: refused with a ChatGPT login.)
    static func model(_ cfg: Config) -> String? { cfg.brainModel.isEmpty ? nil : cfg.brainModel }
    /// Models Codex lists for your account (~/.codex/models_cache.json, visible ones), for the settings menu.
    static func listedModels() -> [String] {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard let d = try? Data(contentsOf: home.appendingPathComponent("models_cache.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let ms = o["models"] as? [[String: Any]] else { return [] }
        return ms.compactMap { $0["visibility"] as? String == "list" ? $0["slug"] as? String : nil }
    }
    /// What the installed Codex knows: its feature names (`codex features list`) and `codex exec` flags. Codex refuses to run
    /// at all when told to switch off a feature it doesn't know (「Unknown feature flag」) — 10/27 a viewer's Codex (another
    /// version) failed every brain turn with 「잘 안 됐습니다」 while quick commands worked. Asked once per Codex binary.
    struct Caps { let features: Set<String>?; let execHelp: String }
    private static var caps: (key: String, value: Caps)?
    private static let capsLock = NSLock()          // warmed in the background, read on the main thread
    static func capabilities(_ bin: String) -> Caps {
        capsLock.lock(); defer { capsLock.unlock() }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: bin)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = bin + "@\(mtime)"
        if let c = caps, c.key == key { return c.value }
        func run(_ args: [String]) -> String? {
            let p = Process(); p.executableURL = URL(fileURLWithPath: bin); p.arguments = args
            var env = ProcessInfo.processInfo.environment; env["PATH"] = Paths.envPath; env["NO_COLOR"] = "1"; p.environment = env
            let o = Pipe(); p.standardOutput = o; p.standardError = Pipe(); p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let kill = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: kill)
            let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); kill.cancel()
            return p.terminationStatus == 0 ? String(decoding: d, as: UTF8.self) : nil
        }
        let list = run(["features", "list"])
        let features = list.map { Set($0.split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) }) }
        let value = Caps(features: features?.isEmpty == false ? features : nil, execHelp: run(["exec", "--help"]) ?? "")
        log("codex caps: \(value.features?.count ?? 0) features · flags \(["--ignore-user-config", "--ignore-rules", "--ephemeral"].filter { value.execHelp.contains($0) })")
        caps = (key, value)
        return value
    }
    /// Everything except the tool box is switched off. Fixed here, where the model can't change it.
    static func arguments(_ cfg: Config, prompt: String, caps: Caps? = nil) -> [String] {
        let box = Paths.tools.appendingPathComponent("butler-mcp").path
        let off = ["shell_tool", "unified_exec", "apps", "browser_use", "browser_use_external", "computer_use", "image_generation",
                   "plugins", "multi_agent", "hooks", "goals", "tool_suggest", "skill_mcp_dependency_install", "skill_search", "memories"]
        // only flags and feature names this Codex knows (an unknown one stops it before it starts)
        let has = { (flag: String) in caps.map { $0.execHelp.isEmpty || $0.execHelp.contains(flag) } ?? true }
        var a = ["exec", "--json"] + ["--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules"].filter(has)
            + ["--sandbox", "read-only", "--color", "never", "-C", Paths.home.appendingPathComponent("work").path]
        let known = caps.map { c in off.filter { c.features?.contains($0) ?? false } } ?? off
        for f in known { a += ["--disable", f] }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let effort = ["low", "medium", "high"].contains(cfg.brainEffort) ? cfg.brainEffort : "low"
        a += ["-c", "approval_policy=\"never\"", "-c", "model_reasoning_effort=\"\(effort)\"",
              "-c", "mcp_servers.butler.command=\(q(box))",
              "-c", "mcp_servers.butler.default_tools_approval_mode=\"approve\"",
              "-c", "mcp_servers.butler.env.MACBUTLER_HOME=\(q(Paths.home.path))",
              "-c", "mcp_servers.butler.env.MACBUTLER_BUNDLE=\(q(Bundle.main.bundleIdentifier ?? ""))"]
        if cfg.brainAccess != "full" { a += ["-c", "mcp_servers.butler.env.MACBUTLER_SAFE=\"1\""] }
        if let m = model(cfg) { a += ["-m", m] }
        return a + [prompt]
    }

    func warm() { if let b = CodexBrain.binary { DispatchQueue.global(qos: .utility).async { _ = CodexBrain.capabilities(b) } } }   // a fresh `codex exec` per turn; learn once what this Codex knows

    func ask(_ command: String, live: String, frontApp: String, context: String, step: @escaping (String) -> Void, done: @escaping (String) -> Void) {
        guard let bin = CodexBrain.binary else {
            done(cfg.ko ? "Codex가 없어요. Codex 명령줄 도구를 설치하고 codex login 을 한 번 해 주세요." : "Codex isn't installed. Install the Codex CLI and run codex login once.")
            return
        }
        if Date().timeIntervalSince(lastUse) > 600 { recent = [] }
        var prompt = Brain.systemPrompt(cfg)
        if !recent.isEmpty {
            prompt += cfg.ko ? "\n\n[방금 나눈 말]\n" : "\n\n[Just before]\n"
            prompt += recent.map { (cfg.ko ? "\(cfg.user): " : "\(cfg.user): ") + $0.said + "\n" + cfg.assistantName + ": " + $0.answer }.joined(separator: "\n")
        }
        prompt += "\n\n" + Brain.turnText(cfg, command, live: live, frontApp: frontApp, context: context)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = CodexBrain.arguments(cfg, prompt: prompt, caps: CodexBrain.capabilities(bin))
        p.currentDirectoryURL = Paths.home.appendingPathComponent("work")
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Paths.envPath; env["NO_COLOR"] = "1"
        p.environment = env
        let o = Pipe(), e = Pipe()
        p.standardInput = FileHandle.nullDevice; p.standardOutput = o; p.standardError = e
        buffer = Data(); err = Data(); answer = ""; turnCommands = []
        o.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { return }
            DispatchQueue.main.async { self?.feed(d) }
        }
        e.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { return }
            DispatchQueue.main.async { if (self?.err.count ?? 0) < 20_000 { self?.err.append(d) } }
        }
        p.terminationHandler = { [weak self] dead in
            DispatchQueue.main.async {
                guard let self, self.proc === dead else { return }
                self.proc = nil
                self.finish(command)
            }
        }
        self.step = step; self.done = done
        do { try p.run() } catch { log("codex failed to start: \(error)"); self.step = nil; self.done = nil; done(strings.failed); return }
        proc = p
        let t = DispatchWorkItem { [weak self] in
            guard let self, self.done != nil else { return }
            log("codex timed out"); self.proc?.terminate()
        }
        timeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: t)
        log("codex ← \(command)")
    }

    private func feed(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }
    /// --json events: tool calls → HUD steps (and jax lines for learning), agent messages → the answer (last one wins).
    func handle(_ obj: [String: Any]) {
        let type = obj["type"] as? String ?? ""
        if type == "turn.completed", let u = obj["usage"] as? [String: Any] {   // Sasarisa's share, same tally as Claude's
            let cached = u["cached_input_tokens"] as? Int ?? 0      // Codex counts cached tokens inside input_tokens
            Usage.record(["usage": ["input_tokens": max((u["input_tokens"] as? Int ?? 0) - cached, 0), "output_tokens": u["output_tokens"] as? Int ?? 0,
                                    "cache_read_input_tokens": cached]])
        }
        guard let item = obj["item"] as? [String: Any] else {
            if type == "turn.failed" || type == "error" {
                log("codex: \(obj)")
                let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? (obj["message"] as? String) ?? ""
                err.append(Data(msg.utf8))
            }
            return
        }
        switch (type, item["type"] as? String ?? "") {
        case ("item.started", "mcp_tool_call"):
            let tool = item["tool"] as? String ?? "", args = item["arguments"] as? [String: Any] ?? [:]
            turnCommands.append(Brain.commandLine(tool, args))
            log("brain(codex) tool: \(Brain.commandLine(tool, args).prefix(160))")     // what it really did (10/25: 「세 창 눌렀다」 couldn't be checked)
            step?(Brain.stepLabel(cfg, tool, args))
        case ("item.completed", "mcp_tool_call"):
            let tool = item["tool"] as? String ?? "", status = item["status"] as? String ?? ""
            let err = (item["error"] as? [String: Any])?["message"] as? String ?? ""
            let res = ((item["result"] as? [String: Any])?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ") ?? ""
            log("brain(codex) tool \(tool) → \(status) \((err.isEmpty ? res : err).prefix(120))")
        case ("item.started", "web_search"):
            step?(strings.toolNames["WebSearch"] ?? strings.working)
        case ("item.completed", "agent_message"):
            if let t = item["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { answer = t }
        default: break
        }
    }

    private func finish(_ command: String) {
        timeout?.cancel(); timeout = nil
        guard let d = done else { return }
        done = nil; step = nil; lastUse = Date()
        lastCommands = turnCommands; turnCommands = []
        let t = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            recent.append((command, t)); if recent.count > 3 { recent.removeFirst() }
            d(t); return
        }
        let why = (String(data: err, encoding: .utf8) ?? "").lowercased()
        log("codex: no answer · \(why.suffix(300))")
        if why.contains("login") || why.contains("not logged in") || why.contains("unauthorized") || why.contains("401") {
            d(cfg.ko ? "Codex 로그인이 필요해요. 터미널에서 codex login 을 한 번 해 주세요." : "Codex needs you to sign in — run codex login once in Terminal.")
        } else if why.contains("model_not_found") || why.contains("model is not supported") {
            d(cfg.ko ? "Codex가 그 모델 이름을 받지 않아요. 설정의 모델 이름을 비우면 기본 모델로 해요." : "Codex doesn't accept that model name — leave Model empty to use its default.")
        } else if why.contains("unknown feature") || why.contains("unexpected argument") || why.contains("unrecognized") || why.contains("found argument") {
            d(cfg.ko ? "설치된 Codex 판이 사사리사와 안 맞아요. 터미널에서 Codex를 업데이트해 주세요(npm i -g @openai/codex 또는 brew upgrade codex)."
                     : "Your Codex version doesn't match Sasarisa. Update Codex in Terminal (npm i -g @openai/codex or brew upgrade codex).")
        } else if why.contains("usage limit") || why.contains("rate limit") || why.contains("429") {
            d(cfg.ko ? "Codex 사용 한도가 찼어요. 잠시 뒤에 다시 하거나 설정에서 두뇌를 바꿔 주세요." : "Codex hit its usage limit. Try later or pick another brain in Settings.")
        } else {
            d(strings.failed)
        }
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
