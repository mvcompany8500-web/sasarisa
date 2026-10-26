// Talk to the running Sasarisa.   butler <say|type|delegate|settings> [text]
//   say       "open chrome"            — run a command as if spoken
//   type      "hello"                  — type into the focused field, character by character
//   delegate  "session name|task"      — hand a task to Claude (empty session name = new session)
//   settings  [close]                  — open (or close) the settings window
//   session   "name"                   — switch the Claude app to that session (no typing)
// Uses a private Unix socket (owner-only); other users and sandboxed apps can't send commands.
import Foundation

/// Sends "<cmd>\n<text>" to the running Sasarisa over its private socket (~/.macbutler/butler.sock).
func butlerSend(_ cmd: String, _ text: String) -> String? {
    let home = ProcessInfo.processInfo.environment["MACBUTLER_HOME"].map { ($0 as NSString).expandingTildeInPath } ?? (NSHomeDirectory() + "/.macbutler")
    let p = home + "/butler.sock"
    let s = socket(AF_UNIX, SOCK_STREAM, 0)
    guard s >= 0 else { return nil }
    defer { close(s) }
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(p.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = b }; raw[bytes.count] = 0 }
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard ok == 0 else { return nil }
    let msg = Array((cmd + "\n" + text).utf8)
    _ = msg.withUnsafeBytes { write(s, $0.baseAddress, msg.count) }
    shutdown(s, SHUT_WR)
    var b = [UInt8](repeating: 0, count: 64); let n = read(s, &b, 64)
    return n > 0 ? String(decoding: b[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""
}

/// butler hf-guard <state.json> — a Claude Code PreToolUse hook for Higgsfield (10/26: credits are money).
/// Reads the hook's JSON on stdin. A generate_* call with "get_cost": true (price only) always passes. Otherwise only in
/// "generate" mode, only the approved tool and model, one output, once. Exit 2 = blocked (the reason goes to the AI).
func hfGuard(_ statePath: String) -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let hook = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
    let tool = (hook["tool_name"] as? String ?? "").replacingOccurrences(of: "mcp__higgsfield__", with: "")
    let ti = hook["tool_input"] as? [String: Any] ?? [:]
    var params = ti["params"] as? [String: Any] ?? [:]
    if let str = ti["params"] as? String, let d = str.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { params = o }
    func block(_ why: String) -> Never { FileHandle.standardError.write((why + "\n").data(using: .utf8)!); exit(2) }
    guard tool.hasPrefix("generate_") else { exit(0) }
    if params["get_cost"] as? Bool == true { exit(0) }
    let url = URL(fileURLWithPath: statePath)
    guard let d = try? Data(contentsOf: url), var st = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { block("Blocked: no approved generation. Price it with \"get_cost\": true.") }
    guard st["mode"] as? String == "generate" else { block("Blocked: price only — add \"get_cost\": true. Nothing may be generated before the user approves the price.") }
    guard (st["used"] as? Int ?? 0) == 0 else { block("Blocked: the one approved generation was already submitted. Do not retry; report the result or the error.") }
    guard tool == st["tool"] as? String, params["model"] as? String == st["model"] as? String else { block("Blocked: only \(st["tool"] ?? "") with model \(st["model"] ?? "") was approved.") }
    guard (params["count"] as? Int ?? 1) == 1 else { block("Blocked: one output only (count 1).") }
    st["used"] = 1
    if let out = try? JSONSerialization.data(withJSONObject: st) { try? out.write(to: url) }
    exit(0)
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "hf-guard" { hfGuard(CommandLine.arguments[2]) }

let a = CommandLine.arguments
guard a.count >= 2, ["say", "type", "delegate", "settings", "session", "setup"].contains(a[1]) else { print("usage: butler <say|type|delegate|settings|session|setup> [text]"); exit(1) }
guard let answer = butlerSend(a[1], a.dropFirst(2).joined(separator: " ")) else { print("Sasarisa is not running"); exit(2) }
_ = answer
if a[1] == "delegate", answer == "sent" { print("sent — free mode: Sasarisa typed the task into the Claude session. Say briefly that it was handed over."); exit(0) }
if a[1] == "delegate" { print("pending — Sasarisa holds the task until the user says yes. In your answer, ASK whether to hand it over; do not say it was done.") }
