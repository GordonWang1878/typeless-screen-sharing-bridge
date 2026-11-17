// Read-only target probe:  TypelessBridgeProbe <identities.json>
// Prints which destination Mac the focused Screen Sharing window is connected to: the Mac
// name in the window's connection document name, matched against the destination
// identities the sender collected (computer name, local host name, ...).
// It does not inspect window contents or record other application names.
import AppKit
import ApplicationServices
import Foundation

let screenSharingFolder = NSHomeDirectory() + "/Library/Containers/com.apple.ScreenSharing/Data/Library/Application Support/Screen Sharing/"

// MARK: host matching (kept identical in guard.swift)
func normalizedHost(_ host: String) -> String {
    var h = host.lowercased()
    if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
    while h.hasSuffix(".") { h.removeLast() }
    return h
}
// The connection document is named "<Name> (<user>).vncloc" or "<Name>.vncloc", where <Name>
// is the remote Mac's name. Only the name is used: reading the document itself would need
// macOS' "access data from other apps" permission, and the user part varies with the login.
func connectionName(_ path: String) -> String? {
    var name = String((path as NSString).lastPathComponent.dropLast(".vncloc".count))
    if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
        name = String(name[..<open.lowerBound])
    }
    let trimmed = normalizedHost(name.trimmingCharacters(in: .whitespaces))
    return trimmed.isEmpty ? nil : trimmed
}
func connectionFile(_ document: String) -> String? {
    guard let url = URL(string: document), url.isFileURL else { return nil }
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(screenSharingFolder), path.hasSuffix(".vncloc"),
          !String(path.dropFirst(screenSharingFolder.count)).contains("/") else { return nil }
    return path
}
func loadIdentities(_ data: Data?) -> [String: Set<String>] {
    guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return [:] }
    return object.mapValues { Set($0.map(normalizedHost)) }
}
// Exactly one destination must claim the host; none or several means "not ours".
func destination(host: String, identities: [String: Set<String>]) -> String? {
    let matches = identities.filter { $0.value.contains(host) }.map(\.key)
    return matches.count == 1 ? matches[0] : nil
}

// The setup wizard asks this to show a live "allowed" check. Must be launched with `open`
// so the app itself, not the terminal, is the process macOS checks.
if CommandLine.arguments.contains("--check-trust") {
    print(AXIsProcessTrusted() ? "trusted" : "untrusted")
    exit(0)
}
if CommandLine.arguments.contains("--self-test") {
    let ids = loadIdentities(#"{"hub":["hub","hub.local","192.0.2.10"],"core":["core","core.local"]}"#.data(using: .utf8))
    func named(_ file: String) -> String? { connectionName(screenSharingFolder + file) }
    precondition(destination(host: named("Hub (alice).vncloc")!, identities: ids) == "hub")
    precondition(destination(host: named("Core (Alice Smith).vncloc")!, identities: ids) == "core")
    precondition(destination(host: named("Core.vncloc")!, identities: ids) == "core")
    precondition(destination(host: named("Laptop (alice).vncloc")!, identities: ids) == nil)
    precondition(destination(host: named("Office Mac (x).vncloc")!, identities: ids) == nil)
    precondition(named(" (x).vncloc") == nil)
    precondition(destination(host: "hub", identities: ["hub": ["hub"], "core": ["hub"]]) == nil)
    precondition(connectionFile(URL(fileURLWithPath: screenSharingFolder + "Hub (x).vncloc").absoluteString) != nil)
    precondition(connectionFile(URL(fileURLWithPath: screenSharingFolder + "sub/Hub.vncloc").absoluteString) == nil)
    precondition(connectionFile("https://example.com/Hub.vncloc") == nil)
    print("10 focus-policy cases passed")
    exit(0)
}
guard CommandLine.arguments.count == 2 else { print("usage"); exit(0) }
guard AXIsProcessTrusted() else { print("no-trust"); exit(0) }
guard let app = NSWorkspace.shared.frontmostApplication else { print("no-frontmost"); exit(0) }
guard app.bundleIdentifier == "com.apple.ScreenSharing" else { print("other-frontmost"); exit(0) }
let element = AXUIElementCreateApplication(app.processIdentifier)
var window: CFTypeRef?
guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
      let w = window, CFGetTypeID(w) == AXUIElementGetTypeID() else { print("focused-window-unavailable"); exit(0) }
var value: CFTypeRef?
let status = AXUIElementCopyAttributeValue((w as! AXUIElement), kAXDocumentAttribute as CFString, &value)
guard status == .success, let v = value else { print("window-document-unavailable"); exit(0) }
let document = (v as? URL)?.absoluteString ?? (v as? String) ?? ""
guard let file = connectionFile(document), let host = connectionName(file) else { print("document-not-recognized"); exit(0) }
let identities = loadIdentities(FileManager.default.contents(atPath: CommandLine.arguments[1]))
print(destination(host: host, identities: identities).map { "target=" + $0 } ?? "name-not-recognized")
