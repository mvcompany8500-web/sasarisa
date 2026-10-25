// 이름 맞추기 (owner 10/24: 「원하는 비서를 만들면 맥이 바로 움직여요 … 음성으로 10번이나 15번 정도 주인의 음성을 인식하는
// 테스트를 먼저 … 음성 인식 테스트 해가지고 원하는 비서의 이름을 정하세요」).
// The owner says the name they want 12 times — 8 times alone, then 4 times with a short command after it, the way it's
// really used (10/25 owner: 「처음 깔면 호칭을 먼저 정하고, 10번 정도 따라 부르게 해서 그 사람 컴퓨터에 맞게 — siri 처럼」). Each time we keep what Apple's live recognizer and Whisper wrote. Whatever
// they wrote when it wasn't recognized as the name — and that sounds like it, or came back the same way twice — is
// learned as another way this Mac hears the name (Config.learnedWakes[name]). The result says how often it was
// recognized before and after, and suggests another name when it's still poor. Text only is kept; no audio.
import Foundation

final class NameTrainer {
    struct Sample: Codable { let apple: String; let whisper: String; let raw: String; var command = "" }   // command: what followed the name, if asked
    struct Result { let name: String; let total: Int; let before: Int; let after: Int; let learned: [String] }

    let name: String
    let total = 12
    var samples: [Sample] = []
    private var busy = false
    private let base: Config
    private let whisper: Whisper?          // nil in the self-test
    var onProgress: (Int, String) -> Void = { _, _ in }      // (takes so far, what was heard)
    var onDone: (Result) -> Void = { _ in }

    init(name: String, base: Config, whisper: Whisper?) {
        self.name = name.trimmingCharacters(in: .whitespaces); self.base = base; self.whisper = whisper
    }
    var finished: Bool { samples.count >= total }
    /// Take n (0-based): the name alone for the first 8, then the name and a short command.
    func command(_ n: Int) -> String {
        let cmds = base.ko ? ["유튜브 틀어", "소리 줄여", "지금 몇 시야", "타이머 3분"] : ["play some music", "turn it down", "what time is it", "set a timer"]
        return n < total - cmds.count ? "" : cmds[(n - (total - cmds.count)) % cmds.count]
    }
    /// What the card asks the owner to say for take n.
    func prompt(_ n: Int, shownName: String) -> String {
        let c = command(n)
        return c.isEmpty ? shownName : shownName + (base.ko ? ", " : ", ") + c
    }

    /// One take: Apple's text now, Whisper's when it's done (Whisper hears made-up names better).
    func take(_ apple: String, _ audio: [Float]) {
        guard !finished, !busy else { return }
        guard !Parser.squash(apple).isEmpty || audio.count > 6000 else { return }      // nothing said
        busy = true
        let finish = { [weak self] (full: String, raw: String) in
            guard let self else { return }
            self.samples.append(Sample(apple: apple, whisper: full, raw: raw, command: self.command(self.samples.count)))
            self.busy = false
            let shown = [full, apple].first { !Parser.squash($0).isEmpty } ?? ""
            self.onProgress(self.samples.count, shown)
            if self.finished { self.onDone(self.result()) }
        }
        if let w = whisper, w.available, audio.count > 6000, audio.count < 16000 * 8 {
            w.transcribe(audio, fallback: apple) { [weak w] full in finish(full, w?.lastRaw ?? "") }
        } else { finish(apple, "") }
    }

    /// A parser that knows `name` (+ `learned`) as the wake word, the way the app will after saving.
    static func parser(_ base: Config, name: String, learned: [String]) -> Parser {
        var c = base
        c.assistantName = name; c.wakeWords = []; c.learnedWakes = [name: learned]
        return Parser(cfg: c)
    }
    static func hits(_ p: Parser, _ s: Sample) -> Bool { [s.apple, s.whisper, s.raw].contains { !Parser.squash($0).isEmpty && p.wakeRange($0) != nil } }

    func result() -> Result {
        let p0 = NameTrainer.parser(base, name: name, learned: base.learnedWakes[name] ?? [])
        let before = samples.filter { NameTrainer.hits(p0, $0) }.count
        let target = base.ko ? (Config.hangulReading(name) ?? name) : name
        let minLen = max(2, min(3, Parser.squash(target).count))      // a 2-syllable name is misheard as 2 syllables too
        var seen: [String: Int] = [:]
        for s in samples where !NameTrainer.hits(p0, s) {
            let said = [s.apple, s.whisper].map(NameTrainer.norm).compactMap { NameTrainer.withoutCommand($0, s.command) }
            for t in Set(said) where NameTrainer.usable(t, parser: p0, minLen: minLen) { seen[t, default: 0] += 1 }
        }
        // 3+ letters: came back the same way twice, or sounds like the name. Shorter: both (short words wake by accident easily).
        let new = seen.filter { k, n in Parser.squash(k).count >= 3 ? (n >= 2 || NameTrainer.close(k, target)) : (n >= 2 && NameTrainer.close(k, target)) }.map(\.key)
        let learned = Array(Set((base.learnedWakes[name] ?? []) + new)).sorted()
        let p1 = NameTrainer.parser(base, name: name, learned: learned)
        let after = samples.filter { NameTrainer.hits(p1, $0) }.count
        return Result(name: name, total: samples.count, before: before, after: after, learned: learned)
    }

    /// Keeps the learned spellings for this name in config.json (other names' spellings stay) and the takes in name-training.json.
    func save(_ r: Result) {
        var all = base.learnedWakes
        all[r.name] = r.learned
        Config.set("learnedWakes", all)
        let url = Paths.home.appendingPathComponent("name-training.json")
        let rec: [String: Any] = ["name": r.name, "at": ISO8601DateFormatter().string(from: Date()), "before": r.before, "after": r.after, "total": r.total,
                                  "learned": r.learned, "takes": samples.map { ["apple": $0.apple, "whisper": $0.whisper, "raw": $0.raw, "command": $0.command] }]
        if let d = try? JSONSerialization.data(withJSONObject: rec, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url) }
        log("name training \(r.name): \(r.before)/\(r.total) → \(r.after)/\(r.total), learned \(r.learned)")
    }

    // MARK: what can be learned

    static func norm(_ s: String) -> String {
        Parser.clean(s.replacingOccurrences(of: "[~∼〜!?.,]+", with: " ", options: .regularExpression))
            .lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    /// The part before the command (「서서 있어 유튜브 틀어」 → 「서서 있어」); nil when the command isn't clearly there.
    static func withoutCommand(_ t: String, _ command: String) -> String? {
        if command.isEmpty { return t }
        let all = Parser.squash(t), cmd = Parser.squash(command)
        guard all.hasSuffix(cmd), all.count > cmd.count else { return nil }
        var keep = all.count - cmd.count, out = ""
        for ch in t { if keep == 0 { break }; out.append(ch); if ch.isLetter || ch.isNumber { keep -= 1 } }
        return norm(out)
    }
    /// Not too short (common words like 「네」 would wake it all day), not too long, and not a command of its own.
    static func usable(_ t: String, parser: Parser, minLen: Int = 3) -> Bool {
        let n = Parser.squash(t).count
        guard n >= minLen, n <= 12 else { return false }
        let common = ["그래서", "아니야", "아니요", "뭐라고", "잠깐만", "있잖아", "그러니까", "알겠어", "고마워", "괜찮아"]
        if common.contains(Parser.squash(t)) { return false }
        return parser.parse(t, hasYouTubeList: false) == .none
    }
    /// Sounds like the name: letters (Hangul split into its sounds) differ in at most ~40 %.
    static func close(_ a: String, _ b: String) -> Bool {
        let x = jamo(Parser.squash(a)), y = jamo(Parser.squash(b))
        guard !x.isEmpty, !y.isEmpty else { return false }
        return distance(x, y) <= max(2, Int(Double(max(x.count, y.count)) * 0.4))
    }
    static func jamo(_ s: String) -> [UInt32] {
        s.unicodeScalars.flatMap { u -> [UInt32] in
            let v = Int(u.value) - 0xAC00
            guard v >= 0, v < 11172 else { return [u.value] }
            let tail = v % 28
            return [UInt32(0x1100 + v / 588), UInt32(0x1161 + (v % 588) / 28)] + (tail > 0 ? [UInt32(0x11A7 + tail)] : [])
        }
    }
    static func distance(_ a: [UInt32], _ b: [UInt32]) -> Int {
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]; row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }

    /// What to tell the owner about the result.
    static func verdict(_ r: Result, ko: Bool) -> String {
        let rate = r.total == 0 ? 0 : Double(r.after) / Double(r.total)
        if rate >= 0.83 { return ko ? "아주 잘 알아들어요. 이 이름으로 쓰셔도 좋아요." : "It hears this name very well." }
        if rate >= 0.58 { return ko ? "괜찮아요. 가끔은 두 번 불러야 할 수 있어요." : "Good enough — now and then you may need to call it twice." }
        return ko ? "이 이름은 이 맥이 잘 못 알아들어요. 받침 없는 2~4글자, 흔한 말과 다른 이름을 추천해요(예: 모모, 루나, 하루, 나비)."
                  : "This Mac struggles with this name. Try a short name that doesn't sound like everyday words (e.g. Momo, Luna, Nova)."
    }
}
