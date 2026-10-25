// Brains you plug in with an API key or a local model server — Anthropic's API, and anything that speaks the OpenAI
// chat API: OpenAI, Gemini, OpenRouter, Groq, Ollama, LM Studio, or your own server (`brainProvider`).
// Sasarisa runs the conversation itself. The hands are the same `butler-mcp` tool box Claude Code gets, started with
// the same fixed safe-mode flags, so every guard (protected apps, send/pay confirmation, password fields) holds
// whatever model is thinking. There is no shell and no file access to hand out in the first place.
import AppKit
import Security

/// What Butler needs from a brain — Claude Code (`Brain`) or an API brain (`APIBrain`).
protocol Thinker: AnyObject {
    var busy: Bool { get }
    var installed: Bool { get }
    var lastCommands: [String] { get }
    func warm()
    func ask(_ command: String, live: String, frontApp: String, context: String, step: @escaping (String) -> Void, done: @escaping (String) -> Void)
    func stop()
    func cancel(silently: Bool)
}
extension Thinker { func cancel() { cancel(silently: false) } }
extension Brain: Thinker {}

enum Brains {
    static func make(_ cfg: Config) -> Thinker {
        if cfg.brainProvider == "aside" { return AsideBrain(cfg: cfg) }      // Aside's browser agent via its CLI
        if cfg.brainProvider == "codex" { return CodexBrain(cfg: cfg) }      // GPT through your signed-in Codex CLI
        if APIBrain.provider(cfg) != nil { return APIBrain(cfg: cfg) }
        // Left on the default (Claude Code) but it isn't installed: use whichever agent CLI is (10/25 owner: 「AI 모두 다 되는데
        // 왜 특정 클로드만」 — someone with only Codex or Aside shouldn't be stuck).
        if cfg.brainProvider == "claude-code", cfg.claudeBinary == nil {
            if CodexBrain.binary != nil { return CodexBrain(cfg: cfg) }
            if AsideBrain.binary != nil { return AsideBrain(cfg: cfg) }
        }
        return Brain(cfg: cfg)
    }
    /// The brain that will think, by name — nil when none of them is ready (Setup shows it).
    static func ready(_ cfg: Config) -> String? {
        let b = make(cfg)
        guard b.installed else { return nil }
        if b is CodexBrain { return "Codex (ChatGPT)" }
        if b is AsideBrain { return "Aside" }
        if b is APIBrain { return cfg.brainProvider }
        return "Claude Code"
    }
}

/// API keys live in the login Keychain (service "Sasarisa", account = the provider), never in config.json.
/// `MacButler --set-key openai` stores one; environment variables are read as a fallback for developers.
enum Keys {
    static let service = "Mac Butler"         // Keychain service — kept after the rename (0.7) so saved keys stay
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
    }
    @discardableResult static func set(_ account: String, _ value: String) -> Bool {
        remove(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    static func remove(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
    static func lookup(_ account: String, env: String?) -> String? {
        get(account) ?? env.flatMap { ProcessInfo.processInfo.environment[$0] }.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The tool box over MCP (stdio): the same server and flags Claude Code gets (`Brain.mcpConfig`).
final class ToolBoxClient {
    private var proc: Process?
    private var input: FileHandle?, output: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private(set) var tools: [[String: Any]] = []
    let safe: Bool
    init(safe: Bool) { self.safe = safe }
    var running: Bool { proc?.isRunning == true }

    func start() -> Bool {
        if running { return true }
        let p = Process()
        p.executableURL = Paths.tools.appendingPathComponent("butler-mcp")
        var env = ProcessInfo.processInfo.environment
        env["MACBUTLER_HOME"] = Paths.home.path; env["MACBUTLER_BUNDLE"] = Bundle.main.bundleIdentifier ?? ""
        env["MACBUTLER_SAFE"] = safe ? "1" : nil
        p.environment = env
        let i = Pipe(), o = Pipe()
        p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { log("tool box failed to start: \(error)"); return false }
        proc = p; input = i.fileHandleForWriting; output = o.fileHandleForReading; buffer = Data()
        guard request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "mac-butler", "version": "1"]]) != nil else { stop(); return false }
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        tools = (request("tools/list", [:])?["tools"] as? [[String: Any]]) ?? []
        log("tool box on: \(tools.count) tools")
        return !tools.isEmpty
    }
    func stop() { proc?.terminate(); proc = nil; input = nil; output = nil }

    private func send(_ msg: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: msg) else { return }
        d.append(0x0A); input?.write(d)
    }
    /// Blocking — call off the main thread.
    private func request(_ method: String, _ params: [String: Any]) -> [String: Any]? {
        let id = nextID; nextID += 1
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        while let out = output {
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl); buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], obj["id"] as? Int == id else { continue }
                return obj["result"] as? [String: Any]
            }
            let d = out.availableData
            if d.isEmpty { return nil }          // the server exited
            buffer.append(d)
        }
        return nil
    }
    /// One tool call → (text, base64 PNGs, isError).
    func call(_ name: String, _ args: [String: Any]) -> (text: String, images: [String], isError: Bool) {
        guard running || start(), let r = request("tools/call", ["name": name, "arguments": args]) else { return ("the tool box is not running", [], true) }
        let content = r["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        let images = content.compactMap { $0["type"] as? String == "image" ? $0["data"] as? String : nil }
        return (text.isEmpty ? "ok" : text, images, r["isError"] as? Bool ?? false)
    }
}

final class APIBrain: Thinker {
    struct Provider {
        let id: String, base: String, keyEnv: String?
        var anthropic = false, local = false, vision = true
    }
    static let providers: [Provider] = [
        Provider(id: "anthropic", base: "https://api.anthropic.com/v1", keyEnv: "ANTHROPIC_API_KEY", anthropic: true),
        Provider(id: "openai", base: "https://api.openai.com/v1", keyEnv: "OPENAI_API_KEY"),
        Provider(id: "gemini", base: "https://generativelanguage.googleapis.com/v1beta/openai", keyEnv: "GEMINI_API_KEY"),
        Provider(id: "openrouter", base: "https://openrouter.ai/api/v1", keyEnv: "OPENROUTER_API_KEY"),
        Provider(id: "groq", base: "https://api.groq.com/openai/v1", keyEnv: "GROQ_API_KEY"),
        Provider(id: "ollama", base: "http://127.0.0.1:11434/v1", keyEnv: nil, local: true, vision: false),
        Provider(id: "lmstudio", base: "http://127.0.0.1:1234/v1", keyEnv: nil, local: true, vision: false),
        Provider(id: "openai-compatible", base: "", keyEnv: "BUTLER_API_KEY", vision: false)]
    /// nil = Claude Code (the default).
    static func provider(_ cfg: Config) -> Provider? {
        guard var p = providers.first(where: { $0.id == cfg.brainProvider }) else { return nil }
        if !cfg.brainBaseURL.isEmpty { p = Provider(id: p.id, base: cfg.brainBaseURL, keyEnv: p.keyEnv, anthropic: p.anthropic, local: p.local, vision: p.vision) }
        return p
    }
    /// Keys only travel over https; plain http only to this Mac (a local model server).
    static func safeBase(_ s: String) -> URL? {
        guard let u = URL(string: s.hasSuffix("/") ? String(s.dropLast()) : s), let host = u.host?.lowercased() else { return nil }
        if u.scheme == "https" { return u }
        return u.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host) ? u : nil
    }

    private let cfg: Config
    private let p: Provider
    private let queue = DispatchQueue(label: "mac-butler.api-brain")
    private lazy var box = ToolBoxClient(safe: cfg.brainAccess != "full")
    private var history: [[String: Any]] = []
    private var turns = 0
    private var lastUse = Date()
    private var model = ""
    private var gen = 0
    private var step: ((String) -> Void)?
    private var done: ((String) -> Void)?
    private var task: URLSessionDataTask?
    private(set) var lastCommands: [String] = []

    init(cfg: Config) { self.cfg = cfg; self.p = APIBrain.provider(cfg)! }
    var busy: Bool { done != nil }
    var key: String? { Keys.lookup(p.id, env: p.keyEnv) }
    var installed: Bool { APIBrain.safeBase(p.base) != nil && (p.local || key != nil) }

    func warm() { queue.async { [weak self] in _ = self?.box.start() } }
    func stop() { task?.cancel(); queue.async { [weak self] in self?.box.stop() } }
    func cancel(silently: Bool) {
        guard let d = done else { return }
        gen += 1; task?.cancel(); done = nil; step = nil
        if !silently { d(Strings(ko: cfg.ko, name: cfg.displayName).stopped) }
    }

    func ask(_ command: String, live: String, frontApp: String, context: String, step: @escaping (String) -> Void, done: @escaping (String) -> Void) {
        guard installed else {
            done(cfg.ko ? "\(p.id) 연결 열쇠가 없습니다. 설정에서 열쇠를 넣어 주세요." : "There's no key for \(p.id) yet — add one in Settings."); return
        }
        gen += 1; let my = gen
        self.step = step; self.done = done
        let text = Brain.turnText(cfg, command, live: live, frontApp: frontApp, context: context)
        log("brain(\(p.id)) ← \(command)")
        queue.async { [weak self] in
            guard let self else { return }
            let (answer, cmds) = self.run(text, my)
            DispatchQueue.main.async {
                guard my == self.gen, let d = self.done else { return }
                self.done = nil; self.step = nil; self.lastUse = Date(); self.lastCommands = cmds
                let t = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                d(t.isEmpty ? Strings(ko: self.cfg.ko, name: self.cfg.displayName).failed : t)
            }
        }
    }

    // MARK: the conversation loop (background queue)

    private func say(_ label: String, _ my: Int) { DispatchQueue.main.async { [weak self] in if self?.gen == my { self?.step?(label) } } }

    private func run(_ text: String, _ my: Int) -> (String, [String]) {
        guard box.start() else { return (cfg.ko ? "손 도구를 켜지 못했습니다." : "Couldn't start the tool box.", []) }
        if model.isEmpty { model = resolveModel() }
        guard !model.isEmpty else { return (cfg.ko ? "두뇌 모델 이름을 설정에 넣어 주세요." : "Set brainModel in Settings.", []) }
        // A fresh conversation now and then keeps it fast (same rule as the Claude Code brain).
        if turns >= 12 || Date().timeIntervalSince(lastUse) > 1800 || approxSize() > 400_000 { history = []; turns = 0 }
        turns += 1
        history.append(["role": "user", "content": text])
        var cmds: [String] = []
        for _ in 0..<12 {
            guard my == gen else { return ("", cmds) }
            let t0 = Date()
            guard let reply = p.anthropic ? anthropicTurn() : openAITurn() else {
                return (cfg.ko ? "두뇌 서버에서 답이 오지 않았습니다." : "The brain didn't answer.", cmds)
            }
            Usage.record(["usage": ["input_tokens": reply.inTokens, "output_tokens": reply.outTokens, "cache_read_input_tokens": reply.cacheRead],
                          "duration_ms": Int(Date().timeIntervalSince(t0) * 1000)])
            if reply.calls.isEmpty { return (reply.text, cmds) }
            var results: [(id: String, text: String, images: [String], isError: Bool)] = []
            for c in reply.calls {
                guard my == gen else { return ("", cmds) }
                say(Brain.stepLabel(cfg, c.name, c.args), my)
                cmds.append(Brain.commandLine(c.name, c.args))
                let r = box.call(c.name, c.args)
                log("brain(\(p.id)) tool \(c.name) → \(r.text.prefix(120))")
                results.append((c.id, r.text, r.images, r.isError))
            }
            if p.anthropic {
                history.append(["role": "user", "content": results.map { r -> [String: Any] in
                    var content: [[String: Any]] = [["type": "text", "text": r.text]]
                    for img in r.images { content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": img]]) }
                    return ["type": "tool_result", "tool_use_id": r.id, "content": content, "is_error": r.isError]
                }])
            } else {
                for r in results { history.append(["role": "tool", "tool_call_id": r.id, "content": r.text]) }
                let imgs = results.flatMap(\.images)
                if !imgs.isEmpty, p.vision {
                    history.append(["role": "user", "content": [["type": "text", "text": "(screenshot from the tool above)"]]
                        + imgs.map { ["type": "image_url", "image_url": ["url": "data:image/png;base64,\($0)"]] }])
                }
            }
        }
        return (cfg.ko ? "단계가 너무 많아서 멈췄습니다." : "That took too many steps, so I stopped.", cmds)
    }

    private struct Reply { var text = ""; var calls: [(id: String, name: String, args: [String: Any])] = []; var inTokens = 0, outTokens = 0, cacheRead = 0 }

    private func systemPrompt(webSearch: Bool) -> String {
        var s = Brain.systemPrompt(cfg)
        if !webSearch {
            s += cfg.ko ? "\n\n(이 두뇌에는 WebSearch 가 없다. 찾아볼 일은 open_url 로 네이버·구글 검색 페이지를 열어 보여 주고, 열었다고 말한다.)"
                        : "\n\n(This brain has no WebSearch. To look something up, open a Google search page with open_url and say you opened it.)"
        }
        return s
    }
    private var toolDefs: [(name: String, desc: String, schema: [String: Any])] {
        box.tools.compactMap { t in
            guard let n = t["name"] as? String else { return nil }
            return (n, t["description"] as? String ?? "", t["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:]])
        }
    }

    private func post(_ path: String, _ body: [String: Any], headers: [String: String]) -> [String: Any]? {
        guard let base = APIBrain.safeBase(p.base), let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"; req.timeoutInterval = 90; req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any]?
        let t = URLSession.shared.dataTask(with: req) { d, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = d.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            if code == 200 { out = obj }
            else { log("brain(\(self.p.id)) HTTP \(code): \(err?.localizedDescription ?? String(describing: (obj?["error"] as? [String: Any])?["message"] ?? obj?["error"] ?? ""))") }
            sem.signal()
        }
        task = t; t.resume(); sem.wait()
        return out
    }
    private func get(_ path: String) -> [String: Any]? {
        guard let base = APIBrain.safeBase(p.base) else { return nil }
        var req = URLRequest(url: base.appendingPathComponent(path)); req.timeoutInterval = 10
        if let k = key { req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
        let sem = DispatchSemaphore(value: 0); var out: [String: Any]?
        URLSession.shared.dataTask(with: req) { d, _, _ in out = d.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }; sem.signal() }.resume()
        sem.wait(); return out
    }
    /// `brainModel`, or the provider's sensible default; a local server's first model if none is set.
    private func resolveModel() -> String {
        if !cfg.brainModel.isEmpty { return cfg.brainModel }
        if p.anthropic { return "claude-sonnet-5-5" }     // same "sonnet for speed" choice as the Claude Code brain
        if p.local || p.id == "openai-compatible" {
            return ((get("models")?["data"] as? [[String: Any]])?.first?["id"] as? String) ?? ""
        }
        return ""                                          // OpenAI, Gemini, OpenRouter, Groq: model names change often — set brainModel
    }
    private func approxSize() -> Int { (try? JSONSerialization.data(withJSONObject: history))?.count ?? 0 }

    // MARK: Anthropic Messages API

    private func anthropicTurn() -> Reply? {
        let haiku = model.contains("haiku")
        var tools: [[String: Any]] = toolDefs.map { ["name": $0.name, "description": $0.desc, "input_schema": $0.schema] }
        tools.append(["type": haiku ? "web_search_20250305" : "web_search_20260209", "name": "web_search", "max_uses": 3])
        var body: [String: Any] = [
            "model": model, "max_tokens": 16000, "tools": tools, "messages": history,
            "system": [["type": "text", "text": systemPrompt(webSearch: true), "cache_control": ["type": "ephemeral"]]],
            "cache_control": ["type": "ephemeral"],                  // also cache the conversation so far
            "output_config": ["effort": "low"]]                      // a spoken one-liner: fast beats deep
        var headers = ["x-api-key": key ?? "", "anthropic-version": "2026-10-21"]
        // A safety classifier that declines (stop_reason "refusal") is retried on a fallback model by the API.
        if ["claude-sonnet-5-5", "claude-opus-5", "claude-fable-5"].contains(where: model.hasPrefix) {
            body["fallbacks"] = "default"; headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        }
        guard let r = post("messages", body, headers: headers) else { return nil }
        let content = r["content"] as? [[String: Any]] ?? []
        history.append(["role": "assistant", "content": content])    // unchanged, thinking blocks included
        var reply = Reply()
        let u = r["usage"] as? [String: Any] ?? [:]
        reply.inTokens = (u["input_tokens"] as? Int ?? 0) + (u["cache_creation_input_tokens"] as? Int ?? 0)
        reply.outTokens = u["output_tokens"] as? Int ?? 0; reply.cacheRead = u["cache_read_input_tokens"] as? Int ?? 0
        let stop = r["stop_reason"] as? String ?? ""
        if stop == "refusal" { reply.text = cfg.ko ? "그 요청은 처리할 수 없습니다." : "I can't help with that one."; return reply }
        if stop == "pause_turn" { return anthropicTurn() }           // a long server-side search — let it continue
        reply.text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        if stop == "tool_use" {
            reply.calls = content.compactMap { c in
                guard c["type"] as? String == "tool_use", let id = c["id"] as? String, let n = c["name"] as? String else { return nil }
                return (id, n, c["input"] as? [String: Any] ?? [:])
            }
        }
        return reply
    }

    // MARK: OpenAI-compatible chat completions (OpenAI, Gemini, OpenRouter, Groq, Ollama, LM Studio, …)

    private func openAITurn() -> Reply? {
        let tools = toolDefs.map { ["type": "function", "function": ["name": $0.name, "description": $0.desc, "parameters": $0.schema]] as [String: Any] }
        let body: [String: Any] = ["model": model, "tools": tools, "tool_choice": "auto", "stream": false,
                                   "messages": [["role": "system", "content": systemPrompt(webSearch: false)]] + history]
        var headers: [String: String] = [:]
        if let k = key { headers["Authorization"] = "Bearer \(k)" }
        if p.id == "openrouter" { headers["X-Title"] = "Sasarisa" }
        guard let r = post("chat/completions", body, headers: headers),
              let msg = ((r["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any] else { return nil }
        var reply = Reply()
        let u = r["usage"] as? [String: Any] ?? [:]
        reply.inTokens = u["prompt_tokens"] as? Int ?? 0; reply.outTokens = u["completion_tokens"] as? Int ?? 0
        let raw = msg["content"] as? String ?? ""
        // Some local models think out loud in <think>…</think> — never speak that.
        reply.text = raw.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        let calls = msg["tool_calls"] as? [[String: Any]] ?? []
        var keep: [String: Any] = ["role": "assistant", "content": raw]
        if !calls.isEmpty { keep["tool_calls"] = calls }
        history.append(keep)
        reply.calls = calls.enumerated().compactMap { i, c in
            guard let f = c["function"] as? [String: Any], let n = f["name"] as? String else { return nil }
            let args: [String: Any]
            if let s = f["arguments"] as? String { args = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:] }
            else { args = f["arguments"] as? [String: Any] ?? [:] }
            return ((c["id"] as? String) ?? "call_\(i)", n, args)
        }
        return reply
    }
}
