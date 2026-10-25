// The conductor: listens, decides, acts, speaks.
import AppKit

final class Butler {
    enum Mode { case idle, awake, dictation, busy, speaking }
    var mode: Mode = .idle { didSet { if mode != oldValue { modeSince = Date() } } }
    var modeSince = Date()
    let cfg: Config
    let S: Strings
    let parser: Parser
    let ear: Ear
    let router: Router
    var lastRouted: (said: String, at: Date)?
    var brainSteps = 0
    /// The last quick action, how to take it back, and how to say it: 「되돌려」 / 「방금 뭐 했어?」
    var lastDone: (said: String, undo: (() -> Void)?)?                    // tool steps the brain has taken this turn (router may only overtake it at 0)
    let hud = HUD()
    let mouth: Mouth
    let brain: Thinker
    let whisper: Whisper
    var awakeUntil = Date.distantPast
    var awakeStarted: Date?
    var enabled = true
    var speakingText = ""
    var bargedIn = false
    var ytList: [(id: String, title: String)] = []
    var cancelSend = false
    var brainAskedAt: Date?            // the brain's last answer asked something back (티키타카)
    var awaitingSend = false           // 보내기 전 미리 보기: waiting for 「응」 / 「아니」 on the message shown
    var sendDecision: Bool?
    var lastLive = ""
    var ignoreUntil = Date.distantPast    // our own voice's tail right after speaking
    var previewUntil = Date.distantPast   // Settings is playing a sample voice — nothing heard is a command
    var trainer: NameTrainer?
    /// After 「○○ 대화창이 안 열려 있어요」: 「열어놨어」「다시 해」 runs the same thing again, without the brain (10/25 it retyped an old message).
    var retryLater: (() -> Void)?
    var retryUntil = Date.distantPast             // Settings → 목소리로 이름 맞추기: what's heard goes here, not to commands
    var spokeAt = Date.distantPast        // when it last stopped talking (finished or interrupted)
    var lastSpoken = ""                   // its last spoken answer — its echo can lead the next recording
    var lastMedia: (play: Bool, at: Date)?
    var lastSite: (label: String, url: String, at: Date)?
    // What it opened for you (this run): page hosts and apps it started — 「창 다 꺼」 closes exactly these.
    var openedHosts: Set<String> = []
    var openedURLs: [String] = []      // the exact pages it opened — 「창 다 꺼」 closes these, not every tab on that site
    var openedApps: Set<String> = []
    static let neverClose: Set<String> = ["Claude", "Finder", "Terminal", "iTerm2", "Xcode", "Visual Studio Code", "Cursor", "Sasarisa", "MacButler"]   // 「쿠팡에서 맥미니」 → then just 「M6 찾아」 stays on Coupang
    /// Can anything you say interrupt it? Only when its voice can't reach the mic (headphones).
    lazy var bargeAny: Bool = {
        if cfg.bargeIn == "any" { return true }
        if cfg.bargeIn == "wake" { return false }
        let out = AudioDevices.device(uid: cfg.outputDevice)?.name ?? AudioDevices.defaultOutputName()
        let n = out.lowercased()
        let headphones = ["airpods", "buds", "headphone", "headset", "beats", "이어폰", "wh-", "wf-", "qc"].contains { n.contains($0) } && !n.contains("외장")
        log("barge-in mode: \(headphones ? "any speech (headphones)" : "wake word / stop words only (speakers)") · output: \(out)")
        return headphones
    }()
    func canBargeIn(_ t: String) -> Bool {
        if bargeAny { return true }
        let a = parser.stripWake(t)
        return parser.wakeRange(t) != nil || parser.isHush(a) || ["멈춰", "그만", "스톱", "stop", "잠깐", "됐어"].contains { Parser.squash(a).hasPrefix($0) }
    }            // what Apple's live recognizer heard for the current command
    var learnCandidate: (phrase: String, steps: [[String]])?      // set when you say “취소/멈춰” while a Claude message is about to be sent
    static let claudeBundle = "com.anthropic.claudefordesktop"

    init(cfg: Config) {
        self.cfg = cfg
        S = Strings(ko: cfg.ko, name: cfg.displayName)
        parser = Parser(cfg: cfg)
        Sound.outputUID = cfg.outputDevice
        hud.position = cfg.hudPosition
        Utterances.enabled = cfg.keepAudio
                // Command words help Apple's recognizer get them right from the first partial (Jarhead does the same).
        let commandWords = cfg.ko ? ["클로드", "엔터", "받아써", "그만", "유튜브", "쿠팡", "네이버", "구글", "검색해", "틀어", "재생", "멈춰", "다음 영상",
                                     "창 다 꺼", "닫아", "뒤로 가", "화면 꺼", "다시 틀어", "최저가", "맥미니"]
                                  : ["Claude", "enter", "stop", "YouTube", "search", "play", "pause", "next video", "close", "go back"]
        ear = Ear(locale: cfg.locale, hints: Array((cfg.wakes + cfg.greets + commandWords + cfg.customWords).prefix(100)), inputUID: cfg.inputDevice)
        mouth = Mouth(cfg: cfg)
        brain = Brains.make(cfg)
        router = Router(cfg: cfg)
        whisper = Whisper(model: cfg.whisperModelPath, binary: cfg.whisperBinary, language: cfg.lang,
                          prompt: Butler.glossary(cfg))
    }

    func start() {
        hud.showIdleOrb = cfg.showIdleOrb
        ear.silenceSec = cfg.silenceSec
        ear.onLevel = { [weak self] v in
            guard let self else { return }
            self.hud.orb.level(v)
            self.mouth.echo.listen(v)
            if self.mode == .speaking, !self.bargeAny, self.cfg.bargeIn != "wake", self.mouth.echo.isUser(v, voicing: self.ear.voicing) { self.bargeInByVoice() }
        }
        ear.onPartial = { [weak self] t in self?.partial(t) }
        ear.onUtterance = { [weak self] t, a in self?.utterance(t, audio: a) }
        brain.warm()
        router.warm()
        Growth.sweep()
        if cfg.pauseInCalls { Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkCalls() } }
        Timers.onFire = { [weak self] label in self?.timerFired(label) }
        Timers.restore()
        // Settings → 화면 위치 moves the orb right away (no restart)
        NotificationCenter.default.addObserver(forName: Notification.Name("MacButlerHUDPosition"), object: nil, queue: .main) { [weak self] n in
            if let p = n.object as? String { self?.hud.position = p }
        }
        // Settings → 인사 화면 미리 보기 (object: the style to show)
        NotificationCenter.default.addObserver(forName: Notification.Name("MacButlerBootPreview"), object: nil, queue: .main) { [weak self] n in
            guard let self, self.mode == .idle || self.mode == .awake else { return }
            self.greet(style: n.object as? String)
        }
        // Setup / Settings → 화면 위치: show the card where it now sits for a moment, so you can see before choosing
        NotificationCenter.default.addObserver(forName: Notification.Name("MacButlerHUDDemo"), object: nil, queue: .main) { [weak self] _ in
            guard let self, self.mode == .idle, self.trainer == nil else { return }
            self.hud.show(self.S.t("✓ 여기에 떠요", "✓ It shows up here"), self.S.t("「\(self.cfg.displayName)」 하고 부르면 이 자리에 이 카드가 나와요", "Call “\(self.cfg.displayName)” and this card appears right here"), heard: "", color: lime)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in if self?.mode == .idle, self?.trainer == nil { self?.hud.idle() } }
        }
        // Settings → 미리 듣기: don't listen to our own sample line
        NotificationCenter.default.addObserver(forName: Notification.Name("MacButlerPreview"), object: nil, queue: .main) { [weak self] n in
            self?.previewUntil = (n.object as? Bool) == true ? Date().addingTimeInterval(30) : Date().addingTimeInterval(1.0)
        }
        // Settings → 목소리로 이름 맞추기 (object: the name to try; nil = stop)
        NotificationCenter.default.addObserver(forName: Notification.Name("MacButlerNameTrain"), object: nil, queue: .main) { [weak self] n in
            self?.nameTraining(n.object as? String)
        }
        // 다 같이 키우기: ask once, then share (with consent) and take the pack, once a day
        let growSync = { [weak self] (mode: String) in
            guard let self else { return }
            GrowTogether.sync(self.cfg, parser: self.parser, mode: mode)
            Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
                guard let self else { return }
                GrowTogether.sync(self.cfg, parser: self.parser, mode: Config.load().growTogether)
            }
        }
        if cfg.growTogether.isEmpty { GrowTogether.askIfNeeded(cfg) { growSync($0) } } else { growSync(cfg.growTogether) }
        // Pro — 폰으로 부르기: only while linked to a TurtleMaker account (the server says no to non-members)
        if cfg.proRemote, ProAccount.token != nil { ProAccount.startRemote { [weak self] text, id in self?.runRemote(text, id) } }
        listenForSignals()
        // Always listening: how much memory and CPU it takes, once an hour (to check a whole day of use — 10/25)
        var lastCPU = (Butler.cpuSeconds(), Date())
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            let now = Butler.cpuSeconds(), dt = max(1, Date().timeIntervalSince(lastCPU.1))
            log(String(format: "resources: memory %.0f MB · cpu %.1f%% over the last hour", Butler.memoryMB(), (now - lastCPU.0) / dt * 100))
            lastCPU = (now, Date())
        }
        // Voice with no text at all (quiet, far away) may still be the name — Whisper listens to it once
        // A muted mic says nothing — show it (no sound, no voice: the owner may be recording)
        ear.onDeadMic = { [weak self] dead in
            guard let self else { return }
            let mic = AudioDevices.device(uid: self.cfg.inputDevice)?.name ?? self.S.t("마이크", "the mic")
            if dead { self.hud.show(self.S.t("🎙 마이크에 소리가 안 들어와요", "🎙 No sound from the mic"),
                                    self.S.t("\(mic) 음소거(빨간불)인지 확인해 주세요", "Is \(mic) muted?"), heard: nil, color: .systemRed, speed: 1) }
            else if self.mode == .idle { self.hud.idle() }
        }
        ear.onSilentSpeech = { [weak self] audio in
            if let tr = self?.trainer { tr.take("", audio); return }
            guard let self, self.mode == .idle else { return }
            self.nameByWhisper("", audio)
        }
        // Teach the recognizer the name (made-up words come back as 「서 서 있어」 otherwise) — built once, then used from here on
        let names = Array(Set([cfg.displayName, cfg.assistantName] + cfg.wakes.filter { !$0.contains(" ") && $0 != "자비스" }.prefix(3))).filter { !$0.isEmpty }
        let (locale, ko) = (cfg.locale, cfg.ko)
        Task { @MainActor [weak self] in
            let m = await NameModel.prepare(names: names, locale: locale, ko: ko)
            guard let self, let m else { return }
            self.ear.nameModel = m; self.ear.restart()
        }
        do { try ear.start() } catch { log("mic failed: \(error)"); hud.show("⚠︎", S.micError, color: amber) }
        if !brain.installed { hud.show("⚠︎", S.noClaude, color: amber) }
        log("ready · whisper=\(whisper.available) claude=\(brain.installed) tts=\(cfg.tts)")
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.mode == .awake else { return }
            if self.awakeStarted.map({ Date().timeIntervalSince($0) > self.cfg.maxUtteranceSec }) == true { self.awakeStarted = nil; self.ear.forceFlush() }
            if Date() > self.awakeUntil { self.goIdle() }
        }
        // Never get stuck: a voice reply or a Claude task that hangs must not leave it deaf.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let age = Date().timeIntervalSince(self.modeSince)
            if self.mode == .speaking, age > 90 { log("watchdog: stuck speaking → idle"); self.mouth.stop(); self.speakingText = ""; self.ear.muted = false; self.ear.restart(); self.goIdle() }
            if self.mode == .busy, age > 180 { log("watchdog: task took too long → stop"); self.brain.cancel(); self.goIdle() }
        }
    }

    /// Commands from the bundled tools (`butler`, `jax field`) over the private control socket (see ControlSocket).
    lazy var control = ControlSocket(handler: { [weak self] cmd, text in self?.signal(cmd, text) },
                                     respond: { [weak self] cmd, text in
                                         guard let self else { return cmd == "delegate" ? "pending" : "ask" }
                                         return cmd == "delegate" ? self.delegateFromBrain(text) : self.confirmAction(text)
                                     })
    private func listenForSignals() { control.start() }
    func signal(_ cmd: String, _ text: String) {
        switch cmd {
        case "restart": log("restart requested over the control socket"); SettingsWindow.relaunch()   // same path as Settings' restart
        case "type":
            if cfg.brainAccess != "full", let b = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Butler.protectedApps.contains(b) || b == Bundle.main.bundleIdentifier {
                log("blocked typing into protected app \(b)"); return
            }
            if cfg.brainAccess != "full", AX.focusedIsSecure() { log("blocked typing into a password field"); return }
            // A line break typed into a chat box or form is Enter — it would send/submit without the send check.
            let line = cfg.brainAccess == "full" ? text : text.replacingOccurrences(of: #"[\r\n\u{2028}\u{2029}]+"#, with: " ", options: .regularExpression)
            DispatchQueue.global().async { Hands.typeVisible(line) }
        case "session":   // switch the Claude app to a session by name — navigation only, nothing typed
            openClaudeSession(text)
        case "settings": if text == "close" { SettingsWindow.window?.close() } else { SettingsWindow.show(cfg: cfg) }
        case "setup": if text == "close" { SetupWindow.window?.close() } else { SetupWindow.show(cfg: cfg) }
        case "say":   // text instead of voice — for testing and screen recordings
            log("text command: \(text)")
            if parser.isGreeting(text) { greet(); return }
            if mode == .idle { mode = .awake; awakeUntil = Date().addingTimeInterval(cfg.followUpSec) }
            utterance(text, audio: [])
        default: break
        }
    }

    // MARK: listening

    /// Hold the hotkey and talk; release to run it right away (exact audio, no waiting for silence).
    func holdBegan() {
        guard enabled else { return }
        if mode == .speaking { mouth.stop(); speakingText = ""; bargedIn = true }
        if brain.busy { brain.cancel(silently: true) }
        whisper.warm()
        ear.muted = false
        ear.beginHold()
        mode = .awake; awakeStarted = nil; awakeUntil = Date().addingTimeInterval(cfg.followUpSec)
        Sound.named(cfg.chime)
        hud.show(S.t("● 듣는 중 · 손을 떼면 실행", "● Listening · release to run"), S.speakNow, heard: "")
    }
    func holdEnded() {
        let (t, audio) = ear.endHold()
        log("hold: \(audio.count / 16) ms, live text: \(t)")
        guard audio.count > 4800 else { converse(); return }
        hud.show(S.transcribing, t.isEmpty ? "…" : t, speed: 2)
        lastLive = parser.stripWake(t)
        whisper.transcribe(audio, fallback: t) { [weak self] full in
            guard let self else { return }
            let cmd = self.parser.stripWake(full)
            if cmd.isEmpty { self.converse(); return }
            if self.mode == .dictation { self.dictate(full) } else { self.byHold = true; self.handle(cmd); self.byHold = false }
        }
    }
    func holdCancelled() { ear.cancelHold() }

    /// Recognizer hints grow with what you say (saved to config.json customWords, used from the next launch).
    func studyWords(whisper w: String, live: String) {
        let new = Growth.study(whisper: w, live: live, known: cfg.customWords + cfg.wakes)
        guard !new.isEmpty else { return }
        let url = Paths.home.appendingPathComponent("config.json")
        var obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        var words = obj["customWords"] as? [String] ?? cfg.customWords
        words.append(contentsOf: new.filter { !words.contains($0) })
        obj["customWords"] = Array(words.suffix(150))
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) { try? d.write(to: url) }
    }

    /// Same as saying the wake word (hotkey). While speaking it interrupts; while awake it ends the conversation.
    func manualWake() {
        guard enabled else { return }
        switch mode {
        case .idle: whisper.warm(); converse(chime: true)
        case .speaking: mouth.stop(); speakingText = ""; bargedIn = true; ear.restart(); converse(chime: true)
        case .awake: Sound.named("Pop"); goIdle()
        case .busy: brain.cancel()
        case .dictation: converse(chime: true)
        }
    }

    func partial(_ t: String) {
        if let tr = trainer { trainCard(tr, heard: t); return }
        guard enabled, cfg.activation != "hold" || ear.holding || mode == .speaking || mode == .dictation else { return }
        switch mode {
        case .idle:
            if parser.isGreeting(t) { greet(); return }
            if let r = parser.wakeRange(t) {        // react the moment the wake word appears
                whisper.warm()
                Sound.named(cfg.chime)
                mode = .awake; awakeStarted = Date()
                awakeUntil = Date().addingTimeInterval(cfg.followUpSec)
                let rest = Parser.clean(String(t[r.upperBound...]))
                hud.show(S.listening, rest.isEmpty ? S.speakNow : rest)
            }
        case .awake:
            if parser.isGreeting(t) { greet(); return }
            if awakeStarted == nil { awakeStarted = Date() }
            awakeUntil = Date().addingTimeInterval(cfg.followUpSec)
            hud.show(S.conversing, t)
        case .dictation: hud.show(S.dictation, t, color: lime)
        case .speaking:
            if !speakingText.isEmpty, !isEcho(t), canBargeIn(t) { bargeIn(t) }
        case .busy:
            if brain.busy { hud.show(S.listening, t, heard: nil, color: amber, speed: 3) }
            let q = Parser.squash(t)
            if ["취소", "멈춰", "하지마", "아니", "스톱", "stop", "cancel"].contains(where: { q.hasSuffix($0) }) { cancelSend = true }
        }
    }

    func utterance(_ t: String, audio: [Float]) {
        guard enabled, !ear.holding else { return }   // push-to-talk delivers its own utterance on release
        if let tr = trainer { log("name training take: \(t)"); tr.take(t, audio); return }
        if Date() < previewUntil { log("ignored (voice preview): \(t)"); return }
        if Date() < ignoreUntil, mode == .awake { log("ignored (our own voice tail): \(t)"); return }
        if cfg.activation == "hold", mode != .dictation, mode != .speaking { return }   // hold-only: nothing is acted on without the key
        log("heard[\(mode)]: \(t)")
        switch mode {
        case .idle:
            if parser.isGreeting(t) { greet(); return }
            guard parser.wakeRange(t) != nil else { nameByWhisper(t, audio); return }
            mode = .awake; awakeUntil = Date().addingTimeInterval(cfg.followUpSec)
            fallthrough
        case .awake:
            awakeStarted = nil
            if parser.isGreeting(t) { return }      // already started from the partial
            let a = parser.stripWake(t)
            if a.isEmpty { hud.show(S.conversing, S.speakNow); return }
            if parser.instant(a) { handle(a); return }
            // A plain quick command (no words of yours to type or search) runs on Apple's text right away — Whisper only
            // adds a second or more (10/25 owner: 「음성을 받아서 진행하는데 정말 느려서 답답해 죽어」)
            if Butler.noFreeText(parser.parse(a, hasYouTubeList: !ytList.isEmpty)) { log("quick (no Whisper wait): \(a)"); lastLive = a; command(t); return }
            refine(audio, t) { [weak self] full in self?.command(full) }
        case .dictation:
            whisper.transcribe(audio, fallback: t) { [weak self] full in self?.dictate(full) }
        case .busy:
            let a = parser.stripWake(t)
            if awaitingSend {
                let q = Parser.squash(a)
                if ["응", "네", "예", "그래", "보내", "좋아", "그렇게", "오케이", "ㅇㅇ", "yes", "yeah", "send", "ok", "okay", "sure"].contains(where: { q.hasPrefix($0) }) { sendDecision = true; return }
                if ["아니", "취소", "하지마", "됐어", "멈춰", "no", "nope", "cancel", "stop"].contains(where: { q.hasPrefix($0) }) { sendDecision = false; return }
                return
            }
            if parser.isHush(a) || parser.isBye(a) || Parser.cancelledAtEnd(" " + a) || ["취소", "멈춰", "stop", "cancel"].contains(Parser.squash(a)) {
                cancelSend = true
                if brain.busy { brain.cancel() }
                return
            }
            // A new command while Claude is still thinking: drop the old one and take the new one right away.
            // (While a message is being typed into the Claude app we don't interrupt — only “취소” stops it.)
            // …but not for a stray word from someone else in the room ("할게"): a real command, the wake word, or a full sentence.
            if brain.busy, parser.wakeRange(t) != nil || parser.parse(a, hasYouTubeList: !ytList.isEmpty) != .none || Parser.squash(a).count >= 8 {
                log("interrupt → new command: \(a)")
                brain.cancel(silently: true)
                mode = .awake; awakeUntil = Date().addingTimeInterval(cfg.followUpSec)
                refine(audio, t) { [weak self] full in self?.command(full) }
            }
        case .speaking:
            if !speakingText.isEmpty, !isEcho(t), canBargeIn(t) {
                bargeIn(t); awakeStarted = nil
                refine(audio, t) { [weak self] full in self?.command(full) }
            }
        }
    }

    /// 이름 맞추기: 12 takes of the name, then the result goes back to Settings (and the learned spellings are saved).
    func nameTraining(_ name: String?) {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            if trainer != nil { trainer = nil; hud.idle(); log("name training stopped") }
            return
        }
        if brain.busy { brain.cancel(silently: true) }
        mouth.stop()
        mode = .idle
        let tr = NameTrainer(name: name, base: cfg, whisper: whisper)
        let post = { (info: [String: Any]) in NotificationCenter.default.post(name: Notification.Name("MacButlerNameTrainProgress"), object: nil, userInfo: info) }
        tr.onProgress = { [weak self, weak tr] n, heard in
            guard let self, let tr else { return }
            Sound.named(self.cfg.chime)
            self.trainCard(tr, heard: heard)
            post(["n": n, "heard": heard, "next": n < tr.total ? tr.prompt(n, shownName: self.cfg.ko ? (Config.hangulReading(tr.name) ?? tr.name) : tr.name) : ""])
        }
        tr.onDone = { [weak self, weak tr] r in
            guard let self, let tr else { return }
            tr.save(r)
            self.trainer = nil
            let v = NameTrainer.verdict(r, ko: self.cfg.ko)
            self.hud.show(self.S.t("✓ 이름 맞추기 끝 · \(r.after)/\(r.total)", "✓ Name check done · \(r.after)/\(r.total)"), v, heard: "", color: r.after * 100 >= r.total * 58 ? lime : amber)
            post(["done": true, "before": r.before, "after": r.after, "total": r.total, "learned": r.learned, "verdict": v])
        }
        trainer = tr
        log("name training started: \(name)")
        trainCard(tr, heard: "")
        post(["n": 0, "heard": "", "next": tr.prompt(0, shownName: cfg.ko ? (Config.hangulReading(tr.name) ?? tr.name) : tr.name)])
    }
    private func trainCard(_ tr: NameTrainer, heard: String) {
        let shown = cfg.ko ? (Config.hangulReading(tr.name) ?? tr.name) : tr.name
        let n = min(tr.samples.count, tr.total - 1), say = tr.prompt(n, shownName: shown)
        hud.show(S.t("🎙 목소리 맞추기 · \(n + 1)/\(tr.total)", "🎙 Voice check · \(n + 1)/\(tr.total)"),
                 S.t("「\(say)」라고 말해 주세요", "Say “\(say)”"), heard: heard, color: cyan)
    }

    /// Apple's text is shown instantly; the command itself uses Whisper's more accurate text.
    /// The live recognizer doesn't know a made-up name — 「사사리사」 came back as 「수술 있어」「서 서 있어」 (10/24). A short
    /// utterance that starts like it (ㅅ·ㅆ·ㅈ·ㅊ) is heard again by Whisper, which is told the name; if it's there, wake.
    func nameByWhisper(_ t: String, _ audio: [Float]) {
        // every short idle utterance (≤ 3 s, a few words): 「있어」「Safari 있어」「헛소리 있어」 were the name too (10/24)
        // (also the name with a command in one breath — 「세살이 YouTube 틀어」 was 「사사리사, 유튜브 틀어」 to Whisper)
        guard cfg.ko, whisper.available, audio.count > 6000, audio.count < 72000, Parser.squash(t).count <= 24 else { return }
        // only sounds that start like the name (same first consonant group: 「서 서 있어」 for 사사리사) — not every cough,
        // clap or OBS sound (10/25: it ran on all of them and commands waited behind)
        // voice with no text at all: only for a name typed in Latin letters (「Sasarisa」) — a Hangul name like 「거북아」 Apple writes itself
        if t.isEmpty, Parser.match(cfg.assistantName, "^[가-힣\\s]+$") != nil { return }
        if !t.isEmpty, let n = Butler.onset(Config.hangulReading(cfg.assistantName) ?? cfg.assistantName), let h = Butler.onset(t), n != h { return }
        whisper.transcribe(audio, fallback: t, low: true) { [weak self] full in
            guard let self, self.mode == .idle else { return }
            guard let heard = [full, self.whisper.lastSetAside, self.whisper.lastRaw].first(where: { self.parser.wakeRange($0) != nil }) else { return }
            log("name heard by Whisper: 「\(t)」 → 「\(heard)」")
            Sound.named(self.cfg.chime)
            self.mode = .awake; self.awakeUntil = Date().addingTimeInterval(self.cfg.followUpSec)
            // only the name is trusted from text Whisper's own filters set aside (it may have added words nobody said)
            let rest = heard == full ? self.parser.stripWake(heard) : ""
            if rest.isEmpty { self.hud.show(self.S.conversing, self.S.speakNow) } else { self.command(heard) }
        }
    }
    /// The first consonant of a Hangul word, by sound group (ㄱㄲㅋ · ㄷㄸㅌ · ㅂㅃㅍ · ㅅㅆㅈㅉㅊ); nil when it isn't Hangul.
    static func onset(_ s: String) -> Int? {
        guard let u = Parser.squash(s).unicodeScalars.first, u.value >= 0xAC00, u.value < 0xD7A4 else { return nil }
        let c = Int(u.value - 0xAC00) / 588
        let group = [0: 0, 1: 0, 15: 0, 3: 3, 4: 3, 16: 3, 7: 7, 8: 7, 17: 7, 9: 9, 10: 9, 12: 9, 13: 9, 14: 9]
        return group[c] ?? c
    }
    /// The browser to act in: the one in front, else the first one running.
    func browserApp() -> NSRunningApplication? {
        let ids = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.naver.Whale"]
        if let f = NSWorkspace.shared.frontmostApplication, let id = f.bundleIdentifier, ids.contains(id) { return f }
        return ids.lazy.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }.first
    }
    /// Intents that carry none of the speaker's own words — Apple's live text is enough for them.
    static func noFreeText(_ i: Intent) -> Bool {
        switch i {
        case .media, .closeTabs, .mediaNext, .seek, .mailNth, .displayOff, .closeOpened, .browser, .volume, .clock, .cancelTimers, .undo, .whatDid, .youtubeNth: return true
        case .kakaoReply(_, let text): return text.isEmpty
        default: return false
        }
    }
    func refine(_ audio: [Float], _ apple: String, then: @escaping (String) -> Void) {
        if !audio.isEmpty && whisper.available { hud.show(S.transcribing, apple, speed: 2) }
        let apple = dropEcho(apple)
        lastLive = parser.stripWake(apple)
        whisper.transcribe(audio, fallback: apple) { [weak self] full in
            guard let self else { return }
            self.studyWords(whisper: full, live: apple)
            var t = self.dropEcho(full)
            // If you said the wake word, nothing before it belongs to this command.
            if self.parser.wakeRange(apple) != nil, let r = self.parser.wakeRange(t), r.lowerBound > t.startIndex { t = String(t[r.lowerBound...]) }
            then(t)
        }
    }
    func command(_ full: String) {
        guard mode != .busy, mode != .speaking else { return }
        var cmd = Parser.ourAddress(parser.stripWake(full))
        // Whisper's text didn't match a quick command but the live text does → trust the live text for this one.
        // (Not when the live text only reads as a broken routine: 「페이지를 내리라고 하면은」 was cut short — 10/25.)
        let liveIntent = lastLive.isEmpty ? Intent.none : parser.parse(lastLive, hasYouTubeList: !ytList.isEmpty)
        if parser.parse(cmd, hasYouTubeList: !ytList.isEmpty) == .none, liveIntent != .none {
            if case .badRoutine = liveIntent { log("live text reads as a broken routine — keeping Whisper's: \(cmd)") }
            else { log("using live text for quick command: \(lastLive)"); cmd = lastLive }
        }
        // Whisper was set aside as "unsure" (「자비스, 아파트」 vs Apple's 「버드」): if ITS version is something known —
        // a quick command, a learned or remembered sentence — it was right; otherwise Claude sees both versions.
        let alt = parser.stripWake(whisper.lastSetAside)
        if !alt.isEmpty, Parser.squash(alt) != Parser.squash(cmd), parser.parse(cmd, hasYouTubeList: !ytList.isEmpty) == .none {
            if parser.parse(alt, hasYouTubeList: !ytList.isEmpty) != .none || Learning.lookup(alt) != nil || Aliases.lookup(alt) != nil {
                log("using Whisper's version after all (it's a known command): \(alt)"); cmd = alt
            } else { lastLive = alt }          // the brain gets both and picks by context
        }
        // A scrap after the name (「거북아보다」→「보다」, 「뽑았다」) isn't a command — don't spend 7 s of the brain on it (10/25); just listen.
        // (Not when it just asked something — then 「응」「그래」 are answers.)
        if !cmd.isEmpty, Parser.squash(cmd).count <= 3, parser.parse(cmd, hasYouTubeList: !ytList.isEmpty) == .none,
           brainAskedAt.map({ Date().timeIntervalSince($0) > 90 }) ?? true, !awaitingSend, retryLater == nil || Date() > retryUntil {
            log("too short to be a command (「\(cmd)」) — just listening"); converse(chime: true); return
        }
        if let again = retryLater, Date() < retryUntil, Parser.match(Parser.squash(cmd), "^(열었|열어놨|열어뒀|열어놓았|열었어|켰어|다시해|다시|이제해|이제됐|됐어다시|해봐다시|tryagain|again|opened)") != nil {
            retryLater = nil; log("retry after 「\(cmd)」"); again(); return
        }
        if cmd.isEmpty { converse(chime: true) } else { handle(cmd) }
    }

    /// Stay in conversation: no wake word needed until `followUpSec` of silence or "that's all".
    func converse(chime: Bool = false, keep: Bool = false) {
        if chime { Sound.named(cfg.chime) }
        mode = .awake; awakeStarted = nil
        awakeUntil = Date().addingTimeInterval(cfg.followUpSec)
        whisper.warm()
        if keep { hud.setStatus(S.conversing) } else { hud.show(S.conversing, S.speakNow) }
    }

    // MARK: acting

    func handle(_ cmd: String) {
        if askingFreeMode, answerFreeMode(cmd) { return }
        if pendingAction != nil, answerAction(cmd) { return }
        if pendingDelegate != nil, answerPending(cmd) { return }
        let q = Parser.squash(cmd)
        if learnCandidate != nil, ["아니", "틀렸", "그게아니", "안됐", "잘못", "no", "wrong"].contains(where: { q.hasPrefix($0) }) {
            log("not learning: \(learnCandidate!.phrase)"); learnCandidate = nil
        }
        if let r = lastRouted, Date().timeIntervalSince(r.at) < 20, ["아니", "틀렸", "그게아니", "no", "wrong"].contains(where: { q.hasPrefix($0) }) {
            Aliases.forget(r.said); GrowTogether.veto(r.said); lastRouted = nil; log("forgot alias: \(r.said)")
        }
        let intent = parser.parse(cmd, hasYouTubeList: !ytList.isEmpty)
        log("intent: \(intent)")
        switch intent {
        case .greet: greet()
        case .dictation:
            mode = .dictation
            speak(S.dictationStart) { [weak self] in guard let self else { return }; self.mode = .dictation; self.hud.show(self.S.dictation, "", color: lime) }
        case .enter: Hands.key(Hands.enter); done(S.key, "⏎")
        case .hush:
            // Nothing of ours to silence but a video is playing → "멈춰" means the video.
            // (Right after it was talking, "멈춰" was meant for its voice — that's already stopped.)
            if Date().timeIntervalSince(spokeAt) > 3, AudioDevices.outputBusy(cfg.outputDevice, micUID: cfg.inputDevice) == true { media(play: false) } else { converse() }
        case .media(let play): media(play: play)
        case .seek(let secs):
            guard let b = browserApp() else { ask(cmd); return }
            b.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                for i in 0..<max(1, abs(secs) / 10) { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.08) { Hands.key(secs > 0 ? 37 : 38) } }   // l / j
            }
            played(secs > 0 ? S.t("빨리 감기", "Forward") : S.t("되감기", "Back"), "\(abs(secs))" + S.t("초", " s"))
        case .mailNth(let n):
            guard let b = browserApp(), let bid = b.bundleIdentifier else { ask(cmd); return }
            mode = .busy
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                b.activate(); Thread.sleep(forTimeInterval: 0.2)
                var mails: [(AXUIElement, String)] = [], count = 0
                if let app = AX.app(bid), let win = AX.windows(app).first {
                    AX.walk(win, count: &count, until: Date().addingTimeInterval(2.5)) { e, role in
                        guard role == "AXLink" else { return }
                        let t = [AX.attr(e, "AXTitle"), AX.attr(e, "AXDescription"), AX.attr(e, "AXValue")].compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
                        if t.hasPrefix("메일 제목") { mails.append((e, t)) }      // Naver Mail: one 「메일 제목 …」 link per mail
                    }
                }
                DispatchQueue.main.async {
                    guard n >= 1, n <= mails.count else { log("mailNth: \(mails.count) mails found — brain takes it"); self.mode = .awake; self.ask(cmd); return }
                    AX.press(mails[n - 1].0)
                    let title = String(mails[n - 1].1.dropFirst("메일 제목".count)).trimmingCharacters(in: .whitespaces)
                    log("mailNth \(n): \(title)")
                    self.done(self.S.t("\(n)번째 메일", "Mail #\(n)"), title)
                }
            }
        case .mediaNext:
            Hands.mediaKey(17)            // ⏭ — YouTube skips to the next video
            played(S.t("다음 영상", "Next"), "⏭")
        case .browser(let what):
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            guard ["Safari", "Google Chrome", "Arc", "Microsoft Edge", "Firefox", "Whale", "Naver Whale"].contains(front) else { ask(cmd); return }
            switch what {
            case "back": Hands.key(33, .maskCommand)        // ⌘[
            case "forward": Hands.key(30, .maskCommand)     // ⌘]
            default: Hands.key(15, .maskCommand)            // ⌘R
            }
            done(front, what == "back" ? S.t("뒤로", "Back") : what == "forward" ? S.t("앞으로", "Forward") : S.t("새로고침", "Reloaded"))
        case .volume(let set, let delta, let mute):
            var e0: NSDictionary?
            let before = NSAppleScript(source: "output volume of (get volume settings)")?.executeAndReturnError(&e0).int32Value ?? 50
            lastDone = (S.t("소리를 바꿨어요", "changed the volume"), { NSAppleScript(source: "set volume output volume \(before) without output muted")?.executeAndReturnError(nil) })
            let script = mute ? "set volume output muted true"
                : set.map { "set volume output volume \($0) without output muted" }
                ?? "set volume output volume \(min(100, max(Int(before) + delta, delta < 0 ? 4 : 0))) without output muted"   // 「줄여」 never silences (10/24: 14 → 0)
            var err: NSDictionary?; NSAppleScript(source: script)?.executeAndReturnError(&err)
            let now = NSAppleScript(source: "output volume of (get volume settings)")?.executeAndReturnError(&err).int32Value ?? 0
            done(S.t("소리", "Volume"), mute ? S.t("음소거", "Muted") : "\(now)")
        case .clock(let date):
            let f = DateFormatter(); f.locale = Locale(identifier: cfg.locale)
            f.dateFormat = date ? (cfg.ko ? "M월 d일 EEEE" : "EEEE, MMMM d") : (cfg.ko ? "a h시 m분" : "h:mm a")
            let line = cfg.ko ? "\(cfg.user.isEmpty ? "" : cfg.user + ", ")\(date ? "오늘은 " : "지금은 ")\(f.string(from: Date()))입니다." : (date ? "Today is " : "It's ") + f.string(from: Date()) + "."
            speak(line) { [weak self] in self?.converse(keep: true) }
        case .timer(let secs, let label):
            let at = Date().addingTimeInterval(TimeInterval(secs))
            Timers.add(at: at, label: label)
            lastDone = (S.t("타이머를 맞췄어요", "set a timer"), { Timers.cancelLast() })
            let f = DateFormatter(); f.locale = Locale(identifier: cfg.locale); f.dateFormat = cfg.ko ? "a h:mm" : "h:mm a"
            let span = secs < 3600 ? (secs % 60 == 0 ? S.t("\(secs / 60)분", "\(secs / 60) min") : S.t("\(secs / 60)분 \(secs % 60)초", "\(secs / 60)m \(secs % 60)s")) : f.string(from: at)
            Sound.named("Pop")
            done(S.t("타이머", "Timer"), (label.isEmpty ? "" : label + " · ") + span + S.t(" 뒤에 알려 드릴게요", " — I'll tell you"))
        case .cancelTimers:
            let n = Timers.cancelAll(); done(S.t("타이머", "Timer"), S.t("\(n)개 취소", "\(n) cancelled"))
        case .map(let place):
            let leg = place.components(separatedBy: " → ")
            if leg.count == 2 { open("https://www.google.com/maps/dir/" + enc(leg[0]) + "/" + enc(leg[1])) } else { open("https://map.naver.com/p/search/" + enc(place)) }
            done(S.t("지도", "Map"), place)
        case .rewrite(let style):
            let (text, refused) = Writer.selection()
            if let refused { done(S.t("못 바꿈", "Can't"), S.t("\(refused)에서는 글을 바꾸지 않아요", "Not in \(refused)")); return }
            guard let text, text.count <= 3000 else { routeOrAsk(cmd); return }   // nothing selected → 「이거 요약해 줘」 likely means the page: the brain looks
            hud.show(S.t("✎ 글 바꾸는 중", "✎ Rewriting"), String(text.prefix(80)), heard: nil, color: amber, speed: 3)
            Sound.soft("Purr")
            Writer.rewrite(text, style: style, cfg: cfg) { [weak self] out in
                guard let self else { return }
                guard let out else { self.done(self.S.t("못 바꿈", "Failed"), self.S.t("다시 말씀해 주세요", "Try again")); return }
                Hands.paste(out)                  // replaces the selection; never presses send — ⌘Z undoes it
                self.lastDone = (self.S.t("선택한 글을 바꿨어요", "rewrote the selection"), { Hands.key(6, .maskCommand) })
                log("rewrite[\(style)] \(text.count) → \(out.count) chars")
                self.done(self.S.t("바꿈 (⌘Z 되돌리기)", "Rewritten (⌘Z to undo)"), String(out.prefix(120)))
            }
        case .undo:
            guard let u = lastDone?.undo else { done(S.t("되돌릴 게 없어요", "Nothing to undo"), ""); return }
            u(); let what = lastDone?.said ?? ""; lastDone = nil
            done(S.t("되돌림", "Undone"), what)
        case .whatDid:
            let what = lastDone?.said ?? S.t("아직 한 일이 없어요", "nothing yet")
            speak(cfg.ko ? "방금 \(what)." : "I just \(what).") { [weak self] in self?.converse(keep: true) }
        case .routine(let name):
            let steps = Routines.all[name] ?? []
            log("routine \(name): \(steps)")
            handle(steps.joined(separator: " 그리고 "))       // runs as one multi-command
            hud.show("◉ " + name, steps.joined(separator: " → "), heard: nil, color: lime, speed: 2)
        case .makeRoutine(let name, let steps):
            Routines.save(name, steps)
            speak(cfg.ko ? "앞으로 「\(name)」 하시면 \(steps.joined(separator: ", ")) 할게요." : "From now on, “\(name)” will \(steps.joined(separator: ", ")).") { [weak self] in self?.converse(keep: true) }
        case .badRoutine(let name):
            speak(cfg.ko ? "「\(name)」 루틴에는 바로 할 수 있는 일만 넣을 수 있어요. 열기, 틀기, 소리, 지도, 타이머 같은 거요." : "Routines can only hold quick actions — open, play, volume, maps, timers.") { [weak self] in self?.converse(keep: true) }
        case .forgetRoutine(let name):
            Routines.remove(name); done(S.t("루틴 지움", "Routine removed"), name)
        case .multi(let parts):
            // Quick parts run one after another right away; parts that need thought go to the brain together at the end —
            // started in between they used to cancel each other (a new command drops a brain turn that's still running).
            let quick = parts.filter { parser.parse($0, hasYouTubeList: !ytList.isEmpty) != .none }
            let slow = parts.filter { parser.parse($0, hasYouTubeList: !ytList.isEmpty) == .none && Parser.squash($0).count >= 4 }
            log("multi: quick \(quick) · brain \(slow)")
            hud.show(S.t("◉ 차례로 하는 중", "◉ Doing them in order"), parts.joined(separator: " → "), heard: nil, color: amber, speed: 3)
            for (i, p) in quick.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.6) { [weak self] in self?.handle(p) }
            }
            if !slow.isEmpty {
                let rest = slow.joined(separator: S.t(" 그리고 ", " and "))
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(quick.count) * 1.6 + 0.4) { [weak self] in self?.ask(rest) }
            }
        case .closeOpened:
            let n = closeOpened()
            if n == 0, AudioDevices.outputBusy(cfg.outputDevice, micUID: cfg.inputDevice) == true { media(play: false); return }   // nothing of ours open, but something's playing
            if n > 0 { done(S.t("닫음", "Closed"), S.t("열어 둔 것 \(n)개", "\(n) things it opened")) } else { done(S.t("닫을 게 없음", "Nothing to close"), S.t("이번에 연 창이 없어요", "Nothing opened this time")) }
        case .displayOff:
            done(S.t("화면 끔", "Display off"), "🌙")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["displaysleepnow"]; try? p.run()
            }
        case .bye: Sound.named("Pop"); goIdle()
        case .type(let text): Hands.paste(text); done(S.typed, text)
        case .kakaoReply(let to, let text): kakaoReply(to: to, text: text)
        case .kakaoType(let to, let text): kakaoReply(to: to, text: text, send: false)
        case .claude(let target, let message, let newSession):
            // Your own spoken request goes straight through (unless confirmDelegate = "always").
            if cfg.confirmDelegate == "always" { askToDelegate(target: target, message: message, newSession: newSession, said: cmd) }
            else { claudeMacro(target: target, message: message, newSession: newSession, said: cmd) }
        case .youtube(let q):
            if q.isEmpty { open("https://www.youtube.com/"); played(S.youtube, "YouTube") } else { youtube(q) }
        case .youtubeNth(let n):
            guard n >= 1, n <= ytList.count else { ask(cmd); return }
            closeVideos()
            open("https://www.youtube.com/watch?v=" + ytList[n - 1].id); played("\(S.youtube) #\(n)", ytList[n - 1].title); ensurePlaying()
        case .search(let q) where lastSite.map({ Date().timeIntervalSince($0.at) < 120 }) == true:
            let s = lastSite!; lastSite = (s.label, s.url, Date()); open(s.url + enc(q)); done(s.label, q)
        case .search(let q): open((cfg.ko ? "https://www.google.com/search?hl=ko&q=" : "https://www.google.com/search?q=") + enc(q)); done(S.searched, q)
        case .remember(let note): Memory.note(note); Sound.named("Pop"); done(S.t("기억함", "Remembered"), note)
        case .web(let label, let q, let url):
            if !q.isEmpty { lastSite = (label, url, Date()) }
            open(q.isEmpty ? url : url + enc(q)); done(label, q.isEmpty ? url : q)
        case .closeTabs(let label, let host):
            let n = closeTabs(host)
            if n == 0, host == "youtube.com", AudioDevices.outputBusy(cfg.outputDevice, micUID: cfg.inputDevice) == true { media(play: false); return }   // music in another app → pause it
            if n > 0 { done(S.t("창 닫음", "Closed"), "\(label) ×\(n)") } else { done(S.t("닫을 창 없음", "Nothing to close"), label) }
        case .openApp(let spoken, let app):
            noteOpened(app: app)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-a", app]; try? p.run()
            done(S.opened, spoken)
        case .none:
            // 티키타카: right after it asked something back, 「응」「그래」「그거 말고」 is an answer — straight to the brain (no router)
            if let t = brainAskedAt, Date().timeIntervalSince(t) < 90 { brainAskedAt = nil; log("reply to its question → brain"); ask(cmd); return }
            if let canon = Aliases.lookup(cmd), isQuick(canon) { log("alias: \(cmd) → \(canon)"); lastRouted = (cmd, Date()); handle(canon); return }
            // 「다 같이 키우기」 pack: what many people taught their Sasarisa (checked again here — safe quick commands only)
            if let canon = GrowTogether.lookup(cmd, parser: parser), isQuick(canon) { log("shared alias: \(cmd) → \(canon)"); lastRouted = (cmd, Date()); handle(canon); return }
            Growth.miss(cmd, front: NSWorkspace.shared.frontmostApplication?.localizedName ?? "")
            if let steps = Learning.lookup(cmd) {      // learned before → instant, no Claude call
                brainCommand = cmd; brainByHold = byHold
                hud.show(S.t("◌ 기억한 대로 하는 중", "◌ Doing it the way I learned"), cmd, heard: nil, color: amber, speed: 3)
                DispatchQueue.global().async { [weak self] in
                    let ok = Learning.replay(steps)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if ok { Learning.used(cmd); Growth.fastHit(); Sound.named("Pop"); self.done(self.S.t("기억한 대로", "Done (learned)"), cmd) }
                        else { Learning.forget(cmd); self.ask(cmd) }   // screen changed — ask Claude and relearn
                    }
                }
                return
            }
            routeOrAsk(cmd)
        }
    }

    /// What Claude should know without spending a tool call: the page in front (if a browser) and what Sasarisa opened.
    func screenContext(_ front: String) -> String {
        var lines: [String] = []
        if ["Safari", "Google Chrome"].contains(front) {
            let src = front == "Safari" ? "tell application \"Safari\" to if (count of windows) > 0 then return (name of current tab of front window) & \" | \" & (URL of current tab of front window)"
                                        : "tell application \"Google Chrome\" to if (count of windows) > 0 then return (title of active tab of front window) & \" | \" & (URL of active tab of front window)"
            var err: NSDictionary?
            if let page = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue, !page.isEmpty {
                lines.append(S.t("앞에 보이는 페이지: ", "Page in front: ") + String(page.prefix(200)))
            }
        }
        if !openedHosts.isEmpty || !openedApps.isEmpty {
            lines.append(S.t("비서가 연 것: ", "Opened by the assistant: ") + (openedHosts.sorted() + openedApps.sorted()).joined(separator: ", "))
        }
        return lines.map { "[" + $0 + "]" }.joined(separator: "\n")
    }
    func noteOpened(url: String) {
        if let h = URL(string: url)?.host(percentEncoded: true), Butler.safeHost(h) { openedHosts.insert(h.lowercased()) }
        if url.hasPrefix("http"), !url.contains("\""), !url.contains("\\"), url.count < 600 { openedURLs.append(url); if openedURLs.count > 50 { openedURLs.removeFirst() } }
    }
    /// Hosts end up inside AppleScript (closeTabs) — only plain host names, nothing that could break out of the quotes.
    static func safeHost(_ h: String) -> Bool { h.count < 254 && h.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil }
    /// An app it starts (not one that was already running) — so closing it later never takes away your own window.
    func noteOpened(app: String) {
        guard !Butler.neverClose.contains(app), !NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == app }) else { return }
        openedApps.insert(app)
    }
    /// What Claude opened in its last turn (`jax open-url …`, `jax open-app …`).
    func noteOpened(fromBrain cmds: [String]) {
        for c in cmds {
            if let r = c.range(of: #"open-url\s+"?(https?://[^\s"']+)"#, options: .regularExpression) {
                let u = String(c[r]).replacingOccurrences(of: #"open-url\s+"?"#, with: "", options: .regularExpression)
                noteOpened(url: u)
            }
            if let r = c.range(of: #"open-app\s+"?([^"]+?)"?\s*$"#, options: .regularExpression) {
                noteOpened(app: String(c[r]).replacingOccurrences(of: #"open-app\s+"?"#, with: "", options: .regularExpression).replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces))
            }
        }
    }
    /// 「창 다 꺼」: the pages it opened (by exact host — not Gmail because it opened a Google search) and the apps it
    /// started. Claude, Finder, terminals and editors are never touched.
    /// Safari windows left with nothing but a blank / start page once its tabs were closed (10/24: 「니가 연 거 끄라고」).
    func closeEmptySafariWindows() -> Int {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty else { return 0 }
        let src = """
        tell application "Safari"
          set n to 0
          repeat with i from (count of windows) to 1 by -1
            set w to window i
            set blank to true
            try
              repeat with t in tabs of w
                set u to URL of t
                if u is not missing value and u is not "" and u does not start with "favorites:" and u does not start with "about:" then set blank to false
              end repeat
            on error
              set blank to false
            end try
            if blank then
              close w
              set n to n + 1
            end if
          end repeat
          return n
        end tell
        """
        var err: NSDictionary?
        let n = Int(NSAppleScript(source: src)?.executeAndReturnError(&err).int32Value ?? 0)
        if n > 0 { log("closed \(n) empty Safari window(s)") }
        return n
    }
    /// What is read aloud: no markdown marks, links read by their text only, bare addresses dropped (10/24 it tried to read
    /// 「[경로 안내](https://…)」).
    static func speakable(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        return t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
    /// Whisper's context like Handy's: 「Glossary: name, …」 — the name and your words first, kept short (whisper.cpp keeps only
    /// the last ~220 tokens of a long prompt, so a long one used to lose the wake word at the front).
    static func glossary(_ cfg: Config) -> String {
        var seen = Set<String>(), words: [String] = []
        for w in [cfg.displayName] + cfg.wakes.filter { !$0.hasPrefix("헤이 ") && !$0.lowercased().hasPrefix("hey ") } + [cfg.user, "Claude", "YouTube"] + cfg.customWords
        where !w.isEmpty && seen.insert(w.lowercased()).inserted { words.append(w) }
        var out = "Glossary:"
        for w in words { if out.count + w.count + 2 > 180 { break }; out += (out.hasSuffix(":") ? " " : ", ") + w }
        return out
    }
    /// One video at a time: the YouTube videos already open are closed before a new one starts.
    func closeVideos() {
        let n = closeTabs("youtube.com/watch", frontFirst: false) + closeTabs("youtube.com/shorts", frontFirst: false)
        if n > 0 { log("closed \(n) open video(s) before the new one") }
    }
    func closeOpened() -> Int {
        var n = 0
        // Only the pages it opened (10/24: closing by site also took the owner's own YouTube search and Coupang tabs).
        // A video it started may have moved on to the next one, so its YouTube videos are matched as any open video.
        var prefixes = openedURLs.map { u -> String in
            var p = u.hasSuffix("/") ? String(u.dropLast()) : u
            if let enc = p.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(CharacterSet(charactersIn: "%"))) { p = enc }
            return p
        }
        if openedURLs.contains(where: { $0.contains("youtube.com/watch") }) { prefixes.append("https://www.youtube.com/watch") }
        n += closeTabs(prefixes: Array(Set(prefixes)))
        for app in openedApps where !Butler.neverClose.contains(app) {
            for a in NSWorkspace.shared.runningApplications where a.localizedName == app { if a.terminate() { n += 1 } }
        }
        n += closeEmptySafariWindows()
        log("closed what it opened: \(n) (hosts \(openedHosts.sorted()), apps \(openedApps.sorted()))")
        openedHosts = []; openedApps = []; openedURLs = []
        return n
    }
    /// Closes browser tabs whose address starts with one of these (the exact pages it opened).
    func closeTabs(prefixes: [String]) -> Int {
        let safe = prefixes.filter { $0.hasPrefix("http") && !$0.contains("\"") && !$0.contains("\\") && $0.count < 800 }
        guard !safe.isEmpty else { return 0 }
        let list = "{" + safe.map { "\"" + $0 + "\"" }.joined(separator: ", ") + "}"
        var total = 0
        for app in ["Google Chrome", "Safari"] {
            let bundle = app == "Safari" ? "com.apple.Safari" : "com.google.Chrome"
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { continue }
            let src = """
            tell application "\(app)"
              set n to 0
              set wanted to \(list)
              repeat with w in windows
                repeat with i from (count of tabs of w) to 1 by -1
                  set u to URL of tab i of w
                  if u is not missing value then
                    repeat with p in wanted
                      if u starts with (p as text) then
                        close tab i of w
                        set n to n + 1
                        exit repeat
                      end if
                    end repeat
                  end if
                end repeat
              end repeat
              return n
            end tell
            """
            var err: NSDictionary?
            total += Int(NSAppleScript(source: src)?.executeAndReturnError(&err).int32Value ?? 0)
            if let err { log("close tabs (\(app)): \(err[NSAppleScript.errorMessage] ?? err)") }
        }
        return total
    }
    /// Closes the browser tabs on that site — the front window first; if none there, any window.
    /// (YouTube Studio and the like are left alone. Only browsers already running are touched.)
    func closeTabs(_ host: String, frontFirst: Bool = true) -> Int {
        guard host.range(of: #"^[A-Za-z0-9.:/-]+$"#, options: .regularExpression) != nil else { log("close tabs: refused odd host \(host.debugDescription)"); return 0 }
        var total = 0
        for (bundle, app) in [("com.google.Chrome", "Google Chrome"), ("com.apple.Safari", "Safari")]
        where !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
            for scope in frontFirst ? ["{front window}", "windows"] : ["windows"] {
                let src = """
                tell application "\(app)"
                  if (count of windows) is 0 then return 0
                  set n to 0
                  repeat with w in \(scope)
                    repeat with i from (count of tabs of w) to 1 by -1
                      set u to URL of tab i of w
                      if u contains "\(host)" and u does not contain "studio." then
                        close tab i of w
                        set n to n + 1
                      end if
                    end repeat
                  end repeat
                  return n
                end tell
                """
                var err: NSDictionary?
                let n = Int(NSAppleScript(source: src)?.executeAndReturnError(&err).int32Value ?? 0)
                if let err { log("close tabs (\(app)): \(err[NSAppleScript.errorMessage] ?? err)") }
                total += n
                if n > 0 { break }
            }
        }
        log("closed \(total) \(host) tab(s)")
        return total
    }
    /// Pause / resume the video or music that's playing (the ⏯ key, so it works whichever window is in front).
    func media(play: Bool) {
        // ⏯ toggles — press it only when it changes something. Can't tell (headset)? Assume it's needed,
        // but never twice within 5 s for the same wish (a paused player can take a moment to go quiet).
        let busy = AudioDevices.outputBusy(cfg.outputDevice, micUID: cfg.inputDevice) ?? !play
        let repeatWish = lastMedia.map { $0.play == play && Date().timeIntervalSince($0.at) < 5 } ?? false
        if play != busy, !repeatWish { Hands.playPause(); lastMedia = (play, Date()) }
        if play { played(S.t("다시 재생", "Resumed"), "▶︎") } else { done(S.t("멈춤", "Paused"), "⏸") }
    }
    /// Quick commands only — what the router / aliases may trigger.
    func isQuick(_ canon: String) -> Bool {
        switch parser.parse(canon, hasYouTubeList: !ytList.isEmpty) {
        case .none, .claude, .type, .dictation, .remember, .makeRoutine, .badRoutine, .forgetRoutine, .greet, .bye, .hush, .enter, .rewrite: return false
        default: return true
        }
    }
    /// Loose phrasing: the brain starts right away and, at the same time, the fast router (2–4 s) tries to map the
    /// sentence to a quick command. If the router wins before the brain has touched anything, the brain is
    /// cancelled quietly and the quick command runs; otherwise the brain just carries on — no extra wait either way.
    /// What the router mapped is remembered, so the same sentence is instant next time.
    func routeOrAsk(_ cmd: String) {
        ask(cmd)
        guard router.enabled, cmd.count <= 60, brain.installed else { return }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        router.route(cmd, front: front, timeout: 6) { [weak self] canon in
            guard let self, let canon, self.isQuick(canon) else { return }
            guard self.mode == .busy, self.brainCommand == cmd, self.brainSteps == 0, self.brain.busy else {
                log("router late (brain already acting): \(cmd) → \(canon)"); Aliases.learn(cmd, canon); return
            }
            self.brain.cancel(silently: true)
            Aliases.learn(cmd, canon); self.lastRouted = (cmd, Date())
            self.mode = .awake
            self.handle(canon)
        }
    }
    func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }
    func open(_ url: String) {
        noteOpened(url: url)
        if let h = URL(string: url)?.host(percentEncoded: true), h.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil {
            lastDone = (S.t("\(h)를 열었어요", "opened \(h)"), { [weak self] in _ = self?.closeTabs("://" + h + "/", frontFirst: true) })
        }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = cfg.browserApp.isEmpty ? [url] : ["-a", cfg.browserApp, url]
        try? p.run()
    }

    /// Reads the YouTube results page (~1 s) and plays the first video; remembers the list for "play the second one".
    func youtube(_ q: String) {
        hud.show(S.youtubeFind, q, heard: nil, color: amber, speed: 3)
        var req = URLRequest(url: URL(string: "https://www.youtube.com/results?search_query=" + enc(q))!)
        req.setValue(cfg.ko ? "ko-KR,ko" : "en-US,en", forHTTPHeaderField: "Accept-Language")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 6
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            let list = Butler.parseYouTube(data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            DispatchQueue.main.async {
                guard let self else { return }
                self.ytList = list
                if let v = list.first { self.closeVideos(); self.open("https://www.youtube.com/watch?v=" + v.id); self.played(self.S.youtubePlay, v.title); self.ensurePlaying() }
                else { self.open("https://www.youtube.com/results?search_query=" + self.enc(q)); self.done(self.S.youtube, q) }
            }
        }.resume()
    }
    static func parseYouTube(_ html: String) -> [(id: String, title: String)] {
        guard let re = try? NSRegularExpression(pattern: "\"videoRenderer\":\\{\"videoId\":\"([\\w-]{11})\".*?\"title\":\\{\"runs\":\\[\\{\"text\":\"(.*?)\"\\}") else { return [] }
        return re.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(10).compactMap { m in
            guard let a = Range(m.range(at: 1), in: html), let b = Range(m.range(at: 2), in: html) else { return nil }
            return (String(html[a]), String(html[b]))
        }
    }

    /// Brings the Claude app forward → (finds the named session, or opens a new one) → types into the prompt box → Enter.
    /// Uses Accessibility only: the mouse pointer never moves.
    func claudeMacro(target: String, message: String, newSession: Bool, said: String = "") {
        mode = .busy
        // The message is tidied by a small model while the window is being found (「…라고 전달해」 quotes stay as said).
        let verbatim = ClaudeRelay.isQuote(said, message: message)
        var composed: String? = nil
        let composing = DispatchGroup()
        composing.enter()
        DispatchQueue.global(qos: .userInitiated).async { [cfg] in
            let t = ClaudeRelay.compose(message, verbatim: verbatim, cfg: cfg)
            DispatchQueue.main.async { composed = t; composing.leave() }
        }
        hud.show(S.claudeOpen, message, heard: target.isEmpty ? "Claude" : "\(target) · Claude", color: amber, speed: 3)
        log("claude[\(target)\(newSession ? " new" : "")]: \(message)")
        NSRunningApplication.runningApplications(withBundleIdentifier: Butler.claudeBundle).first?.activate()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            Thread.sleep(forTimeInterval: 0.3)
            guard let app = AX.app(Butler.claudeBundle) else { DispatchQueue.main.async { self.fail(self.S.claudeNotRunning) }; return }
            var wins = AX.windows(app)
            if wins.isEmpty { Thread.sleep(forTimeInterval: 0.4); wins = AX.windows(app) }
            guard var win = wins.first else { DispatchQueue.main.async { self.fail(self.S.claudeNoWindow) }; return }
            if newSession {
                if let b = AX.button(in: win, titled: ["새로 생성", "새 세션", "New session", "New chat", "New"]) {
                    DispatchQueue.main.async { self.hud.show(self.S.claudeNew, message, heard: nil, color: amber, speed: 3) }
                    AX.press(b)
                    Thread.sleep(forTimeInterval: 0.9)
                }
            } else if !target.isEmpty {
                // Several Claude windows: each window's title is its session/project name. Clear title match → that
                // window; else a sidebar session; else a small model reads the open windows and picks one. No match → stop.
                let titles = wins.map { (AX.attr($0, "AXTitle") as? String) ?? "" }
                let raise = { (w: AXUIElement, title: String) in
                    AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
                    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                    DispatchQueue.main.async { self.hud.show(self.S.claudeFindSession, title, heard: nil, color: amber, speed: 3) }
                    Thread.sleep(forTimeInterval: 0.35)
                }
                // the session list may be folded away — open it so the session can be found (10/25)
                if ClaudeRelay.clearBest(target, titles: titles) == nil, !wins.contains(where: { AX.session($0, target).map { $0.1 >= 120 } == true }),
                   wins.map({ AX.showSidebar($0) }).contains(true) {
                    log("claude: opened the folded session list to find 「\(target)」"); Thread.sleep(forTimeInterval: 0.7)
                }
                if let i = ClaudeRelay.clearBest(target, titles: titles) {
                    win = wins[i]; raise(win, titles[i])
                } else if let (w, item, _) = wins.compactMap({ w in AX.session(w, target).map { (w, $0.0, $0.1) } }).max(by: { $0.2 < $1.2 }), AX.session(w, target).map({ $0.1 >= 120 }) == true {
                    win = w; raise(w, (AX.attr(item, "AXTitle") as? String) ?? target)
                    AX.press(item)
                    Thread.sleep(forTimeInterval: 0.6)
                } else if let i = ClaudeRelay.pick(target, said: said.isEmpty ? target : said, titles: titles, cfg: self.cfg) {
                    win = wins[i]; raise(win, titles[i])
                } else {
                    log("claude window not found: \(target) among \(titles)")
                    DispatchQueue.main.async { self.keepForPaste(message); self.fail(self.S.t("「\(target)」 클로드 창을 못 찾았어요. 전할 말은 복사해 뒀으니 그 창에 ⌘V 로 붙여 넣으세요.", "Couldn't find the “\(target)” Claude window. The message is copied — paste it there with ⌘V.")) }
                    return
                }
            }
            // The Claude app's screen may change in an update — then the words aren't lost: they wait on the clipboard.
            guard let box = AX.composer(win) else {
                log("claude input box not found in \((AX.attr(win, "AXTitle") as? String) ?? "?") — Claude app layout changed?")
                DispatchQueue.main.async { self.keepForPaste(message); self.fail(self.S.claudeNoInput + self.S.t(" 전할 말은 복사해 뒀어요(⌘V).", " The message is copied (⌘V).")) }
                return
            }
            if composing.wait(timeout: .now() + 0.05) == .timedOut {
                DispatchQueue.main.async { self.hud.show(self.S.t("◌ 전할 말 다듬는 중", "◌ Tidying the message"), message, heard: nil, color: amber, speed: 3) }
                _ = composing.wait(timeout: .now() + 20)
            }
            var text = message
            DispatchQueue.main.sync { text = composed ?? message }
            if text != message { log("claude message tidied: \(message) → \(text)") }
            DispatchQueue.main.async { self.cancelSend = false; self.hud.show(self.S.claudeTyping, text, heard: nil, color: amber, speed: 3) }
            AX.focus(box)
            Thread.sleep(forTimeInterval: 0.15)
            if !text.isEmpty { DispatchQueue.main.sync { Hands.paste(text) } }      // "" = 「카톡 전송 눌러」: send what's already there   // instant (typing 30 chars/s was the slow part)
            var cancelled = false
            if self.cfg.previewBeforeSend {
                // 보내기 전 미리 보기 (a viewer's request, 10/24): the message waits in the box until a spoken 「응」; no answer = not sent.
                DispatchQueue.main.async {
                    self.sendDecision = nil; self.awaitingSend = true; Sound.soft("Tink")
                    self.hud.show(self.S.t("◌ 이대로 보낼까요? 「응」 / 「아니」", "◌ Send this? “yes” / “no”"), text, heard: nil, color: amber, speed: 1)
                }
                var decision: Bool? = nil
                for _ in 0..<200 {          // 20 s
                    Thread.sleep(forTimeInterval: 0.1)
                    DispatchQueue.main.sync { decision = self.sendDecision ?? (self.cancelSend ? false : nil) }
                    if decision != nil { break }
                }
                DispatchQueue.main.sync { self.awaitingSend = false; self.cancelSend = false }
                cancelled = decision != true
                if cancelled { log("claude send: preview not confirmed (\(decision == nil ? "no answer" : "no"))") }
            } else {
                // Last chance: 0.8 s to say “취소 / stop” before Enter.
                DispatchQueue.main.async { self.hud.show(self.S.t("◌ 곧 보냄 · 「취소」 하면 멈춤", "◌ Sending… say “stop” to cancel"), text, heard: nil, color: amber, speed: 3) }
                Thread.sleep(forTimeInterval: 0.8)
                DispatchQueue.main.sync { cancelled = self.cancelSend; self.cancelSend = false }
            }
            if cancelled {
                Hands.key(0, .maskCommand); Thread.sleep(forTimeInterval: 0.05); Hands.key(51)   // ⌘A, delete — clear what we typed
                DispatchQueue.main.async { Sound.named("Pop"); log("claude send cancelled"); self.done(self.S.t("취소", "Cancelled"), message) }
                return
            }
            Hands.key(Hands.enter)
            log("claude sent → \((AX.attr(win, "AXTitle") as? String) ?? "?"): \(text)")
            DispatchQueue.main.async { Sound.named("Pop"); self.done(newSession ? self.S.claudeDelegated : self.S.claudeSent, text) }
        }
    }
    // MARK: confirm before handing work to a full-power Claude session
    // Voices from a TV or a web page must not be able to start work on your computer. Say “응 / 맡겨 / yes”.
    static let protectedApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby", "com.apple.ScriptEditor2", "com.apple.Automator",
        "com.apple.shortcuts", "com.apple.systempreferences", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.apple.SecurityAgent", "com.apple.UserNotificationCenter", "com.apple.coreservices.uiagent", "com.apple.installer",
        "com.apple.dt.Xcode", "com.apple.Console", "com.anthropic.claudefordesktop", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.1password.1password", "com.bitwarden.desktop"]
    var pendingDelegate: (target: String, message: String, newSession: Bool)?
    var pendingSaid = ""
    func askToDelegate(target: String, message: String, newSession: Bool, speakQuestion: Bool = true, said: String = "") {
        guard cfg.confirmDelegate != "never" else { claudeMacro(target: target, message: message, newSession: newSession, said: said); return }
        pendingDelegate = (target, message, newSession); pendingSaid = said
        let where_ = newSession ? S.t("클로드 새 세션", "a new Claude session") : (target.isEmpty ? "Claude" : target)
        log("delegate pending: \(message)")
        guard speakQuestion else { return }
        speak(S.t("\(where_)에 맡길까요?", "Hand this to \(where_)?")) { [weak self] in
            guard let self else { return }
            self.converse(keep: true)
            self.hud.show(self.S.t("◌ 맡길까요? 「응」 / 「아니」", "◌ Hand it over? “yes” / “no”"), message, heard: nil, color: amber)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                if self?.pendingDelegate?.message == message { self?.pendingDelegate = nil; log("delegate expired") }
            }
        }
    }
    /// Returns true if the utterance answered a pending hand-off question.
    func answerPending(_ a: String) -> Bool {
        guard let p = pendingDelegate else { return false }
        let s = Parser.squash(a)
        let yes = ["응", "네", "예", "맡겨", "그래", "좋아", "해", "보내", "ㅇㅇ", "yes", "yeah", "doit", "go", "sure", "ok", "okay", "그렇게", "그러자", "부탁", "진행", "고고", "콜", "오케이", "알았어", "알겠어"]
        let no = ["아니", "아니야", "취소", "하지마", "됐어", "no", "nope", "cancel", "stop"]
        pendingDelegate = nil
        if no.contains(where: { s.hasPrefix($0) }) || s.contains("말고") || s.contains("하지마") { Sound.named("Pop"); log("delegate cancelled"); converse(keep: true); return true }
        if yes.contains(where: { s.hasPrefix($0) }) { claudeMacro(target: p.target, message: p.message, newSession: p.newSession, said: pendingSaid); return true }
        log("delegate dropped (no clear yes)")
        return false
    }

    // MARK: send / pay / post / delete — the hands ask before they press (see jax `confirmIrreversible`)
    var brainCommand = ""          // what the user said that the brain (or a learned replay) is acting on right now
    var brainByHold = false        // …and whether they said it holding the hotkey (no TV can do that)
    var byHold = false             // set while handling a push-to-talk command
    var pendingAction: (kind: String, bundle: String, what: String, args: [String], at: Date)?
    lazy var freeMode = cfg.freeMode
    var askingFreeMode = false
    /// After a send/post/delete the user said yes to, ask once: 「다음부터는 묻지 않고 바로 할까요?」 (payments keep asking).
    func offerFreeMode(_ kind: String) {
        guard !freeMode, kind != "pay", !cfg.freeModeAsked, !UserDefaults.standard.bool(forKey: "freeModeAsked") else { return }
        UserDefaults.standard.set(true, forKey: "freeModeAsked"); Config.set("freeModeAsked", true)
        askingFreeMode = true
        speak(S.t("다음부터는 묻지 않고 바로 할까요? 결제는 계속 묻습니다.", "Shall I do these without asking from now on? Payments will still ask.")) { [weak self] in
            guard let self else { return }
            self.converse(keep: true)
            self.hud.show(self.S.t("◌ 자유 모드로 할까요? 「응」 / 「아니」", "◌ Free mode? “yes” / “no”"), self.S.t("결제는 늘 묻습니다", "Payments always ask"), heard: nil, color: amber)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.askingFreeMode = false }
        }
    }
    /// Returns true if the utterance answered the free-mode question.
    func answerFreeMode(_ a: String) -> Bool {
        guard askingFreeMode else { return false }
        askingFreeMode = false
        let s = Parser.squash(a)
        if ["응", "네", "예", "그래", "좋아", "해", "ㅇㅇ", "그렇게", "그러자", "부탁", "오케이", "yes", "yeah", "sure", "ok", "okay"].contains(where: { s.hasPrefix($0) }) {
            freeMode = true; Config.set("freeMode", true); log("free mode on (asked after a confirmed action)")
            Sound.named("Pop"); done(S.t("자유 모드 켬", "Free mode on"), S.t("결제만 묻습니다 · 설정에서 끌 수 있어요", "Only payments ask · turn it off in Settings"))
            return true
        }
        if ["아니", "아니야", "됐어", "싫어", "no", "nope"].contains(where: { s.hasPrefix($0) }) {
            Sound.named("Pop"); done(S.t("계속 묻기", "Keep asking"), S.t("설정에서 바꿀 수 있어요", "You can change it in Settings")); return true
        }
        return false
    }
    static let askedFor: [String: [String]] = [
        "send": ["보내", "전송", "송신", "send"],
        "pay": ["결제", "구매", "구입", "주문", "송금", "이체", "pay", "buy", "purchase", "order", "checkout"],
        "post": ["게시", "올려", "올리", "업로드", "등록", "post", "publish", "upload", "tweet"],
        "delete": ["삭제", "지워", "지우", "비워", "delete", "remove", "trash"]]
    /// Called on the socket thread (synchronously) when a tool is about to press something irreversible.
    /// "yes" only when the user's own words asked for that kind of action; otherwise it's held for a spoken yes.
    func confirmAction(_ text: String) -> String {
        let p = text.components(separatedBy: "\u{1F}")
        guard p.count >= 4 else { return "ask" }
        let kind = p[0]
        if remote != nil, kind == "pay" || !freeMode {
            remote!.held = kind; log("remote: \(kind) not done from the phone → \(p[2])"); return "ask"
        }
        // 자유 모드 (the owner chose it): no question for sending, posting, deleting — paying always asks.
        if freeMode, kind != "pay" { log("free mode: \(kind) without asking → \(p[2])"); return "yes" }
        // Pressed without asking only when the user held the hotkey and said it (a TV or a video can say "보내",
        // it can't hold the key). Spoken the normal way, it asks once.
        if cfg.confirmDelegate != "always", brainByHold, Butler.userAskedFor(kind, brainCommand) {
            log("confirm \(kind): asked for (hotkey) in 「\(brainCommand)」 → \(p[2])"); return "yes"
        }
        pendingAction = (kind, p[1], p[2], Array(p[3...]), Date())
        log("confirm \(kind): holding \(p[2]) for a yes")
        return "ask"
    }
    /// A Claude Code session can do far more than the safe brain, so work the brain wants to hand over always waits for
    /// a spoken yes, whatever `confirmDelegate` says — the brain may have been talked into it by a page title or a link.
    /// ("바로 실행" applies only to a hand-off the user asked for directly — the `.claude` quick command.)
    // MARK: Pro — 폰으로 부르기
    /// A request typed on the phone runs like a spoken one; what it says and shows is collected and sent back as one line
    /// once it goes quiet. Payments never run from the phone; send/post/delete only in free mode (see `confirmAction`).
    var remote: (id: String, at: Date, said: [String], held: String)?
    private var remoteTimer: Timer?
    func runRemote(_ text: String, _ id: String) {
        if remote != nil { finishRemote(force: true) }
        remote = (id, Date(), [], "")
        hud.show(S.t("📱 폰에서", "📱 From your phone"), text, heard: text, color: lime)
        byHold = false
        handle(String(text.prefix(300)))
        remoteSettle(after: 90)
    }
    func remoteSaid(_ text: String) {
        guard remote != nil, !text.isEmpty, remote!.said.last != text else { return }
        remote!.said.append(text); remoteSettle(after: 6)
    }
    private func remoteSettle(after s: TimeInterval) {
        remoteTimer?.invalidate()
        remoteTimer = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in self?.finishRemote() }
    }
    func finishRemote(force: Bool = false) {
        guard let r = remote else { return }
        if !force, mode == .speaking || mode == .busy, Date().timeIntervalSince(r.at) < 300 { remoteSettle(after: 5); return }
        remoteTimer?.invalidate(); remote = nil
        var out = r.said.joined(separator: " ")
        if !r.held.isEmpty {
            out += (out.isEmpty ? "" : " ") + (r.held == "pay"
                ? S.t("결제는 폰에서 하지 않아요. 맥 앞에서 해 주세요.", "Payments never run from the phone — do it at the Mac.")
                : S.t("보내기·게시·삭제는 자유 모드일 때만 폰에서 합니다. 지금은 하지 않았어요.", "Send, post and delete run from the phone only in free mode, so it wasn't done."))
            pendingAction = nil
        }
        ProAccount.reply(r.id, out.isEmpty ? S.t("했어요.", "Done.") : out)
    }

    func delegateFromBrain(_ text: String) -> String {
        let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[1].isEmpty else { return "pending" }
        let here = parts[0] == "." || parts[0] == "지금" || parts[0].lowercased() == "here"
        if freeMode {     // 자유 모드: the brain's hand-off goes straight to the Claude session
            log("free mode: delegate without asking → \(parts[1])")
            let t = here ? "" : parts[0], m = parts[1], fresh = parts[0].isEmpty
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.claudeMacro(target: t, message: m, newSession: fresh) }
            return "sent"
        }
        if remote != nil { remote!.held = "delegate"; log("remote: hand-off not done from the phone → \(parts[1])"); return "pending" }
        pendingDelegate = (here ? "" : parts[0], parts[1], parts[0].isEmpty)
        log("delegate pending (needs a yes): \(parts[1])")
        return "pending"
    }
    static func userAskedFor(_ kind: String, _ said: String) -> Bool {
        let s = said.lowercased()
        return (askedFor[kind] ?? []).contains(where: s.contains)
    }
    func showPendingAction(_ what: String) {
        hud.show(S.t("◌ 누를까요? 「응」 / 「아니」", "◌ Press it? “yes” / “no”"), what, heard: nil, color: amber)
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            if let a = self?.pendingAction, Date().timeIntervalSince(a.at) >= 25 { self?.pendingAction = nil; log("held action expired") }
        }
    }
    /// Returns true if the utterance answered “press it?”.
    func answerAction(_ a: String) -> Bool {
        guard let p = pendingAction else { return false }
        pendingAction = nil
        guard Date().timeIntervalSince(p.at) < 60 else { return false }
        let s = Parser.squash(a)
        let yes = ["응", "네", "예", "그래", "좋아", "눌러", "해", "보내", "결제", "올려", "지워", "ㅇㅇ", "yes", "yeah", "doit", "go", "sure", "ok", "okay", "send", "그렇게", "그러자", "부탁", "진행", "고고", "콜", "오케이", "알았어", "알겠어"]
        let no = ["아니", "아니야", "취소", "하지마", "됐어", "no", "nope", "cancel", "stop"]
        if no.contains(where: { s.hasPrefix($0) }) || s.contains("말고") { Sound.named("Pop"); log("held action cancelled"); done(S.t("취소", "Cancelled"), p.what); return true }
        guard yes.contains(where: { s.hasPrefix($0) }) else { log("held action dropped (no clear yes)"); return false }
        // Only in the app it was meant for — if the screen moved on, pressing now could hit something else.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == p.bundle else {
            fail(S.t("화면이 바뀌어서 누르지 않았습니다.", "The screen changed, so I didn't press it.")); return true
        }
        log("held action confirmed: \(p.what)")
        DispatchQueue.global().async { [weak self] in
            let proc = Process()
            proc.executableURL = Paths.tools.appendingPathComponent("jax")
            proc.arguments = p.args
            var env = ProcessInfo.processInfo.environment
            env["MACBUTLER_SAFE"] = "1"; env["MACBUTLER_CONFIRMED"] = "1"; env["MACBUTLER_BUNDLE"] = Bundle.main.bundleIdentifier ?? ""
            proc.environment = env
            proc.standardOutput = FileHandle.nullDevice; proc.standardError = FileHandle.nullDevice
            let ok = (try? proc.run()) != nil && { proc.waitUntilExit(); return proc.terminationStatus == 0 }()
            DispatchQueue.main.async {
                guard let self else { return }
                if ok { Sound.named("Pop"); self.done(self.S.t("눌렀음", "Done"), p.what); self.offerFreeMode(p.kind) }
                else { self.fail(self.S.t("누르지 못했습니다.", "Couldn't press it.")) }
            }
        }
        return true
    }

    func openClaudeSession(_ name: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: Butler.claudeBundle).first?.activate()
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            Thread.sleep(forTimeInterval: 0.3)
            guard let app = AX.app(Butler.claudeBundle) else { return }
            if !AX.windows(app).contains(where: { AX.session($0, name) != nil }), AX.windows(app).map({ AX.showSidebar($0) }).contains(true) {
                log("claude: opened the folded session list to find 「\(name)」"); Thread.sleep(forTimeInterval: 0.7)
            }
            if let (w, item, _) = AX.windows(app).compactMap({ w in AX.session(w, name).map { (w, $0.0, $0.1) } }).max(by: { $0.2 < $1.2 }) {
                AXUIElementPerformAction(w, kAXRaiseAction as CFString); AX.press(item)
                let title = (AX.attr(item, "AXTitle") as? String) ?? name
                log("claude session: 「\(name)」 → opened 「\(title)」")
                DispatchQueue.main.async { self.done(self.S.t("세션 열기", "Opened"), title) }
            } else { log("claude session: 「\(name)」 not found"); DispatchQueue.main.async { self.fail(self.S.t("그 세션을 못 찾았습니다.", "Couldn't find that session.")) } }
        }
    }

    func fail(_ why: String) { speak(why) { [weak self] in self?.converse(keep: true) } }

    /// 「카톡 영웅님한테 아 힘들다라고 답장해」: find that chat window (or the chat in front), put the words in its input box,
    /// and send after a spoken yes (free mode sends right away). Never the brain fumbling with coordinates (10/25).
    func kakaoReply(to name: String, text: String, send wantSend: Bool = true) {
        let bundle = "com.kakao.KakaoTalkMac"
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { fail(S.t("카카오톡이 켜져 있지 않아요.", "KakaoTalk isn't open.")); return }
        mode = .busy
        hud.show(S.t("◌ 카톡 답장 준비", "◌ Getting the KakaoTalk reply ready"), text, heard: name.isEmpty ? "KakaoTalk" : "\(name) · KakaoTalk", color: amber, speed: 3)
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            running.activate()
            Thread.sleep(forTimeInterval: 0.35)
            guard let app = AX.app(bundle) else { DispatchQueue.main.async { self.fail(self.S.t("카톡 화면을 읽지 못했어요.", "Couldn't read KakaoTalk.")) }; return }
            let wins = AX.windows(app)
            let title = { (w: AXUIElement) in (AX.attr(w, "AXTitle") as? String) ?? "" }
            let isMain = { (t: String) in ["카카오톡", "kakaotalk", ""].contains(t.lowercased()) }
            let want = AX.norm(name)
            // each chat opens in its own window titled with the chat's name; with no name, the chat window in front.
            // Names are matched by sound too — 「영웅」 said, the window was 「영응님」 (10/25).
            // how far a window's name is from the one said: 0 = contains it, else sounds apart (Hangul split into its sounds)
            let gap = { (t: String) -> Int in
                let h = AX.norm(t).replacingOccurrences(of: "님", with: "")
                if h.isEmpty { return 99 }
                if h.contains(want) || want.contains(h) { return 0 }
                return NameTrainer.distance(NameTrainer.jamo(h), NameTrainer.jamo(want))
            }
            let limit = want.count <= 3 ? 1 : 2      // a short name may differ by one sound only — never someone else's chat
            let target = want.isEmpty ? wins.first { !isMain(title($0)) }
                : wins.filter { !isMain(title($0)) }.map { ($0, gap(title($0))) }.filter { $0.1 <= limit }.min { $0.1 < $1.1 }?.0
            guard let win = target else {
                log("kakao reply: no chat window for 「\(name)」 among \(wins.map(title))")
                DispatchQueue.main.async {
                    self.keepForPaste(text)
                    self.retryLater = { [weak self] in self?.kakaoReply(to: name, text: text, send: wantSend) }; self.retryUntil = Date().addingTimeInterval(120)
                    self.fail(name.isEmpty ? self.S.t("열려 있는 카톡 대화창이 없어요. 대화창을 열고 다시 말해 주세요. 보낼 말은 복사해 뒀어요.", "No KakaoTalk chat window is open. Open it and ask again — the words are copied.")
                                           : self.S.t("「\(name)」 대화창이 열려 있지 않아요. 카톡에서 그 대화를 열고 다시 말해 주세요. 보낼 말은 복사해 뒀어요.", "The chat with “\(name)” isn't open. Open it in KakaoTalk and ask again — the words are copied."))
                }
                return
            }
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            Thread.sleep(forTimeInterval: 0.2)
            guard let box = AX.composer(win) else {
                DispatchQueue.main.async { self.keepForPaste(text); self.fail(self.S.t("카톡 입력칸을 못 찾았어요. 보낼 말은 복사해 뒀어요(⌘V).", "Couldn't find KakaoTalk's input box — the words are copied (⌘V).")) }
                return
            }
            AX.focus(box)
            Thread.sleep(forTimeInterval: 0.15)
            DispatchQueue.main.sync { Hands.paste(text) }
            let who = title(win)
            log("kakao reply: typed into 「\(who)」: \(text)")
            if !wantSend {          // 「입력해·써」: leave it in the box, never press Enter
                DispatchQueue.main.async { Sound.named("Pop"); self.done(self.S.t("카톡에 입력함 (안 보냄)", "Typed in KakaoTalk (not sent)"), "\(who) · \(text)") }
                return
            }
            var send = self.cfg.freeMode
            if !send {
                DispatchQueue.main.async {
                    self.sendDecision = nil; self.awaitingSend = true; Sound.soft("Tink")
                    self.hud.show(self.S.t("◌ \(who)님께 보낼까요? 「응」 / 「아니」", "◌ Send to \(who)? “yes” / “no”"), text, heard: nil, color: amber, speed: 1)
                }
                var decision: Bool? = nil
                for _ in 0..<200 {          // 20 s
                    Thread.sleep(forTimeInterval: 0.1)
                    DispatchQueue.main.sync { decision = self.sendDecision ?? (self.cancelSend ? false : nil) }
                    if decision != nil { break }
                }
                DispatchQueue.main.sync { self.awaitingSend = false; self.cancelSend = false }
                send = decision == true
            }
            if send {
                AX.focus(box); Hands.key(Hands.enter)
                log("kakao reply sent → 「\(who)」: \(text)")
                DispatchQueue.main.async { Sound.named("Pop"); self.done(self.S.t("카톡 보냄", "Sent on KakaoTalk"), "\(who) · \(text)") }
            } else {
                if !text.isEmpty { AX.focus(box); Hands.key(0, .maskCommand); Thread.sleep(forTimeInterval: 0.05); Hands.key(51) }   // ⌘A, delete — take our words back out (never the owner's)
                log("kakao reply not sent (no yes)")
                DispatchQueue.main.async { Sound.named("Pop"); self.done(self.S.t("안 보냄", "Not sent"), text) }
            }
        }
    }
    static func cpuSeconds() -> Double {
        var r = rusage(); getrusage(RUSAGE_SELF, &r)
        return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
    }
    /// Memory as Activity Monitor shows it (physical footprint).
    static func memoryMB() -> Double {
        var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    /// A message that couldn't be delivered stays on the clipboard, so nothing said is lost.
    func keepForPaste(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); log("kept on clipboard for pasting: \(text.prefix(80))") }

    func dictate(_ t: String) {
        let s = Parser.squash(t)
        if parser.isBye(t) || parser.isHush(t) || ["그만", "끝", "받아쓰기끝"].contains(s) { Sound.named("Pop"); converse(); return }
        if ["엔터", "보내", "전송", "줄바꿈", "enter", "newline", "send"].contains(s) { Hands.key(Hands.enter); hud.body("⏎"); return }
        if ["지워", "취소", "되돌려", "undo", "deletethat"].contains(s) { Hands.key(6, .maskCommand); hud.body("↶"); return }
        var text = t.split(separator: " ").filter { w in !cfg.fillers.contains(w.trimmingCharacters(in: .punctuationCharacters)) }.joined(separator: " ")
        var enter = false
        for suf in [" 엔터", " 보내", " enter", " send"] where text.lowercased().hasSuffix(suf) { text = String(text.dropLast(suf.count)); enter = true }
        let paste = { (t: String) in
            Hands.paste(t + " ")
            if enter { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { Hands.key(Hands.enter) } }
        }
        if cfg.polishDictation { Polish.run(text, ko: cfg.ko, words: cfg.customWords, done: paste) } else { paste(text) }
    }

    func ask(_ cmd: String) {
        guard brain.installed else { fail(S.noClaude); return }
        mode = .busy
        brainCommand = cmd; brainByHold = byHold; pendingAction = nil
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        hud.show(S.thinking, "…", heard: cmd, color: amber, speed: 3)
        Sound.soft("Purr")      // heard you — thinking (so the wait isn't silent)
        brainSteps = 0
        brain.ask(cmd, live: lastLive, frontApp: front, context: screenContext(front), step: { [weak self] label in
            guard let self else { return }
            self.brainSteps += 1
            self.hud.show(self.S.working, label, heard: nil, color: amber, speed: 3)
        }, done: { [weak self] answer in
            guard let self else { return }
            log("brain → \(answer)")
            Memory.exchange(user: cmd, reply: answer)
            self.lastDone = (self.S.t("「\(cmd)」 하신 걸 클로드가 처리했어요: \(answer)", "Claude handled “\(cmd)”: \(answer)"), nil)   // what it did, not undoable
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.brain.warm() }   // swap in a fresh brain now if it got heavy, not on the next question
            self.noteOpened(fromBrain: self.brain.lastCommands)
            let correction = ["아니", "그게 아니", "no ", "not "].contains { cmd.lowercased().hasPrefix($0) }
            let failed = ["못 ", "못했", "않았", "않습니다", "실패", "확인되지", "안 됐", "안 돼", "안됐", "couldn't", "could not", "failed", "didn't", "not able"].contains(where: answer.lowercased().contains)
            if !correction, !failed, let steps = Learning.replayable(self.brain.lastCommands) {
                self.learnCandidate = (cmd, steps)
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in   // no “아니” within 12 s → keep it
                    guard let self, let c = self.learnCandidate, c.phrase == cmd else { return }
                    Learning.remember(c.phrase, c.steps); self.learnCandidate = nil
                }
            }
            let spoken = Butler.speakable(answer)
            self.brainAskedAt = spoken.hasSuffix("?") || spoken.hasSuffix("까요") ? Date() : nil   // it asked back → the next short reply is the answer
            self.speak(spoken) {
                if Parser.startedMedia(answer) { self.played(self.S.youtubePlay, spoken); return }
                self.converse(keep: true)   // leave the answer on screen
                if let a = self.pendingAction { self.showPendingAction(a.what) }
                if let p = self.pendingDelegate {
                    self.hud.show(self.S.t("◌ 맡길까요? 「응」 / 「아니」", "◌ Hand it over? “yes” / “no”"), p.message, heard: nil, color: amber)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                        if self?.pendingDelegate?.message == p.message { self?.pendingDelegate = nil; log("delegate expired") }
                    }
                }
            }
        })
    }

    // MARK: greeting / speaking

    /// 「아빠 왔어」: the greeting screen in the style picked in Settings (`style` = a preview of another one).
    func greet(style: String? = nil) {
        if mode == .speaking { return }
        let now = Config.load(), style = style ?? now.bootStyle            // read fresh, so a change in Settings applies at once
        mode = .speaking
        for u in cfg.greetOpen where style == now.bootStyle { if let url = URL(string: u) { NSWorkspace.shared.open(url) } }
        if style == "card" {         // no full screen — just say hello in the card
            speak(cfg.greeting) { [weak self] in self?.converse(keep: true) }
            return
        }
        ear.muted = true
        hud.hideAll(true)
        let text = BootScene.Text(title: now.bootTitleShown, subtitle: cfg.subtitle, hello: cfg.greeting, strings: S, locale: cfg.locale)
        BootScene.play(target: hud.orbCenterOnScreen, text: text, sound: Paths.voiceFile("boot"), calm: style == "calm") { [weak self] in
            guard let self else { return }
            self.hud.hideAll(false)
            self.hud.show(self.S.speaking, self.cfg.greeting, heard: "", speed: 1.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.ear.muted = false; self.ear.restart(); self.converse(keep: true) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.35) { [weak self] in   // when the greeting text is typed out
            guard let self else { return }
            if let f = Paths.voiceFile("greeting") { Mouth.play(f) } else { self.mouth.speak(self.cfg.greeting) {} }
        }
    }

    /// The ear stays open while speaking — if the user starts talking, stop and listen (barge-in).
    func speak(_ text: String, then: @escaping () -> Void) {
        remoteSaid(text)
        lastSpoken = text
        mode = .speaking
        speakingText = text; bargedIn = false
        ear.muted = false; ear.restart()
        hud.show(S.speaking, text, heard: nil, speed: 1.5)
        mouth.speak(text) { [weak self] in
            guard let self else { return }
            self.speakingText = ""
            self.spokeAt = Date()
            if self.bargedIn { return }
            self.ignoreUntil = Date().addingTimeInterval(self.bargeAny ? 0 : 0.6)
            self.ear.restart(); then()
        }
    }
    func bargeIn(_ t: String) {
        guard !bargedIn else { return }
        bargedIn = true
        log("barge-in: \(t)")
        mouth.stop(); spokeAt = Date()
        speakingText = ""
        ear.markSegmentNow()
        mode = .awake; awakeStarted = Date()
        awakeUntil = Date().addingTimeInterval(cfg.followUpSec)
        whisper.warm()
        hud.show(S.conversing, t, heard: "")
    }
    /// You started talking over its voice through the speakers (louder than its echo): stop and take what you say next.
    func bargeInByVoice() {
        guard !bargedIn else { return }
        bargedIn = true
        log("barge-in: your voice over the speaker")
        mouth.stop(); spokeAt = Date()
        speakingText = ""
        ear.restart(); ear.markSegmentNow(back: 0.6)     // Whisper gets the start of what you said (not much of its own voice)
        mode = .awake; awakeStarted = Date()
        awakeUntil = Date().addingTimeInterval(cfg.followUpSec)
        whisper.warm()
        hud.show(S.conversing, S.speakNow, heard: "")
    }
    /// "대표님. 아니 아멜리아 먹방…" — right after you cut in, the recording can start with the tail of its own answer.
    /// Only its way of addressing you is dropped: your own first words may well repeat what it said ("유튜브 영상…").
    func dropEcho(_ t: String) -> String {
        guard Date().timeIntervalSince(spokeAt) < 20, !lastSpoken.isEmpty else { return t }
        let me = Parser.squash(cfg.user)
        guard !me.isEmpty else { return t }
        var words = t.split(separator: " ").map(String.init)
        var dropped = 0
        while let w = words.first, Parser.squash(w) == me, words.count > 1 { words.removeFirst(); dropped += 1 }
        if dropped > 0 { log("dropped its own voice: \(dropped) word(s)") }
        return words.joined(separator: " ")
    }
    /// Don't mistake our own voice (from speakers) for the user.
    func isEcho(_ t: String) -> Bool {
        let a = Parser.squash(t), b = Parser.squash(speakingText)
        if a.count < 2 { return true }
        if b.contains(a) { return true }
        let bs = Set(b), hit = a.filter { bs.contains($0) }.count
        return a.count >= 4 && Double(hit) / Double(a.count) > 0.85
    }
    func done(_ kind: String, _ body: String) {
        remoteSaid(body.isEmpty ? kind : kind + " · " + body)
        hud.show("✓ \(kind)", body, color: lime)
        mode = .awake; awakeUntil = Date().addingTimeInterval(cfg.followUpSec)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in if self?.mode == .awake { self?.converse() } }
    }
    /// After starting a video/music, go idle so its audio isn't taken as commands.
    func played(_ kind: String, _ body: String) {
        remoteSaid(body.isEmpty ? kind : kind + " · " + body)
        hud.show("▶ \(kind)", body, color: lime)
        mode = .idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in if self?.mode == .idle { self?.hud.idle() } }
    }
    /// Safari blocks autoplay with sound by default, so a YouTube page can open paused. If nothing is playing
    /// after 3 s and the browser is in front, press YouTube's play key (k) — once, never when it's already playing.
    func ensurePlaying() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, AudioDevices.outputBusy(self.cfg.outputDevice, micUID: self.cfg.inputDevice) == false,
                  let front = NSWorkspace.shared.frontmostApplication?.localizedName,
                  front == (self.cfg.browserApp.isEmpty ? front : self.cfg.browserApp) || ["Safari", "Google Chrome"].contains(front) else { return }
            log("video didn't start (autoplay blocked?) → pressing play")
            Hands.key(40)      // k = YouTube play/pause
        }
    }
    /// A timer went off: chime, card, and say it — unless it's busy talking or working, then just chime and show it.
    func timerFired(_ label: String) {
        Sound.named("Glass"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Sound.named("Glass") }
        let line = cfg.ko ? "\(cfg.user.isEmpty ? "" : cfg.user + ", ")\(label.isEmpty ? "시간 됐습니다." : label + " 시간입니다.")"
                          : (label.isEmpty ? "Time's up." : "Time for \(label).")
        hud.show(S.t("⏰ 타이머", "⏰ Timer"), line, heard: "", color: amber, speed: 2)
        guard mode == .idle || mode == .awake else { return }
        speak(line) { [weak self] in self?.goIdle() }
    }
    /// Apps that mean "I'm in a call" (or dictating with Handy) when they record from the mic.
    static let callApps: Set<String> = ["us.zoom.xos", "zoom.us", "com.microsoft.teams", "com.microsoft.teams2", "com.apple.FaceTime",
        "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.kakao.KakaoTalkMac",
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.pais.handy", "com.apple.VoiceMemos"]
    var inCall = false
    /// While a call app records from the mic, stop listening (no commands from the meeting's audio); resume after.
    func checkCalls() {
        let busy = AudioDevices.micUsers().contains { Butler.callApps.contains($0) }
        if busy, !inCall, mode == .idle || mode == .awake {
            inCall = true; ear.muted = true; mode = .idle
            log("call/dictation app is using the mic → pausing")
            hud.show(S.t("🎙 통화 중 · 잠시 쉼", "🎙 In a call · paused"), S.t("끝나면 다시 들어요 (단축키는 그대로 돼요)", "Back when it ends (hotkey still works)"), heard: "", color: amber, speed: 0.3)
        } else if busy, inCall, mode == .idle, !ear.holding, !ear.muted {
            ear.muted = true          // after a hotkey command during the call, stop listening again
        } else if !busy, inCall {
            inCall = false; ear.muted = false; ear.restart()
            log("mic free again → listening"); hud.idle()
        }
    }
    func goIdle() { mode = .idle; hud.idle() }
    func shutdown() { whisper.stop(); brain.stop(); router.stop(); mouth.stop(); control.stop() }
}
