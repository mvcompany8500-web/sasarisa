// Turns a spoken sentence into an intent. Pure functions — covered by `MacButler --selftest`.
// Anything that isn't matched here goes to Claude.
import Foundation

enum Intent: Equatable {
    case greet, dictation, bye, hush, enter
    case type(String)
    case claude(target: String, message: String, newSession: Bool)
    case youtube(String)          // "" = YouTube home
    case youtubeNth(Int)
    case seek(Int)                // 「빨리 감기」「30초 되감기」 — seconds, + forward / − back (YouTube's l / j)
    case mailNth(Int)             // 「네 번째 메일 열어」 — the nth mail in the web mail list in front
    case search(String)
    case web(label: String, query: String, url: String)   // shopping / site search
    case remember(String)                                   // 「기억해: …」 — a long-term note
    case media(play: Bool)                                  // pause / resume whatever video or music is playing
    case closeTabs(label: String, host: String)             // 「유튜브 창 꺼」 — close those browser tabs
    case mediaNext                                          // 「다음 영상」 — skip to the next video / track
    case displayOff                                         // 「화면 꺼」 — turn the display off (sleep)
    case closeOpened                                        // 「창 다 꺼」 — close what it opened for you (pages, apps)
    case browser(String)                                    // 「뒤로 가」「앞으로」「새로고침」 in the browser in front: back / forward / reload
    case volume(set: Int?, delta: Int, mute: Bool)          // 「소리 키워」「볼륨 30」「음소거」
    case clock(date: Bool)                                  // 「몇 시야」「오늘 며칠이야」 — answered on the Mac, no Claude
    case timer(seconds: Int, label: String)                 // 「라면 3분」「10분 뒤에 알려 줘」「5시에 회의 알려 줘」
    case cancelTimers                                       // 「타이머 취소」
    case map(String)                                        // 「강남역 가는 길」 → Naver Map
    case multi([String])                                    // 「로파이 틀고 소리 줄이고 화면 꺼」 — each part is a quick command
    case routine(String)                                    // a routine's name was said → run its steps
    case rewrite(String)                                    // 「이거 존댓말로 바꿔」 — rewrite the selected text (style)
    case undo                                               // 「방금 거 취소」「되돌려」「원래대로」 — undo the last quick action
    case whatDid                                            // 「방금 뭐 했어?」
    case makeRoutine(name: String, steps: [String])         // 「앞으로 '작업 시작' 하면 A하고 B해」 (steps = quick commands only)
    case badRoutine(String)                                 // tried to put something that isn't a quick command in a routine
    case forgetRoutine(String)                              // 「작업 시작 루틴 지워」
    case openApp(spoken: String, app: String)
    case kakaoReply(to: String, text: String)               // 「카톡 영웅님한테 아 힘들다라고 답장해」 — typed into that chat, sent after a yes
    case kakaoType(to: String, text: String)                // 「카톡 창에 오늘도 힘드네요라고 입력해」 — typed into that chat, not sent
    case none
}

struct Parser {
    let cfg: Config

    static let defaultApps: [String: String] = [
        "크롬": "Google Chrome", "구글 크롬": "Google Chrome", "사파리": "Safari", "메모": "Notes", "메모장": "Notes",
        "카톡": "KakaoTalk", "카카오톡": "KakaoTalk", "클로드": "Claude", "터미널": "Terminal", "파인더": "Finder",
        "캘린더": "Calendar", "달력": "Calendar", "메일": "Mail", "음악": "Music", "사진": "Photos", "설정": "System Settings",
        "텔레그램": "Telegram", "슬랙": "Slack", "텍스트 편집기": "TextEdit", "계산기": "Calculator",
        "chrome": "Google Chrome", "safari": "Safari", "notes": "Notes", "terminal": "Terminal", "finder": "Finder",
        "calendar": "Calendar", "mail": "Mail", "music": "Music", "photos": "Photos", "settings": "System Settings",
        "slack": "Slack", "telegram": "Telegram", "calculator": "Calculator", "claude": "Claude", "textedit": "TextEdit"]
    var apps: [String: String] { Parser.defaultApps.merging(cfg.apps) { _, new in new } }
    func app(_ spoken: String) -> String? {
        let k = spoken.trimmingCharacters(in: .whitespaces)
        return apps[k] ?? apps[k.lowercased()]
    }

    // MARK: helpers

    static func match(_ s: String, _ pat: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }
    /// 「카톡 떠 있는 거 영웅님한테 아 힘들다라고 답장해」 → ("영웅", "아 힘들다"); 「카톡에 알겠어라고 보내」 → ("", "알겠어").
    /// Done by Sasarisa itself (10/25: the brain fumbled it — the list timed out and it pressed Enter before typing).
    static func kakaoReply(_ s: String) -> (String, String, Bool)? {
        guard let k = s.range(of: "카(?:카오)?톡", options: .regularExpression) else { return nil }
        let rest = String(s[k.upperBound...])
        guard let m = match(rest, "^\\s*(?:지금\\s*)?(?:(?:떠|켜져|열려)\\s*있는\\s*|열린\\s*|켜진\\s*)?(?:거|것|창|방|곳|데|대화방|채팅방)?\\s*(?:에다가|에다|에서|으로|에)?\\s*,?\\s*(?:(\\S+?)\\s*(?:님)?\\s*(?:한테|에게|께)\\s+)?(.+?)\\s*(?:이?라고|하고)\\s*(답장|답|보내|전송|전해|말해|입력|써|쳐|적어)") else { return nil }
        // 「카톡창 열려있잖아. 거기에다가 오늘도 힘내세요라고」 — only the words after 「거기에다가」 are the message (10/25)
        let text = m[2].replacingOccurrences(of: "^(?:(?:열려|켜져|떠)\\s*있(?:잖아|어|는데|지|네)[.,!]?\\s*)?(?:(?:거기|여기|그\\s*창|이\\s*창|그곳|이곳|그\\s*방|이\\s*방)\\s*(?:에다가|에다|에)\\s+)?", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var name = m[1].trimmingCharacters(in: .whitespaces)
        if name.hasSuffix("님") { name.removeLast() }
        // 「입력해·써」 = put it in, don't send (10/25) — unless 「입력해서 엔터까지 쳐」「입력하고 보내」 says to send it too
        let after = rest.range(of: "(?:이?라고|하고)\\s*(?:답장|답|보내|전송|전해|말해|입력|써|쳐|적어)", options: .regularExpression).map { String(rest[$0.upperBound...]) } ?? ""
        let sendToo = after.range(of: "엔터|보내|전송|send", options: .regularExpression) != nil
        return (name, text, sendToo || !["입력", "써", "쳐", "적어"].contains(m[3]))
    }
    static func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
    static func clean(_ s: String) -> String {
        var x = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for p in ["야 ", "야,", "님 "] where x.hasPrefix(p) { x = String(x.dropFirst(p.count)) }
        return x.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    // MARK: wake word / greeting

    /// How Whisper / Apple often mishear the wake word: "재비스", "하이 자비스".
    var wakeVariants: [String] {
        var out = cfg.wakes
        for w in cfg.wakes {
            if w.contains("자비스") { out.append(w.replacingOccurrences(of: "자비스", with: "재비스")) }
            if w.hasPrefix("헤이 ") { out.append("하이 " + w.dropFirst(3)) }
        }
        out += cfg.wakes.filter { $0.hasPrefix("헤이 ") && $0.contains("자비스") }.map { "하이 " + $0.dropFirst(3).replacingOccurrences(of: "자비스", with: "재비스") }
        return out.sorted { $0.count > $1.count }          // longest first: "헤이 자비스" before "자비스"
    }
    /// The assistant's name as Korean speech recognition tends to write it (see `Config.soundAlike`).
    var nameSoundsLike: String? { cfg.ko ? (Config.hangulReading(cfg.assistantName) ?? (cfg.assistantName.unicodeScalars.allSatisfy { $0.value >= 0xAC00 && $0.value < 0xD7A4 } ? cfg.assistantName : nil)).flatMap(Config.soundAlike) : nil }
    /// The name followed by 「.com / 닷컴」 is a web address, not a call (10/25: 「싸싸리싸.com 들어가」 lost the name and opened Chrome).
    static let notAddress = "(?!\\s*(?:(?:\\.|닷)\\s*(?:com|컴|net|넷|kr|co\\b)|버프|buff))"   // 「거북이 버프입니다」 — the channel name, not a call (10/25)
    func wakeRange(_ t: String) -> Range<String.Index>? {
        if let p = nameSoundsLike, let r = t.range(of: "(헤이|하이|hey)?\\s*" + p + "[~∼〜]*" + Parser.notAddress, options: [.regularExpression, .caseInsensitive]) { return r }
        for w in wakeVariants {
            let pat = w.replacingOccurrences(of: " ", with: "").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s*") + Parser.notAddress
            if let r = t.range(of: pat, options: [.regularExpression, .caseInsensitive]) { return r }
        }
        return nil
    }
    /// Our own site said aloud — 「싸싸리싸.com」「사사리사 닷컴」 — written as the address the brain can open.
    static func ourAddress(_ t: String) -> String {
        guard let p = Config.soundAlike("사사리사") else { return t }
        return t.replacingOccurrences(of: p + "\\s*(?:\\.|닷)\\s*(?:com|컴)", with: "sasarisa.com", options: [.regularExpression, .caseInsensitive])
    }
    /// Removes a leading wake word ("자비스, …", "hey jarvis …", "자비스, 자비스, …").
    func stripWake(_ t: String) -> String {
        var t = t
        for _ in 0..<3 {
            guard let r = wakeRange(t), t.distance(from: t.startIndex, to: r.lowerBound) < 8 else { break }
            var rest = String(t[r.upperBound...])
            if rest.hasPrefix("야") { rest.removeFirst() }
            t = Parser.clean(rest)
        }
        return Parser.clean(t)
    }
    func isGreeting(_ t: String) -> Bool {
        let s = Parser.squash(t)
        return cfg.greets.contains { s.contains(Parser.squash($0)) }
    }

    // MARK: short commands that don't need Whisper

    private var byeWords: Set<String> {
        ["됐어", "그만", "고마워", "끝", "됐다", "잘자", "쉬어", "수고했어", "꺼져",
         "땡큐", "땡큐허니", "피니쉬", "finish", "thatsall", "thanks", "thankyou", "goodnight", "nevermind", "gotosleep", "stoplistening"]
    }
    private var hushWords: Set<String> {
        ["시끄러", "시끄러워", "조용", "조용히", "조용히해", "멈춰", "스톱", "그만해", "잠깐", "잠깐만", "쉿",
         "stop", "quiet", "shutup", "wait", "holdon", "hush"]
    }
    private var enterWords: Set<String> { ["엔터", "엔터쳐", "보내", "전송", "enter", "pressenter", "send"] }

    func isBye(_ c: String) -> Bool {
        let s = Parser.squash(c)
        if byeWords.contains(s) { return true }
        if s.count <= 6, ["됐어", "됐다"].contains(where: s.hasPrefix) { return true }
        // only "너 꺼", "자비스 꺼", "너 이제 꺼" — "다 꺼", "그래 꺼", "크롬 꺼" are actions for Claude
        if ["너꺼", "자비스꺼", "너이제꺼", "이제꺼져", "너꺼져", "자비스꺼져", "그만꺼"].contains(s) { return true }
        return false
    }
    func isHush(_ c: String) -> Bool {
        let s = Parser.squash(c)
        if hushWords.contains(s) { return true }
        // only with a short lead-in: "알았어 조용히 해", "야 멈춰", "okay stop" — but "영상 멈춰" is an action, not hush
        let leads = ["", "알았어", "알겠어", "야", "아니", "됐고", "그래", "오케이", "자비스", "ok", "okay", "hey"]
        for h in ["조용히해", "조용", "멈춰", "그만해", "시끄러워", "시끄러", "쉿", "stop", "quiet"] where s.hasSuffix(h) {
            if leads.contains(String(s.dropLast(h.count))) { return true }
        }
        return false
    }

    /// True when Apple's live text is good enough to act on right away.
    func instant(_ c: String) -> Bool {
        if isBye(c) || isHush(c) || enterWords.contains(Parser.squash(c)) { return true }
        if case .openApp = parse(c, hasYouTubeList: false) { return true }
        return false
    }

    // MARK: the grammar

    func parse(_ raw: String, hasYouTubeList: Bool) -> Intent {
        var s = Parser.clean(raw)
        let sq = Parser.squash(s)
        if s.isEmpty { return .none }
        // 「응 찾아봐」「그래 해 줘」「좋아 틀어 줘」 — an answer to something it just offered, not a search for 「응」 (the brain knows the offer)
        if let m = Parser.match(sq, "^(응|네|예|어|그래|좋아|오케이|ㅇㅇ|당연하지|부탁해|yes|yeah|sure|ok|okay)(.*)$"),
           m[2].count <= 6, ["", "찾아봐", "찾아줘", "찾아", "해줘", "해봐", "해", "그렇게해", "그렇게해줘", "틀어줘", "틀어", "보여줘", "알려줘", "열어줘", "부탁해", "please", "doit", "goahead"].contains(m[2]) { return .none }
        if Parser.isCancelTimers(s) { return .cancelTimers }
        if ["방금거취소", "방금거취소해", "방금건취소", "되돌려", "되돌려줘", "원래대로", "원래대로해", "원래대로돌려", "실행취소", "방금거되돌려", "undo", "undothat"].contains(sq.replacingOccurrences(of: "것", with: "거")) { return .undo }
        if ["방금뭐했어", "뭐했어", "방금뭐한거야", "방금뭐했니", "whatdidyoujustdo", "whatdidyoudo"].contains(sq) { return .whatDid }
        if Parser.cancelledAtEnd(s) { return .hush }     // “…, 아니 취소” / “…, never mind” — the speaker took it back
        if isGreeting(s) { return .greet }
        if ["받아써", "받아적어", "받아쓰기", "타이핑모드", "말하는대로써", "takedictation", "dictationmode", "startdictation"].contains(where: sq.contains) { return .dictation }
        if enterWords.contains(sq) { return .enter }
        if isHush(s) { return .hush }
        if isBye(s) { return .bye }
        s = Parser.dropLeadIn(s)
        // 「유튜브 창 다 끄고 카톡에 …라고 입력해」 — the command before 카톡 runs first (10/25: it was dropped and its words typed)
        if let k = s.range(of: "카(?:카오)?톡", options: .regularExpression), k.lowerBound != s.startIndex,
           Parser.kakaoReply(String(s[k.lowerBound...])) != nil,
           let lead = Parser.splitCommands(s[..<k.lowerBound].trimmingCharacters(in: .whitespaces) + " 카톡"), lead.count >= 2 {
            let before = Array(lead.dropLast())
            if before.allSatisfy({ parse($0, hasYouTubeList: hasYouTubeList) != .none }) { return .multi(before + [String(s[k.lowerBound...])]) }
        }
        if Parser.match(Parser.squash(s), "^카(?:카오)?톡(?:방|창)?(?:에서|에)?(?:전송|전속|보내기|엔터)(?:버튼)?(?:좀)?(?:눌러|클릭|쳐)") != nil { return .kakaoReply(to: "", text: "") }
        // Done here, not by the brain (10/25 filming: 10–15 s each through Codex)
        if let sk = Parser.seek(s) { return .seek(sk) }
        if let m = Parser.mailSite(s) { return .web(label: m.0, query: "", url: m.1) }
        if let m = Parser.match(s, "^(\\S+)\\s*번째\\s*(?:메일|이메일|편지)(?:을|를)?\\s*(?:좀\\s*)?(?:열어|클릭|눌러|들어가|봐|보여|확인)"), let n = Parser.ordinal(m[1]) { return .mailNth(n) }
        if let k = Parser.kakaoReply(s) { return k.2 ? .kakaoReply(to: k.0, text: k.1) : .kakaoType(to: k.0, text: k.1) }
        if let r = Routines.match(s) { return .routine(r) }
        if let st = Parser.rewriteStyle(s) { return .rewrite(st) }
        if let m = Parser.match(s, "^(.+?)\\s*루틴\\s*(지워|삭제|없애)"), let r = Routines.match(m[1]) { return .forgetRoutine(r) }
        // 「앞으로 작업 시작 하면 클로드 열고 로파이 틀어」「작업 시작이라고 하면 …」
        if let m = Parser.match(s, "^(?:앞으로\\s+|이제부터\\s+)?[\"'「]?(.+?)[\"'」]?\\s*(?:이?라고\\s*하면|라고\\s*말하면|하면은|하면)\\s*[,]?\\s*(.+)$"),
           s.hasPrefix("앞으로") || s.hasPrefix("이제부터") || ((s.contains("라고 하면") || s.contains("라고 말하면")) && !s.contains("?") && !s.contains("어떻게")) {
            let name = m[1].trimmingCharacters(in: .whitespaces)
            let steps = Parser.splitCommands(m[2]) ?? [m[2]]
            let ok = steps.allSatisfy { p in
                let i = parse(p, hasYouTubeList: false)
                switch i { case .none, .claude, .type, .dictation, .multi, .routine, .makeRoutine, .badRoutine, .forgetRoutine, .remember, .bye, .hush, .greet, .rewrite: return false
                           default: return true }
            }
            return ok && !name.isEmpty ? .makeRoutine(name: name, steps: steps) : .badRoutine(name)
        }
        // "쿠팡 말고 유튜브 터틀메이커 검색해봐" — the part after 말고 is what you want
        if let r = s.range(of: #"\s말고[,\s]+"#, options: .regularExpression), s[r.upperBound...].count >= 2 { s = String(s[r.upperBound...]) }
        if Parser.isCompound(s), !s.contains("클로드"), !s.lowercased().contains("claude") {
            // Every part a quick command → do them in order right away; otherwise Claude takes the whole sentence.
            if let parts = Parser.splitCommands(s), parts.count >= 2 {
                let kinds = parts.map { parse($0, hasYouTubeList: hasYouTubeList) }
                let quick = kinds.filter { i in if case .multi = i { return false }; if case .claude = i { return false }; return i != .none && i != .dictation }.count
                let mixedOK = !kinds.contains { i in if case .claude = i { return true }; if case .type = i { return true }; return i == .dictation }
                // all quick → do them in order · some quick, some needing thought → quick ones now, the rest to the brain after
                if quick == parts.count || (quick >= 1 && mixedOK) { return .multi(parts) }
            }
            return .none
        }
        if let c = Parser.closeTabs(s) { return .closeTabs(label: c.0, host: c.1) }
        if Parser.isCloseOpened(s) { return .closeOpened }
        if let b = Parser.browserNav(s) { return .browser(b) }
        if let v = Parser.volume(s) { return .volume(set: v.0, delta: v.1, mute: v.2) }
        if let d = Parser.clock(s) { return .clock(date: d) }
        if let t = Parser.timer(s) { return .timer(seconds: t.0, label: t.1) }
        if let place = Parser.mapPlace(s) { return .map(place) }
        if Parser.isDisplayOff(s) { return .displayOff }
        if Parser.isNext(s) { return .mediaNext }
        if Parser.closesVideo(s) { return .closeTabs(label: "유튜브", host: "youtube.com") }
        if let play = Parser.mediaControl(s) { return .media(play: play) }

        let tail = "\\s*(해 봐 줘|해봐줘|해 봐|해봐|해 줘|해줘|해 주세요|해|줘|좀|봐|봐 줘|봐줘|주세요)?$"
        // Korean: 「안녕하세요 라고 써 줘」
        if let m = Parser.match(s, "^(.+?)\\s*(이?라고)\\s*(써|쳐|입력해|타이핑해|적어)\\s*(줘|주세요)?$") {
            // 「지금 열려 있는 메모 창에 ○○라고 써 줘」: where to type isn't part of the text (10/25 it typed the whole sentence)
            let text = m[1].replacingOccurrences(of: "^(?:지금\\s*)?(?:(?:열려\\s*있는|떠\\s*있는|켜져\\s*있는|열린)\\s*)?(?:\\S+\\s*)?(?:창|칸|입력칸|채팅창|메모장|메모)\\s*에\\s*", with: "", options: .regularExpression)
            return .type(text.isEmpty ? m[1] : text)
        }
        // English: "type hello world"
        if let m = Parser.match(s, "^(type|write)\\s+(.+)$") { return .type(m[2]) }

        // 「클로드 (창 중에) 댓글 작업용 프로젝트에 ○○ 전달해」 — the window named after 클로드: same as 「댓글 작업용 프로젝트 클로드에 ○○」
        if let m = Parser.match(s, "^(클로드\\s*코드|클로드)\\s*(창|세션)?\\s*(중에서|중에)?\\s*(.+?)\\s*(프로젝트|창|세션)\\s*(에다가|에다|에게|한테|에)\\s*[,，]?\\s*(.+)$"),
           !["한테", "에게", "에", "에다", "에다가"].contains(m[4]) {
            s = m[4] + " 프로젝트 클로드에 " + m[7]
        }
        // 「클로드 음성 제어 Mac 설정에다가 버그 고치라고 해」 — a window name right after 클로드, without 「프로젝트」 (10/24 it went to the
        // brain and took 26 s). With plain 「에」 only when the sentence ends in an order, so 「클로드 3시에 …」 isn't read as a window.
        if let m = Parser.match(s, "^(클로드\\s*코드|클로드)\\s+(.{2,30}?)\\s*(에다가|에다|에게|한테|에)\\s+(.+)$"),
           !m[2].contains("클로드"), !m[2].hasPrefix("코드"), !["창", "세션", "프로젝트", "지금", "현재"].contains(m[2]), m[2].split(separator: " ").count <= 6,
           m[3] != "에" || Parser.match(m[4], "(하라고|해|해줘|해 줘|전달해|전해|시켜|보내|얘기해|말해)\\s*(줘|놔|둬|라)?$") != nil {
            s = m[2] + " 프로젝트 클로드에 " + m[4]
        }
        // Claude: 「(세션) 클로드한테 ○○ 라고 전달해」 → relay just that; 「클로드코드한테 ○○ 해서 보내」 → whole task.
        if let m = Parser.match(s, "^(.*?)\\s*(클로드\\s*코드|클로드)\\s*(한테|에게|창에다가|창에다|창에|에다가|에다|에|님|보고)\\s*[,，]?\\s*(.+)$") {
            var target = m[1]
            // "쿠팡 열고 클로드에 …" — another action before the hand-off → Claude (the brain) takes the whole sentence
            if target.split(separator: " ").contains(where: { ["열고", "틀고", "켜고", "끄고", "찾고", "하고", "멈추고", "닫고", "검색하고"].contains(String($0)) }) { return .none }
            let here = ["지금", "현재", "여기", "이 창", "열린", "켜진", "켜져 있는", "보고 있는", "떠 있는", "떠있는", "열려 있는"].contains { target.contains($0) } || (m[3].hasPrefix("창에") && target.isEmpty)
            for w in ["프로젝트", "세션", "창", "에 있는", "떠 있는", "떠있는", "열려 있는", "있는", "지금", "켜져 있는", "켜진", "열린", "현재", "여기", "보고"] { target = target.replacingOccurrences(of: w, with: "") }
            target = target.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            // "켜져있는 클로드에게" — what's left is only a "the open one" word → the current window
            let openWords = ["켜져", "켜져있는", "떠", "떠있는", "열려", "열려있는", "켜진", "열린", "지금", "현재", "여기", "이"]
            let isHere = here || openWords.contains(Parser.squash(target))
            if openWords.contains(Parser.squash(target)) { target = "" }
            var rest = m[4]
            for p in ["다가 ", "다 "] where rest.hasPrefix(p) { rest = String(rest.dropFirst(p.count)) }
            let delivery: Set<String> = ["전달해", "전달해놔", "전달해줘", "전달해둬", "전해", "전해줘", "전해놔", "보내", "보내줘", "넣어", "넣어놔", "넣어줘", "얘기해", "얘기해줘", "말해", "말해줘", "알려줘", "알려"]
            if delivery.contains(Parser.squash(rest)), !m[1].isEmpty, !here {
                return .claude(target: "", message: m[1].trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)), newSession: false)
            }
            // "클로드한테 얘기해. <내용>" — the verb came first, the content after it
            for p in ["얘기해서", "말해서", "시켜서", "얘기해", "말해", "전해", "전달해", "시켜", "물어봐"] where rest.hasPrefix(p) {
                let after = String(rest.dropFirst(p.count)).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
                if after.count >= 2 { rest = after }
            }
            for p in ["시켜서 ", "시켜 ", "얘기해서 ", "말해서 "] where rest.hasPrefix(p) { rest = String(rest.dropFirst(p.count)) }
            if let q = Parser.match(rest, "^(.+?)\\s*(이?라고)\\s*(전달|보내|말|입력|써|적어|넣어|해|얘기)" + tail) {
                // 「테스트라고 전달해」 quotes a word; 「버그 고치라고 해」 is an order — keep the whole order.
                let verbStem = "하치기리지가보내주우추르꾸들켜꺼써봐줘라".contains(q[1].last ?? " ")
                return .claude(target: target, message: verbStem ? rest : q[1], newSession: target.isEmpty && !isHere)
            }
            return .claude(target: target, message: rest, newSession: target.isEmpty && !isHere)
        }
        if let m = Parser.match(s, "^(ask|tell|have)\\s+claude(\\s+code)?\\s+(to\\s+)?(.+)$") {
            return .claude(target: "", message: m[4], newSession: m[1].lowercased() != "tell")
        }

        // YouTube: play the first result right away
        if let m = Parser.match(s, "^(유튜브|youtube)\\s*(에다가(?=\\s)|에다(?=\\s)|에서(?=\\s)|로(?=\\s)|에(?=\\s))?\\s*(.*?)\\s*(?:검색해서|검색해 가지고|찾아서)?\\s*(틀어|재생\\s*시켜|재생해|재생|켜|보여|찾아|검색|열어)" + tail) {
            let filler: Set<String> = ["아무거나", "영상", "하나", "동영상", "거", "좀", "한", "개", "아무", "창", "화면", "페이지", "사이트", "홈", "앱", "참"]   // 참 = 창 misheard
            let q = m[3].split(separator: " ").map(String.init).filter { !filler.contains($0) }.joined(separator: " ")
            if Parser.alsoStops(q) { return .none }          // 「지금 음악 끄고 베토벤 틀어」 → two steps, the router splits them
            return .youtube(Parser.isOther(q) ? "추천" : q)
        }
        if let m = Parser.match(s, "^play\\s+(.+?)\\s+on\\s+youtube$") ?? Parser.match(s, "^youtube\\s+([^가-힣]+)$") { return .youtube(m[1]) }
        if hasYouTubeList {
            if let m = Parser.match(s, "^(.+?)\\s*(번째|번)\\s*(거|것|영상|꺼|걸로)?\\s*(틀어|켜|재생|열어|보여|눌러|클릭|찍어|들어가)" + tail), let n = Parser.ordinal(m[1]) { return .youtubeNth(n) }
            if let m = Parser.match(s, "^play\\s+(the\\s+)?(number\\s+)?(\\w+)(\\s+one)?$"), let n = Parser.ordinal(m[3]) { return .youtubeNth(n) }
        }

        // 「로파이 틀어」「아이유 노래 틀어 줘」 — playing something with no site named means YouTube
        if Parser.isCompound(s) { return .none }
        if let m = Parser.match(s, "^(.+?)\\s*(?:검색해서|찾아서)?\\s*(틀어|재생해|재생 해|틀어 봐|틀어봐)" + tail), app(m[1]) == nil,
           Parser.match(m[1], "(번째|번)\\s*(거|것|영상|꺼)?$") == nil,
           !["영상", "다시", "이어서", "계속", "음악", "노래"].contains(m[1].trimmingCharacters(in: .whitespaces)) {
            if Parser.alsoStops(m[1]) { return .none }
            let words = m[1].split(separator: " ").map(String.init).filter { !["하나", "좀", "한번", "한 번", "아무거나"].contains($0) }
                .map { ["음악도", "노래도", "영상도", "곡도"].contains($0) ? String($0.dropLast()) : $0 }
            let q = words.joined(separator: " ")
            return .youtube(Parser.isOther(q) ? "추천" : (q.isEmpty ? m[1] : q))
        }
        // Two things in one breath ("영상 멈추고 쿠팡에서 …", "X 하고 Y") → Claude does them in order.
        if let m = Parser.match(s, "^(기억해|기억해 둬|기억해둬|메모해|remember(?: that)?)\\s*[:,]?\\s*(.+)$") { return .remember(m[2]) }
        if let m = Parser.match(s, "^(.+?)\\s*(이?라고|라는 거|라는 걸)?\\s*(기억해 둬|기억해둬|기억해)$"), m[1].count >= 2 { return .remember(m[1]) }
        if Parser.isCompound(s) { return .none }

        // Shopping & site search — the site can be named anywhere: "쿠팡 홈페이지에 들어가서 맥미니 가격",
        // "쿠팡 들어가서 이어폰 찾아 줘", "네이버 쇼핑에서 …", "쿠팡 열어" (home page).
        let sites: [(String, String, String, String)] = [
            ("쿠팡", "쿠팡", "https://www.coupang.com/np/search?q=", "https://www.coupang.com/"),
            ("네이버\\s*쇼핑", "네이버 쇼핑", "https://search.shopping.naver.com/search/all?query=", "https://shopping.naver.com/"),
            ("네이버", "네이버", "https://search.naver.com/search.naver?query=", "https://www.naver.com/"),
            ("구글", "Google", "https://www.google.com/search?q=", "https://www.google.com/"),
            ("아마존|amazon", "Amazon", "https://www.amazon.com/s?k=", "https://www.amazon.com/")]
        for (pat, label, url, home) in sites {
            // "쿠팡에/쿠팡의/쿠팡이 …" — a particle only when glued to the name ("쿠팡 에어팟" keeps 에어팟)
            guard let m = Parser.match(s, "^(" + pat + ")(?:(?:에다가|에다|에서|에|의|이|가|은|는|으로|로)(?=\\s|$))?\\s*(.*)$") else { continue }
            var q = m[2]
            // drop "홈페이지에 들어가서", "사이트에서", "에서", "가서", "접속해서" …
            for lead in ["홈페이지에 들어가서", "홈페이지 들어가서", "홈페이지에서", "홈페이지에", "사이트에 들어가서", "사이트에서", "앱에서",
                         "에 들어가서", "들어가서", "에 가서", "가서", "접속해서", "띄워서", "열어서", "켜서", "열면", "켜면", "들어가 가지고"] {
                if q.hasPrefix(lead) { q = String(q.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces) }
            }
            q = Parser.stripAsk(q)
            if Parser.siteAction(q) || Parser.carriesOtherJob(q) { return .none }     // 「네이버 로그아웃 해」「네이버 메일 확인해」 → the brain does it on the page
            if q.isEmpty || ["열어", "켜", "들어가", "가", "접속해", "띄워"].contains(where: { q == $0 }) { return .web(label: label, query: "", url: home) }
            return .web(label: label, query: q, url: url)
        }
        if let m = Parser.match(s, "^(.+?)\\s*(최저가|가격 비교)\\s*(찾아|검색|보여|알아봐)?" + tail) { return .web(label: "네이버 쇼핑", query: m[1], url: "https://search.shopping.naver.com/search/all?query=") }
        if let m = Parser.match(s, "^(shop for|buy|find)\\s+(.+?)\\s+on\\s+amazon$") { return .web(label: "Amazon", query: m[2], url: "https://www.amazon.com/s?k=") }

        // Web search
        if let m = Parser.match(s, "^(.+?)\\s*(검색|찾아 ?봐|찾아)" + tail), !m[1].contains("클로드"), m[1].split(separator: " ").count <= 6 { return .search(m[1]) }
        if let m = Parser.match(s, "^(search( for)?|google|look up)\\s+(.+)$") { return .search(m[3]) }

        // Open an app
        if let m = Parser.match(s, "^(.+?)\\s*(좀\\s*)?(열어|켜|띄워|실행)" + tail), let a = app(m[1]) { return .openApp(spoken: m[1], app: a) }
        if let m = Parser.match(s, "^(open|launch|start)\\s+(.+)$"), let a = app(m[2]) { return .openApp(spoken: m[2], app: a) }
        return .none
    }

    /// "알았어. 그러면 유튜브에 …" → "유튜브에 …" (a reply to it, then the actual command).
    static func dropLeadIn(_ s: String) -> String {
        var t = s
        let leads = ["아니 그게 아니라", "그게 아니라", "아니야", "아니", "알았어", "알겠어", "오케이", "좋아", "그래", "그러면", "그럼", "자", "음", "아", "okay", "ok", "so", "then", "no"]
        var changed = true
        while changed {
            changed = false
            let low = t.lowercased()
            for l in leads where low.hasPrefix(l) {
                let rest = String(t.dropFirst(l.count))
                guard let c = rest.first, c == " " || c == "," || c == "." else { continue }
                let r = rest.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
                if r.count >= 2 { t = r; changed = true }
                break
            }
        }
        return t
    }
    /// "지금 켜져 있는 유튜브 창 꺼", "쿠팡 탭 닫아" → close those tabs (not just pause).
    static func closeTabs(_ s: String) -> (String, String)? {
        let q = squash(s)
        guard ["창", "탭", "페이지", "화면", "window", "tab"].contains(where: q.contains),
              ["꺼", "닫아", "닫어", "종료", "없애", "close"].contains(where: q.contains) else { return nil }
        let sites = [("유튜브", "youtube.com"), ("youtube", "youtube.com"), ("쿠팡", "coupang.com"), ("네이버", "naver.com"), ("구글", "google.com"), ("아마존", "amazon.com")]
        // "구글이나 이런 거 탭들 다 꺼" — more than one site, vaguely → Claude decides.
        if ["이나", "같은거", "이런거", "같은것", "등등"].contains(where: q.contains) { return nil }
        guard let (word, host) = sites.first(where: { q.contains($0.0) }) else { return nil }
        return (word == "youtube" ? "유튜브" : word, host)
    }
    /// "화면 꺼", "화면 전체를 아예 꺼 버려", "모니터 꺼" → the display itself. Only those words — "이미지랑 폴더 화면에
    ///있는 거 다 꺼" is about windows, so anything else in the sentence sends it to Claude.
    static func isDisplayOff(_ s: String) -> Bool {
        var q = squash(s)
        guard ["화면", "모니터", "디스플레이", "screen", "display"].contains(where: q.contains), ["꺼", "끄", "off"].contains(where: q.contains) else { return false }
        let ok = ["디스플레이", "버리라고", "turnoff", "display", "screen", "모니터", "전체를", "이제", "화면", "전체", "아예", "버려", "라고", "꺼", "끄", "다", "좀", "줘", "the", "off"]
        var changed = true
        while changed && !q.isEmpty {
            changed = false
            for w in ok where q.hasPrefix(w) { q.removeFirst(w.count); changed = true; break }
        }
        return q.isEmpty
    }
    /// "창 다 꺼", "지금 켜져 있는 창들 다 꺼줘", "켜 놨던 거 다 닫아" — no particular site → what it opened.
    static func isCloseOpened(_ s: String) -> Bool {
        let q = squash(s)
        if ["다꺼", "다꺼줘", "다끄라고", "다꺼라", "다꺼버려", "전부꺼", "싹다꺼", "다닫아", "다닫아줘", "전부닫아"].contains(q) { return true }
        guard q.count <= 30, ["꺼", "닫아", "닫어", "종료", "없애", "close"].contains(where: q.contains) else { return false }
        let what = ["창", "탭", "켜놨던", "켜놓은", "켜둔", "열어놓은", "열어둔", "열어놨던", "띄운", "띄워놓은", "띄워둔", "windows", "tabs"]
        let all = ["다", "전부", "모두", "싹", "all"]
        // "썸네일 이미지들 다 꺼", "폴더 창 다 닫아" — something specific it didn't open → Claude
        if ["이미지", "사진", "썸네일", "폴더", "파일", "문서", "미리보기", "finder", "image", "folder"].contains(where: q.contains) { return false }
        return what.contains(where: q.contains) && all.contains(where: q.contains)
    }
    /// 「뒤로 가기 눌러」「뒤로 가」「앞으로 가」「새로고침」 (short sentences only — longer ones go to Claude)
    static func browserNav(_ s: String) -> String? {
        let q = squash(s)
        guard q.count <= 18 else { return nil }
        if ["뒤로가", "뒤로가기", "이전페이지", "goback"].contains(where: q.contains), !q.contains("채널") { return "back" }
        if ["앞으로가", "다음페이지", "goforward"].contains(where: q.contains) { return "forward" }
        if ["새로고침", "새로고쳐", "refresh", "reload"].contains(where: q.contains) { return "reload" }
        return nil
    }
    /// 「소리 키워」「볼륨 좀 줄여」「소리 30으로」「음소거」 → (set, delta, mute)
    static func volume(_ s: String) -> (Int?, Int, Bool)? {
        let q = squash(s)
        guard q.count <= 22, ["소리", "볼륨", "음량", "volume", "음소거", "mute"].contains(where: q.contains) else { return nil }
        if q.contains("음소거") && !q.contains("해제") || q.contains("mute") && !q.contains("unmute") { return (nil, 0, true) }
        if let n = Int(q.filter(\.isNumber)), (0...100).contains(n) { return (n, 0, false) }
        if ["적당", "알맞게", "잘들리게", "잘들을수", "듣기좋게", "comfortable"].contains(where: q.contains) { return (50, 0, false) }
        let step = ["많이", "두배", "2배", "확", "엄청", "훨씬", "왕창", "alot", "much"].contains(where: q.contains) ? 30
            : ["조금", "살짝", "약간", "little", "bit"].contains(where: q.contains) ? 7 : 15
        if ["키워", "크게", "올려", "높여", "up", "louder"].contains(where: q.contains) { return (nil, step, false) }
        if ["줄여", "작게", "낮춰", "내려", "down", "quieter"].contains(where: q.contains) { return (nil, -step, false) }
        if q.contains("해제") || q.contains("unmute") { return (nil, 0, false) }
        return nil
    }
    /// 「몇 시야」「지금 몇 시」 → false · 「오늘 며칠이야」「무슨 요일」 → true
    static func clock(_ s: String) -> Bool? {
        let q = squash(s)
        guard q.count <= 14 else { return nil }
        if ["몇시", "whattime", "시간알려"].contains(where: q.contains) { return false }
        if ["며칠", "몇일", "무슨요일", "오늘날짜", "whatday", "date"].contains(where: q.contains) { return true }
        return nil
    }
    /// 「이거 존댓말로 바꿔」「선택한 거 영어로 번역해」「이 글 짧게 줄여 줘」「맞춤법 고쳐 줘」「좀 다듬어 줘」
    static func rewriteStyle(_ s: String) -> String? {
        let low = s.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        let en: [(String, String)] = [("make this more polite", "polite"), ("make this polite", "polite"), ("make this formal", "polite"),
            ("make this casual", "casual"), ("make this shorter", "short"), ("shorten this", "short"), ("make this longer", "long"),
            ("translate this to english", "en"), ("translate this into english", "en"), ("translate this to korean", "ko"), ("translate this into korean", "ko"),
            ("translate this to japanese", "ja"), ("fix the spelling", "spell"), ("fix spelling", "spell"), ("polish this", "polish"), ("clean this up", "polish")]
        if let hit = en.first(where: { low == $0.0 }) { return hit.1 }
        let q = squash(s)
        guard q.count <= 22 else { return nil }
        let pointed = ["이거", "이글", "이문장", "선택한", "방금쓴", "쓴거", "이내용", "이메시지"].contains(where: q.contains)
        let verb = ["바꿔", "고쳐", "번역", "줄여", "늘려", "다듬", "만들어", "써줘", "해줘", "바꿔줘"].contains(where: q.contains)
        let styles: [(String, [String])] = [("polite", ["존댓말", "공손", "정중", "높임말"]), ("casual", ["반말"]), ("en", ["영어", "english"]),
            ("ja", ["일본어"]), ("zh", ["중국어"]), ("ko", ["한국어로", "한글로"]), ("spell", ["맞춤법", "오타", "띄어쓰기"]),
            ("short", ["짧게", "간단히", "요약"]), ("long", ["길게", "자세히", "늘려"]), ("polish", ["다듬", "자연스럽게", "매끄럽게"])]
        guard let st = styles.first(where: { $0.1.contains(where: q.contains) })?.0 else { return nil }
        // 「맞춤법 고쳐」「다듬어 줘」 are clear on their own; others need 「이거/선택한 …」 + a verb
        if ["spell", "polish"].contains(st), verb { return st }
        return pointed && verb ? st : nil
    }
    static let nativeNum: [String: Int] = ["한": 1, "두": 2, "세": 3, "네": 4, "다섯": 5, "여섯": 6, "일곱": 7, "여덟": 8, "아홉": 9, "열": 10, "열한": 11, "열두": 12,
                                           "일": 1, "이": 2, "삼": 3, "사": 4, "오": 5, "육": 6, "칠": 7, "팔": 8, "구": 9, "십": 10, "십오": 15, "이십": 20, "삼십": 30]
    static func num(_ w: String) -> Int? { Int(w) ?? nativeNum[w] }
    /// 「라면 3분」「3분 타이머」「10분 뒤에 알려 줘」「1시간 30분 후에 알려 줘」「30초」 · 「5시에 회의 알려 줘」「오후 3시 반에 알려 줘」
    static func timer(_ s: String) -> (Int, String)? {
        let t = s.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: ".", with: " ")
        // English: "3 minute timer", "set a timer for 10 minutes", "remind me in 20 minutes to stretch"
        let low = t.lowercased()
        if let m = match(low, "^(?:set (?:a )?)?(\\d+)\\s*(minute|min|second|sec|hour)s?\\s*timer$")
            ?? match(low, "^(?:set )?(?:a )?timer (?:for )?(\\d+)\\s*(minute|min|second|sec|hour)s?$"), let n = Int(m[1]) {
            let secs = m[2].hasPrefix("h") ? n * 3600 : m[2].hasPrefix("s") ? n : n * 60
            return secs > 0 && secs <= 86400 ? (secs, "") : nil
        }
        if let m = match(low, "^remind me in (\\d+)\\s*(minute|min|hour)s?(?: to (.+))?$"), let n = Int(m[1]) {
            return ((m[2].hasPrefix("h") ? n * 3600 : n * 60), m[3])
        }
        // At a clock time: (오전|오후)? N시 (M분|반)? 에 …
        if let m = match(t, "^(?:(오전|오후|아침|저녁|밤|새벽)\\s*)?(\\S+?)\\s*시\\s*(?:(\\S+?)\\s*분|(반))?\\s*에\\s*(.*?)\\s*(?:알려|깨워|불러|말해)\\s*(?:줘|주세요|줄래)?$"),
           let h = num(m[2]), (0...24).contains(h) {
            let minute = m[4] == "반" ? 30 : (num(m[3]) ?? 0)
            var label = m[5].replacingOccurrences(of: "라고", with: "").trimmingCharacters(in: .whitespaces)
            for suffix in ["이라고", "고", "을", "를", "있다고", "있는 거"] where label.hasSuffix(suffix) { label = String(label.dropLast(suffix.count)) }
            let cal = Calendar.current, now = Date()
            var best: Date?
            let hours = m[1].isEmpty ? ((1...6).contains(h) ? [h + 12] : h <= 12 ? [h, h + 12] : [h])
                                     : (["오후", "저녁", "밤"].contains(m[1]) && h < 12 ? [h + 12] : [h])
            for day in 0...1 { for hh in hours where hh < 24 {
                if var d = cal.date(bySettingHour: hh, minute: minute, second: 0, of: now) {
                    if day == 1 { d = cal.date(byAdding: .day, value: 1, to: d)! }
                    if d > now, best == nil || d < best! { best = d }
                } } }
            guard let at = best else { return nil }
            return (Int(at.timeIntervalSince(now).rounded()), label.trimmingCharacters(in: .whitespaces))
        }
        // A duration: [label] N시간 N분 N초 [타이머|뒤에|후에 …] [label] [알려 줘]
        guard let re = try? NSRegularExpression(pattern: "(\\d+|[가-힣]{1,2})\\s*(시간|분|초)(?![가-힣])|(\\d+|[가-힣]{1,2})\\s*(시간|분|초)(?=\\s*(타이머|알람|뒤|후|있다가|지나면))") else { return nil }
        let ns = t as NSString
        let hits = re.matches(in: t, range: NSRange(location: 0, length: ns.length))
        guard !hits.isEmpty else { return nil }
        var secs = 0
        for h in hits {
            let gi = h.range(at: 1).location != NSNotFound ? 1 : 3
            guard let n = num(ns.substring(with: h.range(at: gi))) else { return nil }
            switch ns.substring(with: h.range(at: gi + 1)) { case "시간": secs += n * 3600; case "분": secs += n * 60; default: secs += n }
        }
        guard secs > 0, secs <= 24 * 3600 else { return nil }
        var label = ns.substring(to: hits[0].range.location).trimmingCharacters(in: .whitespaces)
        var rest = ns.substring(from: NSMaxRange(hits.last!.range)).trimmingCharacters(in: .whitespaces)
        var keyword = false
        for k in ["타이머", "알람", "뒤에", "후에", "뒤", "후", "있다가", "지나면"] where rest.hasPrefix(k) { rest = String(rest.dropFirst(k.count)).trimmingCharacters(in: .whitespaces); keyword = true; break }
        let ask = #"^(?:(.*?)\s*(?:(?:이)?라고|고)?\s*)?(알려|깨워|불러|말해|맞춰|재|해)\s*(줘|주세요|줄래|봐)?$"#
        if !rest.isEmpty {
            guard let m = Parser.match(rest, ask) else { return nil }        // "3분짜리 영상 찾아 줘" is not a timer
            if label.isEmpty { label = m[1] }
        } else if !keyword, label.split(separator: " ").count > 2 { return nil }   // "…를 3분" in a longer sentence — leave it
        if ["지금", "한", "타이머", "알람"].contains(label) { label = "" }
        return (secs, label.trimmingCharacters(in: .whitespaces))
    }
    static func isCancelTimers(_ s: String) -> Bool {
        let q = squash(s)
        return q.count <= 14 && ["타이머", "알람", "알림"].contains(where: q.contains) && ["취소", "꺼", "지워", "없애", "그만", "cancel"].contains(where: q.contains)
    }
    /// 「강남역 가는 길」「서울역 어떻게 가」「롯데월드 길 찾아 줘」「스타벅스 강남점 어디야」 → place
    static func mapPlace(_ s: String) -> String? {
        guard let m = match(s, "^(.+?)\\s*(?:까지\\s*)?(가는\\s*(?:길|내비게이션|네비게이션|내비|네비|경로|방법)|길\\s*찾아|길찾기|어떻게\\s*가|위치\\s*알려|위치|어디야|어디\\s*있어|지도)(?:\\s*(?:좀|줘|알려\\s*줘|보여\\s*줘|찾아\\s*줘|찾아|켜\\s*줘|봐))*$") else { return nil }
        var place = m[1]
        // 「(제주도에서) 서귀포에서 제주시로 가는 길」 → a route: 서귀포 → 제주시 (10/25: it went to a web search)
        if let r = match(place, "^(?:.*\\s)?(\\S+?)에서\\s+(.+?)(?:으로|로|까지)?$"), squash(r[1]).count >= 2, squash(r[2]).count >= 2 { return r[1] + " → " + r[2] }
        for p in ["으로", "로", "에", "까지"] where place.hasSuffix(p) && place.count > p.count + 1 { place = String(place.dropLast(p.count)) }
        let q = squash(place)
        guard q.count >= 2, !["지금", "여기", "너", "나", "자비스", "클로드", "그거", "이거", "파일", "폴더", "설정"].contains(where: { q == $0 || q.hasPrefix($0) && q.count <= $0.count + 1 }) else { return nil }
        return place
    }
    /// 「로파이 틀고 소리 줄이고 화면 꺼」 → ["로파이 틀어", "소리 줄여", "화면 꺼"]
    static func splitCommands(_ s: String) -> [String]? {
        let joints: [String: String] = ["틀고": "틀어", "켜고": "켜", "끄고": "꺼", "열고": "열어", "닫고": "닫아", "멈추고": "멈춰", "줄이고": "줄여",
                                        "키우고": "키워", "하고": "해", "찾고": "찾아", "올리고": "올려", "내리고": "내려", "누르고": "눌러", "넘기고": "넘겨",
                                        "검색하고": "검색해", "재생하고": "재생해", "가서": "가", "맞추고": "맞춰", "알려주고": "알려 줘",
                                        // 「맥미니 검색하면서 베토벤 틀어」 — 「~면서」 joins two jobs too
                                        "검색하면서": "검색해", "찾으면서": "찾아", "틀면서": "틀어", "켜면서": "켜", "하면서": "해", "보면서": "봐",
                                        "줄이면서": "줄여", "키우면서": "키워", "재생하면서": "재생해",
                                        // 「쿠팡에 맥미니 좀 검색해 주고 …」 (10/24: everything after it became the search words)
                                        "주고": "줘", "해주고": "해 줘", "봐주고": "봐 줘", "찾아주고": "찾아 줘", "검색해주고": "검색해 줘", "틀어주고": "틀어 줘"]
        var parts: [String] = [], cur: [String] = []
        for raw in s.split(separator: " ").map(String.init) {
            let w = raw.trimmingCharacters(in: .punctuationCharacters)
            if ["그리고", "다음에", "그다음에", "그다음", "그러고"].contains(w) { if !cur.isEmpty { parts.append(cur.joined(separator: " ")); cur = [] }; continue }
            if let v = joints[w] { cur.append(v); parts.append(cur.joined(separator: " ")); cur = []; continue }
            cur.append(w)
            if raw.hasSuffix(",") || raw.hasSuffix(".") || raw.hasSuffix("?") || raw.hasSuffix("!") { parts.append(cur.joined(separator: " ")); cur = [] }
        }
        if !cur.isEmpty { parts.append(cur.joined(separator: " ")) }
        parts = parts.flatMap { p -> [String] in
            if let m = match(p, "^(유튜브|youtube)(?:에|에서|로)?\\s+(.+?)\\s+(?:좀\\s+)?((?:소리|볼륨|음량)\\s*.+)$"), !m[2].contains("틀") {
                return ["유튜브 " + m[2].replacingOccurrences(of: " 좀", with: "") + " 틀어", m[3]]
            }
            return [p]
        }
        return parts.count >= 2 ? parts : nil
    }
    /// "다음 영상으로 넘겨", "다음 곡", "next video"
    /// 「빨리 감기 해 줘」「30초 앞으로 넘겨」「되감기」 → +10 / +30 / −10 seconds.
    static func seek(_ s: String) -> Int? {
        let q = squash(s)
        guard q.count <= 22 else { return nil }
        let fwd = ["빨리감기", "빨리감아", "앞으로감기", "앞으로감아", "앞으로넘겨", "빨리넘겨", "fastforward", "skipahead"]
        let back = ["되감기", "되감아", "뒤로감기", "뒤로감아", "뒤로넘겨", "rewind"]
        let sign = fwd.contains(where: q.contains) ? 1 : back.contains(where: q.contains) ? -1 : 0
        guard sign != 0 else { return nil }
        var secs = 10
        if let m = match(q, "(\\d+)초") { secs = Int(m[1]) ?? 10 } else if let m = match(q, "(\\d+)분") { secs = (Int(m[1]) ?? 1) * 60 }
        return sign * max(5, min(secs, 600))
    }
    /// 「네이버 메일 열어」「지메일 들어가자」 → the web mail page.
    static func mailSite(_ s: String) -> (String, String)? {
        let q = squash(s)
        guard q.count <= 22, match(q, "(열어|켜|들어가|가자|보여|띄워|open)") != nil, q.contains("메일") || q.contains("gmail") || q.contains("mail") else { return nil }
        if q.contains("네이버") || q.contains("naver") { return ("네이버 메일", "https://mail.naver.com") }
        if q.contains("지메일") || q.contains("gmail") || q.contains("구글") || q.contains("google") { return ("Gmail", "https://mail.google.com") }
        return nil
    }
    static func isNext(_ s: String) -> Bool {
        let q = squash(s)
        return q.count <= 16 && (["다음영상", "다음곡", "다음노래", "다음거틀어", "다음걸로", "nextvideo", "nextsong", "skip"].contains(where: q.contains))
    }
    /// "영상 멈춰", "유튜브 꺼", "노래 정지", "틀어져 있는 영상들 다 꺼" → pause · "다시 틀어", "이어서 재생" → play.
    static func mediaControl(_ s: String) -> Bool? {
        let q = squash(s)
        guard q.count <= 24 else { return nil }
        let things = ["영상", "동영상", "유튜브", "youtube", "음악", "노래", "재생중", "틀어져", "video", "music"]
        let stops = ["멈춰", "멈춤", "정지", "일시정지", "중지", "꺼", "끄", "스톱", "stop", "pause"]
        if things.contains(where: q.contains),
           stops.contains(where: { q.hasSuffix($0) || q.hasSuffix($0 + "줘") || q.hasSuffix($0 + "봐") || q.hasPrefix($0) }) { return false }
        if ["다시틀어", "다시재생", "이어서틀어", "이어서재생", "계속틀어", "계속재생", "resume", "playagain"].contains(where: q.contains) { return true }
        return nil
    }
    /// 「유튜브 꺼」「이전 영상 꺼」「음악 끄라고」 — 꺼 means close it (pausing is 멈춰·정지). No YouTube page → pause instead.
    static func closesVideo(_ s: String) -> Bool {
        let q = squash(s)
        guard q.count <= 24, ["유튜브", "youtube", "영상", "동영상", "음악", "노래"].contains(where: q.contains) else { return false }
        if ["멈춰", "정지", "중지", "스톱", "pause", "stop", "끄고", "말고", "틀어"].contains(where: q.contains) { return false }
        return ["꺼", "끄라", "끄자", "끄랬", "꺼줘", "꺼라", "닫아"].contains(where: { q.hasSuffix($0) || q.hasSuffix($0 + "고") || q.contains($0) })
    }
    /// Claude's reply says it started a video / music ("…재생했습니다", "틀었습니다", "Playing …").
    static func startedMedia(_ answer: String) -> Bool {
        let a = answer.lowercased()
        return ["재생했", "재생합니다", "재생 중", "재생중", "틀었", "틀어 드렸", "틀어드렸", "now playing", "started playing", "is playing"].contains(where: a.contains)
            && !["멈췄", "정지했", "껐", "paused", "stopped"].contains(where: a.contains)
    }
    /// "X 멈추고 Y", "X 하고 Y", "X 그리고 Y", "X 한 다음 Y" — more than one action.
    static func isCompound(_ s: String) -> Bool {
        if [" 그리고 ", "한 다음", "하고 나서", "고 나서", "한 뒤에", "다음에 "].contains(where: { s.contains($0) }) { return true }
        if match(s, "(?:뒤로|앞으로)\\s*가서\\s+\\S+") != nil { return true }      // 「뒤로 가서 네 번째 메일 클릭해」 (10/25: only went back)
        // 「쿠팡에서 맥미니 검색하면서 베토벤 틀어봐」 — 「~면서」 joins two jobs (10/24: it searched the whole sentence)
        if match(s, "(하|해|찾|열|틀|켜|보|키우|줄이|올리|내리)\\s*(으)?면서\\s+\\S+") != nil { return true }
        // Two sentences that each ask for something: 「베토벤 틀어봐. 볼륨은 적당하게」
        let sentences = s.components(separatedBy: CharacterSet(charactersIn: ".!?。")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 }
        // (the same job said twice — 「영상 다 꺼. 유튜브 화면 다 꺼.」 — is one job)
        let jobs = sentences.map(actions).filter { !$0.isEmpty }
        if jobs.count >= 2, jobs.dropFirst().contains(where: { $0.isDisjoint(with: jobs[0]) }) { return true }
        // 「네이버에 ○○ 검색해서 △△ 알려줘」「크몽 들어가서 대화 이어가」 — find/open, then read, answer or carry on: the brain does both
        if match(s, "(검색해서|검색하고|찾아서|찾아보고|찾아 보고|들어가서|들어가 가지고|열어서|열고|보고)\\s+.*(알려|말해|정리|요약|비교|읽어|골라|추천|이어가|이어서|답장|답해|확인해|봐 줘|봐줘)") != nil { return true }
        return match(s, "(멈추|끄|켜|열|닫|틀|누르|찾|가|보|치|하|주|줄이|키우|올리|내리|넘기|맞추)고\\s+\\S+.*(해|줘|봐|켜|꺼|열어|틀어|찾아|검색|보여|줄여|키워|넘겨|올려|내려)") != nil
    }
    /// A sentence that asks for an action (or names a setting to change: 「볼륨은 적당하게」).
    static func actions(_ s: String) -> Set<String> {
        let q = squash(s)
        let kinds: [(String, [String])] = [("play", ["틀어", "재생"]), ("close", ["꺼", "닫아", "끄"]), ("open", ["열어", "켜"]),
            ("search", ["검색", "찾아"]), ("tell", ["알려", "보여"]), ("volume", ["볼륨", "소리", "음량", "줄여", "키워"])]
        return Set(kinds.filter { $0.1.contains(where: q.contains) }.map(\.0))
    }
    /// Another job slipped into a search: 「맥미니 검색하면서 베토벤 틀어봐」 — the search words must not carry it.
    static func carriesOtherJob(_ q: String) -> Bool {
        isCompound(q) || ["틀어", "재생", "볼륨", "음량", "소리 ", "꺼", "켜 ", "면서", "그리고", "주고", "체크", "가는 길", "어떻게",
                          "검색해", "찾아 ", "알려", "알아봐", "확인해"].contains(where: q.contains)
    }
    /// Removes a trailing ask: "찾아 줘", "검색해", "보여 줘", "알아봐", "좀".
    /// 「다른 영상」「다른 걸로」「딴 거」 — something else, not those words.
    static func isOther(_ q: String) -> Bool {
        let t = squash(q)
        return t.count <= 7 && ["다른", "딴", "another", "something else"].contains(where: t.hasPrefix)
    }
    /// The query also asks to stop or close something first (「지금 음악 끄고 …」).
    static func alsoStops(_ q: String) -> Bool { ["끄고", "꺼고", "멈추고", "닫고", "끈 다음", "끄고서"].contains(where: q.contains) }
    /// Doing something on the site rather than searching it.
    static func siteAction(_ q: String) -> Bool {
        let t = squash(q)
        return ["로그아웃", "로그인", "메일", "확인해", "확인하", "하라고", "읽어", "답장", "logout", "login", "signin", "mail", "inbox"].contains(where: t.contains)
    }
    static func stripAsk(_ q: String) -> String {
        var t = q.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let asks = ["얼만가 봐 봐", "얼만가 봐봐", "얼만가 봐", "얼마인지 봐 봐", "얼마인지 봐봐", "얼마인지 봐", "얼마인지", "얼마야", "얼마예요", "얼만지", "얼마지",
                    "가격 봐 봐", "가격 봐봐", "봐 봐", "봐봐", "알려 줘", "알려줘", "띄워 봐", "띄워봐", "띄워 줘", "띄워줘", "서치해 줘", "서치해줘", "서치해 봐", "서치 해 봐", "서치해봐", "서치해", "서치", "검색해 봐", "검색해봐",
                    "검색해 줘", "검색해줘", "검색해", "검색", "찾아 줘", "찾아줘", "찾아 봐", "찾아봐", "찾아", "보여 줘", "보여줘", "보여", "알아봐 줘", "알아봐", "열어 줘", "열어줘", "열어", "좀"]
        var changed = true
        while changed {
            changed = false
            for a in asks where t.hasSuffix(a) { t = String(t.dropLast(a.count)).trimmingCharacters(in: .whitespaces); changed = true; break }
        }
        return t
    }
    static let cancelWords = ["아니 취소", "아니취소", "취소", "하지 마", "하지마", "아니야 됐어", "아니 됐어", "never mind", "nevermind", "cancel that", "scratch that"]
    static func cancelledAtEnd(_ s: String) -> Bool {
        let t = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return t.count > 4 && cancelWords.contains { t.hasSuffix($0) }
    }
    static func ordinal(_ w: String) -> Int? {
        let t = w.replacingOccurrences(of: " ", with: "").lowercased()
        if let n = Int(t.filter { $0.isNumber }), n > 0 { return n }
        let en = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5]
        if let n = en[t] { return n }
        let ko: [(String, Int)] = [("다섯", 5), ("여섯", 6), ("일곱", 7), ("여덟", 8), ("아홉", 9), ("하나", 1), ("첫", 1), ("한", 1), ("두", 2), ("둘", 2), ("세", 3), ("셋", 3), ("네", 4), ("넷", 4), ("열", 10)]
        return ko.first { t.hasSuffix($0.0) }?.1
    }
}
