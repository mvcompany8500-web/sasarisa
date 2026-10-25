// Settings window (menu → Settings…). Edits ~/.macbutler/config.json and restarts the app.
import AppKit
import SwiftUI
import AVFoundation
import Charts

final class SettingsModel: ObservableObject {
    @Published var language: String
    @Published var activation: String
    @Published var userName: String
    @Published var assistantName: String
    @Published var wakeWords: String
    @Published var greetingText: String
    @Published var bootStyle: String
    @Published var hotkey: String
    @Published var tts: String
    @Published var sayVoice: String
    @Published var elevenVoiceId: String
    @Published var elevenKeyFile: String
    @Published var claudeModel: String
    @Published var inputDevice: String
    @Published var bargeIn: String
    @Published var outputDevice: String
    @Published var hudPosition: String
    @Published var confirmDelegate: String
    @Published var freeMode: Bool
    @Published var growTogether: String
    @Published var proRemote: Bool
    @Published var previewBeforeSend: Bool
    @Published var polishDictation: Bool
    @Published var pro: ProAccount.Status?
    @Published var proLinked = ProAccount.token != nil
    @Published var proCode = ""
    @Published var plans: [String: AIUsage.Plan] = [:]
    @Published var daily: [(day: String, calls: Int, tokens: Int)] = []
    /// AI plan windows (Claude from its last run, Codex from its logs) and Sasarisa's own use — read when the window opens.
    func refreshUsage() {
        if SettingsWindow.shooting { return }
        DispatchQueue.global().async {
            AIUsage.refreshCodex()
            let p = AIUsage.load(), d = AIUsage.daily(7)
            DispatchQueue.main.async { self.plans = p; self.daily = d }
        }
    }             // shown while waiting for approval in the browser
    @Published var brainProvider: String
    @Published var brainModel: String
    @Published var brainBaseURL: String
    @Published var brainEffort: String
    @Published var brainKey = ""            // typed here, saved to the Keychain only — never to config.json
    @Published var ttsVoice: String
    @Published var ttsRegion: String
    @Published var ttsURL: String
    @Published var voiceKey = ""
    let inputs = AudioDevices.inputs(), outputs = AudioDevices.outputs()
    private(set) var cfg: Config

    init(_ c: Config) {
        cfg = c
        language = c.lang; activation = c.activation; userName = c.userName; assistantName = c.assistantName
        wakeWords = c.wakeWords.joined(separator: ", "); greetingText = c.greetingText; bootStyle = c.bootStyle
        hotkey = c.hotkey; tts = c.tts; sayVoice = c.sayVoice
        elevenVoiceId = c.elevenLabs.voiceId; elevenKeyFile = c.elevenLabs.apiKeyFile; claudeModel = c.claudeModel
        inputDevice = c.inputDevice; outputDevice = c.outputDevice; bargeIn = c.bargeIn; hudPosition = c.hudPosition; confirmDelegate = c.confirmDelegate; freeMode = c.freeMode; growTogether = c.growTogether.isEmpty ? "together" : c.growTogether; proRemote = c.proRemote; previewBeforeSend = c.previewBeforeSend; polishDictation = c.polishDictation
        brainProvider = c.brainProvider; brainModel = c.brainModel; brainBaseURL = c.brainBaseURL; brainEffort = c.brainEffort
        ttsVoice = c.ttsVoice; ttsRegion = c.ttsRegion; ttsURL = c.ttsURL
        voice.onDone = { [weak self] in self?.needsRestart = true }      // the learned spellings are used from the next start
    }
    /// 목소리로 이름 맞추기 (shared with the setup window).
    let voice = NameTrainingModel()
    /// Everything that needs a restart to take effect (screen position applies live; keys are saved when the window closes).
    var snapshot: String {
        [language, activation, userName, assistantName, wakeWords, greetingText, hotkey, tts, sayVoice, elevenVoiceId, elevenKeyFile,
         claudeModel, inputDevice, bargeIn, outputDevice, confirmDelegate, brainProvider, brainModel, brainBaseURL, brainEffort,
         ttsVoice, ttsRegion, ttsURL, growTogether, freeMode ? "1" : "0", proRemote ? "1" : "0", previewBeforeSend ? "1" : "0", polishDictation ? "1" : "0"].joined(separator: "\u{1F}")
    }
    /// Something that needs a restart changed — closing the window restarts Sasarisa to apply it.
    @Published var needsRestart = false
    /// 미리 듣기: says a sample line with the engine and voice chosen in the window right now (before saving).
    @Published var previewing = false
    private var previewMouth: Mouth?
    func preview() {
        var c = Config.load()
        c.language = language; c.tts = tts; c.sayVoice = sayVoice; c.ttsVoice = ttsVoice; c.ttsRegion = ttsRegion; c.ttsURL = ttsURL
        c.elevenLabs.voiceId = elevenVoiceId; c.elevenLabs.apiKeyFile = elevenKeyFile; c.outputDevice = outputDevice
        if !userName.isEmpty { c.userName = userName }
        if !assistantName.isEmpty { c.assistantName = assistantName }
        let vk = voiceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vk.isEmpty, !voiceAccount.isEmpty { Keys.set(voiceAccount, vk) }     // the same place Save puts it
        let who = c.userName.isEmpty ? (c.ko ? "주인님" : "") : c.userName
        let line = c.ko ? "안녕하세요, \(who). \(c.assistantName)입니다. 이 목소리로 읽어 드릴게요."
                        : "Hello\(who.isEmpty ? "" : ", " + who). I'm \(c.assistantName), and this is how I'll sound."
        previewMouth?.stop()
        let m = Mouth(cfg: c); previewMouth = m; previewing = true
        // Sasarisa must not take its own sample line for a command (10/24 it handed 「안녕하세요 주인님…」 to the brain)
        NotificationCenter.default.post(name: Notification.Name("MacButlerPreview"), object: true)
        m.speak(line) { [weak self] in DispatchQueue.main.async {
            self?.previewing = false
            NotificationCenter.default.post(name: Notification.Name("MacButlerPreview"), object: false)
        } }
    }
    /// Pro: membership and voice allowance, read in the background when the window opens.
    func refreshPro() {
        if SettingsWindow.shooting { proLinked = false; pro = nil; return }      // a picture for the README: no account on it
        guard ProAccount.token != nil else { proLinked = false; pro = nil; return }
        DispatchQueue.global().async { let st = ProAccount.refresh()
            DispatchQueue.main.async { self.pro = st; self.proLinked = ProAccount.token != nil } }
    }
    func linkPro() {
        proCode = "…"
        ProAccount.link(name: Host.current().localizedName ?? "Mac", code: { self.proCode = $0 }) { ok in
            self.proCode = ""; self.proLinked = ok; if ok { self.pro = ProAccount.status; self.needsRestart = true }
        }
    }
    func unlinkPro() { ProAccount.unlink(); proLinked = false; pro = nil; if tts == "pro" { tts = "say" } }
    /// Keychain account for the chosen voice's key.
    var voiceAccount: String { ["openai": "openai", "azure": "azure-speech", "http": "http-tts", "elevenlabs": "elevenlabs"][tts] ?? "" }
    static func keyHint(_ account: String) -> String { Keys.get(account).map { "…" + $0.suffix(4) } ?? "" }

    /// Writes only the keys this window manages; everything else in config.json is kept as is.
    func save() {
        let url = Paths.home.appendingPathComponent("config.json")
        var obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        obj["language"] = language; obj["activation"] = activation; obj["userName"] = userName; obj["assistantName"] = assistantName
        obj["wakeWords"] = wakeWords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        obj["greetingText"] = greetingText; obj["bootStyle"] = bootStyle; obj["hotkey"] = hotkey; obj["tts"] = tts; obj["sayVoice"] = sayVoice
        obj["claudeModel"] = claudeModel; obj["inputDevice"] = inputDevice; obj["outputDevice"] = outputDevice; obj["bargeIn"] = bargeIn; obj["hudPosition"] = hudPosition; obj["confirmDelegate"] = confirmDelegate; obj["freeMode"] = freeMode; obj["growTogether"] = growTogether; obj["proRemote"] = proRemote; obj["previewBeforeSend"] = previewBeforeSend; obj["polishDictation"] = polishDictation
        obj["brainProvider"] = brainProvider; obj["brainModel"] = brainModel; obj["brainBaseURL"] = brainBaseURL; obj["brainEffort"] = brainEffort
        obj["ttsVoice"] = ttsVoice; obj["ttsRegion"] = ttsRegion; obj["ttsURL"] = ttsURL
        let bk = brainKey.trimmingCharacters(in: .whitespacesAndNewlines), vk = voiceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bk.isEmpty, !["claude-code", "codex", "aside", "ollama", "lmstudio"].contains(brainProvider) { Keys.set(brainProvider, bk); log("saved a key for \(brainProvider)") }
        if !vk.isEmpty, !voiceAccount.isEmpty { Keys.set(voiceAccount, vk); log("saved a key for \(voiceAccount)") }
        var el = obj["elevenLabs"] as? [String: Any] ?? [:]
        el["voiceId"] = elevenVoiceId; el["apiKeyFile"] = elevenKeyFile
        obj["elevenLabs"] = el
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? d.write(to: url)
            log("settings saved")
        }
    }

    /// macOS voices for the language, best first: (identifier, "Yuna · Premium").
    static func sayVoices(lang: String) -> [(id: String, label: String)] {
        let want = String((Config.languages.first { $0.code == lang }?.locale ?? "en-US").prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(want) && ($0.identifier.hasPrefix("com.apple.voice.") || $0.quality != .default || $0.identifier.contains("eloquence")) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
            .map { v in
                let q = v.quality == .premium ? " · Premium" : v.quality == .enhanced ? " · Enhanced" : v.identifier.contains("eloquence") ? " · robot" : ""
                return (v.identifier, v.name + q)
            }
    }
}

struct SettingsView: View {
    @ObservedObject var m: SettingsModel
    let S: Strings
    var height: CGFloat = 760
    var onSave: () -> Void
    var body: some View {
        Form {
            Section(S.t("기본", "Basics")) {
                Picker(S.t("언어", "Language"), selection: $m.language) { ForEach(Config.languages, id: \.code) { Text($0.name).tag($0.code) } }
                Picker(S.t("부르는 방식", "How to call it"), selection: $m.activation) {
                    Text(S.t("부르는 말 (+ 단축키)", "Wake word (+ hotkey)")).tag("voice")
                    Text(S.t("단축키만", "Hotkey only")).tag("hold")
                }
                Note(S.t("부르는 말은 늘 귀를 열어 두고, 단축키만은 누를 때만 듣습니다.", "The wake word keeps listening; hotkey only listens while you press it."))
                TextField(S.t("나를 부르는 호칭", "What it calls you"), text: $m.userName, prompt: Text(S.t("예: 대표님", "e.g. Tony")))
                TextField(S.t("비서 이름", "Assistant name"), text: $m.assistantName)
                NameTrainingRow(t: m.voice, name: m.assistantName, S: S)
                TextField(S.t("부르는 말", "Wake words"), text: $m.wakeWords, prompt: Text(S.t("쉼표로 여러 개 · 비우면 기본값", "comma-separated · empty = default")))
                TextField(S.t("인사말", "Greeting"), text: $m.greetingText, prompt: Text(S.t("어서 오십시오, {user}", "Welcome home, {user}.")))
                HStack {
                    Picker(S.t("인사 화면", "Greeting screen"), selection: $m.bootStyle) {
                        Text(S.t("화려하게 (기본)", "Flashy (default)")).tag("reactor")
                        Text(S.t("깔끔하게", "Calm")).tag("calm")
                        Text(S.t("카드로만", "Card only")).tag("card")
                    }
                    Button(S.t("미리 보기", "Preview")) { m.save(); NotificationCenter.default.post(name: Notification.Name("MacButlerBootPreview"), object: m.bootStyle) }
                }
                Note(S.t("「\(m.cfg.greets.first ?? "아빠 왔어")」 하고 들어오면 나오는 화면이에요.", "What shows when you come home and say “\(m.cfg.greets.first ?? "I'm home")”."))
                Picker(S.t("단축키로 부르기", "Wake hotkey"), selection: $m.hotkey) {
                    Text(S.t("오른쪽 ⌥ (기본)", "Right ⌥ (default)")).tag("rightOption"); Text(S.t("오른쪽 ⌘", "Right ⌘")).tag("rightCommand"); Text(S.t("끔", "Off")).tag("none")
                }
                Note(S.t("한 번 톡 누르면 부르기, 누른 채 말하면 그동안만 듣습니다.", "Tap once to wake it; hold it and talk to be heard only while held."))
                Picker(S.t("실행 방식", "How it acts"), selection: $m.confirmDelegate) {
                    Text(S.t("바로 실행 (기본)", "Right away (default)")).tag("never")
                    Text(S.t("클로드에 넘길 때만 묻기", "Ask before handing to Claude")).tag("brain")
                    Text(S.t("물어보고 실행", "Ask first")).tag("always")
                }
                Note(S.t("바로 실행은 묻지 않고 합니다. 보내기·게시·삭제처럼 되돌릴 수 없는 일은 한 번 묻습니다(자유 모드가 아니면).",
                         "Right away just does it. Irreversible things (sending, posting, deleting) are asked once — unless free mode is on."))
                Toggle(S.t("자유 모드 — 결제만 묻기", "Free mode — ask only before paying"), isOn: $m.freeMode)
                Note(S.t("보내기·게시·삭제, 클로드에 일 넘기기까지 묻지 않고 바로 합니다. 결제는 늘 묻습니다. 텔레비전·영상 소리도 명령처럼 들릴 수 있으니 이어폰이나 단축키와 함께 쓰세요.",
                         "Sends, posts, deletes and hand-offs to Claude happen without asking. Payments always ask. TV or video audio can sound like a command, so pair it with headphones or the hotkey."))
                Toggle(S.t("보내기 전 미리 보기", "Preview before sending"), isOn: $m.previewBeforeSend)
                Note(S.t("클로드 창에 전할 말을 입력칸에 넣어 보여 주고, 「응」 하면 보냅니다. 「아니」 하거나 20초 동안 답이 없으면 지우고 보내지 않습니다.",
                         "The message for a Claude window is put in its box for you to read, and sent only when you say “yes”. “No”, or no answer in 20 s, clears it."))
                Toggle(S.t("받아쓰기 다듬기 — 핸디처럼", "Tidy dictation — like Handy"), isOn: $m.polishDictation).disabled(!Polish.available)
                Note(Polish.available
                     ? S.t("받아 적은 글을 붙이기 전에 맥 안의 Apple Intelligence가 맞춤법·문장부호(?·.)·숫자를 고칩니다. 핸디에 고른 다듬기 지시문이 있으면 그걸 씁니다. 밖으로 나가는 것 없음, 비용 0.",
                           "Before dictation is pasted, Apple Intelligence on this Mac fixes spelling, punctuation and numbers — with your Handy post-process prompt if you have one. Nothing leaves the Mac.")
                     : S.t("Apple Intelligence를 켜면 쓸 수 있어요(시스템 설정 → Apple Intelligence).", "Turn on Apple Intelligence to use it (System Settings → Apple Intelligence)."))
                Picker(S.t("화면 위치", "On-screen position"), selection: $m.hudPosition) {
                    ForEach(HUD.positions(S), id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            Section(S.t("키우기", "Learning")) {
                Picker(S.t("배운 말 나누기", "Share what it learns"), selection: $m.growTogether) {
                    Text(S.t("다 같이 키우기", "Grow together")).tag("together"); Text(S.t("혼자 키우기", "Grow alone")).tag("solo")
                }.pickerStyle(.segmented)
                Note(m.growTogether == "together"
                     ? S.t("알아들은 짧은 말과 그 말로 한 빠른 명령(소리·영상·창 닫기·앱 열기)만 이름 없이 하루 한 번 보냅니다. 여러 사람이 같은 말을 쓸 때만 모두에게 들어갑니다. 목소리·대화·화면·파일·이름·검색어는 보내지 않습니다.",
                           "Once a day it shares only short sentences it understood and the quick command they ran (volume, video, closing pages, opening apps), with no name. A sentence reaches everyone only when many people use it. No audio, conversations, screen, files, names or search words.")
                     : S.t("배운 것은 이 맥에만 둡니다. 모두가 함께 키운 말은 그대로 받아 씁니다.", "What it learns stays on this Mac. It still uses what everyone taught together."))
            }
            Section(S.t("마이크·스피커", "Microphone & speaker")) {
                Picker(S.t("마이크", "Microphone"), selection: $m.inputDevice) {
                    Text(S.t("시스템 기본", "System default")).tag("")
                    ForEach(m.inputs, id: \.uid) { Text($0.name).tag($0.uid) }
                }
                Picker(S.t("스피커", "Speaker"), selection: $m.outputDevice) {
                    Text(S.t("시스템 기본", "System default")).tag("")
                    ForEach(m.outputs, id: \.uid) { Text($0.name).tag($0.uid) }
                }
                Picker(S.t("말하는 중에 끊기", "Interrupting while it talks"), selection: $m.bargeIn) {
                    Text(S.t("자동 (기본)", "Auto (default)")).tag("auto")
                    Text(S.t("아무 말로나", "Any speech")).tag("any")
                    Text(S.t("부르는 말·「멈춰」로만", "Wake word or “stop” only")).tag("wake")
                }
                Note(S.t("자동은 이어폰이면 아무 말로, 스피커면 부르는 말·「멈춰」로만 끊습니다. 스피커 소리를 제 말로 착각하지 않게요.",
                         "Auto: with headphones any speech interrupts; on speakers only the wake word or “stop” — so it doesn't mistake its own voice for you."))
            }
            Section(S.t("목소리", "Voice")) {
                LabeledContent(S.t("읽어 주는 엔진", "Speech engine")) {
                    EngineMenu(selection: $m.tts, localTitle: S.t("이 맥에서", "On this Mac"), local: [
                        Choice("say", S.t("맥 목소리 — 무료 (기본)", "macOS voice — free (default)")),
                        Choice("http", S.t("내 음성 서버 — 주소로 연결", "My voice server — by URL"))
                    ], apiTitle: S.t("API 키 연결", "API key"), api: [
                        Choice("elevenlabs", "ElevenLabs"),
                        Choice("openai", S.t("OpenAI 목소리", "OpenAI voice")),
                        Choice("azure", S.t("Azure 음성 — 매달 무료 한도", "Azure Speech — monthly free tier"))
                    ], proTitle: S.t("멤버십 Pro", "Membership Pro"), pro: [
                        Choice("pro", S.t("좋은 목소리 — 터틀메이커 멤버십", "Natural voice — TurtleMaker membership"))
                    ])
                }
                if m.tts == "say" {
                    Picker(S.t("맥 목소리", "macOS voice"), selection: $m.sayVoice) {
                        Text(S.t("자동 — 가장 자연스러운 목소리", "Auto — the most natural one")).tag("")
                        ForEach(SettingsModel.sayVoices(lang: m.language), id: \.id) { Text($0.label).tag($0.id) }
                    }
                    Text(S.t("더 자연스러운 목소리(무료): 시스템 설정 → 손쉬운 사용 → 읽기 및 말하기 → 시스템 목소리 → 목소리 관리… → Premium 받기",
                             "More natural voices (free): System Settings → Accessibility → Spoken Content → System voice → Manage Voices… → download a Premium voice"))
                        .font(.caption).foregroundStyle(.secondary)
                } else if m.tts == "pro" {
                    Picker(S.t("목소리", "Voice"), selection: $m.ttsVoice) {
                        ForEach(ProAccount.voices.sorted { ($0.lang == m.language.prefix(2)) && ($1.lang != m.language.prefix(2)) }, id: \.id) { v in Text(S.t(v.ko, v.en)).tag(v.id) }
                    }
                    .onAppear { if !ProAccount.voices.contains(where: { $0.id == m.ttsVoice }) { m.ttsVoice = ProAccount.voices[0].id } }
                    Note(!m.proLinked
                         ? S.t("아래 「멤버십 Pro」에서 터틀메이커 계정을 연결하면 씁니다. 그 전에는 맥 목소리로 읽습니다.",
                               "Link your TurtleMaker account under Membership Pro below. Until then the macOS voice reads.")
                         : m.pro?.voice == true
                         ? S.t("이번 달 \(m.pro!.used.formatted()) / \(m.pro!.limit.formatted())자 사용. 다 쓰면 다음 달까지 맥 목소리로 읽습니다.",
                               "\(m.pro!.used.formatted()) / \(m.pro!.limit.formatted()) characters used this month. After that, the macOS voice reads until next month.")
                         : S.t("좋은 목소리는 홈페이지·프로그램 멤버십에 들어 있습니다. 지금은 맥 목소리로 읽습니다.",
                               "The natural voice comes with the site or program membership. For now the macOS voice reads."))
                } else if m.tts == "elevenlabs" {
                    TextField("ElevenLabs voice ID", text: $m.elevenVoiceId)
                    TextField(S.t("API 키가 든 .env 파일 (또는 아래 칸)", ".env file with ELEVENLABS_API_KEY (or the box below)"), text: $m.elevenKeyFile)
                } else {
                    TextField(S.t("목소리 이름", "Voice"), text: $m.ttsVoice,
                              prompt: Text(m.tts == "azure" ? "ko-KR-SunHiNeural" : m.tts == "openai" ? "alloy" : S.t("서버가 아는 이름", "a name your server knows")))
                    if m.tts == "azure" { TextField(S.t("지역", "Region"), text: $m.ttsRegion, prompt: Text("koreacentral")) }
                    if m.tts == "http" { TextField(S.t("서버 주소", "Server URL"), text: $m.ttsURL, prompt: Text("http://127.0.0.1:5002/tts")) }
                }
                if m.tts != "say" && m.tts != "pro" {
                    SecureField(S.t("API 키 (맥 키체인에만 저장)", "API key (kept in the macOS Keychain only)"), text: $m.voiceKey,
                                prompt: Text(SettingsModel.keyHint(m.voiceAccount).isEmpty ? S.t(m.tts == "http" ? "필요할 때만" : "붙여 넣기", m.tts == "http" ? "only if needed" : "paste it here") : S.t("저장됨 ", "saved ") + SettingsModel.keyHint(m.voiceAccount)))
                    Text(S.t("안 되면 늘 무료 맥 목소리로 대신 읽습니다.", "If it fails, the free macOS voice reads instead.")).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent(S.t("미리 듣기", "Preview")) {
                    Button { m.preview() } label: { Label(m.previewing ? S.t("읽는 중…", "Speaking…") : S.t("들어 보기", "Listen"), systemImage: m.previewing ? "speaker.wave.2.fill" : "play.fill") }
                        .disabled(m.previewing)
                }
            }
            Section {
                if !m.proLinked {
                    LabeledContent(S.t("터틀메이커 계정", "TurtleMaker account")) {
                        if m.proCode.isEmpty {
                            Button(S.t("연결하기", "Link")) { m.linkPro() }
                        } else {
                            Text(m.proCode == "…" ? S.t("여는 중…", "Opening…") : S.t("브라우저에서 승인 · \(m.proCode)", "Approve in the browser · \(m.proCode)"))
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Note(S.t("브라우저에서 터틀메이커에 로그인한 채 「연결」을 누르면 끝납니다. 이 맥에는 연결 열쇠만 키체인에 남습니다.",
                             "Press Link in the browser while signed in to TurtleMaker. Only a link key stays on this Mac, in the Keychain."))
                } else {
                    LabeledContent(S.t("터틀메이커 계정", "TurtleMaker account")) {
                        HStack {
                            Text(m.pro?.email ?? "…").foregroundStyle(.secondary)
                            Button(S.t("연결 끊기", "Unlink")) { m.unlinkPro() }
                        }
                    }
                    LabeledContent(S.t("멤버십", "Membership")) {
                        if m.pro?.active == true {
                            Text(S.t("회원 · Pro 사용 중", "Member · Pro on")).foregroundStyle(.secondary)
                        } else {
                            Link(S.t("멤버십 보기", "See membership"), destination: URL(string: "https://turtlebuffkit.com/join")!)
                        }
                    }
                    Toggle(S.t("폰으로 부르기", "Call it from your phone"), isOn: $m.proRemote)
                    Note(S.t("폰에서 maker.buffm.com/butler/remote 를 열어 글로 시키면 이 맥이 하고 결과를 한 줄로 알려 줍니다. 폰에서 시킨 일은 결제를 하지 않고, 보내기·삭제는 자유 모드일 때만 합니다.",
                             "Open maker.buffm.com/butler/remote on your phone and type a request; this Mac does it and answers in one line. Requests from the phone never pay, and send or delete only in free mode."))
                }
            } header: { Text(S.t("멤버십 Pro", "Membership Pro")) } footer: {
                Note(S.t("이 맥·내 구독·내 API 키로 하는 일은 모두 계속 무료입니다. Pro는 서버가 드는 것(폰으로 부르기·좋은 목소리)만 담고, 터틀메이커 통합 멤버십에 들어 있습니다.",
                         "Everything that runs on this Mac, your plan or your API key stays free. Pro only covers what needs our servers (phone, natural voice) and comes with the TurtleMaker membership."))
            }
            Section {
                ForEach(["claude", "codex"], id: \.self) { key in
                    if let p = m.plans[key] {
                        ForEach(Array(p.windows.enumerated()), id: \.offset) { _, w in
                            UsageBar(title: (key == "claude" ? "Claude" : "Codex") + " · " + S.t(w.label, w.label.replacingOccurrences(of: "시간", with: " h").replacingOccurrences(of: "7일", with: "7 days")),
                                     used: w.used, detail: w.resets.map { S.t("\(Self.when($0)) 다시 채워짐", "resets \(Self.when($0))") } ?? "")
                        }
                    }
                }
                if m.plans.isEmpty {
                    Note(S.t("두뇌가 한 번 일하면 남은 양이 여기 나옵니다(Claude 코드·Codex).", "Your plan's remaining share shows here after the brain runs once (Claude Code, Codex)."))
                }
                if m.proLinked, let p = m.pro, p.voice {
                    UsageBar(title: S.t("좋은 목소리 · 이번 달", "Natural voice · this month"), used: Double(p.used) / Double(max(p.limit, 1)),
                             detail: "\(p.used.formatted()) / \(p.limit.formatted())" + S.t("자", " chars"))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(S.t("\(m.assistantName.isEmpty ? "비서" : m.assistantName)가 쓴 양 · 7일", "Used by \(m.assistantName.isEmpty ? "the assistant" : m.assistantName) · 7 days"))
                    Chart(m.daily, id: \.day) { d in
                        BarMark(x: .value("day", d.day), y: .value("tokens", d.tokens)).foregroundStyle(Color.accentColor.gradient).cornerRadius(3)
                    }
                    .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine(); AxisValueLabel { if let n = v.as(Int.self) { Text(Self.short(n)) } } } }
                    .frame(height: 110)
                    let today = m.daily.last
                    Note(S.t("오늘 \(today?.calls ?? 0)번 · 약 \(Self.short(today?.tokens ?? 0)) 토큰(다시 읽은 부분은 1/10로 셈)",
                             "Today \(today?.calls ?? 0) runs · about \(Self.short(today?.tokens ?? 0)) tokens (re-read context counted at 1/10)"))
                }
            } header: { Text(S.t("AI 사용량", "AI usage")) } footer: {
                Note(S.t("막대는 요금제 전체(다른 앱에서 쓴 것 포함)가 얼마나 찼는지이고, 그래프는 이 비서가 쓴 몫입니다. 이 맥 안에서만 읽고 어디에도 보내지 않습니다.",
                         "The bars are how full your whole plan is (including other apps); the chart is this assistant's share. Read on this Mac only, sent nowhere."))
            }
            Section {
                LabeledContent(S.t("생각하는 AI", "Who does the thinking")) {
                    EngineMenu(selection: $m.brainProvider, localTitle: S.t("로컬 연결 — 이 맥에 로그인된 AI", "Local — AI signed in on this Mac"), local: [
                        Choice("claude-code", S.t("Claude Code — Claude 구독 (기본)", "Claude Code — your Claude plan (default)")),
                        Choice("codex", S.t("Codex — ChatGPT 구독 (GPT)", "Codex — your ChatGPT plan (GPT)")),
                        Choice("ollama", S.t("Ollama — 이 맥에서 무료", "Ollama — free on this Mac")),
                        Choice("lmstudio", S.t("LM Studio — 이 맥에서 무료", "LM Studio — free on this Mac")),
                        Choice("aside", S.t("Aside — Aside 브라우저", "Aside — the Aside browser")),
                        Choice("combo", S.t("조합 — 코덱스·클로드·Aside 나눠 맡기기 (무료 · 고사양 맥)", "Combo — Codex, Claude and Aside share the work (free · high-end Mac)"))
                    ], apiTitle: S.t("API 키 연결", "API key"), api: [
                        Choice("anthropic", "Claude (Anthropic)"),
                        Choice("openai", "GPT (OpenAI)"),
                        Choice("gemini", "Gemini (Google)"),
                        Choice("openrouter", S.t("OpenRouter — 여러 회사 모델", "OpenRouter — many models")),
                        Choice("groq", "Groq"),
                        Choice("openai-compatible", S.t("OpenAI 호환 서버 — 주소로 연결", "OpenAI-compatible server — by URL"))
                    ])
                }
                switch m.brainProvider {
                case "claude-code":
                    Picker(S.t("모델", "Model"), selection: $m.claudeModel) { Text("Sonnet").tag("sonnet"); Text("Haiku").tag("haiku"); Text("Opus").tag("opus") }
                        .pickerStyle(.segmented)
                    Note(S.t("보통은 Sonnet. Haiku는 더 빠르고, Opus는 더 깊게 생각합니다.", "Sonnet for most things. Haiku is faster, Opus thinks deeper."))
                case "codex":
                    Picker(S.t("생각 깊이", "Thinking"), selection: $m.brainEffort) {
                        Text(S.t("빠르게", "Fast")).tag("low"); Text(S.t("보통", "Normal")).tag("medium"); Text(S.t("깊게", "Deep")).tag("high")
                    }.pickerStyle(.segmented)
                    Picker(S.t("모델", "Model"), selection: $m.brainModel) {
                        Text(S.t("기본 — Codex가 고름 (권장)", "Default — Codex picks (recommended)")).tag("")
                        ForEach(CodexBrain.listedModels(), id: \.self) { Text($0).tag($0) }
                    }
                    Note(CodexBrain.binary == nil
                         ? S.t("이 맥에 Codex가 없습니다. Codex 명령줄 도구를 설치하고 터미널에서 codex login 을 한 번 해 주세요.",
                               "Codex isn't on this Mac. Install the Codex CLI and run codex login once in Terminal.")
                         : S.t("이 맥에 로그인된 Codex로 생각합니다. 빠르게가 음성 비서에 맞고, 목록 모델이 안 되면 기본으로 돌리세요.",
                               "Thinks with the Codex you're signed in to. Fast suits a voice assistant; if a listed model fails, go back to Default."))
                case "combo":
                    let found = [("Codex", CodexBrain.binary != nil), ("Claude Code", Config.load().claudeBinary != nil), ("Aside", AsideBrain.binary != nil)]
                    Note(S.t("웹 심부름(사이트·메일·쇼핑·댓글)은 Aside, 코딩은 클로드 코드, 나머지는 코덱스가 맡아요. 각자 쓰시는 구독이라 추가 비용 없이 무료예요. ",
                             "Web errands (sites, mail, shopping, comments) go to Aside, coding to Claude Code, the rest to Codex — each on your own plan, so it's free. ")
                         + S.t("찾은 것: ", "Found: ") + found.map { $0.0 + ($0.1 ? " ✓" : " ✗") }.joined(separator: " · ") + ". "
                         + (ComboBrain.highSpec ? S.t("이 맥은 고사양이라 잘 돌아요.", "This Mac has the memory for it.")
                                                : S.t("여러 AI를 함께 쓰니 애플 실리콘·메모리 16GB 이상 맥을 권해요(이 맥에서도 되지만 느릴 수 있어요).", "Recommended for Apple silicon with 16 GB or more (it works here, but may be slow).")))
                case "aside":
                    Note(AsideBrain.binary == nil
                         ? S.t("Aside 명령줄 도구가 아직 없습니다. Aside 설정 → 개발자에서 설치하고, 터미널에서 aside login 을 한 번 해 주세요.",
                               "The Aside CLI isn't installed yet. Install it in Aside → Settings → Developer, then run aside login once in Terminal.")
                         : S.t("소리·앱 열기·타이머 같은 빠른 명령은 사사리사가 하고, 나머지는 Aside 브라우저가 합니다. 결제·보내기·지우기 직전에는 멈추고 묻게 합니다.",
                               "Quick commands (volume, apps, timers) stay with Sasarisa; the rest goes to Aside's browser, told to stop and ask before paying, sending or deleting."))
                case "ollama", "lmstudio":
                    TextField(S.t("모델", "Model"), text: $m.brainModel, prompt: Text(m.brainProvider == "ollama" ? S.t("비우면 설치된 첫 모델", "empty = first installed") : S.t("비우면 불러온 첫 모델", "empty = first loaded")))
                    Note(S.t("이 맥 안에서만 생각합니다. 인터넷으로 나가는 것이 없습니다.", "Thinks entirely on this Mac. Nothing leaves it."))
                default:
                    TextField(S.t("모델", "Model"), text: $m.brainModel,
                              prompt: Text(["anthropic": "claude-sonnet-5-5"][m.brainProvider] ?? S.t("그 회사 모델 목록의 이름", "a name from their model list")))
                    if m.brainProvider == "openai-compatible" {
                        TextField(S.t("서버 주소", "Server URL"), text: $m.brainBaseURL, prompt: Text("https://…/v1"))
                    }
                    SecureField(S.t("API 키", "API key"), text: $m.brainKey,
                                prompt: Text(SettingsModel.keyHint(m.brainProvider).isEmpty ? S.t("붙여 넣기", "paste it here") : S.t("저장됨 ", "saved ") + SettingsModel.keyHint(m.brainProvider)))
                    Note(S.t("API 키는 맥 키체인에만 저장되고, 쓴 만큼 그 회사에 요금이 나갑니다.", "The key is kept in the macOS Keychain only; that company bills you for what you use."))
                }
            } header: { Text(S.t("두뇌", "Brain")) } footer: {
                Text(S.t("어떤 두뇌든 손(누르기·입력·열기)은 같은 안전 장치를 지납니다. 셸·파일은 없습니다.",
                         "Whatever brain you pick, the hands go through the same safety checks. There's no shell or file access."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button(S.t("설정 폴더 열기", "Open folder")) { NSWorkspace.shared.open(Paths.home) }
                    Spacer()
                    Button(S.t("지금 다시 켜서 적용", "Restart now to apply")) { m.save(); onSave() }
                        .keyboardShortcut(.defaultAction).disabled(!m.needsRestart)
                }
            } footer: {
                Note(m.needsRestart
                     ? S.t("바꾼 설정은 저장됐습니다. 창을 닫으면 다시 켜서 적용합니다.", "Saved. Closing this window restarts Sasarisa to apply it.")
                     : S.t("바꾸는 즉시 저장됩니다. 화면 위치는 바로 바뀝니다.", "Changes are saved as you make them. The on-screen position moves right away."))
            }
        }
        .formStyle(.grouped)
        .onAppear { m.refreshPro(); m.refreshUsage() }
        .onChange(of: m.snapshot) { _ in m.save(); m.needsRestart = true }
        .onChange(of: m.hudPosition) { v in
            m.save()
            NotificationCenter.default.post(name: Notification.Name("MacButlerHUDPosition"), object: v)
            NotificationCenter.default.post(name: Notification.Name("MacButlerHUDDemo"), object: nil)       // show the card there for a moment
        }
        .frame(width: 580, height: height)
        .padding(.bottom, 8)
    }
}

extension SettingsView {
    static func when(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale.current
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: d)
    }
    static func short(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.0fK", Double(n) / 1e3) : "\(n)" }
}

/// One plan window: name, how full, when it resets.
struct UsageBar: View {
    let title: String; let used: Double; let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text("\(Int((used * 100).rounded()))%").monospacedDigit().foregroundStyle(used > 0.85 ? .red : .secondary) }
            ProgressView(value: min(max(used, 0), 1)).tint(used > 0.85 ? .red : used > 0.6 ? .orange : .accentColor)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

enum SettingsWindow {
    static var window: NSWindow?
    static var shooting = false
    /// The whole settings form drawn off screen into a PNG (design check, `--settings-shot`).
    static func shot(_ path: String) {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        shooting = true
        let cfg = Config.load(), S = Strings(ko: cfg.ko, name: cfg.displayName)
        let model = SettingsModel(cfg); model.proLinked = false
        let host = NSHostingController(rootView: SettingsView(m: model, S: S, height: 2400) {})
        let w = NSWindow(contentViewController: host)
        w.setFrame(NSRect(x: -4000, y: 0, width: 580, height: 2400), display: true)
        w.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let v = host.view
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    static var model: SettingsModel?
    /// Closing the window: keys typed are saved, and if something that needs a restart changed, Sasarisa restarts.
    final class Closer: NSObject, NSWindowDelegate {
        func windowWillClose(_ n: Notification) {
            guard let m = SettingsWindow.model else { return }
            if m.voice.training { m.voice.stop() }        // 목소리 맞추기 stops with the window
            m.save()
            SettingsWindow.window = nil; SettingsWindow.model = nil
            if m.needsRestart { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { SettingsWindow.relaunch() } }
        }
    }
    static let closer = Closer()
    static func show(cfg: Config) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let S = Strings(ko: cfg.ko, name: cfg.displayName)
        let model = SettingsModel(cfg); self.model = model
        let view = SettingsView(m: model, S: S) { relaunch() }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.delegate = closer
        w.title = S.t("사사리사 — 설정", "Sasarisa — Settings")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    /// Under launchd (installed with scripts/install.sh) a non-zero exit makes launchd start us again.
    /// Otherwise start a fresh copy, then quit.
    static func relaunch() {
        (NSApp.delegate as? AppDelegate)?.butler?.shutdown()
        // Run by our launch agent (its label is the bundle id; KeepAlive restarts a non-zero exit). Opened as an app the name
        // is "application.<bundle id>.<numbers>" — that used to match too, so it quit and nothing restarted it (10/24).
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == Bundle.main.bundleIdentifier { exit(3) }
        // A child process dies with us (launchd ends the app's whole process group), so `open -n` / `sleep; open` never
        // ran and it ended with none running (10/24). Ask LaunchServices for the new copy, which waits for this one to go.
        let conf = NSWorkspace.OpenConfiguration()
        conf.createsNewApplicationInstance = true
        conf.arguments = ["--after", String(getpid())]
        conf.activates = false
        let started = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: conf) { app, err in
            if let err { log("restart: couldn't start the new copy: \(err.localizedDescription)") } else { log("restart: new copy \(app?.processIdentifier ?? 0)") }
            started.signal()
        }
        _ = started.wait(timeout: .now() + 8)
        exit(0)
    }
}


/// One choice in an engine menu: what's saved (tag) and what's shown.
struct Choice: Identifiable { let id: String; let label: String; init(_ id: String, _ label: String) { self.id = id; self.label = label } }

/// Engine chooser (Handy-style settings, 2026-10-24): local choices first; API-key services sit in a submenu that opens
/// sideways on hover, so the main list stays short.
struct EngineMenu: View {
    @Binding var selection: String
    let localTitle: String
    let local: [Choice]
    let apiTitle: String
    let api: [Choice]
    var proTitle = ""
    var pro: [Choice] = []
    var body: some View {
        Menu {
            Section(localTitle) {
                Picker("", selection: $selection) { ForEach(local) { Text($0.label).tag($0.id) } }.pickerStyle(.inline).labelsHidden()
            }
            Divider()
            Menu(apiTitle) {
                Picker("", selection: $selection) { ForEach(api) { Text($0.label).tag($0.id) } }.pickerStyle(.inline).labelsHidden()
            }
            if !pro.isEmpty {
                Divider()
                Section(proTitle) {
                    Picker("", selection: $selection) { ForEach(pro) { Text($0.label).tag($0.id) } }.pickerStyle(.inline).labelsHidden()
                }
            }
        } label: { Text(current) }
        .fixedSize()
    }
    private var current: String {
        if let c = local.first(where: { $0.id == selection }) { return c.label }
        if let c = api.first(where: { $0.id == selection }) { return apiTitle + " · " + c.label }
        if let c = pro.first(where: { $0.id == selection }) { return c.label }
        return selection
    }
}

/// The one-line explanation under a setting.
/// 목소리 맞추기 state, shared by Settings and Setup — the running app does the listening (Butler.nameTraining).
final class NameTrainingModel: ObservableObject {
    @Published var training = false
    @Published var count = 0
    @Published var heard = ""
    @Published var next = ""            // what to say now
    @Published var result = ""
    @Published var verdict = ""
    @Published var learned: [String] = []
    var onDone: () -> Void = {}
    private var observer: NSObjectProtocol?
    init() {
        observer = NotificationCenter.default.addObserver(forName: Notification.Name("MacButlerNameTrainProgress"), object: nil, queue: .main) { [weak self] n in
            guard let self, self.training, let u = n.userInfo else { return }
            if u["done"] as? Bool == true {
                self.training = false
                self.result = "\(u["before"] as? Int ?? 0)/\(u["total"] as? Int ?? 0) → \(u["after"] as? Int ?? 0)/\(u["total"] as? Int ?? 0)"
                self.verdict = u["verdict"] as? String ?? ""
                self.learned = u["learned"] as? [String] ?? []
                self.onDone()
            } else {
                self.count = u["n"] as? Int ?? 0; self.heard = u["heard"] as? String ?? ""; self.next = u["next"] as? String ?? self.next
            }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func start(_ name: String) {
        training = true; count = 0; heard = ""; next = ""; result = ""; verdict = ""; learned = []
        NotificationCenter.default.post(name: Notification.Name("MacButlerNameTrain"), object: name.isEmpty ? "Sasarisa" : name)
    }
    func stop() {
        training = false
        NotificationCenter.default.post(name: Notification.Name("MacButlerNameTrain"), object: nil)
    }
}

/// 비서 이름 아래: 원하는 이름을 12번(이름만 8번 + 짧은 명령과 4번) 따라 말해 이 맥이 그 목소리를 어떻게 받아 적는지 배우게 합니다.
struct NameTrainingRow: View {
    @ObservedObject var t: NameTrainingModel
    let name: String
    let S: Strings
    var enabled = true
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if t.training {
                    ProgressView(value: Double(t.count), total: 12).frame(width: 140)
                    Text("\(t.count)/12").monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button(S.t("그만", "Stop")) { t.stop() }
                } else {
                    Button(t.result.isEmpty ? S.t("목소리로 이름 맞추기", "Train the name with my voice") : S.t("다시 맞추기", "Train again")) { t.start(name) }.disabled(!enabled)
                    Spacer()
                }
            }
            if t.training {
                if !t.next.isEmpty { Text(S.t("지금 말할 것: 「\(t.next)」", "Say now: “\(t.next)”")).font(.callout.weight(.semibold)) }
                Note(S.t("화면 구석 카드에 나오는 말을 한 번씩 끊어서, 평소 목소리로 따라 말해 주세요." + (t.heard.isEmpty ? "" : " 방금 들은 말: 「\(t.heard)」"),
                         "Say what the corner card shows, one at a time, in your normal voice." + (t.heard.isEmpty ? "" : " Just heard: “\(t.heard)”")))
            } else if !t.result.isEmpty {
                Text(S.t("알아들은 횟수 \(t.result)", "Recognized \(t.result)")).font(.callout.weight(.semibold))
                Note(t.verdict + (t.learned.isEmpty ? "" : S.t(" 이렇게도 알아듣게 배웠어요: ", " Also learned: ") + t.learned.prefix(6).joined(separator: ", ")))
            } else {
                Note(enabled
                     ? S.t("시리처럼, 이름을 8번 그리고 짧은 명령과 함께 4번 따라 말하면 이 맥이 내 목소리로 그 이름을 어떻게 받아 적는지 배우고 잘 알아듣는지 알려 드려요.",
                           "Like Siri: say the name 8 times, then 4 times with a short command — this Mac learns how it hears your voice and tells you how well it works.")
                     : S.t("마이크와 음성 인식을 허용하면 할 수 있어요.", "Allow the microphone and speech recognition first."))
            }
        }
    }
}

struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}
