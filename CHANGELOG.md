# Changelog

## Unreleased
- **Make images and videos with Higgsfield by voice, saving credits:** 「힉스필드로 … 만들어」 → the cheapest plan and its price first (0 credits) → made once after 「응」 → saved to ~/Movies|Pictures/Sasarisa. A guard blocks unpriced, unapproved, multi-output and repeat generations; a per-job cap (50 credits) and a history to reuse earlier results. `MacButler --hf "<request>" [--make]` does the same from the terminal

## 0.7.2 — 2026-10-26 · Runs on macOS 14 Sonoma and Intel Macs, much faster replies
- **Opens on macOS 14 (Sonoma) and 15 again, and on Intel Macs:** 0.7.1 was built for macOS 27 only, so it wouldn't start on older macOS even though macOS 14 was listed. The app is now one universal file (Apple silicon + Intel) for macOS 14 and later
- **Much faster after you speak:** commands now go to the front of the transcription queue, and stray sounds (claps, a recording app, people talking) are no longer all transcribed in the background — commands waited 5–26 s behind them. Simple commands (close tabs, back, volume, what time, KakaoTalk send) run on the live text right away
- **New quick commands, no AI round-trip:** 「빨리 감기」「30초 되감기」 (YouTube), 「네이버 메일 열어」「지메일 들어가자」, 「네 번째 메일 열어」 (Naver Mail), 「카톡 전송 눌러」, and routes like 「서귀포에서 제주시로 가는 길」 open a directions map
- **KakaoTalk:** 「카톡 창에 △△라고 입력해」 only types △△ (doesn't send); 「…입력해서 엔터까지 쳐」 sends; 「카톡창 열려있잖아. 거기에다가 △△라고 말해」 sends only △△; a command before it (「유튜브 창 다 끄고 카톡에 …」) runs first
- **A muted mic is shown:** if the mic sends pure silence for 2 minutes (e.g. its mute button is on), a card says so — no sound, in case you're recording
- **Listens on the mic you chose** even when AirPods or a recording app take over the Mac's default input; restarts calm down instead of looping
- Fixes: 「뒤로 가서 네 번째 메일 클릭해」 does both; 「땡큐」「피니쉬」 end the conversation; your own channel name (「거북이 버프입니다」) no longer wakes it; the Claude window is found even with its sidebar collapsed; 1–3 letter scraps after the name just listen instead of asking the AI

## 0.7.1 — 2026-10-25 · Name it like Siri, any AI, combo brain
- **Name your assistant first, like “Hey Siri”:** the setup window now starts with its name, what it calls you, and a **voice check** — say the name 8 times and with a short command 4 times; it learns how *your* voice comes out on *this* Mac (also in Settings → 목소리로 이름 맞추기). It shows how often it was understood before and after, and suggests another name if it's still poor. A name typed in Hangul gets the same sound-alikes as its Latin spelling
- **Pick everything in setup:** the brain (installed ones marked ✓), the voice (with a preview) and where the card shows up — choosing a place moves the real card there for a moment. The card now sits **in the middle of the screen** by default (no resting orb there); bottom center (above the Dock), bottom right, bottom left and top center are one click away
- **Greeting screen in three styles** (Settings → 인사 화면, with a preview): flashy (default), calm (orb, name and greeting only) or card only — and its title is your assistant's name now (it still said MAC BUTLER)
- **An app icon** (the orb and rings) — System Settings showed a blank one; Sasarisa now also appears in the Screen Recording list when you open it from setup
- **Any AI, not just Claude:** setup passes with any one brain (Claude Code, Codex, Aside, an API key or a local model); if the default Claude Code isn't installed, an installed Codex or Aside is used automatically
- **Combo brain (free, best on a high-end Mac):** Settings → 조합 — web errands go to Aside, coding to Claude Code, the rest to Codex, each on your own plan
- **Safer and more honest:** bringing the Claude app to the front works (pressing/typing inside it stays blocked); deleting mail or messages is asked about instead of refused (emptying the trash is still never done); the brain only says it did what a tool really did, and every tool call is logged
- **KakaoTalk replies by voice:** 「카톡 ○○님한테 △△라고 답장해」 — Sasarisa finds that chat window (a name that sounds close counts, but a short name may differ by one sound only), puts the words in its input box and sends after your 「응」; if the chat isn't open, the words wait on the clipboard and 「열어놨어」 tries again
- **Messages to Claude are tidied so Claude understands** — your words, cleaned up; 「너」 said to the assistant becomes “Sasarisa (the voice assistant)”, and asking it to look at your conversation adds where the log is. Exactly as said only when you say 「그대로」
- **Faster:** reading a chat app's screen no longer walks every message bubble (KakaoTalk: 10+ s → 0.05 s); “backspace” is a known key
- **Nothing said is lost:** if a Claude window or its input box can't be found (e.g. after a Claude update), the message waits on the clipboard for ⌘V
- Fixes: 「싸싸리싸.com 들어가」 no longer drops the name (it opens sasarisa.com); a cut-short live transcript isn't trusted over Whisper; learned steps that fail log where; memory and CPU are logged hourly
- README demo plays all scenes again

## 0.7.0 — 2026-10-24 · Mac Butler is now **Sasarisa (사사리사)**
- New name, one word you can say: 「사사리사」 / “Sasarisa” is the default name and wake word (heard as 사사리사·샤샤리사·싸싸리사; 「자비스」 keeps working for people who used it). Home: **sasarisa.com**
- Your settings (`~/.macbutler`), saved keys, Pro link and learned commands carry over; the app is now `Sasarisa.app` (the old `MacButler.app` is removed by the installer)
- Downloads: `releases/latest/download/Sasarisa.zip` (the old `MacButler.zip` link still works) · Homebrew: `brew install --cask mvcompany8500-web/tap/sasarisa`
- Also in this release: everything listed under 0.6.8 below

## 0.6.8 — 2026-10-24 (shipped as part of 0.7.0)
- **Pick your brain, signed in on this Mac:** Codex (your ChatGPT plan) and Aside join Claude Code, Ollama and LM Studio; API-key services moved to an “API key” submenu. Everything local stays free
- **Talk to the right Claude window:** 「클로드 ○○ 프로젝트에 …」 finds that window among many and sends a tidied message (your words, first person, slips fixed); 「…라고 전달해」 stays verbatim. **Preview before sending** (Settings): it waits in the box until you say 「응」
- **Several jobs in one breath:** 「쿠팡에서 맥미니 검색하면서 베토벤 틀어봐. 볼륨은 적당하게」 → Coupang search · YouTube · volume 50 — searches never carry the other jobs
- **Free mode** (Settings, or asked once after a confirmed send): sends, posts, deletes and hand-offs go without asking — payments always ask
- **Grow together** (asked once): short sentences it understood and the safe quick command they ran, no names, once a day; a phrase reaches everyone only when 5+ installs on 3+ networks agree
- **AI usage in Settings:** how full your Claude / Codex plan is (5-hour and 7-day windows) and how much the assistant itself used (7-day chart)
- **Your assistant's name is its wake word** (a Latin name is also heard in Hangul: sasarisa → 사사리사); voice preview button; Settings save as you change them and the on-screen position moves at once
- **Pro (membership, optional):** natural voices (Korean Teo / Hana / Sun, English Christina / Brian) and calling your Mac from your phone — linked with a code, a key in the Keychain only; phone requests never pay
- Fixes: a new video closes the old one; 「유튜브 꺼」 closes the page; 「창 다 꺼」 closes only the pages it opened; restart from Settings no longer leaves it off; it no longer learns from runs that failed or from closing keys

## 0.6.7 — 2026-10-24
- Fix: when Whisper's version was set aside as "unsure" but is a known command (「자비스, 아파트」 vs Apple's 「버드」), it's used; otherwise the brain sees both versions
- 「세 번째 영상 찍어/눌러/클릭해」 = play the 3rd video; the fast router skips a late answer instead of restarting (no cold start next time)
- New README hero and demo (`docs/make-demo.sh` renders the demo from the real HUD, off-screen); Mac first — Windows later

## 0.6.6 — 2026-10-24
- **Faster turn-taking:** a sentence that clearly ended (…해/줘/틀어/?) runs after 0.9 s instead of the full pause; a soft sound the moment a request goes to the brain; a fresh brain is swapped in right after a heavy turn instead of on your next question (a 100k-token turn took 32 s, a fresh one ~7 s)
- **Fast router:** a small model (Haiku) runs *alongside* the brain and maps loose phrasing (「너무 시끄럽다 좀 작게」 → 소리 줄여) to a quick command; if it wins before the brain acts, the brain is cancelled. Mappings are remembered → instant next time; 「아니」 forgets one
- **Routines by voice:** 「앞으로 '작업 시작' 하면 클로드 열고 로파이 틀고 소리 30으로 해」 → 「작업 시작」 (quick commands only)
- **Rewrite the selection:** 「이거 존댓말로 바꿔」, 「영어로」, 「짧게」, 「맞춤법 고쳐」 — pastes over the selection, never sends, ⌘Z undoes; refused in password fields
- **Pauses in calls:** while Zoom / FaceTime / Teams / Meet in a browser / KakaoTalk (or Handy) records from the mic, it stops listening; the hotkey still works
- **「되돌려」 / 「방금 뭐 했어?」:** undo the last quick action (volume, a page it opened, a timer, a rewrite), or hear what it just did

## 0.6.5 — 2026-10-23 · security
- **Hand-offs Claude proposes always wait for your spoken yes** (in every mode). Your own 「클로드한테 …」 still goes straight through
- **Send / pay / post / delete** buttons, Enter in messengers and web forms, ⌘/⌃+Enter are held until you say yes (or say it holding the hotkey); brain-typed line breaks become spaces; never types into password fields
- Fix: a crafted page address could inject AppleScript through 「다 꺼」 — only plain host names are remembered now
- Memory and past conversation are given to the brain as facts, not instructions; every press/type/open is logged (logs/actions.log)
- **Any brain, any voice:** the hands are an MCP tool server (`butler-mcp`) so every brain gets the same guarded tools — Claude Code (default) or API brains (Anthropic, OpenAI, Gemini, OpenRouter, Groq, Ollama, LM Studio, OpenAI-compatible); voices: macOS, ElevenLabs, OpenAI, Azure, your own server. Keys live in the Keychain
- `MacButler --ask "…"` runs one request without the mic

## 0.6.4 — 2026-10-23
- **Timers & reminders:** 「라면 3분」, 「10분 뒤에 알려 줘」, 「5시에 회의 알려 줘」, 「타이머 취소」 — chime + spoken reminder, kept across restarts; reminders never act on their own
- **Naver Map:** 「강남역 가는 길」, 「서울역 어떻게 가」, 「○○ 어디야」
- **Several commands in one sentence:** 「로파이 틀고 소리 줄이고 화면 꺼」 runs each right away, in order (anything it can't do alone → Claude takes the whole sentence)
- Quick: 「뒤로 가」/「앞으로」/「새로고침」, 「소리 키워/줄여」, 「볼륨 30」, 「음소거」, 「몇 시야」, 「오늘 며칠이야」, 「다 꺼」, 「로파이 틀어」 (= YouTube)
- After each press, Claude sees what's in front now (no extra screenshot); sentences it couldn't do alone are logged so new quick rules can be added (`MacButler --misses`)

## 0.6.3 — 2026-10-23
- **Acts right away by default** (like a car assistant): no "shall I?" questions; it does the most likely thing and you correct it with 「아니」. Settings → Basics → 「실행 방식」 switches to ask-first. Sending, paying and deleting always ask once
- **Faster, lighter brain:** only the tools it uses are described to Claude and no skill list — ~34k → ~10k tokens a turn, about 1.3 s faster
- Claude is told the page in front (title + URL) and what Mac Butler opened, so 「그거」, 「뒤로 가」 need no extra look
- 「창 다 꺼」 closes what it opened for you (pages by exact site, apps it started) — never Claude, Finder, terminals or editors
- Understands 「쿠팡 말고 유튜브 …」, 「유튜브에다가」, 「아니, …」 corrections, 「…검색해봐」
- Opens links in **Safari** by default (every Mac has it; set `browserApp` for Chrome). If Safari's autoplay block leaves a YouTube video paused, it presses play once
- The orb & card now sit in the bottom-right corner by default (out of the way of what you're doing); bottom-left / top in Settings → Basics

## 0.6.2 — 2026-10-23
- Fix: breathing into the mic stopped it mid-answer. Cutting in now also needs a voice-like pitch (breath, a bump or a puff on the mic don't have one) — checked on 1,391 chunks of real speech vs. noise

## 0.6.1 — 2026-10-23
- Fix: the first word went missing when the live recognizer split a sentence (「하이 자비스 / 아멜리아 먹방…」 → 「먹방…」)
- Whisper output that heard a video or other people (dialogue lines, far longer than what you said) falls back to the live text
- Cutting in over speakers is stricter (someone else talking or a video won't cut it off); the wake word / hotkey always works
- A stray word from someone in the room no longer cancels what Claude is doing; corrections (「아니 …」) aren't learned as commands
- New: 「화면 꺼」 (display off), 「다음 영상」 (⏭), 「유튜브 화면 꺼」 closes those tabs, 「켜져 있는 클로드에게」 = current window

## 0.6.0 — 2026-10-23
- **Works out of the box with the built-in macOS voice** — free, offline; picks the most natural installed voice (Premium > Enhanced > Yuna/Samantha). Setup shows how to get a free Premium voice. ElevenLabs stays optional (the demo video's voice)
- **Cut in over speakers** — no headphones needed: it compares the mic with how loud it is talking, and ignores a video playing in the room (`--echotest` checks your room)
- **Korean read aloud correctly** — 「3시 16분」→「세 시 십육 분」, 「10월」→「시월」, 「M4」→「엠포」, money, units
- **Video control:** 「영상 멈춰」, 「유튜브 꺼」, 「다시 틀어」 (⏯, only when something is playing); 「유튜브 창 꺼」 closes those tabs; after a video starts it stops listening so the video isn't taken as commands
- **Commands:** 「유튜브에 ○○ 검색해서 재생시켜」, lead-ins like 「알았어. 그러면」 dropped, 「쿠팡의/쿠팡이 …」, 「띄워서」, a follow-up search stays on the same shop, 「지금 떠 있는 클로드 창」, misheard wake words (「하이 재비스」)
- **Recognition:** utterance audio no longer cut by a click after you finish; Whisper's shaky words and repeated made-up tails fall back to the live text; YouTube = 유튜브 when comparing; optional `keepAudio` keeps the last 30 utterances locally for tuning
- Remembers past conversations (`memory.md` + recent log); shorter spoken answers (one sentence)
- On-screen orb & card can sit top / bottom-right / bottom-left (Settings → Basics)

## 0.5.1 — 2026-10-23
- Fix: the mic could get stuck restarting after audio changes (stopped hearing the wake word) — now restarts only when it really stopped, with a fresh engine and a 3 s debounce; recognizer stall detection
- Choose microphone and speaker in Settings (`--devices` lists them)
- Claude sees both transcripts when Whisper and live recognition disagree; quick commands fall back to the live text
- Grows: missed words are studied into the vocabulary; stale learned commands and temp files are swept; progress in the menu

## 0.5.0 — 2026-10-23
- **Push-to-talk:** hold right ⌥ and talk, release to run (exact audio, like Handy); tap still wakes. New `activation: "hold"` = hotkey only, nothing transcribed otherwise
- **Setup window** on first launch: live permission checklist, one-click fixes, in-app Whisper download with SHA-256 check
- **Learns:** steps Claude found once are replayed instantly next time (no Claude call); “아니/no” right after = don't learn; menu shows today's calls/tokens and can forget everything
- **Interrupt anytime:** a new command while Claude works replaces the old one; trailing 「아니 취소」 cancels; 0.8 s cancel window before sending to Claude; pasting instead of slow typing
- **Recognition:** mic restarts automatically after audio changes (the “stops responding after a while” bug), VAD utterance start, Whisper hallucination/unrelated-text filter, Handy vocabulary import, filler removal
- **12 languages:** ko, en, ja, zh, es, fr, de, pt, it, vi, th, id (Claude answers in your language); defaults to the Mac's language
- Spoken Claude hand-offs go straight through; confirmation only when the assistant proposes one; 「지금 켜진 클로드 창에」 targets the current session; `butler session`

## 0.4.0 — 2026-10-23 · security hardening
- **Safe mode (default):** Claude gets a fixed tool allowlist — no arbitrary shell, file writes, URL fetching or MCP; user Claude settings aren't loaded (`brainAccess: "full"` to opt out)
- `jax`/`jtype` refuse to press/type/click in terminals, code editors, Claude, System Settings, Keychain, password managers and permission prompts; `jax open-app`, `open-url` (http/s only), `screenshot`, `click`, `key`, `volume`, `front`
- Handing a task to Claude Code asks for a spoken yes first (`confirmDelegate`)
- Commands from tools go over an owner-only Unix socket with peer-uid check (replaces public distributed notifications)
- Whisper on a random loopback port, used only while our own process is alive; pid-file cleanup
- `~/.macbutler` is 0700, logs 0600 and rotated at 5 MB
- Model download verifies SHA-256; CI pinned + read-only; SECURITY.md
- Shopping & site search: 쿠팡 / 네이버 쇼핑 / 네이버 / 구글 / 아마존, 「○○ 최저가」
- Releases signed with Developer ID and notarized

## 0.3.0 — 2026-10-23
- Settings window (menu → Settings…, ⌘,): language, name, wake words, voice, hotkey, Claude model — saves to config.json (other keys kept) and restarts
- `butler settings` opens it from the command line
- Boot log title keeps word spacing (“MAC BUTLER · BOOT SEQUENCE”)

## 0.2.0 — 2026-10-23
- Renamed **My Jarvis → Mac Butler** (repo `mac-butler`, app `MacButler.app`, settings `~/.macbutler`, CLI `butler`).
  The assistant still answers to “Jarvis” by default; `~/.myjarvis` is moved automatically on first launch.
- README: demo GIF, one-line install, Homebrew tap, CI badge; non-affiliation notice
- CI: build + `--selftest` on every push

## 0.1.0 — 2026-10-23
First public version.
- Always-on wake word (Apple on-device speech) + Whisper large-v3-turbo for accurate text
- Warm Claude Code brain (stream-json), answers spoken via macOS `say` or ElevenLabs
- Quick commands (ko/en): open apps, web search, YouTube play / “the second one”, type, dictation
- Hand tasks to a new Claude Code session in the Claude app — by Accessibility, no mouse movement
- Barge-in, conversation mode, right-⌥ hotkey, status/permission checklist in the menu
- Wake-up animation, HUD orb, `--selftest`
