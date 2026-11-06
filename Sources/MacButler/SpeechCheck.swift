// Can Apple's speech recognizer write anything on this Mac right now? A short line made by `say` into a file (never
// played aloud) is recognized the way the app listens (on-device when possible). 11/6 iMac M1 「불러도 반응을 안 합니다」:
// with Siri and Dictation off the recognizer fails at once (kLSRErrorDomain 201), and without this language's
// on-device files it fails with 102 — the app looked alive and heard nothing.
import Foundation
import Speech

enum SpeechCheck {
    /// nil = works (or heard the file as silence — the engine itself runs); otherwise the recognizer's error.
    static func run(locale: String, done: @escaping (NSError?) -> Void) {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("sasarisa-speechcheck-\(getpid()).aiff")
        DispatchQueue.global(qos: .utility).async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-o", f.path, locale.hasPrefix("ko") ? "안녕하세요, 지금 몇 시예요" : "hello, what time is it"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            DispatchQueue.main.async {
                guard let rec = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
                    done(NSError(domain: "Sasarisa", code: -1, userInfo: [NSLocalizedDescriptionKey: "no recognizer for \(locale)"])); return
                }
                let r = SFSpeechURLRecognitionRequest(url: f)
                if rec.supportsOnDeviceRecognition { r.requiresOnDeviceRecognition = true }
                var finished = false
                let end = { (e: NSError?) in
                    guard !finished else { return }
                    finished = true; try? FileManager.default.removeItem(at: f); done(e)
                }
                rec.recognitionTask(with: r) { res, err in
                    DispatchQueue.main.async {
                        _ = rec                                                    // keep the recognizer alive for the task
                        if let err = err as NSError? { end(err.code == 1110 ? nil : err) }      // 1110 = no speech: the engine ran
                        else if res?.isFinal == true { end(nil) }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                    end(NSError(domain: "Sasarisa", code: -2, userInfo: [NSLocalizedDescriptionKey: "no answer in 20 s"]))
                }
            }
        }
    }
    /// In words, for the doctor and the setup window.
    static func describe(_ e: NSError?, ko: Bool) -> String {
        guard let e else { return ko ? "됨" : "works" }
        switch e.code {
        case 201: return ko ? "안 됨 — 받아쓰기·Siri 가 꺼져 있음 (시스템 설정 → 키보드 → 받아쓰기 켜기)" : "fails — Siri and Dictation are off (System Settings → Keyboard → Dictation)"
        case 102: return ko ? "안 됨 — 이 언어의 음성 인식 파일이 없음 (받아쓰기를 켜고 언어 추가)" : "fails — this language's speech files are missing (turn on Dictation with it)"
        default: return (ko ? "안 됨 — " : "fails — ") + "\(e.domain) \(e.code) · \(e.localizedDescription)"
        }
    }
}
