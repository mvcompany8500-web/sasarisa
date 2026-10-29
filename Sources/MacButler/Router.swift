// A small, fast model (Claude Haiku by default) that rewrites a sentence the instant rules missed into a command
// they DO understand — 「유튜브에서 아이유 노래 좀 찾아서 틀어 봐」 → 「유튜브 아이유 노래 틀어」 — in about a second,
// instead of the 7–13 s trip to the big brain. Anything else comes back as BRAIN and goes to the brain as before.
// It has no tools at all; its answer is only ever re-parsed by Parser, and only quick commands are accepted
// (no typing, no Claude hand-offs, no memory), so a fooled router can at worst do a harmless quick action.
// Sentences it mapped are remembered (aliases.json) and run instantly next time — the rules grow from use.
import Foundation

final class Router {
    private let cfg: Config
    private var proc: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var waiting: ((String?) -> Void)?
    private var turns = 0
    private var skip = 0             // answers still coming for questions we already gave up on
    var enabled: Bool { cfg.router != "off" && cfg.claudeBinary != nil }

    init(cfg: Config) { self.cfg = cfg }

    static func prompt(ko: Bool) -> String {
        """
        You turn one spoken request into ONE canonical command line, or the word BRAIN. Output only that line.
        Canonical commands (fill the parts in {braces}, keep the user's language for names and search words):
        유튜브 {검색어} 틀어 | 다음 영상 | 영상 멈춰 | 영상 다시 틀어 | 유튜브 창 꺼 | 창 다 꺼
        쿠팡에서 {검색어} 찾아 | 네이버 쇼핑에서 {검색어} 찾아 | 네이버에서 {검색어} 찾아 | 구글에서 {검색어} 찾아 | {상품} 최저가
        {앱 이름} 열어 | 뒤로 가 | 앞으로 가 | 새로고침 | 화면 꺼
        소리 키워 | 소리 줄여 | 볼륨 {0-100} | 음소거 | 몇 시야 | 오늘 며칠이야
        {N}분 타이머 | {N}시에 {할 일} 알려 줘 | 타이머 취소 | {장소} 가는 길
        Several of them in one sentence → join with " 그리고 ". Keep EVERY job that was asked for (never drop one), and put only
        the thing to find into a search — never the other jobs. 「적당하게·잘 들리게」 for volume → 볼륨 50.
        Answer BRAIN for anything else: questions that need thinking or looking at the screen, clicking something
        on a page, typing or sending text, anything about Claude/sessions/files/code, or when unsure.
        Examples:
        「유튜브에서 아이유 노래 좀 찾아서 틀어 봐」 → 유튜브 아이유 노래 틀어
        「쿠팡 가서 무선 이어폰 좀 보여 줄래」 → 쿠팡에서 무선 이어폰 찾아
        「너무 시끄럽다 좀 작게」 → 소리 줄여
        「이거 다음 거」 → 다음 영상
        「쿠팡에서 맥미니 검색하면서 베토벤 음악도 하나 틀어봐. 볼륨은 적당하게」 → 쿠팡에서 맥미니 찾아 그리고 유튜브 베토벤 음악 틀어 그리고 볼륨 50
        「이 페이지 요약해 줘」 → BRAIN
        「카톡으로 엄마한테 늦는다고 보내」 → BRAIN
        """
    }

    func warm() { if enabled { ensure() } }
    private func ensure() {
        if let p = proc, p.isRunning, turns < 30 { return }
        proc?.terminate(); proc = nil
        guard let bin = cfg.claudeBinary else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                       "--model", cfg.router.isEmpty || cfg.router == "on" ? "haiku" : cfg.router,
                       "--system-prompt", Router.prompt(ko: cfg.ko),
                       "--tools", "", "--disable-slash-commands", "--setting-sources", "project", "--strict-mcp-config"]
        p.currentDirectoryURL = Paths.home.appendingPathComponent("work")
        var env = ProcessInfo.processInfo.environment; env["PATH"] = Paths.envPath; p.environment = env
        let inPipe = Pipe(), out = Pipe()
        p.standardInput = inPipe; p.standardOutput = out; p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }   // end of output: stop, or it is called again and again (10/29: a busy loop after every turn)
            DispatchQueue.main.async { self?.feed(d) }
        }
        p.terminationHandler = { [weak self] dead in DispatchQueue.main.async { if self?.proc === dead { self?.proc = nil; self?.reply(nil) } } }
        do { try p.run() } catch { log("router failed to start: \(error)"); return }
        proc = p; stdin = inPipe.fileHandleForWriting; turns = 0; skip = 0; buffer = Data()
        log("router warm")
    }
    private func feed(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if obj["type"] as? String == "rate_limit_event" { AIUsage.noteClaude(obj); continue }
            guard obj["type"] as? String == "result" else { continue }
            if skip > 0 { skip -= 1; continue }
            reply((obj["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    private func reply(_ s: String?) { let w = waiting; waiting = nil; w?(s) }

    /// Rewrites `text` into a canonical command, or nil (BRAIN / unsure / too slow).
    func route(_ text: String, front: String, timeout: TimeInterval = 3, done: @escaping (String?) -> Void) {
        guard enabled, waiting == nil, text.count <= 60 else { done(nil); return }
        ensure()
        guard let stdin else { done(nil); return }
        let t0 = Date()
        waiting = { s in
            let line = (s ?? "").split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            log(String(format: "router %.1fs: %@ → %@", Date().timeIntervalSince(t0), text, line.isEmpty ? "-" : line))
            done(line.isEmpty || line.uppercased().hasPrefix("BRAIN") ? nil : line)
        }
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": "[front app: \(front)] \(text)"]]
        guard var data = try? JSONSerialization.data(withJSONObject: msg) else { reply(nil); return }
        data.append(0x0A); turns += 1
        stdin.write(data)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.waiting != nil else { return }
            log("router too slow → brain"); self.reply(nil)
            self.skip += 1                               // its late answer must not land on the next question
        }
    }
    func stop() { proc?.terminate(); proc = nil }
}

/// Sentences the router mapped, kept so they run instantly next time (no model at all). ~/.macbutler/aliases.json, 0600.
enum Aliases {
    private static var file: URL { Paths.home.appendingPathComponent("aliases.json") }
    private(set) static var all: [String: String] = {
        guard let d = try? Data(contentsOf: file), let a = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return a
    }()
    static func lookup(_ said: String) -> String? { all[Parser.squash(said)] }
    static func learn(_ said: String, _ canon: String) {
        all[Parser.squash(said)] = canon
        if all.count > 500 { all.removeValue(forKey: all.keys.first!) }
        guard let d = try? JSONEncoder().encode(all) else { return }
        FileManager.default.createFile(atPath: file.path, contents: d, attributes: [.posixPermissions: 0o600])
    }
    static func forget(_ said: String) { all[Parser.squash(said)] = nil }
}
