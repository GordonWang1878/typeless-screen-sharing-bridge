// Screen Sharing Bridge for Typeless: receiver (LaunchAgent org.local.typelessbridge.receiver).
//
// Listens on a Unix socket only this user can open. Each connection carries one JSON line:
//   {"op":"health"}                                  -> {"status":"ready"|"needs-accessibility"}
//   {"op":"paste-current","id":"<uuid>","text":"…"} -> {"status":"paste-sent-unconfirmed"|<reason>}
// A paste puts the text on the clipboard, presses Command-V at whatever has focus, and puts
// the previous clipboard back afterwards. Each id is pasted at most once, even across restarts.
// No request ever runs code; text is never logged.
import AppKit
import ApplicationServices
import Carbon
import Darwin
import Foundation

enum Outcome: String {
    case sent = "paste-sent-unconfirmed"
    case invalid = "invalid-request"
    case rejected = "rejected"
    case duplicate = "already-consumed"
    case inactive = "no-active-session"
    case secure = "secure-field"
    case noEvent = "event-unavailable"
    case clipboard = "clipboard-write-failed"
    case focusMoved = "frontmost-changed"
    case journal = "journal-unavailable"
}

struct Limits {
    static let requestBytes = 512 * 1024
    static let textBytes = 64 * 1024
    static let rememberedIDs = 1000
    static let restoreDelay = 1.5
}

func stop(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: request parsing (pure)
enum Request: Equatable {
    case health
    case paste(id: String, text: String)
}
func parseRequest(_ line: Data) -> Request? {
    guard line.count <= Limits.requestBytes,
          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          let op = object["op"] as? String else { return nil }
    switch op {
    case "health":
        return .health
    case "paste-current":
        guard let id = object["id"] as? String, (1...128).contains(id.utf8.count),
              let text = object["text"] as? String, !text.isEmpty, !text.contains("\0"),
              text.utf8.count <= Limits.textBytes else { return nil }
        return .paste(id: id, text: text)
    default:
        return nil
    }
}

// MARK: at-most-once journal
final class Journal {
    let file: URL
    private(set) var ids: [String] = []
    private(set) var usable = true

    init(file: URL) {
        self.file = file
        guard let data = try? Data(contentsOf: file) else { return }
        let stored = try? JSONSerialization.jsonObject(with: data)
        if let list = stored as? [String] {
            ids = list
        } else if let table = stored as? [String: Any] {
            ids = Array(table.keys)   // older receivers kept {id: time}
        } else {
            // Unreadable: keep it for inspection and start a new journal. Ids are one-shot
            // UUIDs that senders never resend, so this cannot cause a repeated paste.
            let aside = file.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
            if (try? FileManager.default.moveItem(at: file, to: aside)) != nil {
                FileHandle.standardError.write("journal unreadable, moved to \(aside.lastPathComponent)\n".data(using: .utf8)!)
            } else {
                usable = false   // cannot even move it: refuse rather than guess
            }
        }
    }
    func contains(_ id: String) -> Bool { ids.contains(id) }
    // Recorded before the paste is attempted, so a crash can never lead to a second paste.
    func record(_ id: String) -> Bool {
        guard usable else { return false }
        let next = Array((ids + [id]).suffix(Limits.rememberedIDs))
        guard let data = try? JSONSerialization.data(withJSONObject: next),
              (try? data.write(to: file, options: [.atomic])) != nil else { return false }
        chmod(file.path, 0o600)
        ids = next
        return true
    }
}

// MARK: clipboard
struct ClipboardCopy {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func take(_ board: NSPasteboard) -> ClipboardCopy {
        ClipboardCopy(items: (board.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { entry[type] = data } }
            return entry
        })
    }
    func put(back board: NSPasteboard) {
        board.clearContents()
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { board.writeObjects(restored) }
    }
}
// Clipboard managers should neither show nor keep the dictated text.
let privateMarkers = [NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
                      NSPasteboard.PasteboardType("org.nspasteboard.TransientType")]

// MARK: session and input checks
func sessionIsActive() -> Bool {
    guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    let onConsole = info[kCGSessionOnConsoleKey as String] as? Bool ?? false
    let locked = info["CGSSessionScreenIsLocked"] as? Bool ?? false
    return onConsole && !locked
}
func pressCommandV() -> Bool {
    let source = CGEventSource(stateID: .combinedSessionState)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
}

// MARK: paste
// Runs on the main queue; requests are handled one at a time.
func paste(id: String, text: String, journal: Journal) -> Outcome {
    guard AXIsProcessTrusted() else { return .rejected }
    guard !journal.contains(id) else { return .duplicate }
    guard sessionIsActive() else { return .inactive }
    guard !IsSecureEventInputEnabled() else { return .secure }
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    guard journal.record(id) else { return .journal }

    let board = NSPasteboard.general
    let previous = ClipboardCopy.take(board)
    board.clearContents()
    let item = NSPasteboardItem()
    guard item.setString(text, forType: .string) else { previous.put(back: board); return .clipboard }
    for marker in privateMarkers { item.setString("", forType: marker) }
    guard board.writeObjects([item]) else { previous.put(back: board); return .clipboard }
    let ours = board.changeCount

    // Focus moved while we were preparing: do not paste into something else.
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front else {
        previous.put(back: board); return .focusMoved
    }
    guard !IsSecureEventInputEnabled() else { previous.put(back: board); return .secure }
    guard pressCommandV() else { previous.put(back: board); return .noEvent }

    // Give the target app time to read the clipboard; skip the restore if the user copied
    // something new in the meantime.
    DispatchQueue.main.asyncAfter(deadline: .now() + Limits.restoreDelay) {
        if board.changeCount == ours { previous.put(back: board) }
    }
    return .sent
}

// MARK: socket server
func readLine(_ fd: Int32) -> Data? {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while buffer.count <= Limits.requestBytes {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        buffer.append(contentsOf: chunk[0..<n])
        if let newline = buffer.firstIndex(of: 0x0A) { return buffer.prefix(upTo: newline) }
    }
    return buffer.isEmpty || buffer.count > Limits.requestBytes ? nil : buffer
}
func reply(_ fd: Int32, _ status: String) {
    var data = (try? JSONSerialization.data(withJSONObject: ["status": status])) ?? Data()
    data.append(0x0A)
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
}
func serve(_ fd: Int32, journal: Journal) {
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let status: String
    switch readLine(fd).flatMap(parseRequest) {
    case .health?:
        status = AXIsProcessTrusted() ? "ready" : "needs-accessibility"
    case let .paste(id, text)?:
        status = DispatchQueue.main.sync { paste(id: id, text: text, journal: journal) }.rawValue
    case nil:
        status = Outcome.invalid.rawValue
    }
    reply(fd, status)
    close(fd)
}

// The setup wizard asks this to show a live "allowed" check. Must be launched with `open`
// so the app itself, not the terminal, is the process macOS checks.
if CommandLine.arguments.contains("--check-trust") {
    print(AXIsProcessTrusted() ? "trusted" : "untrusted")
    exit(0)
}
if CommandLine.arguments.contains("--self-test") {
    precondition(parseRequest(#"{"op":"health"}"#.data(using: .utf8)!) == .health)
    precondition(parseRequest(#"{"op":"paste-current","id":"a","text":"你好"}"#.data(using: .utf8)!) == .paste(id: "a", text: "你好"))
    precondition(parseRequest(#"{"op":"paste-current","id":"a","text":""}"#.data(using: .utf8)!) == nil)
    precondition(parseRequest(#"{"op":"paste-current","text":"x"}"#.data(using: .utf8)!) == nil)
    precondition(parseRequest(#"{"op":"run","cmd":"x"}"#.data(using: .utf8)!) == nil)
    precondition(parseRequest("not json".data(using: .utf8)!) == nil)
    let big = String(repeating: "a", count: Limits.textBytes + 1)
    precondition(parseRequest(try! JSONSerialization.data(withJSONObject: ["op": "paste-current", "id": "a", "text": big])) == nil)
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("receiver-selftest-\(getpid())")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("consumed.json")
    let journal = Journal(file: file)
    precondition(journal.record("x") && journal.contains("x") && Journal(file: file).contains("x"))
    try? #"{"old-id": 1.5}"#.write(to: file, atomically: true, encoding: .utf8)
    precondition(Journal(file: file).contains("old-id"))
    try? "garbage".write(to: file, atomically: true, encoding: .utf8)
    let recovered = Journal(file: file)
    precondition(recovered.record("y") && recovered.contains("y") && !recovered.contains("old-id"))
    let kept = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    precondition(kept.contains { $0.hasPrefix("consumed.json.unreadable-") })
    try? FileManager.default.removeItem(at: folder)
    print("11 receiver checks passed")
    exit(0)
}

// MARK: start-up
let state = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/typeless-remote-bridge")
do { try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true) }
catch { stop("cannot create state folder") }
chmod(state.path, 0o700)

let lock = open(state.appendingPathComponent("receiver.lock").path, O_CREAT | O_RDWR, 0o600)
guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { stop("another receiver is running") }

let journal = Journal(file: state.appendingPathComponent("consumed.json"))
let socketPath = state.appendingPathComponent("receiver.sock").path
unlink(socketPath)
let listener = socket(AF_UNIX, SOCK_STREAM, 0)
guard listener >= 0 else { stop("socket failed") }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { stop("socket path too long") }
withUnsafeMutableBytes(of: &address.sun_path) { raw in
    raw.copyBytes(from: pathBytes)
    raw[pathBytes.count] = 0
}
let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard bound == 0, chmod(socketPath, 0o600) == 0, listen(listener, 8) == 0 else { stop("cannot listen") }

Thread.detachNewThread {
    while true {
        let client = accept(listener, nil, nil)
        if client < 0 { continue }
        DispatchQueue.global().async { serve(client, journal: journal) }
    }
}
RunLoop.main.run()
