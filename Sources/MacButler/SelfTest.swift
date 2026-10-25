// Grammar tests: `MacButler.app/Contents/MacOS/MacButler --selftest`
import Foundation

enum SelfTest {
    static func run() -> Bool {
        logQuiet = true
        var ko = Config(); ko.language = "ko"; ko.userName = "대표님"; ko.apps = ["브루": "Vrew"]
        var en = Config(); en.language = "en"
        let pk = Parser(cfg: ko), pe = Parser(cfg: en)
        var fails = 0, total = 0
        func check(_ p: Parser, _ s: String, _ want: Intent, yt: Bool = false) {
            total += 1
            let got = p.parse(s, hasYouTubeList: yt)
            if got != want { fails += 1; print("FAIL  「\(s)」\n      want \(want)\n      got  \(got)") }
        }
        func checkBool(_ name: String, _ v: Bool) { total += 1; if !v { fails += 1; print("FAIL  \(name)") } }

        // Korean
        check(pk, "크롬 열어 줘", .openApp(spoken: "크롬", app: "Google Chrome"))
        check(pk, "브루 켜", .openApp(spoken: "브루", app: "Vrew"))
        check(pk, "맥미니 가격 검색해", .search("맥미니 가격"))
        check(pk, "유튜브 거북이 버프 영상 하나 켜봐", .youtube("거북이 버프"))
        check(pk, "유튜브에서 로파이 음악 틀어", .youtube("로파이 음악"))
        check(pk, "두 번째 거 틀어", .youtubeNth(2), yt: true)
        check(pk, "3번째 영상 재생해", .youtubeNth(3), yt: true)
        check(pk, "안녕하세요 라고 써 줘", .type("안녕하세요"))
        check(pk, "클로드코드에게 지금 켜져있는 모든 프로젝트 전체 점검해서 텔레그램으로 우선순위 정해서 보내",
              .claude(target: "", message: "지금 켜져있는 모든 프로젝트 전체 점검해서 텔레그램으로 우선순위 정해서 보내", newSession: true))
        check(pk, "클로드 코드한테 시켜서 블로그 점검하고 보고해", .claude(target: "", message: "블로그 점검하고 보고해", newSession: true))
        check(pk, "음성 제어 Mac 설정 프로젝트 클로드에다가 시험이라고 전달해", .claude(target: "음성 제어 Mac 설정", message: "시험", newSession: false))
        check(pk, "쿠팡에서 무선 이어폰 찾아 줘", .web(label: "쿠팡", query: "무선 이어폰", url: "https://www.coupang.com/np/search?q="))
        check(pk, "네이버 쇼핑에서 맥미니 검색해", .web(label: "네이버 쇼핑", query: "맥미니", url: "https://search.shopping.naver.com/search/all?query="))
        check(pk, "에어팟 최저가 찾아 줘", .web(label: "네이버 쇼핑", query: "에어팟", url: "https://search.shopping.naver.com/search/all?query="))
        check(pk, "네이버에서 오늘 날씨 검색해", .web(label: "네이버", query: "오늘 날씨", url: "https://search.naver.com/search.naver?query="))
        check(pk, "지금 켜진 클로드 창에 로그인 버그 고쳐 줘", .claude(target: "", message: "로그인 버그 고쳐 줘", newSession: false))
        check(pk, "네이버에 맥미니 가격 검색해서 제일 싼 거 알려줘", .none)
        check(pk, "크몽 들어가서 지금 대화 이어가", .none)
        check(pk, "카톡에 엄마 채팅창 찾아서 글 읽고 답장 좀 해 줘", .none)
        check(pk, "클로드 댓글 작업용 프로젝트에 테스트라고 전달해", .claude(target: "댓글 작업용", message: "테스트", newSession: false))
        check(pk, "클로드 창 중에 잡일 시키기 창에 오늘 할 일 정리해 줘", .claude(target: "잡일 시키기", message: "오늘 할 일 정리해 줘", newSession: false))
        check(pk, "지금 켜진 클로드 창에 로그인 버그 고치고, 아니, 취소", .hush)
        // 10/24 conversation bugs
        check(pk, "유튜브 꺼", .closeTabs(label: "유튜브", host: "youtube.com"))
        check(pk, "이전 영상 꺼", .closeTabs(label: "유튜브", host: "youtube.com"))
        check(pk, "베토벤 음악 끄라고", .closeTabs(label: "유튜브", host: "youtube.com"))
        check(pk, "영상 멈춰", .media(play: false))
        check(pk, "다른 영상 틀어", .youtube("추천"))
        check(pk, "유튜브 다른 걸로 틀어", .youtube("추천"))
        check(pk, "쿠팡의 맥 스튜디오 M5 맥스 얼만가 봐봐", .web(label: "쿠팡", query: "맥 스튜디오 M5 맥스", url: "https://www.coupang.com/np/search?q="))
        check(pk, "네이버 로그아웃해", .none)
        check(pk, "네이버 메일 뭐 왔는지 확인해", .none)
        check(pk, "볼륨 많이 키워", .volume(set: nil, delta: 30, mute: false))
        check(pk, "볼륨 두 배 더 키워", .volume(set: nil, delta: 30, mute: false))
        check(pk, "소리 조금 줄여", .volume(set: nil, delta: -7, mute: false))
        // 10/24 「쿠팡에서 맥미니 검색하면서 베토벤 음악도 하나 틀어봐. 음악 볼륨은 적당하게 내가 잘 들을 수 있게」 → split, not one search
        check(pk, "쿠팡에서 맥미니 검색하면서 베토벤 음악도 하나 틀어봐. 음악 볼륨은 적당하게 내가 잘 들을 수 있게",
              .multi(["쿠팡에서 맥미니 검색해", "베토벤 음악도 하나 틀어봐", "음악 볼륨은 적당하게 내가 잘 들을 수 있게"]))
        check(pk, "쿠팡에서 맥미니 검색하면서 베토벤 음악도 하나 틀어봐", .multi(["쿠팡에서 맥미니 검색해", "베토벤 음악도 하나 틀어봐"]))
        check(pk, "쿠팡에서 맥미니 검색해", .web(label: "쿠팡", query: "맥미니", url: "https://www.coupang.com/np/search?q="))
        check(pk, "베토벤 음악도 하나 틀어봐", .youtube("베토벤 음악"))
        check(pk, "음악 볼륨은 적당하게 내가 잘 들을 수 있게", .volume(set: 50, delta: 0, mute: false))
        check(pk, "쿠팡 맥미니 검색", .web(label: "쿠팡", query: "맥미니", url: "https://www.coupang.com/np/search?q="))
        check(pk, "유튜브 베토벤 음악 틀어", .youtube("베토벤 음악"))
        check(pk, "볼륨 적당하게 해줘", .volume(set: 50, delta: 0, mute: false))
        check(pk, "쿠팡에서 무선 이어폰 찾아 줘", .web(label: "쿠팡", query: "무선 이어폰", url: "https://www.coupang.com/np/search?q="))
        // 10/24 four jobs at once: YouTube 베토벤 · volume down · Coupang 맥미니 · a route question for the brain
        check(pk, "유튜브에 베토벤 음악 좀 소리 작게 하고 그리고 쿠팡에 맥미니 좀 검색해 주고 강남으로 가는 길 제주도에서 비행기를 어떻게 가는지 체크해 봐",
              .multi(["유튜브 베토벤 음악 틀어", "소리 작게 해", "쿠팡에 맥미니 좀 검색해 줘", "강남으로 가는 길 제주도에서 비행기를 어떻게 가는지 체크해 봐"]))
        check(pk, "쿠팡에 맥미니 좀 검색해 줘", .web(label: "쿠팡", query: "맥미니", url: "https://www.coupang.com/np/search?q="))
        check(pk, "강남으로 가는 길 제주도에서 비행기를 어떻게 가는지 체크해 봐", .none)
        check(pk, "쿠팡에 맥미니 좀 검색해 주고 강남으로 가는 길 체크해 봐", .multi(["쿠팡에 맥미니 좀 검색해 줘", "강남으로 가는 길 체크해 봐"]))
        checkBool("speakable", Butler.speakable("주인님, 9호선 급행입니다. [경로 안내](https://www.gimpo.go.kr/x) **좋아요**") == "주인님, 9호선 급행입니다. 경로 안내 좋아요")
        do { var g = Config(); g.language = "ko"; g.assistantName = "Sasarisa"; g.customWords = (1...200).map { "낱말\($0)" }
             let gl = Butler.glossary(g); checkBool("glossary keeps the name first and short", gl.hasPrefix("Glossary: 사사리사") && gl.count <= 180) }
        for yes in ["응", "응 찾아봐", "그래 해 줘", "좋아 틀어 줘", "네 알려 주세요"] { check(pk, yes, .none) }
        check(pk, "응원가 틀어", .youtube("응원가"))
        // 10/24 relay sentences from the log
        check(pk, "서 서 있어 서 서 있어 이거 발음 클로드에다가 전달해놔", .claude(target: "", message: "서 서 있어 서 서 있어 이거 발음", newSession: false))
        if case .claude(let t, _, false) = pk.parse("클로드 음성 제어 Mac 설정에다가 방금 내 발음들 버그 고치 놓으라고 전달 하라고", hasYouTubeList: false) { checkBool("window name without 프로젝트", t == "음성 제어 Mac 설정") } else { checkBool("window name without 프로젝트", false) }
        if case .claude(let t, _, _) = pk.parse("클로드 음성 제어 Mac 설정에 버그 고치라고 해", hasYouTubeList: false) { checkBool("window name + 에", t == "음성 제어 Mac 설정") } else { checkBool("window name + 에", false) }
        checkBool("hangul reading", Config.hangulReading("sasarisa") == "사사리사" && Config.hangulReading("Nova") == "노바" && Config.hangulReading("Pudding") == nil)
        var named = Config(); named.language = "ko"; named.assistantName = "sasarisa"
        checkBool("name is a wake word", named.wakes.contains("사사리사") && named.wakes.contains("자비스"))
        let sp = Parser(cfg: named)
        for said in ["샤싸 리사 몇 시야", "사사니사 몇 시야", "서서 리사 몇 시야", "사사리사~ 몇 시야", "싸사리사, 몇 시야", "헤이 사사리샤 몇 시야"] {
            checkBool("sounds like 사사리사: " + said, sp.stripWake(said) == "몇 시야")
        }
        checkBool("서 서 있어 wakes", sp.stripWake("서 서 있어 지금 몇 시야") == "지금 몇 시야")
        checkBool("sounds like 싸싸릐싸", sp.stripWake("싸싸릐싸 몇 시야") == "몇 시야" && sp.stripWake("싸싸리싸, 몇 시야") == "몇 시야")
        checkBool("said twice keeps ?", Whisper.saidTwice("사사리사, 지금 몇 시야? 사사리사, 지금 몇 시야?") == "사사리사, 지금 몇 시야?")
        checkBool("not a wake: 사서 이사", sp.wakeRange("오늘 책 사서 집에 가") == nil)
        var chosen = Config(); chosen.brainProvider = "codex"
        checkBool("a chosen brain is used as is", Brains.make(chosen) is CodexBrain)
        checkBool("combo splits the work", ComboBrain.pick("쿠팡에서 맥미니 찾아서 장바구니에 넣어") == "aside" && ComboBrain.pick("로그인 버그 고쳐 줘") == "claude" && ComboBrain.pick("오늘 일정 정리해 줘") == "codex")
        chosen.brainProvider = "combo"
        checkBool("combo is a brain", Brains.make(chosen) is ComboBrain)
        var boot = Config(); boot.assistantName = "Sasarisa"; boot.bootTitle = "M A C   B U T L E R"
        checkBool("greeting title is the assistant's name", boot.bootTitleShown == "S A S A R I S A" && Config().bootTitleShown == "S A S A R I S A")
        boot.assistantName = "거북아"; boot.bootTitle = ""
        checkBool("greeting title follows a new name", boot.bootTitleShown == "거 북 아")
        // 10/25: the name in a web address is not a call, and it's written as our address for the brain
        checkBool("name.com is not a wake", sp.wakeRange("싸싸리싸.com 들어가 있어") == nil && sp.wakeRange("사사리싸 닷컴을 입력해") == nil)
        checkBool("call, then the address", sp.stripWake("사사리사, 사사리사닷컴 열어") == "사사리사닷컴 열어")
        checkBool("our address", Parser.ourAddress("사사리싸.com 들어가 있어") == "sasarisa.com 들어가 있어" && Parser.ourAddress("싸싸리싸 닷컴을 입력해") == "sasarisa.com을 입력해")
        checkBool("cut-short 「…하면은」 is a broken routine", { if case .badRoutine = pk.parse("페이지를 내리라고 하면은", hasYouTubeList: false) { return true }; return false }())
        // 이름 맞추기: what the recognizers wrote for the owner's voice becomes a wake word — but not common words or commands
        var momo = Config(); momo.language = "ko"
        let tr = NameTrainer(name: "모모", base: momo, whisper: nil)
        let takes = ["모모", "모모", "모모야", "모모", "뭐뭐", "뭐뭐", "뭐뭐", "보보", "보보", "그래서", "그래서", "유튜브 틀어"]
        tr.samples = takes.map { NameTrainer.Sample(apple: $0, whisper: $0, raw: "") }
        let r = tr.result()
        checkBool("name training before 4/12", r.before == 4)
        checkBool("name training learns 뭐뭐·보보", r.learned.contains("뭐뭐") && r.learned.contains("보보"))
        checkBool("name training skips common words and commands", !r.learned.contains("그래서") && !r.learned.contains("유튜브 틀어"))
        checkBool("name training after 9/12", r.after == 9)
        momo.assistantName = "모모"; momo.learnedWakes = ["모모": ["뭐뭐"]]
        checkBool("learned spelling wakes", Parser(cfg: momo).stripWake("뭐뭐 몇 시야") == "몇 시야")
        checkBool("learned spelling only for its name", !Config().wakes.contains("뭐뭐"))
        checkBool("sounds close", NameTrainer.close("사사리싸", "사사리사") && !NameTrainer.close("오늘 날씨", "사사리사"))
        checkBool("8 name takes then 4 with a command", tr.command(0) == "" && tr.command(7) == "" && tr.command(8) == "유튜브 틀어" && tr.prompt(9, shownName: "모모") == "모모, 소리 줄여")
        checkBool("name part of a command take", NameTrainer.withoutCommand("서서 있어 유튜브 틀어", "유튜브 틀어") == "서서 있어" && NameTrainer.withoutCommand("유튜브 틀어", "유튜브 틀어") == nil && NameTrainer.withoutCommand("뭐뭐 소리 키워", "소리 줄여") == nil)
        let tr2 = NameTrainer(name: "모모", base: momo, whisper: nil)
        tr2.samples = ["보보 유튜브 틀어", "보보 소리 줄여"].enumerated().map { NameTrainer.Sample(apple: $1, whisper: $1, raw: "", command: tr2.command($0 + 8)) }
        checkBool("learns from command takes", tr2.result().learned.contains("보보"))
        var hangulName = Config(); hangulName.language = "ko"; hangulName.assistantName = "사사리사"
        checkBool("a name typed in Hangul gets its sound-alikes", hangulName.wakes.contains("싸싸리싸") && Parser(cfg: hangulName).stripWake("서 서 있어 몇 시야") == "몇 시야")
        let np = Parser(cfg: named)
        checkBool("default name 사사리사", Config().assistantName == "Sasarisa" && pk.stripWake("사사리사, 크롬 열어") == "크롬 열어" && pk.stripWake("자비스, 크롬 열어") == "크롬 열어")
        checkBool("샤샤 리사 wakes", np.stripWake("샤샤 리사 유튜브 로파이 틀어") == "유튜브 로파이 틀어")
        checkBool("whisper said twice", Whisper.saidTwice("자비스, 지금 음악 끄고, 사기 음악 틀어. 자비스, 지금 음악 끄고, 사기 음악 틀어.") == "자비스, 지금 음악 끄고, 사기 음악 틀어.")
        checkBool("whisper once stays", Whisper.saidTwice("유튜브 꺼. 쿠팡 열어.") == nil)
        checkBool("direct order", ClaudeRelay.directOrder("이거 영상 좋으니깐 이제 전체 다 실행 하라고 얘기 하라고") == "이거 영상 좋으니깐 이제 전체 다 실행해 주세요")
        checkBool("direct order keeps others", ClaudeRelay.directOrder("버그 고치라고") == "버그 고치라고")
        check(pk, "지금 켜진 클로드 창에다가 버그 고치라고 해", .claude(target: "", message: "버그 고치라고 해", newSession: false))
        checkBool("알았어 조용히 해 = hush", pk.isHush("알았어 조용히 해"))
        check(pk, "쿠팡 홈페이지에 들어가서 맥미니 가격", .web(label: "쿠팡", query: "맥미니 가격", url: "https://www.coupang.com/np/search?q="))
        check(pk, "쿠팡 들어가서 무선 이어폰 찾아 줘", .web(label: "쿠팡", query: "무선 이어폰", url: "https://www.coupang.com/np/search?q="))
        check(pk, "쿠팡 열어", .web(label: "쿠팡", query: "", url: "https://www.coupang.com/"))
        check(pk, "영상 멈추고 쿠팡에서 맥미니 찾아 줘", .multi(["영상 멈춰", "쿠팡에서 맥미니 찾아 줘"]))   // 10/23: quick parts run in order
        checkBool("영상 멈춰 is not hush", !pk.isHush("이거 영상 멈춰"))
        check(pk, "클로드한테 얘기해. 애플 인증서 받는 게 좋은지", .claude(target: "", message: "애플 인증서 받는 게 좋은지", newSession: true))
        check(pk, "그래 다 꺼", .closeOpened)   // 10/23: 「다 꺼」 = close what it opened
        check(pk, "너 꺼", .bye)
        check(pk, "기억해: 내 유튜브 채널은 거북이버프야", .remember("내 유튜브 채널은 거북이버프야"))
        check(pk, "됐어", .bye)
        check(pk, "너 꺼", .bye)
        check(pk, "시끄러워", .hush)
        check(pk, "엔터", .enter)
        check(pk, "받아써", .dictation)
        check(pk, "아빠 왔다", .greet)
        check(pk, "오늘 일정 정리해서 알려 줘", .none)
        checkBool("ko wake strip", pk.stripWake("자비스, 크롬 열어") == "크롬 열어")
        checkBool("ko wake strip 야", pk.stripWake("자비스야 엔터") == "엔터")
        checkBool("ko instant app", pk.instant("크롬 켜"))
        checkBool("ko not instant search", !pk.instant("맥미니 가격 검색해"))
        checkBool("크롬 꺼 is not bye", !pk.isBye("크롬 꺼"))

        // English
        check(pe, "open chrome", .openApp(spoken: "chrome", app: "Google Chrome"))
        check(pe, "search for mac mini price", .search("mac mini price"))
        check(pe, "play lofi music on youtube", .youtube("lofi music"))
        check(pe, "play the second one", .youtubeNth(2), yt: true)
        check(pe, "type hello world", .type("hello world"))
        check(pe, "ask claude code to review all my projects", .claude(target: "", message: "review all my projects", newSession: true))
        check(pe, "find usb c cable on amazon", .web(label: "Amazon", query: "usb c cable", url: "https://www.amazon.com/s?k="))
        check(pe, "that's all", .bye)
        check(pe, "daddy's home", .greet)
        checkBool("en wake strip", pe.stripWake("Hey Sasarisa, open chrome") == "open chrome")

        // Hands ask before send / pay / post / delete, and before handing work to a full-power Claude session
        checkBool("「카톡으로 보내 줘」 asked to send", Butler.userAskedFor("send", "엄마한테 카톡으로 보내 줘"))
        checkBool("「카톡 열어」 didn't ask to send", !Butler.userAskedFor("send", "카톡 열어서 엄마 채팅 찾아"))
        checkBool("「결제해」 asked to pay", Butler.userAskedFor("pay", "장바구니 결제해"))
        checkBool("「보내」 is not a pay request", !Butler.userAskedFor("pay", "이거 보내"))
        checkBool("plain host kept", Butler.safeHost("www.youtube.com"))
        checkBool("AppleScript-breaking host refused", !Butler.safeHost("x\" then\ntell current application to do shell script \"id"))
        checkBool("percent-encoded host refused", !Butler.safeHost("x%22%20then"))
        checkBool("MCP tap → jax line", Brain.commandLine("tap", ["name": "저장", "n": 2]) == "jax tap \"저장\" \"2\"")
        checkBool("MCP open_url → jax line", Brain.commandLine("open_url", ["url": "https://naver.com"]) == "jax open-url \"https://naver.com\"")
        checkBool("MCP steps are learnable", Learning.replayable([Brain.commandLine("open_url", ["url": "https://naver.com"])]) != nil)
        checkBool("MCP delegate is never learned", Learning.replayable([Brain.commandLine("delegate", ["session": "", "task": "x"])]) == nil)

        // Plug-in voices and brains: keys only over https, plain http only to this Mac
        var hv = Config(); hv.tts = "http"; hv.ttsURL = "http://127.0.0.1:5002/tts"
        checkBool("http voice on this Mac", Mouth.speechRequest(hv, "안녕")?.url?.absoluteString == "http://127.0.0.1:5002/tts")
        hv.ttsURL = "http://example.com/tts"
        checkBool("http voice elsewhere needs https", Mouth.speechRequest(hv, "안녕") == nil)
        var az = Config(); az.tts = "azure"; az.ttsRegion = "korea.central/../x"
        checkBool("azure region can't inject a host", Mouth.speechRequest(az, "안녕") == nil)
        checkBool("brain base: https ok", APIBrain.safeBase("https://openrouter.ai/api/v1") != nil)
        checkBool("brain base: local http ok", APIBrain.safeBase("http://127.0.0.1:11434/v1") != nil)
        checkBool("brain base: remote http refused", APIBrain.safeBase("http://evil.example/v1") == nil)
        var cc = Config(); checkBool("default brain is Claude Code", APIBrain.provider(cc) == nil)
        cc.brainProvider = "ollama"; checkBool("ollama brain", APIBrain.provider(cc)?.local == true)
        // 다 같이 키우기: only safe quick commands and short, number-free sentences are ever shared
        checkBool("share: volume down", GrowTogether.isShareable("소리 줄여", parser: pk))
        checkBool("share: close pages", GrowTogether.isShareable("창 다 꺼", parser: pk))
        checkBool("no share: a YouTube search", !GrowTogether.isShareable("유튜브에서 로파이 틀어", parser: pk))
        checkBool("no share: a Claude task", !GrowTogether.isShareable("클로드한테 버그 고쳐 줘", parser: pk))
        checkBool("no share: a timer label", !GrowTogether.isShareable("라면 3분", parser: pk))
        checkBool("no share: phone-number-like sentence", !GrowTogether.cleanSaid("010 1234 5678로 소리 줄여"))
        checkBool("share: short sentence", GrowTogether.cleanSaid("소리 좀 줄여 봐"))
        // Several Claude windows (titles = session names), 2026-10-24
        do {
            let wins = ["음성 제어 Mac 설정", "터틀메이커 전체 프로젝트", "터틀메이커 소개·튜토리얼 영상 시리즈 만들기", "홈페이지 터틀메이커 영상 칸을 새 시리즈로 교체", "잡일 시키기", "댓글 작업용 프로젝트"]
            checkBool("window: 댓글 작업", ClaudeRelay.clearBest("댓글 작업", titles: wins) == 5)
            checkBool("window: 잡일", ClaudeRelay.clearBest("잡일", titles: wins) == 4)
            checkBool("window: 음성 제어 맥 설정", ClaudeRelay.clearBest("음성 제어 맥 설정", titles: wins) == 0)
            checkBool("window: 터틀메이커 alone is a close call (model decides)", ClaudeRelay.clearBest("터틀메이커", titles: wins) == nil)
            checkBool("as said only when asked (10/25)", ClaudeRelay.isQuote("클로드에 이거 그대로 전달해", message: "이거") && !ClaudeRelay.isQuote("클로드에 버그 고치라고 전달해", message: "버그 고치라고"))
            checkBool("tidy-up that guesses is refused", ClaudeRelay.invented("지금 방금 얘기했던 거 버그 입력한 거 들어가서 고치라고 해", "지금 방금 이야기한 버그를 버그 입력 페이지에 등록한 내용을 들어가서 고쳐 주세요.") > 2)
            checkBool("spelling fixes are fine", ClaudeRelay.invented("어 그 썸네일 그거 다시 만들고 끝나면 텔레그렘으로 보내라고", "그 썸네일 다시 만들고, 끝나면 텔레그램으로 보내 주세요.") <= 2)
            checkBool("문이 → 문의 is fine", ClaudeRelay.invented("크몽 들어가서 문이 있는 거 확인하라 그래", "크몽 들어가서 문의가 있는지 확인해 주세요.") <= 2)
            checkBool("filler out", ClaudeRelay.stripFiller("어 그 썸네일 다시 만들어") == "썸네일 다시 만들어")
            checkBool("an order gets tidied", !ClaudeRelay.isQuote("클로드한테 버그 고치라고 해", message: "버그 고치라고 해"))
        }
        cc.brainProvider = "aside"; checkBool("aside brain is the CLI one", Brains.make(cc) is AsideBrain)
        cc.brainProvider = "codex"; checkBool("codex brain is the CLI one", Brains.make(cc) is CodexBrain)
        do {
            let a = CodexBrain.arguments(cc, prompt: "x")
            checkBool("codex: no shell, no user config, read-only, nothing saved",
                      a.contains("--ignore-user-config") && a.contains("--ephemeral") && a.contains("read-only")
                      && zip(a, a.dropFirst()).contains { $0 == "--disable" && $1 == "shell_tool" }
                      && zip(a, a.dropFirst()).contains { $0 == "--disable" && $1 == "unified_exec" }
                      && zip(a, a.dropFirst()).contains { $0 == "--disable" && $1 == "computer_use" })
            checkBool("codex: only the butler tool box, safe mode on", a.contains { $0.hasPrefix("mcp_servers.butler.command=") } && a.contains("mcp_servers.butler.env.MACBUTLER_SAFE=\"1\"") && a.last == "x")
            let b = CodexBrain(cfg: cc)
            b.handle(["type": "item.started", "item": ["type": "mcp_tool_call", "tool": "open_app", "arguments": ["name": "Safari"]]])
            b.handle(["type": "item.completed", "item": ["type": "agent_message", "text": "확인할게요."]])
            b.handle(["type": "item.completed", "item": ["type": "agent_message", "text": "사파리를 열었어요."]])
            checkBool("codex events parsed", true)
        }
        checkBool("aside answer = last paragraph", AsideBrain.answer("Opening tab\nsession: abc12345\n\n\u{1B}[32m쿠팡 최저가는 1만 2천 원이에요.\u{1B}[0m".replacingOccurrences(of: "\u{1B}[32m", with: "").replacingOccurrences(of: "\u{1B}[0m", with: "")) == "쿠팡 최저가는 1만 2천 원이에요.")
        checkBool("aside session id", AsideBrain.sessionID("Session ID: ses_9fA2kq") == "ses_9fA2kq")
        checkBool("aside strips colors", AsideBrain.clean("\u{1B}[1m완료\u{1B}[0m") == "완료")

        // Whisper sanity
        checkBool("whisper drops subtitle line", Whisper.clean("한글자막 by 한효정\n 헤이 자비스 지금 몇 시야?", apple: "헤이 자비스 지금 몇 시야") == "헤이 자비스 지금 몇 시야?")
        checkBool("whisper unrelated rejected", !Whisper.related("자비스, 이거 지금, 고맙습니다.", "됐어"))
        checkBool("whisper related kept", Whisper.related("한글 인식 자체가 생각보다 많이 안 돼.", "한글 이진식 자체가 생각보다 많이 안 돼"))
        for (said, want) in [("쿠팡의 맥미니 서치해봐", "web(label: \"쿠팡\", query: \"맥미니\""), ("알았어. 그러면 유튜브에 터틀메이커 검색해서 재생시켜봐", "youtube(\"터틀메이커\")"),
                             ("유튜브 로파이 틀어", "youtube(\"로파이\")"), ("멈춰, 영상", "media(play: false)"), ("YouTube 영상 멈춰", "media(play: false)"),
                             ("지금 틀어져 있는 영상들 다 꺼", "media(play: false)"), ("영상 다시 틀어", "media(play: true)"), ("멈춰", "hush"),
                             ("쿠팡 띄워서 Mac mini 찾아봐", "web(label: \"쿠팡\", query: \"Mac mini\""), ("쿠팡이 나에게 맞는 컴퓨터 찾아줘", "web(label: \"쿠팡\", query: \"나에게 맞는 컴퓨터\""),
                             ("쿠팡 에어팟 찾아 줘", "web(label: \"쿠팡\", query: \"에어팟\""), ("쿠팡 의자 찾아 줘", "web(label: \"쿠팡\", query: \"의자\""),
                             ("지금 켜져 있는 유튜브 창 꺼", "closeTabs(label: \"유튜브\""), ("YouTube 창 꺼 종료시켜", "closeTabs(label: \"유튜브\""),
                             ("자비스, 자비스, 클로드 창에다가 지금 버그 체크해서 다시 고쳐놓으라 그래", "claude(target: \"\""),
                             ("하이재비스 유튜브 참 켜", "youtube(\"\")"), ("YouTube창 켜", "youtube(\"\")"), ("유튜브 창 켜 봐", "youtube(\"\")"),
                             ("하이 재비스 쿠팡 열어", "web(label: \"쿠팡\", query: \"\""),
                             ("이제 화면 다 꺼", "displayOff"), ("화면 전체를 아예 꺼버리라고", "displayOff"), ("다음 영상으로 넘겨", "mediaNext"),
                             ("그래, 사파리 영상이 다 꺼. 유튜브 켜져 있는 화면 다 꺼.", "closeTabs(label: \"유튜브\""),
                             ("켜져있는 클로드에게 지금 버그 지금까지 된거 한번 더 체크해서 고치라고 해", "claude(target: \"\", message: \"지금 버그 지금까지 된거 한번 더 체크해서 고치라고 해\", newSession: false)"),
                             ("자비스야, 쿠팡 말고 유튜브 터틀메이커 검색해봐.", "youtube(\"터틀메이커\")"), ("아니, 유튜브에다가 터틀메이커 검색해줘.", "youtube(\"터틀메이커\")"),
                             ("지금 켜져 있는 창들 다 꺼줘.", "closeOpened"), ("창 다 꺼", "closeOpened"), ("아니 취소", "hush"),
                             ("지금 켜져 있는 유튜브 뒤로 가기 누르라고", "browser(\"back\")"), ("소리 키워", "volume(set: nil, delta: 15"), ("볼륨 30으로 해", "volume(set: Optional(30)"),
                             ("몇 시야", "clock(date: false)"), ("오늘 며칠이야", "clock(date: true)"), ("다 끄라고", "closeOpened"),
                             ("라면 3분", "timer(seconds: 180, label: \"라면\")"), ("10분 뒤에 알려 줘", "timer(seconds: 600"), ("1시간 30분 후에 회의라고 알려 줘", "timer(seconds: 5400, label: \"회의\")"),
                             ("3분짜리 영상 찾아 줘", "search("), ("타이머 취소", "cancelTimers"), ("강남역 가는 길", "map(\"강남역\")"), ("지금 어디야", "none"),
                             ("로파이 틀고 소리 줄이고 화면 꺼", "multi([\"로파이 틀어\", \"소리 줄여\", \"화면 꺼\"])"), ("로파이 틀어", "youtube(\"로파이\")"),
                             ("쿠팡 열고 클로드에 버그 고치라고 해", "none"),
                             ("앞으로 작업 시작 하면 클로드 열고 로파이 틀고 소리 30으로 해", "makeRoutine(name: \"작업 시작\", steps: [\"클로드 열어\", \"로파이 틀어\", \"소리 30으로 해\"])"),
                             ("작업 시작이라고 하면 카톡에 보내고 결제해", "badRoutine("), ("쿠팡 열면 맥미니 찾아", "web(label: \"쿠팡\", query: \"맥미니\""),
                             ("이거 존댓말로 바꿔", "rewrite(\"polite\")"), ("선택한 거 영어로 번역해 줘", "rewrite(\"en\")"), ("맞춤법 고쳐 줘", "rewrite(\"spell\")"),
                             ("영어로 된 영상 찾아 줘", "search("), ("존댓말이 뭐야", "none"),
                             ("방금 거 취소", "undo"), ("되돌려 줘", "undo"), ("방금 뭐 했어", "whatDid"), ("로그인 버그 고치고, 아니, 취소", "hush"),
                             ("3 minute timer", "timer(seconds: 180"), ("set a timer for 10 minutes", "timer(seconds: 600"), ("remind me in 20 minutes to stretch", "timer(seconds: 1200, label: \"stretch\")"),
                             ("make this more polite", "rewrite(\"polite\")"), ("translate this to english", "rewrite(\"en\")"),
                             ("지금 떠있는 클로드 창에 이제 시작한다고 말해줘", "claude(target: \"\", message: \"이제 시작한다고 말해줘\", newSession: false)")] {
            checkBool("parse: \(said)", "\(pk.parse(pk.stripWake(said), hasYouTubeList: true))".hasPrefix(want))
        }
        checkBool("whisper repeated tail dropped", Whisper.dropRepeatedTail("맥미니 M6 찾아. 고팩! 고팩! 고팩!", apple: "Mac mini MS 찾아").0 == "맥미니 M6 찾아.")
        checkBool("whisper YouTube = 유튜브", Whisper.related("지금 켜져 있는 유튜브 창 꺼.", "자비스 지금 켜져 있는 YouTube 창 꺼"))
        do {   // breath vs voice: a 140 Hz voice-like tone with harmonics is voiced; dark noise (a puff on the mic) isn't
            var voice = [Float](repeating: 0, count: 1600), puff = [Float](repeating: 0, count: 1600), acc: Float = 0
            for i in 0..<1600 {
                let t = Float(i) / 16000
                voice[i] = 0.1 * (sin(2 * .pi * 140 * t) + 0.5 * sin(2 * .pi * 280 * t) + 0.3 * sin(2 * .pi * 420 * t))
                acc = acc * 0.97 + Float.random(in: -1...1); puff[i] = acc * 0.01
            }
            checkBool("voice is voiced", voice.withUnsafeBufferPointer { DoubleTalk.periodicity($0.baseAddress!, 1600) } > DoubleTalk.voiced)
            checkBool("breath is not voiced", puff.withUnsafeBufferPointer { DoubleTalk.periodicity($0.baseAddress!, 1600) } < DoubleTalk.voiced)
        }
        checkBool("sentence sounds finished", Ear.soundsFinished("유튜브 로파이 틀어") && Ear.soundsFinished("몇 시야?") && !Ear.soundsFinished("유튜브에서") && !Ear.soundsFinished("그리고"))
        checkBool("brain started a video", Parser.startedMedia("사파리에서 유튜브에 터틀메이커를 검색해 첫 영상을 재생했습니다."))
        checkBool("brain paused a video", !Parser.startedMedia("영상을 일시정지했습니다."))
        checkBool("whisper shaky word → Apple text", !Whisper.shaky([("자비스,", 0.9), ("신별시야.", 0.2)], apple: "자비스 지금 몇 시야").isEmpty)
        checkBool("whisper sure word kept", Whisper.shaky([("한글", 0.9), ("인식", 0.6)], apple: "한글 이진식").isEmpty)
        checkBool("whisper shaky word Apple also heard", Whisper.shaky([("코덱스", 0.2)], apple: "코덱스 켜").isEmpty)

        // Learning: only safe action steps are replayable
        checkBool("learn jax key", Learning.replayable(["jax front", "jax key space"])?.count == 1)
        checkBool("learn rejects shell", Learning.replayable(["jax key space; rm -rf ~"]) == nil)
        checkBool("learn rejects delegate", Learning.replayable(["butler delegate \"|x\""]) == nil)
        checkBool("learn rejects click", Learning.replayable(["jax click 10 10"]) == nil)
        checkBool("tokens quoted", Learning.tokens("jax tap \"Save as\" 2") == ["jax", "tap", "Save as", "2"])

        // Growth: names are studied, verbs are not
        checkBool("study ignores verbs", !Growth.words("크롬 열어 줘").contains("열어") || Growth.study(whisper: "열어", live: "x", known: []).isEmpty)
        checkBool("words latin", Growth.words("open ComfyUI now").contains("ComfyUI"))

        // Korean reading for TTS
        let kr: [(String, String)] = [
            ("오후 3시 16분입니다", "오후 세 시 십육 분입니다"), ("1,399,900원", "백삼십구만 구천구백 원"), ("사과 2개", "사과 두 개"),
            ("10월 23일", "시월 이십삼 일"), ("M4 맥미니", "엠포 맥미니"), ("24GB", "이십사 기가"), ("30%", "삼십 퍼센트"),
            ("2026년", "이천이십육 년"), ("17분 10초", "십칠 분 십 초"), ("20명", "스무 명"), ("1.5배", "일 점 오 배"), ("10000원", "만 원")]
        for (a, b) in kr { checkBool("read \(a) → \(KoreanReader.read(a))", KoreanReader.read(a) == b) }

        // YouTube parser
        let html = #""videoRenderer":{"videoId":"abcdefghijk","thumbnail":{},"title":{"runs":[{"text":"First video"}]}"#
        checkBool("youtube parse", Butler.parseYouTube(html).first?.id == "abcdefghijk")

        print(fails == 0 ? "selftest: all \(total) passed" : "selftest: \(fails)/\(total) failed")
        return fails == 0
    }
}
