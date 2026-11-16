// A newer Sasarisa is out → say so once (a card) and keep a menu item until it's installed. Bug fixes only reach
// people who update, and nothing told them (11/16: 4 of 12 Macs still ran 0.7.1–0.7.3). One small file from our own
// homepage (sasarisa.com/latest.json), at launch and twice a day — no id, nothing about you.
import AppKit

enum Update {
    static let url = URL(string: "https://sasarisa.com/latest.json")!
    static let page = URL(string: "https://github.com/mvcompany8500-web/sasarisa/releases/latest")!
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    /// The newer version, once one has been seen (main thread).
    private(set) static var available: String?

    /// 0.7.10 > 0.7.9: compared number by number.
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
    /// Installed with Homebrew: the update is one command, not a download.
    static var viaBrew: Bool { ["/opt/homebrew/Caskroom/sasarisa", "/usr/local/Caskroom/sasarisa"].contains { FileManager.default.fileExists(atPath: $0) } }

    /// `first`: called on the main thread the first time a given newer version is seen on this Mac (show a card then).
    static func check(first: @escaping (String) -> Void) {
        URLSession.shared.dataTask(with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)) { data, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let v = o["version"] as? String,
                  v.count <= 20, newer(v, than: current) else { return }
            DispatchQueue.main.async {
                available = v
                log("update: \(v) is out (this is \(current))")
                if UserDefaults.standard.string(forKey: "updateNotified") != v {
                    UserDefaults.standard.set(v, forKey: "updateNotified")
                    first(v)
                }
            }
        }.resume()
    }
    /// The menu item: Homebrew → the command is copied and Terminal opens; otherwise the release page with the download.
    static func open() {
        if viaBrew {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString("brew upgrade --cask sasarisa", forType: .string)
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        } else { NSWorkspace.shared.open(page) }
    }
}
