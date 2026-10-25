// Always-on microphone → live partial text (Apple on-device speech) + utterance audio (16 kHz) for Whisper.
import AVFoundation
import Speech

final class Ear {
    private var engine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer
    /// The custom language model that knows the assistant's name (NameModel) — set once it's ready, used from the next restart.
    var nameModel: Any?
    /// Automatic gain (10/24: the name said from across the room reached the mic at -50 dB and nothing recognized it). Speech
    /// is raised toward -12 dBFS for the recognizer and Whisper only — levels for echo and barge-in stay as heard. Tap thread only.
    private var agcPeak: Float = 0.25, agcGain: Float = 1
    static let agcMax: Float = 10          // at most +20 dB, so a quiet room isn't turned into noise
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var lastText = ""
    private var lastChange = Date()
    private var taskStart = Date()
    private var gen = 0
    private var floor: Float = 0.01
    private var lastLoud = Date.distantPast
    private let hints: [String]
    var muted = false
    var silenceSec = 1.8
    var onPartial: (String) -> Void = { _ in }
    var onUtterance: (String, [Float]) -> Void = { _, _ in }
    /// A short burst of voice the recognizer wrote nothing for (the name said quietly or from afar often ends up like this).
    var onSilentSpeech: ([Float]) -> Void = { _ in }
    private var silentHandled = -1
    var onLevel: (Float) -> Void = { _ in }
    /// true: the mic has sent pure digital silence for 2 minutes (muted at the mic — 10/25 the Shure MV7+ was muted for 1.5 h
    /// and nothing said so); false: sound is back.
    var onDeadMic: (Bool) -> Void = { _ in }
    private var silentMinutes = 0
    private(set) var voicing: Float = 0          // how voice-like the latest chunk was (DoubleTalk.periodicity)

    // Last 40 s of 16 kHz mono audio; each utterance is cut from here and re-transcribed by Whisper.
    private var ring: [Float] = []
    private var ringBase = 0
    private var segStart = 0
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var ringEnd: Int { ringBase + ring.count }

    private let inputUID: String
    init(locale: String, hints: [String], inputUID: String = "") {
        self.inputUID = inputUID
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) ?? SFSpeechRecognizer()!
        self.hints = hints
    }

    private func segment() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let a = max(max(segStart, speechOnset) - ringBase, 0)
        return a < ring.count ? Array(ring[a...]) : []
    }

    private var lastBuffer = Date()
    private var speechOnset = 0                 // absolute sample where the current utterance began (VAD)
    private var lastTextSample = 0              // ring position when the live text last changed
    private var engineObserver: NSObjectProtocol?

    func start() throws {
        // If the mic can't start now, don't stay deaf: the watchdog below retries every few seconds (10/24 01:34).
        do { try startEngine() } catch { log("ear: mic start failed (\(error)) → will retry") }
        restart()
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
        // The mic stops when another app (e.g. a dictation app) or a device change reconfigures audio.
        // Restart on Apple's notification, and as a watchdog if no audio arrived for 3 s.
        observeEngine()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.lastRestart) > 3 else { return }
            self.lock.lock(); let last = self.lastBuffer; self.lock.unlock()
            if Date().timeIntervalSince(last) > 3, Date() >= self.settleUntil { log("ear: no audio for 3 s → restarting mic"); self.restartEngine() }
            // Voice is coming in but the recognizer has produced nothing for 10 s → it's stuck; start a fresh task.
            if !self.muted, !self.holding, Date().timeIntervalSince(self.lastLoud) < 2, Date().timeIntervalSince(self.lastChange) > 20,
               Date().timeIntervalSince(self.taskStart) > 20 { log("ear: speech but no text for 20 s → restarting recognizer"); self.restart() }
        }
        // Heartbeat for troubleshooting: loudest level heard in the last minute.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            log(String(format: "ear: alive · peak %.3f · floor %.4f", self.peak, self.floor))
            if self.peak < 0.001, self.floor < 0.0001, !self.muted {      // muted Shure: −91 dB ≈ 0.00003, never exactly 0; a live mic peaks ≥ 0.01 a minute
                self.silentMinutes += 1; if self.silentMinutes == 2 { log("ear: mic sends pure silence (muted at the mic?)"); self.onDeadMic(true) } }
            else { if self.silentMinutes >= 2 { log("ear: sound is back"); self.onDeadMic(false) }; self.silentMinutes = 0 }
            self.peak = 0
        }
        log("ear on: on-device=\(recognizer.supportsOnDeviceRecognition)")
    }

    private var lastRestart = Date.distantPast
    private var peak: Float = 0
    private func observeEngine() {
        if let o = engineObserver { NotificationCenter.default.removeObserver(o) }
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            // Our own restart (or picking a device) also fires this — only react if the mic really stopped,
            // and never more than once every 3 s (this used to loop 70 times a minute).
            guard self.capture == nil, !self.engine.isRunning, Date().timeIntervalSince(self.lastRestart) > 3 else { return }
            // Let the other app finish reconfiguring first (OBS + screen recording on the same mic ping-ponged with us, 10/25 17:07)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.capture == nil, !self.engine.isRunning else { return }
                log("ear: audio configuration changed → restarting mic"); self.restartEngine()
            }
        }
    }
    private var retired: [AVAudioEngine] = []
    private var recentRestarts: [Date] = []
    private var settleUntil = Date.distantPast
    private var settleRetry = false
    /// Several restarts in a row mean another app (OBS, screen recording, a call) keeps changing the mic: back off and let it settle.
    private func restartEngine() {
        let now = Date()
        if now < settleUntil {
            if !settleRetry { settleRetry = true
                DispatchQueue.main.asyncAfter(deadline: .now() + settleUntil.timeIntervalSince(now) + 0.1) { [weak self] in self?.settleRetry = false; self?.restartEngine() } }
            return
        }
        recentRestarts = recentRestarts.filter { now.timeIntervalSince($0) < 30 } + [now]
        if recentRestarts.count >= 4 {
            let wait: TimeInterval = recentRestarts.count >= 8 ? 15 : 8
            settleUntil = now.addingTimeInterval(wait)
            log("ear: the mic keeps changing (another app such as OBS or screen recording is using it) → waiting \(Int(wait)) s for it to settle")
        }
        lastRestart = Date()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Keep the old engine alive a moment: freeing it while Core Audio is still tearing it down crashed (10/24 00:39).
        let old = engine; retired.append(old)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.retired.removeAll { $0 === old } }
        engine = AVAudioEngine()          // a fresh engine so the chosen mic is applied cleanly
        observeEngine()
        lock.lock(); lastBuffer = Date(); lock.unlock()
        do { try startEngine(); restart() } catch { log("ear: mic restart failed: \(error)") }
    }

    private var capture: MicCapture?
    private func startEngine() throws {
        // The chosen mic isn't the Mac's default input (e.g. AirPods became the default): open it directly. Going through the
        // engine left it in the default device's format (24 kHz AirPods vs the MV7+'s 48 kHz) and it kept failing (10/25 17:07).
        capture?.stop(); capture = nil
        if !inputUID.isEmpty, AudioDevices.defaultInputUID() != inputUID, AudioDevices.device(uid: inputUID) != nil {
            let cap = MicCapture(uid: inputUID)
            cap.onBuffer = { [weak self] b in self?.process(b) }
            try cap.start()
            capture = cap
            log("ear: listening on the chosen mic directly (the Mac's default input is another device)")
            return
        }
        let input = engine.inputNode
        if !inputUID.isEmpty, !AudioDevices.use(inputUID, on: input.audioUnit) { log("ear: chosen mic not found → system default") }
        // The node's format, as before (this worked for hours). But if it no longer matches what the mic hardware
        // delivers (after a call app or a device switch), installing a tap aborts the whole app (10/24 01:33) — so
        // refuse instead; the watchdog retries a few seconds later with a fresh engine, which picks up the new format.
        var fmt0 = input.outputFormat(forBus: 0); let hw = input.inputFormat(forBus: 0)
        guard fmt0.sampleRate > 0, hw.sampleRate > 0 else { throw NSError(domain: "Ear", code: 1, userInfo: [NSLocalizedDescriptionKey: "no input device"]) }
        if fmt0.sampleRate != hw.sampleRate {
            // After another app reconfigured the mic the node kept its old rate, and a fresh engine did too — refusing looped every
            // 4 s and left it deaf (10/24 23:00). Re-link the input at the mic's own rate into a silent mixer (never the speakers).
            let sink = AVAudioMixerNode(); sink.outputVolume = 0
            engine.attach(sink)
            engine.connect(input, to: sink, format: hw)
            fmt0 = input.outputFormat(forBus: 0)
            log("ear: mic format \(Int(fmt0.sampleRate)) Hz re-linked to the mic's \(Int(hw.sampleRate)) Hz")
            guard fmt0.sampleRate == hw.sampleRate else {
                throw NSError(domain: "Ear", code: 2, userInfo: [NSLocalizedDescriptionKey: "mic format changed (\(Int(hw.sampleRate)) Hz) — retrying with a fresh engine"])
            }
        }
        converter = nil
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt0) { [weak self] buf, _ in self?.process(buf) }
        engine.prepare()
        try engine.start()
    }

    /// Every chunk of mic audio, from the engine tap or from the chosen mic opened directly (MicCapture). Audio thread.
    private func process(_ buf: AVAudioPCMBuffer) {
        let fmt = buf.format
        // automatic gain: learn how loud speech peaks (only while it's clearly speech), then raise it toward -12 dBFS
        var rawRMS: Float = 0, rawPeak: Float = 0
        if let ch = buf.floatChannelData?[0] {
            let n = Int(buf.frameLength); var sum: Float = 0
            for i in 0..<n { let v = ch[i]; sum += v * v; rawPeak = max(rawPeak, abs(v)) }
            rawRMS = sqrt(sum / Float(max(n, 1)))
        }
        if rawRMS > max(self.floor * 4, 0.002) {
            self.agcPeak = rawPeak > self.agcPeak ? rawPeak : self.agcPeak * 0.97   // follows a quieter voice within ~0.5 s
            let want = min(Ear.agcMax, max(1, 0.25 / max(self.agcPeak, 0.0001)))
            self.agcGain += (want - self.agcGain) * 0.2
        }
        let gain = self.agcGain
        if self.converter?.inputFormat != fmt { self.converter = AVAudioConverter(from: fmt, to: self.target) }
        self.lock.lock(); self.lastBuffer = Date(); self.lock.unlock()
        var voice: Float = 0
        if let conv = self.converter {
            let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / fmt.sampleRate) + 32
            if let out = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: cap) {
                var fed = false
                conv.convert(to: out, error: nil) { _, st in
                    if fed { st.pointee = .noDataNow; return nil }
                    fed = true; st.pointee = .haveData; return buf
                }
                if let d = out.floatChannelData?[0], out.frameLength > 0 {
                    if gain > 1.05 { for i in 0..<Int(out.frameLength) { d[i] = max(-1, min(1, d[i] * gain)) } }
                    // pitch check only for loud chunks (cheap gate) — tells a voice from breath
                    var e: Float = 0
                    for i in 0..<Int(out.frameLength) { e += d[i] * d[i] }
                    if sqrt(e / Float(out.frameLength)) > 0.02 { voice = DoubleTalk.periodicity(d, Int(out.frameLength)) }
                    self.lock.lock()
                    self.ring.append(contentsOf: UnsafeBufferPointer(start: d, count: Int(out.frameLength)))
                    let over = self.ring.count - 16000 * 40
                    if over > 0 { self.ring.removeFirst(over); self.ringBase += over }
                    self.lock.unlock()
                }
            }
        }
        if let ch = buf.floatChannelData?[0] {
            var sum: Float = 0
            let n = Int(buf.frameLength)
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            DispatchQueue.main.async {
                self.peak = max(self.peak, rms)
                if !self.muted {
                    self.floor = rms < self.floor ? rms : self.floor * 0.998 + rms * 0.002
                    if rms > max(self.floor * 3.5, 0.003) {
                        // Voice after a real pause = a new utterance starts here (keep 0.4 s of lead-in).
                        // Not once words are already in: a click or chime after you finished must not cut you off.
                        if Date().timeIntervalSince(self.lastLoud) > self.silenceSec, self.lastText.isEmpty {
                            self.lock.lock(); self.speechOnset = max(self.ringEnd - 6400, self.ringBase); self.lock.unlock()
                        }
                        self.lastLoud = Date()
                    }
                }
                self.voicing = voice
                self.onLevel(self.muted ? 0 : rms)
            }
        }
        if self.muted { return }
        if gain > 1.05, let chans = buf.floatChannelData {
            for c in 0..<Int(buf.format.channelCount) { let ch = chans[c]; for i in 0..<Int(buf.frameLength) { ch[i] = max(-1, min(1, ch[i] * gain)) } }
        }
        self.lock.lock(); let r = self.request; self.lock.unlock()
        r?.append(buf)
    }

    func restart() {
        gen += 1
        let myGen = gen
        task?.cancel()
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { r.requiresOnDeviceRecognition = true }
        r.contextualStrings = hints
        if #available(macOS 13, *) { r.addsPunctuation = true }      // 「…야?」 keeps its question mark, like Handy
        if #available(macOS 14, *), r.requiresOnDeviceRecognition, let m = nameModel as? SFSpeechLanguageModel.Configuration { r.customizedLanguageModel = m }
        lock.lock(); request = r; segStart = max(ringEnd - 4800, ringBase); lock.unlock()   // keep 0.3 s before
        lastText = ""; lastChange = Date(); taskStart = Date()
        task = recognizer.recognitionTask(with: r) { [weak self] res, err in
            DispatchQueue.main.async {
                guard let self, myGen == self.gen else { return }
                if let res {
                    let t = res.bestTranscription.formattedString
                    // The recognizer sometimes drops what it heard and starts over — hand the dropped text over first.
                    if !self.lastText.isEmpty, Ear.isReset(self.lastText, t) {
                        let prev = self.lastText
                        self.lastText = ""
                        let audio = self.segment()
                        // The new words began right after the old text stopped changing — not now (that cut the first word).
                        self.lock.lock(); self.segStart = max(self.lastTextSample - 3200, self.ringBase); self.lock.unlock()
                        self.onUtterance(prev, audio)
                        if myGen != self.gen { return }
                    }
                    if t != self.lastText {
                        self.lastText = t; self.lastChange = Date()
                        self.lock.lock(); self.lastTextSample = self.ringEnd; self.lock.unlock()
                        self.onPartial(t)
                    }
                    if res.isFinal { self.flush() }
                } else if err != nil {
                    self.restart()
                }
            }
        }
    }

    static func isReset(_ a: String, _ b: String) -> Bool {
        let x = a.replacingOccurrences(of: " ", with: ""), y = b.replacingOccurrences(of: " ", with: "")
        if y.count >= x.count / 2 { return false }
        return !x.hasPrefix(String(y.prefix(2)))
    }

    func forceFlush() { if !lastText.isEmpty { flush() } }

    // Push-to-talk (hold the hotkey): exact start/stop like Handy — no guessing where speech begins or ends.
    private(set) var holding = false
    private var holdStart = 0
    func beginHold() { lock.lock(); holdStart = max(ringEnd - 3200, ringBase); lock.unlock(); holding = true; restart() }
    /// Returns what Apple heard live and the exact audio between press and release.
    func endHold() -> (String, [Float]) {
        holding = false
        lock.lock(); let a = max(holdStart - ringBase, 0); let audio = a < ring.count ? Array(ring[a...]) : []; lock.unlock()
        let t = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        restart()
        return (t, audio)
    }
    func cancelHold() { holding = false }
    /// Count only audio from ~0.4 s ago as the current utterance (used when the user interrupts).
    func markSegmentNow(back sec: Double = 0.4) { lock.lock(); segStart = max(ringEnd - Int(sec * 16000), ringBase); lock.unlock() }

    private func flush() {
        let t = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        let audio = segment()
        restart()
        if !t.isEmpty { onUtterance(t, audio) }
    }

    /// Ends like a Korean request or question: 해/줘/봐/켜/꺼/틀어/야/요/까/니/?
    static func soundsFinished(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("?") || s.hasSuffix(".") { return true }
        guard let last = s.split(separator: " ").last.map(String.init), last.count >= 1 else { return false }
        let ends = ["해", "줘", "봐", "켜", "꺼", "어", "아", "야", "요", "다", "까", "니", "래", "자", "워", "려", "와", "라"]
        return ends.contains(String(last.suffix(1))) && !["그래", "아니야", "자비스야"].contains(last) && s.count >= 3
    }
    private func tick() {
        if muted || holding { return }
        // A sentence that clearly ended (「…틀어」「…해 줘」「…야?」) is acted on after 0.9 s, not the full pause.
        let finished = Ear.soundsFinished(lastText)
        let quiet = Date().timeIntervalSince(lastLoud) > (finished ? 0.5 : 0.7)
        if !lastText.isEmpty, quiet, Date().timeIntervalSince(lastChange) > (finished ? min(0.9, silenceSec) : silenceSec) { flush() }
        else if lastText.isEmpty, speechOnset != silentHandled, Date().timeIntervalSince(lastLoud) > 0.8, Date().timeIntervalSince(lastLoud) < 3 {
            lock.lock(); let len = ringEnd - speechOnset; lock.unlock()
            if len > 6400 && len < 72000 { silentHandled = speechOnset; onSilentSpeech(segment()) }      // 0.4–4.5 s of voice, no text
        }
        else if lastText.isEmpty, Date().timeIntervalSince(taskStart) > 50 { restart() }
    }
}
