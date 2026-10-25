// 조합 두뇌 (owner 10/25: 「고사양 컴퓨터 옵션으로 코덱스 + 클로드 + 어사이드까지 조합해서 고를 수 있게」 → 「조합 무료에
// 고사양 맥 된다고 하던가 해」). Each task goes to the brain that's best at it: web errands to Aside's browser agent,
// coding and anything about a Claude session to Claude Code, everything else to Codex. Each runs on the owner's own plan,
// so it costs Sasarisa nothing — it's free. Several agents side by side want memory, so Settings recommends it for
// Apple silicon with 16 GB or more. A brain that isn't installed is skipped; the task goes to one that is.
import Foundation

final class ComboBrain: Thinker {
    private let parts: [(name: String, brain: Thinker)]
    private var current: Thinker?
    private(set) var lastPick = ""

    init(cfg: Config) {
        var p: [(String, Thinker)] = []
        let codex = CodexBrain(cfg: cfg); if codex.installed { p.append(("codex", codex)) }
        let claude = Brain(cfg: cfg); if claude.installed { p.append(("claude", claude)) }
        let aside = AsideBrain(cfg: cfg); if aside.installed { p.append(("aside", aside)) }
        parts = p
    }
    /// Apple silicon with 16 GB or more — where running these agents side by side stays smooth.
    static var highSpec: Bool {
        #if arch(arm64)
        return ProcessInfo.processInfo.physicalMemory >= 16 << 30
        #else
        return false
        #endif
    }
    /// Which brain a task wants: "aside" (web errands), "claude" (coding), "codex" (the rest).
    static func pick(_ command: String) -> String {
        let s = command.lowercased()
        let coding = ["코드", "코딩", "버그", "빌드", "배포", "커밋", "깃허브", "github", "함수", "에러", "리팩", "스크립트", "프로그램 짜", "앱 만들",
                      "클로드", "claude", "xcode", "terminal", "code", "bug", "build", "deploy", "commit", "refactor", "script"]
        let web = ["사이트", "홈페이지", "웹", "들어가", "접속", "로그인", "메일", "쿠팡", "스레드", "인스타", "스튜디오", "네이버", "구글", "예약", "주문",
                   "장바구니", "페이지", "브라우저", "댓글", "검색해서", "찾아서", "가격 비교", "website", "site", "page", "browser", "mail", "order",
                   "book a", "comment", "log in", "sign in", "amazon"]
        if coding.contains(where: { s.contains($0) }) { return "claude" }
        if web.contains(where: { s.contains($0) }) { return "aside" }
        return "codex"
    }
    private func brain(for want: String) -> (String, Thinker)? {
        let order = ["claude": ["claude", "codex", "aside"], "aside": ["aside", "codex", "claude"]][want] ?? ["codex", "claude", "aside"]
        for n in order { if let b = parts.first(where: { $0.name == n }) { return (n, b.brain) } }
        return nil
    }

    var busy: Bool { parts.contains { $0.brain.busy } }
    var installed: Bool { !parts.isEmpty }
    var lastCommands: [String] { current?.lastCommands ?? [] }
    var names: [String] { parts.map(\.name) }
    func warm() { brain(for: "codex")?.1.warm() }          // only the everyday one; the others start when a task needs them
    func ask(_ command: String, live: String, frontApp: String, context: String, step: @escaping (String) -> Void, done: @escaping (String) -> Void) {
        guard let (name, b) = brain(for: ComboBrain.pick(command)) else { done(""); return }
        current = b; lastPick = name
        log("combo → \(name): \(command.prefix(80))")
        b.ask(command, live: live, frontApp: frontApp, context: context, step: step, done: done)
    }
    func stop() { parts.forEach { $0.brain.stop() } }
    func cancel(silently: Bool) { current?.cancel(silently: silently) }
}
