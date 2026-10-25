// Local Whisper (whisper.cpp `whisper-server`) for accurate final text.
// Started on demand, stopped after 3 idle minutes (~1 GB of memory).
import Foundation

final class Whisper {
    let model: String
    let binary: String?
    let language: String
    let prompt: String
    // A fresh random loopback port each launch, and we only talk to the server process we started —
    // another program can't squat a known port and feed us fake "transcriptions".
    let port = Int.random(in: 20_000...60_000)
    private var proc: Process?
    private var lastUse = Date()
    private var queue: [([Float], String, (String) -> Void, Bool)] = []      // last: low (listening for the name in passing)
    private var running = false

    init(model: String, binary: String?, language: String, prompt: String) {
        self.model = model; self.binary = binary; self.language = language; self.prompt = prompt
        // Clean up a server we left behind in a previous run (pid file, and only if it really is whisper-server).
        let pidFile = Paths.home.appendingPathComponent("whisper.pid")
        if let t = try? String(contentsOf: pidFile, encoding: .utf8), let old = pid_t(t.trimmingCharacters(in: .whitespacesAndNewlines)),
           let name = Whisper.processName(old), name.contains("whisper-server") { kill(old, SIGTERM) }
        try? FileManager.default.removeItem(at: pidFile)
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, let p = self.proc, p.isRunning, Date().timeIntervalSince(self.lastUse) > 180 else { return }
            p.terminate(); self.proc = nil; log("whisper idle → stopped")
        }
    }
    var available: Bool { binary != nil && FileManager.default.fileExists(atPath: model) }

    func warm() {
        lastUse = Date()
        guard available, let binary, proc?.isRunning != true else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["-m", model, "--host", "127.0.0.1", "--port", String(port), "-l", language, "-t", "4"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do {
            try p.run(); proc = p; log("whisper on (port \(port))")
            try? String(p.processIdentifier).write(to: Paths.home.appendingPathComponent("whisper.pid"), atomically: true, encoding: .utf8)
        } catch { log("whisper failed: \(error)") }
    }
    func stop() { proc?.terminate(); proc = nil }

    /// One at a time so dictation stays in order. Falls back to Apple's text on any failure.
    /// What Whisper heard when its text was set aside for Apple's (unsure / unrelated) — the other candidate.
    private(set) var lastSetAside = ""
    /// Exactly what Whisper wrote last, before any filter (the name check looks at it even when the text was set aside).
    private(set) var lastRaw = ""
    /// One job at a time. A command goes ahead of everything; `low` jobs (is the name in this stray sound?) are skipped when
    /// anything else is waiting — 10/25 during filming every cough, clap and OBS sound was queued and commands waited 5–26 s.
    func transcribe(_ audio: [Float], fallback: String, low: Bool = false, done: @escaping (String) -> Void) {
        lastSetAside = ""
        guard available, audio.count > 8000 else { done(fallback); return }
        if low {
            guard !running, queue.isEmpty else { done(fallback); return }
            queue.append((audio, fallback, done, true))
        } else {
            let stale = queue.filter { $0.3 }
            queue.removeAll { $0.3 }
            stale.forEach { $0.2($0.1) }
            queue.insert((audio, fallback, done, false), at: queue.firstIndex { $0.3 } ?? queue.count)
        }
        next()
    }
    private func next() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let (audio, fallback, done, _) = queue.removeFirst()
        warm()
        let wav = Whisper.wav(audio)
        attempt(wav, tries: 30) { [weak self] text, words in
            guard let self else { return }
            var t = Whisper.clean(text ?? "", apple: fallback)
            let heard = t
            self.lastRaw = heard
            // "맥미니 M6 찾아. 고팩! 고팩! 고팩!" — a word repeated at the end that Apple didn't hear is made up.
            let (trimmed, dropped) = Whisper.dropRepeatedTail(t, apple: fallback)
            if !dropped.isEmpty { log("whisper: dropped repeated tail \(dropped)"); t = trimmed }
            // 「자비스, 지금 음악 끄고 …. 자비스, 지금 음악 끄고 ….」 — the whole sentence twice → once
            if let once = Whisper.saidTwice(t) { log("whisper: same sentence twice → once"); t = once }
            let kept = words.filter { w in !dropped.contains(Parser.squash(w.0)) }
            // A word Whisper itself wasn't sure of, that Apple didn't hear either, means the audio was garbled
            // (e.g. "지금 몇 시야" → "신별시야") — then Apple's live text is the safer one.
            let shaky = Whisper.shaky(kept, apple: fallback)
            if !t.isEmpty, !shaky.isEmpty, Parser.squash(fallback).count * 10 >= Parser.squash(t).count * 7 {
                log("whisper unsure of \(shaky.joined(separator: ", ")) → Apple text: \(t)"); t = ""
            }
            Utterances.keep(wav, apple: fallback, whisper: t)
            if Whisper.isHallucination(t, apple: fallback) { t = "" }
            // "- 어디야죠? - 혼자 더 맛있어. - 하이자비스. …" — a video or other people talking got transcribed too.
            if !t.isEmpty, !fallback.isEmpty, t.hasPrefix("- ") || t.contains(" - ")
                || Parser.squash(t).count > Parser.squash(Whisper.hangulize(fallback)).count * 2 + 6 {
                log("whisper heard more than you said (video / other voices) → Apple text: \(t)"); t = ""
            }
            if !t.isEmpty, !fallback.isEmpty, !Whisper.related(t, fallback) { log("whisper ignored (unrelated to what was heard): \(t)"); t = "" }
            if self.language == "ko", !t.isEmpty, Whisper.hangulRatio(fallback) > 0.5, Whisper.hangulRatio(t) < 0.5 { t = "" }
            if t.isEmpty, !heard.isEmpty, !heard.contains(" - "), Parser.squash(heard).count <= Parser.squash(fallback).count * 3 + 10 { self.lastSetAside = heard }
            log("whisper: \(t.isEmpty ? "(using Apple text)" : t)")
            done(t.isEmpty ? fallback : t)
            self.running = false; self.next()
        }
    }
    /// The text is one sentence repeated (optionally with the wake word again) → that sentence.
    static func saidTwice(_ t: String) -> String? {
        let parts = t.components(separatedBy: CharacterSet(charactersIn: ".?!。")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count >= 2, parts.count % 2 == 0 else { return nil }
        let half = parts.count / 2
        let key = { (xs: ArraySlice<String>) in Parser.squash(xs.joined(separator: " ")).replacingOccurrences(of: "자비스", with: "") }
        guard key(parts[..<half]).count >= 4, key(parts[..<half]) == key(parts[half...]) else { return nil }
        // the first half as it was written — its own 「?」「!」 kept (Handy-like punctuation)
        var ends = 0
        for i in t.indices where ".?!。".contains(t[i]) {
            ends += 1
            if ends == half { return String(t[...i]).trimmingCharacters(in: .whitespaces) }
        }
        return parts[..<half].joined(separator: ". ") + "."
    }
    private func attempt(_ wav: Data, tries: Int, done: @escaping (String?, [(String, Double)]) -> Void) {
        guard proc?.isRunning == true else { done(nil, []); return }   // never trust a port we didn't start
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        req.httpMethod = "POST"; req.timeoutInterval = 15
        let b = "mj\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(b)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ n: String, _ v: String) { body.append("--\(b)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!) }
        field("response_format", "verbose_json"); field("language", language); field("temperature", "0")
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(b)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav); body.append("\r\n--\(b)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            DispatchQueue.main.async {
                if err != nil, tries > 0 {   // model still loading
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.attempt(wav, tries: tries - 1, done: done) }
                    return
                }
                let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                // Pieces without a leading space belong to the word before; a word is as sure as its least sure piece.
                var words: [(String, Double)] = []
                for w in (obj?["segments"] as? [[String: Any]] ?? []).flatMap({ $0["words"] as? [[String: Any]] ?? [] }) {
                    guard let t = w["word"] as? String, let p = w["probability"] as? Double else { continue }
                    if t.hasPrefix(" ") || words.isEmpty { words.append((t.trimmingCharacters(in: .whitespaces), p)) }
                    else { words[words.count - 1].0 += t; words[words.count - 1].1 = min(words[words.count - 1].1, p) }
                }
                done(obj?["text"] as? String, words)
            }
        }.resume()
    }

    static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }
    /// Line by line: removes the classic subtitle/thanks hallucinations Whisper adds on noise.
    static func clean(_ raw: String, apple: String) -> String {
        let bad = ["자막", "시청해", "구독", "좋아요", "MBC", "KBS", "SBS", "by ", "Thanks for watching", "Subtitles"]
        return raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in !line.isEmpty && !bad.contains { line.contains($0) && !apple.contains($0) } }
            .joined(separator: " ")
    }
    /// Whisper's text should share most of its characters with what Apple heard live; if not, the audio was
    /// probably cut wrong (old speech, our own voice) — better to trust the live text.
    static func related(_ w: String, _ apple: String) -> Bool {
        let apple = Whisper.hangulize(apple), w = Whisper.hangulize(w)
        let a = apple.filter { $0.isLetter || $0.isNumber }.lowercased(), b = w.filter { $0.isLetter || $0.isNumber }.lowercased()
        guard a.count >= 3 else { return b.count <= max(8, a.count * 4) }
        let bag = Set(b)
        let hit = a.filter { bag.contains($0) }.count
        return Double(hit) / Double(a.count) >= 0.45 && b.count <= a.count * 3 + 10
    }
    /// Apple writes some words in Latin letters, Whisper in Hangul — compare them as the same.
    static func hangulize(_ s: String) -> String {
        var t = s
        for (en, ko) in [("youtube", "유튜브"), ("mac mini", "맥미니"), ("macbook", "맥북"), ("claude", "클로드"), ("chrome", "크롬"), ("google", "구글"),
                         ("safari", "사파리"), ("github", "깃허브"), ("iphone", "아이폰"), ("ok", "오케이")] {
            t = t.replacingOccurrences(of: en, with: ko, options: .caseInsensitive)
        }
        return t
    }
    /// Removes a word Whisper repeated at the very end ("…, 고팩! 고팩! 고팩!") unless Apple heard it too.
    static func dropRepeatedTail(_ t: String, apple: String) -> (String, Set<String>) {
        var parts = t.split(separator: " ").map(String.init)
        guard parts.count >= 3 else { return (t, []) }
        let last = Parser.squash(parts.last!)
        guard !last.isEmpty, Parser.squash(parts[parts.count - 2]) == last, !Parser.squash(apple).contains(last) else { return (t, []) }
        while let p = parts.last, Parser.squash(p) == last { parts.removeLast() }
        return (parts.joined(separator: " "), [last])
    }
    /// Words Whisper gave low probability to and that Apple's live text doesn't contain.
    static func shaky(_ words: [(String, Double)], apple: String) -> [String] {
        let a = Parser.squash(Whisper.hangulize(apple))
        return words.filter { w, p in
            let k = Parser.squash(w)
            return p < 0.35 && k.count >= 2 && !a.contains(k)
        }.map { "\($0.0) \(String(format: "%.2f", $0.1))" }
    }
    static func hangulRatio(_ x: String) -> Double {
        Double(x.unicodeScalars.filter { $0.value >= 0xAC00 && $0.value <= 0xD7A3 }.count) / Double(max(x.filter { $0.isLetter }.count, 1))
    }
    /// Classic Whisper hallucinations on silence/noise.
    static func isHallucination(_ t: String, apple: String) -> Bool {
        if t.isEmpty { return true }
        let bad = ["시청해 주셔서", "구독과 좋아요", "구독 좋아요", "MBC 뉴스", "자막 제공", "감사합니다.", "Thanks for watching", "Thank you for watching", "Subtitles by"]
        return bad.contains { t.contains($0) && !apple.contains($0.replacingOccurrences(of: ".", with: "")) }
    }
    static func wav(_ f: [Float], rate: Int = 16000) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + f.count * 2)); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(f.count * 2))
        var pcm = [Int16](repeating: 0, count: f.count)
        for i in 0..<f.count { pcm[i] = Int16(max(-1, min(1, f[i])) * 32767) }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
