// UI and spoken phrases for each language.
import Foundation

struct Strings {
    let ko: Bool
    var name = "Sasarisa"
    func t(_ k: String, _ e: String) -> String { ko ? k : e }

    var listening: String { t("● 듣는 중", "● Listening") }
    var conversing: String { t("● 대화 중 · 「됐어」 하면 끝", "● Listening · say “that's all” to stop") }
    var speakNow: String { t("말씀하세요", "Go ahead") }
    var transcribing: String { t("◌ 받아 적는 중", "◌ Transcribing") }
    var thinking: String { t("◌ 생각 중", "◌ Thinking") }
    var working: String { t("◌ 실행 중", "◌ Working") }
    var dictation: String { t("✎ 받아쓰기 · 「그만」하면 끝", "✎ Dictation · say “stop” to end") }
    var speaking: String { "◉ " + name.uppercased() }
    var dictationStart: String { t("받아쓰겠습니다. 끝나면 그만이라고 해 주세요.", "Dictation on. Say stop when you're done.") }
    var micError: String { t("마이크를 열 수 없습니다", "Can't open the microphone") }
    var noClaude: String { t("쓸 AI를 찾지 못했습니다. 클로드 코드나 코덱스에 로그인하거나, 설정 → 두뇌에서 골라 주세요.", "No AI is ready. Log in to Claude Code or Codex, or pick a brain in Settings.") }
    var failed: String { t("잘 안 됐습니다. 다시 말씀해 주세요.", "That didn't work. Please try again.") }
    var stopped: String { t("멈췄습니다.", "Stopped.") }
    var typed: String { t("입력", "Typed") }
    var key: String { t("키", "Key") }
    var opened: String { t("열기", "Opened") }
    var searched: String { t("검색", "Search") }
    var youtube: String { t("유튜브", "YouTube") }
    var youtubePlay: String { t("유튜브 재생", "Playing on YouTube") }
    var youtubeFind: String { t("◌ 유튜브에서 찾는 중", "◌ Searching YouTube") }
    var claudeOpen: String { t("◌ 클로드 창 여는 중", "◌ Opening Claude") }
    var claudeNew: String { t("◌ 새 세션 여는 중", "◌ Opening a new session") }
    var claudeFindSession: String { t("◌ 세션 찾는 중", "◌ Finding the session") }
    var claudeTyping: String { t("◌ 클로드에게 입력 중", "◌ Typing to Claude") }
    var claudeSent: String { t("클로드에게 보냄", "Sent to Claude") }
    var claudeDelegated: String { t("새 세션에 맡김", "Handed to a new session") }
    var claudeNotRunning: String { t("클로드 앱이 안 켜져 있습니다.", "The Claude app isn't running.") }
    var claudeNoWindow: String { t("클로드 창을 못 찾았습니다.", "Couldn't find a Claude window.") }
    var claudeNoInput: String { t("클로드 입력칸을 못 찾았습니다.", "Couldn't find Claude's input box.") }
    func menuToggle() -> String { t("듣기 켜기/끄기", "Listening on/off") }
    func menuGreet() -> String { t("깨우기 장면 보기", "Play wake-up scene") }
    func menuFolder() -> String { t("설정 폴더 열기", "Open settings folder") }
    func menuQuit() -> String { t("종료", "Quit") }
    var permMic: String { t("마이크", "Microphone") }
    var permSpeech: String { t("음성 인식", "Speech Recognition") }
    var permAX: String { t("손쉬운 사용 (키 입력·버튼 누르기)", "Accessibility (typing, pressing)") }
    var permScreen: String { t("화면 기록 (화면 보기)", "Screen Recording (seeing the screen)") }
    var depClaude: String { t("Claude Code (두뇌)", "Claude Code (brain)") }
    var depWhisper: String { t("Whisper 모델 (정확한 받아쓰기)", "Whisper model (accurate text)") }
    var menuStatus: String { t("상태 점검", "Status") }
    func hotkeyHint(_ k: String) -> String { t("단축키: \(k) 톡 = 부르기 · 누르고 말하기 = 바로 실행", "Hotkey: tap \(k) = wake · hold & talk = run on release") }

    var toolNames: [String: String] {
        ko ? ["Read": "화면·파일 살펴보는 중", "Bash": "맥 조작 중", "WebSearch": "인터넷 검색 중", "WebFetch": "페이지 읽는 중", "Glob": "파일 찾는 중", "Grep": "내용 찾는 중"]
           : ["Read": "Looking", "Bash": "Operating the Mac", "WebSearch": "Searching the web", "WebFetch": "Reading a page", "Glob": "Finding files", "Grep": "Searching files"]
    }
    var bootLines: [String] {
        ko ? ["> 음성 인식 모듈 ············ ONLINE", "> WHISPER ··················· READY", "> CLAUDE 링크 ················ ONLINE", "> 화면 · 키보드 제어 ·········· GRANTED"]
           : ["> SPEECH RECOGNITION ········· ONLINE", "> WHISPER ···················· READY", "> CLAUDE LINK ················ ONLINE", "> SCREEN · KEYBOARD CONTROL ··· GRANTED"]
    }
    var bootMemory: String { t("> 메모리 %.1f / %.0f GB ········· OK", "> MEMORY %.1f / %.0f GB ········ OK") }
    var bootDisk: String { t("> 디스크 여유 %.0f GB ··········· OK", "> DISK FREE %.0f GB ············ OK") }
    var bootAllGood: String { t("> 모든 시스템 정상", "> ALL SYSTEMS GO") }
}
