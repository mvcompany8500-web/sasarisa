// 힉스필드로 만들기 (owner 10/26: 「사사리사 업데이트 해놔라 가능하도록 … 크레딧 아낄 수 있게」).
// 「힉스필드로 바다 위 거북이 5초 영상 만들어」 → Claude Code plans ONE generation the cheapest way and only asks its
// price (get_cost) → Sasarisa says what and how much (credits left too) → only after 「응」 it is generated, once, saved
// to ~/Movies/Sasarisa and shown in Finder (not played — you may be recording).
// Uses Higgsfield's official MCP server (https://mcp.higgsfield.ai/mcp) signed in once in Claude Code
// (`claude mcp add --transport http higgsfield https://mcp.higgsfield.ai/mcp`). Every generation there spends credits.
// The `butler hf-guard` hook holds whatever the AI decides: price-only until approved, then the approved tool and model,
// one output, one call — no retries.
import AppKit

final class Higgsfield {
    struct Plan { let tool: String; let params: [String: Any]; let credits: Double; let balance: Double?; let unlim: Bool; let summary: String; let request: String }

    static let url = "https://mcp.higgsfield.ai/mcp"
    static let setupCommand = "claude mcp add --transport http --scope user higgsfield \(url)"
    private let cfg: Config
    private var proc: Process?
    private var dir: URL { Paths.home.appendingPathComponent("higgsfield") }
    init(cfg: Config) { self.cfg = cfg }

    /// 「힉스필드로 … 만들어/그려/뽑아」 — the word 힉스필드 must be said: nothing here spends credits by accident.
    static func request(_ s: String) -> String? {
        guard s.range(of: "[힉익히]스\\s*[필펠플빌피]드|히그스\\s*필드|higgs\\s*field", options: [.regularExpression, .caseInsensitive]) != nil,
              s.range(of: "만들|그려|생성|뽑아|제작|make|generate|create|render", options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return s
    }

    var busy: Bool { proc?.isRunning == true }
    func stop() { proc?.terminate() }

    // MARK: 1 · price only (0 credits)

    func quote(_ request: String, done: @escaping (Result<Plan, Error>) -> Void) {
        let recent = history().prefix(5).map { "- \($0["at"] ?? ""): \($0["summary"] ?? "") · job_id \($0["job_id"] ?? "") · \($0["kind"] ?? "")" }.joined(separator: "\n")
        let prompt = """
        You plan ONE Higgsfield generation for a voice-assistant user, spending as few credits as possible, and only ask its price.
        You must NOT generate anything: every generate_* call must include "get_cost": true (a guard blocks anything else).

        Spoken request: «\(request)»
        Earlier results (newest first; reuse one by putting its job_id in medias instead of making a new picture):
        \(recent.isEmpty ? "(none)" : recent)

        Rules to save credits:
        - One output (count 1). No variants, no retries.
        - Video: the shortest length the model allows (5 s unless a length was said), 720p, the cheapest model that fits —
          e.g. seedance_2_0_mini (about 5 credits for 5 s) rather than seedance_2_0 (about 22.5). Lip-sync / a talking person:
          wan2_7 at 720p, only the talking part. Sound only if asked. Vertical (9:16) only if asked or said for Shorts/Reels.
        - Still picture: the cheapest good model, e.g. gpt_image_2_5 (about 0.25 credits).
        - A model, length, resolution or ratio the user named is kept.
        - "아까 그 그림으로 …" (from an earlier result): pass that job_id in medias.
        - Call models_explore only if you don't know a fitting model id. Call balance once.
        - If a response offers unlim_choice (free generations), don't answer it — set "unlim": true in your output.
        Finally output ONLY this JSON as the last line (no markdown):
        {"tool":"generate_video or generate_image","params":{exact params, without get_cost},"credits":<number>,"balance":<number>,"unlim":false,"summary":"<short Korean summary, e.g. 5초 영상 · seedance mini · 720p>"}
        If it can't be done: {"error":"<short Korean reason>"}
        """
        setGuard(["mode": "quote"])
        run(prompt, tools: ["balance", "models_explore", "generate_video", "generate_image"], turns: 14) { [weak self] out in
            guard let self else { return }
            switch Higgsfield.lastJSON(out) {
            case .failure(let e): done(.failure(e))
            case .success(let j):
                if let err = j["error"] as? String { done(.failure(HFError(err))); return }
                guard let tool = j["tool"] as? String, tool.hasPrefix("generate_"), let params = j["params"] as? [String: Any],
                      params["model"] is String, let credits = Higgsfield.number(j["credits"]) else { done(.failure(HFError(self.cfg.ko ? "견적을 읽지 못했어요" : "Couldn't read the price"))); return }
                done(.success(Plan(tool: tool, params: params.filter { $0.key != "get_cost" }, credits: credits, balance: Higgsfield.number(j["balance"]),
                                   unlim: j["unlim"] as? Bool ?? false, summary: j["summary"] as? String ?? tool, request: request)))
            }
        }
    }

    // MARK: 2 · the one approved generation

    func generate(_ plan: Plan, done: @escaping (Result<URL, Error>) -> Void) {
        var params = plan.params
        if plan.unlim { params["use_unlim"] = true }
        params["count"] = 1
        let json = String(data: (try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "{}"
        let prompt = """
        The user approved exactly this one Higgsfield generation (about \(plan.credits) credits). Call \(plan.tool) ONCE with
        params = \(json)
        Never call it again, even if it fails (a guard blocks a second call). Then wait with jobs_wait (call it again until the job
        is finished, up to about 10 minutes). Finally output ONLY this JSON as the last line (no markdown):
        {"job_id":"...","url":"<direct https link to the finished file>","credits":<credits charged, if shown>}
        If it failed: {"error":"<short Korean reason>"}
        """
        setGuard(["mode": "generate", "tool": plan.tool, "model": plan.params["model"] as? String ?? "", "used": 0])
        run(prompt, tools: [plan.tool, "jobs_wait", "show_generation_by_ids", "job_display", "balance"], turns: 30, timeout: 900) { [weak self] out in
            guard let self else { return }
            self.setGuard(["mode": "quote"])
            switch Higgsfield.lastJSON(out) {
            case .failure(let e): done(.failure(e))
            case .success(let j):
                if let err = j["error"] as? String { done(.failure(HFError(err))); return }
                guard let s = j["url"] as? String, let link = URL(string: s), link.scheme == "https" else { done(.failure(HFError(self.cfg.ko ? "결과 주소를 받지 못했어요" : "No result link"))); return }
                self.save(link, plan: plan, jobID: j["job_id"] as? String ?? "", charged: Higgsfield.number(j["credits"]) ?? plan.credits, done: done)
            }
        }
    }

    // MARK: running Claude Code with only Higgsfield

    private func run(_ prompt: String, tools: [String], turns: Int, timeout: TimeInterval = 240, done: @escaping (String) -> Void) {
        guard let claude = cfg.claudeBinary else { done(""); return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mcp = dir.appendingPathComponent("mcp.json")
        try? #"{"mcpServers":{"higgsfield":{"type":"http","url":"\#(Higgsfield.url)"}}}"#.write(to: mcp, atomically: true, encoding: .utf8)
        let guardCmd = "'" + Paths.tools.appendingPathComponent("butler").path.replacingOccurrences(of: "'", with: "'\\''") + "' hf-guard '" + dir.appendingPathComponent("guard.json").path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let settings: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "mcp__higgsfield__generate_.*", "hooks": [["type": "command", "command": guardCmd]]]]]]
        let settingsJSON = String(data: (try? JSONSerialization.data(withJSONObject: settings)) ?? Data(), encoding: .utf8) ?? "{}"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = ["-p", prompt, "--output-format", "text", "--max-turns", String(turns), "--model", "sonnet",
                       "--strict-mcp-config", "--mcp-config", mcp.path, "--setting-sources", "", "--settings", settingsJSON,
                       "--permission-mode", "default", "--allowedTools", tools.map { "mcp__higgsfield__" + $0 }.joined(separator: ","),
                       "--disallowedTools", "Bash,Edit,Write,Read,WebFetch,WebSearch,Task,Agent"]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Paths.envPath + ":" + (env["PATH"] ?? "")
        env["ENABLE_TOOL_SEARCH"] = "false"   // 10/29: deferred tool loading sometimes left the Higgsfield tools unloaded («never loaded»)
        env["MCP_TIMEOUT"] = "120000"; env["MCP_TOOL_TIMEOUT"] = "180000"   // 10/29: the remote tool list took ~60 s; 30 s timed out
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        proc = p
        let started = Date()
        DispatchQueue.global().async {
            do { try p.run() } catch { DispatchQueue.main.async { done("") }; return }
            let killer = DispatchWorkItem { if p.isRunning { log("higgsfield: timed out"); p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit(); killer.cancel()
            let out = String(decoding: data, as: UTF8.self)
            log(String(format: "higgsfield: %.0f s · %@", Date().timeIntervalSince(started), String(out.suffix(300)).replacingOccurrences(of: "\n", with: " ")))
            DispatchQueue.main.async { done(out) }
        }
    }
    private func setGuard(_ st: [String: Any]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: st) { try? d.write(to: dir.appendingPathComponent("guard.json")) }
    }

    // MARK: result file and history

    private func save(_ link: URL, plan: Plan, jobID: String, charged: Double, done: @escaping (Result<URL, Error>) -> Void) {
        URLSession.shared.downloadTask(with: link) { tmp, resp, err in
            guard let tmp, err == nil else { DispatchQueue.main.async { done(.failure(err ?? HFError("download"))) }; return }
            let video = plan.tool == "generate_video"
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(video ? "Movies/Sasarisa" : "Pictures/Sasarisa")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var ext = link.pathExtension.lowercased()
            if ext.isEmpty || ext.count > 4 { ext = (resp?.mimeType ?? "").contains("png") ? "png" : (resp?.mimeType ?? "").contains("jpeg") ? "jpg" : video ? "mp4" : "png" }
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            let file = folder.appendingPathComponent("higgsfield-\(f.string(from: Date())).\(ext)")
            try? FileManager.default.moveItem(at: tmp, to: file)
            DispatchQueue.main.async {
                self.remember(["at": ISO8601DateFormatter().string(from: Date()), "request": plan.request, "summary": plan.summary, "kind": video ? "video" : "image",
                               "job_id": jobID, "credits": charged, "file": file.path, "model": plan.params["model"] as? String ?? ""])
                NSWorkspace.shared.activateFileViewerSelecting([file])      // shown, not played
                done(.success(file))
            }
        }.resume()
    }
    func history() -> [[String: Any]] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("history.json")) else { return [] }
        return (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] ?? []
    }
    private func remember(_ r: [String: Any]) {
        let all = [r] + history().prefix(49)
        if let d = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted]) { try? d.write(to: dir.appendingPathComponent("history.json")) }
    }
    /// Credits spent through Sasarisa today (from the history).
    func spentToday() -> Double {
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        return history().filter { ($0["at"] as? String ?? "").hasPrefix(day) }.compactMap { Higgsfield.number($0["credits"]) }.reduce(0, +)
    }

    // MARK: parsing

    struct HFError: LocalizedError { let msg: String; init(_ m: String) { msg = m }; var errorDescription: String? { msg } }
    static func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap { Double($0) } }
    /// The last {...} line of the output, parsed.
    static func lastJSON(_ out: String) -> Result<[String: Any], Error> {
        for line in out.split(separator: "\n").reversed() {
            let t = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            guard t.hasPrefix("{"), let d = t.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            return .success(o)
        }
        if out.contains("higgsfield") && (out.contains("auth") || out.contains("인증") || out.contains("로그인")) {
            return .failure(HFError("힉스필드 로그인이 필요해요. 터미널에서 한 번: \(setupCommand)"))
        }
        return .failure(HFError(out.isEmpty ? "클로드 코드가 없거나 힉스필드 연결이 안 돼요 — 터미널에서 한 번: \(setupCommand)" : "답을 읽지 못했어요"))
    }
}
