// First-run setup (menu → Setup…): live checklist of permissions and dependencies, one-click fixes,
// and an in-app Whisper model download with progress and SHA-256 verification.
import AppKit
import SwiftUI
import AVFoundation
import Speech
import CryptoKit
import ScreenCaptureKit

final class SetupModel: NSObject, ObservableObject, URLSessionDownloadDelegate {
    let cfg: Config
    @Published var mic = false
    @Published var speech = false
    @Published var ax = false
    @Published var screen = false
    @Published var brain: String? = nil         // the AI that will think (Claude Code, Codex, Aside, an API or local model)
    @Published var whisperBin = false
    @Published var model = false
    @Published var voice = ""                  // the macOS voice it will speak with, e.g. "Yuna · Premium"
    @Published var naturalVoice = false        // a Premium / Enhanced voice (or ElevenLabs) is in use
    @Published var progress: Double = -1          // -1 = not downloading
    @Published var downloadError = ""
    /// 1단계: what you call it, what it calls you, and the voice check (owner 10/25: 「처음 깔면 호칭을 먼저 정하게 — siri 처럼」).
    @Published var name: String { didSet { save("assistantName", name, was: oldValue) } }
    @Published var userName: String { didSet { save("userName", userName, was: oldValue) } }
    let voiceCheck = NameTrainingModel()
    /// Picked here too (owner 10/25: 「두뇌도 목소리도 기본형이지만 처음부터 선택할 수 있게」).
    @Published var brainChoice: String { didSet { save("brainProvider", brainChoice, was: oldValue) } }
    @Published var voiceChoice: String { didSet { save("sayVoice", voiceChoice, was: oldValue) } }
    @Published var previewing = false
    /// Where the card shows up — picking one moves the real card there for a moment (owner 10/25: 「보면서 고를 수 있게」).
    @Published var position: String {
        didSet {
            save("hudPosition", position, was: oldValue)
            NotificationCenter.default.post(name: Notification.Name("MacButlerHUDPosition"), object: position)
            NotificationCenter.default.post(name: Notification.Name("MacButlerHUDDemo"), object: nil)
        }
    }
    private var previewMouth: Mouth?
    var brainOptions: [(id: String, label: String)] {
        let ko = cfg.ko, have: (Bool) -> String = { $0 ? " ✓" : "" }
        return [("claude-code", "Claude Code — " + (ko ? "Claude 구독" : "your Claude plan") + have(cfg.claudeBinary != nil)),
                ("codex", "Codex — " + (ko ? "ChatGPT 구독" : "your ChatGPT plan") + have(CodexBrain.binary != nil)),
                ("aside", "Aside — " + (ko ? "Aside 브라우저" : "the Aside browser") + have(AsideBrain.binary != nil)),
                ("combo", ko ? "조합 — 셋이 나눠 맡기 (무료 · 고사양 맥)" : "Combo — the three share the work (free · high-end Mac)"),
                ("ollama", ko ? "Ollama — 이 맥에서 무료" : "Ollama — free on this Mac"),
                ("lmstudio", ko ? "LM Studio — 이 맥에서 무료" : "LM Studio — free on this Mac")]
    }
    lazy var voiceOptions: [(id: String, label: String)] = SettingsModel.sayVoices(lang: cfg.lang)
    func previewVoice() {
        var c = Config.load(); c.sayVoice = voiceChoice
        if !name.isEmpty { c.assistantName = name }; if !userName.isEmpty { c.userName = userName }
        let who = c.userName.isEmpty ? (c.ko ? "주인님" : "") : c.userName
        let line = c.ko ? "안녕하세요, \(who). \(name.isEmpty ? c.displayName : name)입니다. 이 목소리로 읽어 드릴게요."
                        : "Hello\(who.isEmpty ? "" : ", " + who). I'm \(name.isEmpty ? c.displayName : name), and this is how I'll sound."
        previewMouth?.stop()
        let m = Mouth(cfg: c); previewMouth = m; previewing = true
        NotificationCenter.default.post(name: Notification.Name("MacButlerPreview"), object: true)     // not a command
        m.speak(line) { [weak self] in DispatchQueue.main.async {
            self?.previewing = false
            NotificationCenter.default.post(name: Notification.Name("MacButlerPreview"), object: false)
        } }
    }
    var changed = false                 // name/호칭 changed or the voice check ran → restart when setup closes
    private func save(_ key: String, _ value: String, was: String) {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard v != was.trimmingCharacters(in: .whitespaces), key == "userName" || key == "sayVoice" || !v.isEmpty else { return }
        Config.set(key, v); changed = true
    }
    private var timer: Timer?
    static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin")!
    static let modelSHA = "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1"

    init(cfg: Config) {
        self.cfg = cfg
        name = cfg.displayName; userName = cfg.userName; brainChoice = cfg.brainProvider; voiceChoice = cfg.sayVoice; position = cfg.hudPosition
        super.init()
        voiceCheck.onDone = { [weak self] in self?.changed = true }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    deinit { timer?.invalidate() }
    var allRequired: Bool { mic && speech && ax && brain != nil }

    func refresh() {
        mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speech = SFSpeechRecognizer.authorizationStatus() == .authorized
        ax = AXIsProcessTrusted()
        screen = CGPreflightScreenCaptureAccess()
        brain = Brains.ready(Config.load())
        whisperBin = cfg.whisperBinary != nil
        model = FileManager.default.fileExists(atPath: cfg.whisperModelPath)
        let v = Mouth.bestVoice(locale: cfg.locale, chosen: cfg.sayVoice)
        voice = cfg.tts == "elevenlabs" ? "ElevenLabs" : (v.map { $0.name + ($0.quality == .premium ? " · Premium" : $0.quality == .enhanced ? " · Enhanced" : "") } ?? "—")
        naturalVoice = cfg.tts == "elevenlabs" || (v?.quality ?? .default) != .default
    }
    func openPane(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane)!)
    }

    func download() {
        downloadError = ""; progress = 0
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        s.downloadTask(with: SetupModel.modelURL).resume()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        progress = t > 0 ? Double(w) / Double(t) : 0
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Verify before keeping it — a tampered model could transcribe whatever an attacker wants.
        guard let h = try? FileHandle(forReadingFrom: location) else { downloadError = "read failed"; progress = -1; return }
        var sha = SHA256()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        try? h.close()
        let hex = sha.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == SetupModel.modelSHA else { downloadError = "checksum mismatch — discarded"; progress = -1; return }
        let dest = URL(fileURLWithPath: cfg.whisperModelPath)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: location, to: dest); log("whisper model downloaded and verified") }
        catch { downloadError = error.localizedDescription }
        progress = -1; refresh()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { downloadError = error.localizedDescription; progress = -1 }
    }
}

struct SetupView: View {
    @ObservedObject var m: SetupModel
    let S: Strings
    var onDone: () -> Void

    @ViewBuilder func row(_ ok: Bool, _ title: String, _ why: String, required: Bool = true, @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : (required ? "xmark.circle.fill" : "minus.circle"))
                .foregroundStyle(ok ? .green : (required ? .red : .secondary)).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !ok { action() }
        }.padding(.vertical, 4)
    }

    /// A row that always shows its controls (a choice with a sensible default), under the text.
    @ViewBuilder func pickRow(_ ok: Bool, _ title: String, _ why: String, @ViewBuilder controls: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red).font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                HStack(spacing: 8) { controls() }
                Text(why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }.padding(.vertical, 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(S.t("사사리사 준비", "Set up Sasarisa")).font(.largeTitle.bold())
            Text(S.t("빨간 것만 해결하면 됩니다. 소리는 맥 밖으로 나가지 않아요.", "Fix anything red. Your audio never leaves this Mac."))
                .foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(S.t("비서 이름 정하기", "Name your assistant")).font(.headline)
                    HStack {
                        Text(S.t("부르는 이름", "Its name")).frame(width: 110, alignment: .leading)
                        TextField(S.t("예: 사사리사", "e.g. Sasarisa"), text: $m.name).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text(S.t("나를 부르는 호칭", "What it calls you")).frame(width: 110, alignment: .leading)
                        TextField(S.t("예: 대표님 (선택)", "e.g. Tony (optional)"), text: $m.userName).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text(S.t("화면 위치", "Where it shows")).frame(width: 110, alignment: .leading)
                        Picker("", selection: $m.position) { ForEach(HUD.positions(S), id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden()
                        Button(S.t("다시 보기", "Show me")) { NotificationCenter.default.post(name: Notification.Name("MacButlerHUDDemo"), object: nil) }
                    }
                    NameTrainingRow(t: m.voiceCheck, name: m.name, S: S, enabled: m.mic && m.speech)
                }.padding(6)
            }
            GroupBox {
                VStack(alignment: .leading) {
                    row(m.mic, S.t("마이크", "Microphone"), S.t("부르는 말을 듣기 위해", "To hear the wake word")) {
                        Button(S.t("허용", "Allow")) { AVCaptureDevice.requestAccess(for: .audio) { _ in }; m.openPane("Privacy_Microphone") }
                    }
                    row(m.speech, S.t("음성 인식", "Speech Recognition"), S.t("맥 안에서 말을 글자로", "On-device speech to text")) {
                        Button(S.t("허용", "Allow")) { SFSpeechRecognizer.requestAuthorization { _ in }; m.openPane("Privacy_SpeechRecognition") }
                    }
                    row(m.ax, S.t("손쉬운 사용", "Accessibility"), S.t("글자 입력·버튼 누르기 (마우스는 안 움직임)", "Typing and pressing buttons (the mouse never moves)")) {
                        Button(S.t("설정 열기", "Open Settings")) { m.openPane("Privacy_Accessibility") }
                    }
                    row(m.screen, S.t("화면 기록 (선택)", "Screen Recording (optional)"), S.t("「화면에 뭐 있어?」에 답하려면", "Only for “what's on my screen?”"), required: false) {
                        Button(S.t("설정 열기", "Open Settings")) {
                            // Asking alone didn't put Sasarisa in the list (10/25) — reading the screen once does, and shows the prompt
                            CGRequestScreenCaptureAccess()
                            Task { _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
                            m.openPane("Privacy_ScreenCapture")
                        }
                    }
                }
            }
            GroupBox {
                VStack(alignment: .leading) {
                    pickRow(m.brain != nil, S.t("두뇌 (생각하는 AI)", "Brain (the AI that thinks)"),
                            m.brain.map { S.t("지금: \($0). 기본은 Claude Code예요 — 쓰시는 AI로 골라도 돼요.", "Now: \($0). Claude Code by default — pick the AI you use.") }
                            ?? S.t("고른 AI가 아직 이 맥에 없어요. 클로드 코드나 코덱스를 깔고 터미널에서 `claude` 또는 `codex` 를 한 번 실행해 로그인하세요.",
                                   "The AI you picked isn't on this Mac yet. Install Claude Code or Codex and run `claude` or `codex` once in Terminal.")) {
                        Picker("", selection: $m.brainChoice) { ForEach(m.brainOptions, id: \.id) { Text($0.label).tag($0.id) } }.labelsHidden().frame(width: 300)
                        Button(S.t("API 키로…", "API key…")) { SettingsWindow.show(cfg: Config.load()) }
                    }
                    row(m.whisperBin, "whisper.cpp", S.t("정확한 받아쓰기 엔진: 터미널에서 `brew install whisper-cpp`", "Accurate transcription engine: `brew install whisper-cpp` in Terminal"), required: false) {
                        Button(S.t("명령 복사", "Copy command")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("brew install whisper-cpp cliclick", forType: .string) }
                    }
                    pickRow(true, S.t("목소리", "Voice"),
                            m.cfg.tts != "say" ? S.t("지금은 설정에서 고른 목소리(\(m.cfg.tts))를 써요.", "Using the voice picked in Settings (\(m.cfg.tts)).")
                            : S.t("맥 기본 목소리로 바로 돼요. 더 사람 같은 목소리는 시스템 설정 → 손쉬운 사용 → 읽기 및 말하기 → 목소리 관리…에서 「Premium」을 받으면 여기 나와요.",
                                  "Mac voices work as is. Download a “Premium” one in System Settings → Accessibility → Spoken Content → Manage Voices… and it shows up here.")) {
                        if m.cfg.tts == "say" {
                            Picker("", selection: $m.voiceChoice) {
                                Text(S.t("자동 — 가장 자연스러운 목소리", "Auto — the most natural voice")).tag("")
                                ForEach(m.voiceOptions, id: \.id) { Text($0.label).tag($0.id) }
                            }.labelsHidden().frame(width: 300)
                        }
                        Button(m.previewing ? S.t("말하는 중…", "Speaking…") : S.t("미리 듣기", "Preview")) { m.previewVoice() }.disabled(m.previewing)
                    }
                    row(m.model, S.t("Whisper 모델 (874 MB)", "Whisper model (874 MB)"), m.downloadError.isEmpty ? S.t("없으면 맥 기본 인식만 씁니다(덜 정확).", "Without it, Apple's live recognition is used (less accurate).") : "⚠︎ " + m.downloadError, required: false) {
                        if m.progress >= 0 { ProgressView(value: m.progress).frame(width: 140) }
                        else { Button(S.t("받기", "Download")) { m.download() } }
                    }
                }
            }
            HStack {
                Text(S.t("다 되면 「\(m.name.isEmpty ? m.cfg.displayName : m.name)」라고 불러 보세요 — 또는 오른쪽 ⌥ 를 누른 채 말하기.", "Then say “\((m.name.isEmpty ? m.cfg.displayName : m.name).capitalized)” — or hold right ⌥ and talk."))
                    .font(.callout)
                Spacer()
                Button(m.allRequired ? S.t("시작", "Start") : S.t("나중에", "Later")) { onDone() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}

enum SetupWindow {
    static var window: NSWindow?
    /// The setup window drawn off screen into a PNG (README picture, `--setup-shot`).
    static func shot(_ path: String) {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let cfg = Config.load(), S = Strings(ko: cfg.ko, name: cfg.displayName)
        let host = NSHostingController(rootView: SetupView(m: SetupModel(cfg: cfg), S: S) {})
        let w = NSWindow(contentViewController: host)
        let size = host.view.fittingSize
        w.setFrame(NSRect(x: -4000, y: 0, width: max(size.width, 560), height: max(size.height, 500)), display: true)
        w.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let v = host.view
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    static var flag: URL { Paths.home.appendingPathComponent(".setup-shown") }
    /// Shown on first launch, or whenever something required is missing.
    static func showIfNeeded(cfg: Config) {
        let m = SetupModel(cfg: cfg)
        if !FileManager.default.fileExists(atPath: flag.path) || !m.allRequired { show(cfg: cfg) }
    }
    static func show(cfg: Config) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let S = Strings(ko: cfg.ko, name: cfg.displayName)
        let model = SetupModel(cfg: cfg)
        let view = SetupView(m: model, S: S) {
            FileManager.default.createFile(atPath: flag.path, contents: Data())
            if model.voiceCheck.training { model.voiceCheck.stop() }
            window?.close()
            if model.changed { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { SettingsWindow.relaunch() } }      // the new name / learned voice take effect
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Sasarisa"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
