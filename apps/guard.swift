// Screen Sharing Bridge for Typeless: paste guard. Started by the sender service:
//   TypelessBridgeGuard <heartbeat-file> <destinations: ssh aliases, e.g. studio,office> <identities.json> <delivered-file>
// Suppresses only Typeless' own Command-V, only while the focused Screen Sharing window is
// connected to one of the configured destinations (matched by Mac name, see focus probe) and
// the sender's heartbeat is fresh.
// After each suppressed paste it also closes Typeless' "Copy last transcript" popup (the text goes
// through the bridge instead), pressing only that popup's close button via Accessibility.
import AppKit
import ApplicationServices
import CoreGraphics
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
    func unique(_ name: String) -> String?? {   // nil: no match; .some(nil): ambiguous
        let matches = identities.filter { $0.value.contains(name) }.map(\.key)
        return matches.isEmpty ? nil : .some(matches.count == 1 ? matches[0] : nil)
    }
    if let exact = unique(host) { return exact }
    // A DNS name such as core.tailnet.ts.net (Tailscale and the like): try its first label.
    // Never for addresses.
    let isAddress = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
    guard !isAddress, let dot = host.firstIndex(of: "."), dot != host.startIndex else { return nil }
    return unique(String(host[..<dot])) ?? nil
}


func fresh(_ timestamp: TimeInterval?, now: TimeInterval, within: TimeInterval = 1) -> Bool {
    guard let timestamp else { return false }
    let age = now - timestamp
    return age >= 0 && age < within
}
func allowedDestinations(_ destinations: String) -> Set<String>? {
    let names = destinations.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard !names.isEmpty, Set(names).count == names.count,
          names.allSatisfy({ !$0.isEmpty && $0.count <= 32 && $0 != "local" && !$0.hasPrefix("-") &&
                             $0.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") } })
    else { return nil }
    return Set(names)
}
func eligible(source: Int64, typeless: Int64, key: Int64, command: Bool,
              front: String?, heartbeat: TimeInterval?, now: TimeInterval) -> Bool {
    typeless > 0 && source == typeless && key == 9 && command &&
      front == "com.apple.ScreenSharing" && fresh(heartbeat, now: now)
}
// The popup's title and its Copy / Copied button in every Typeless 2.11 UI language, taken from
// the app's own translations (keys floating_bar__alert__click_to_copy__title,
// floating_bar__alert__button__copy, floating_bar__alert__button__copied).
let popupTitles: Set<String> = [
    "Copia l'ultima trascrizione", "Copia la darrera transcripció", "Copiar última transcripción",
    "Copiar última transcrição", "Copiază ultima transcriere", "Copier la dernière transcription",
    "Copy last transcript", "Kopeeri viimane transkriptsioon", "Kopieer laatste transcript",
    "Kopier sidste transskription", "Kopier siste transkripsjon", "Kopiera senaste transkription",
    "Kopijuoti paskutinę transkripciją", "Kopioi viimeisin transkriptio",
    "Kopiraj poslednji transkript", "Kopiraj posljednju transkripciju",
    "Kopiraj zadnjo transkripcijo", "Kopírovat poslední přepis", "Kopírovať posledný prepis",
    "Kopēt pēdējo transkripciju", "Letztes Transkript kopieren", "Másold az utolsó átiratot",
    "Nakili transkripti ya mwisho", "Salin transkrip terakhir", "Sao chép bản ghi cuối",
    "Skopiuj ostatnią transkrypcję", "Son transkripti kopyala", "Αντιγραφή τελευταίας μεταγραφής",
    "Копирай последната транскрипция", "Скопировать последнюю транскрипцию",
    "Скопіювати останній транскрипт", "Պատճենել վերջին տեքստի փոխանցումը",
    "העתק את ההקלטה האחרונה", "آخری نقل کاپی کریں", "نسخ النسخة الأخيرة", "کپی آخرین ترجمه",
    "अंतिम ट्रांसक्रिप्ट कॉपी करें", "शेवटची प्रतिलिपी कॉपी करा", "শেষ ট্রান্সক্রিপ্ট কপি করুন",
    "છેલ્લી ટ્રાન્સક્રિપ્ટ નકલ કરો", "கடைசி பதிவை நகலெடுக்கவும்",
    "చివరి ట్రాన్స్క్రిప్ట్‌ను కాపీ చేయండి", "ಕೊನೆಯ ಪಠ್ಯವನ್ನು ನಕಲಿಸಿ",
    "അവസാന ട്രാൻസ്ക്രിപ്റ്റ് പകർപ്പിക്കുക", "คัดลอกการถอดเสียงล่าสุด", "የመጨረሻ ትርጉም ይቅርታ",
    "复制最后的转录", "最後のトランスクリプトをコピー", "複製最後的轉錄", "마지막 전사 복사"
]
let copyLabels: Set<String> = [
    "Copia", "Copiado", "Copiar", "Copiat", "Copiato", "Copiază", "Copied", "Copier", "Copié",
    "Copy", "Disalin", "Gekopieerd", "Imenakiliwa", "Kopeeri", "Kopeeritud", "Kopier", "Kopiera",
    "Kopierad", "Kopieren", "Kopieret", "Kopiert", "Kopijuota", "Kopijuoti", "Kopioi", "Kopioitu",
    "Kopiraj", "Kopirano", "Kopiuj", "Kopiëren", "Kopyala", "Kopyalandı", "Kopírovat", "Kopírovať",
    "Kopēt", "Kopēts", "Másolva", "Másolás", "Nakili", "Salin", "Sao chép", "Skopiowano",
    "Skopírované", "Zkopírováno", "Đã sao chép", "Αντιγράφηκε", "Αντιγραφή", "Копирай", "Копирано",
    "Скопировано", "Скопировать", "Скопійовано", "Скопіювати", "Պատճենել", "Պատճենված", "הועתק",
    "העתק", "تم النسخ", "نسخ", "کاپی کر لیا", "کاپی کریں", "کپی", "کپی شد", "कॉपी करा",
    "कॉपी करें", "कॉपी किया गया", "कॉपी केले", "কপি করা হয়েছে", "কপি করুন", "નકલ કરવામાં આવ્યું",
    "નકલ કરો", "நகலெடு", "நகலெடுக்கப்பட்டது", "కాపీ", "కాపీ చేయబడింది", "ನಕಲಿಸಲಾಗಿದೆ", "ನಕಲಿಸಿ",
    "പകർപ്പിക്കുക", "പകർപ്പിച്ചു", "คัดลอก", "คัดลอกแล้ว", "ተቀይሯል", "ይቅርታ", "コピー", "コピーしました", "复制",
    "已复制", "已複製", "複製", "복사", "복사됨"
]
// One child of the copy popup's container, as seen through Accessibility.
struct PopupItem { let role: String; let label: String?; let isTitle: Bool }
// The close button is the only unlabeled button, right after the title; the only other
// button is Copy. Anything else (a Typeless UI change, a half-built popup) is not pressed.
func closeButtonIndex(_ items: [PopupItem]) -> Int? {
    let buttons = items.indices.filter { items[$0].role == "AXButton" }
    guard buttons.count == 2, let title = items.firstIndex(where: { $0.isTitle }),
          let close = buttons.first(where: { items[$0].label == nil }), close == title + 1,
          buttons.contains(where: { copyLabels.contains(items[$0].label ?? "") }) else { return nil }
    return close
}
// The setup wizard asks this to show a live "allowed" check. Must be launched with `open`
// so the app itself, not the terminal, is the process macOS checks.
if CommandLine.arguments.contains("--check-trust") {
    print(AXIsProcessTrusted() ? "trusted" : "untrusted")
    exit(0)
}
if CommandLine.arguments.contains("--self-test") {
    precondition(eligible(source: 10, typeless: 10, key: 9, command: true, front: "com.apple.ScreenSharing", heartbeat: 100, now: 100.1))
    precondition(!eligible(source: 0, typeless: 10, key: 9, command: true, front: "com.apple.ScreenSharing", heartbeat: 100, now: 100.1))
    precondition(!eligible(source: 10, typeless: 10, key: 9, command: true, front: "com.apple.ScreenSharing", heartbeat: 100, now: 101.1))
    precondition(!eligible(source: 10, typeless: 10, key: 9, command: true, front: "com.apple.ScreenSharing", heartbeat: nil, now: 100))
    precondition(!eligible(source: 10, typeless: 10, key: 9, command: true, front: "com.apple.Notes", heartbeat: 100, now: 100.1))
    precondition(!eligible(source: 10, typeless: 10, key: 9, command: true, front: "com.apple.ScreenSharing", heartbeat: 101, now: 100))
    precondition(!eligible(source: 10, typeless: 10, key: 9, command: false, front: "com.apple.ScreenSharing", heartbeat: 100, now: 100.1))
    precondition(allowedDestinations("hub") == ["hub"] && allowedDestinations("core,hub") == ["core", "hub"])
    precondition(allowedDestinations("") == nil && allowedDestinations("hub,hub") == nil && allowedDestinations("Hub") == nil)
    precondition(allowedDestinations("-x") == nil && allowedDestinations("local") == nil && allowedDestinations("studio-2") == ["studio-2"])
    let ids = loadIdentities(#"{"hub":["hub","hub.local"],"core":["core"]}"#.data(using: .utf8))
    precondition(destination(host: connectionName(screenSharingFolder + "Hub (Alice Smith).vncloc")!, identities: ids) == "hub")
    let title = PopupItem(role: "AXGroup", label: nil, isTitle: true)
    let close = PopupItem(role: "AXButton", label: nil, isTitle: false)
    let copy = PopupItem(role: "AXButton", label: "复制", isTitle: false)
    let text = PopupItem(role: "AXStaticText", label: nil, isTitle: false)
    precondition(closeButtonIndex([title, close, text, text, copy]) == 1)
    precondition(closeButtonIndex([title, close, text]) == nil)
    precondition(closeButtonIndex([title, copy, close]) == nil)
    precondition(closeButtonIndex([title, close, close, copy]) == nil)
    precondition(closeButtonIndex([text, close, text, copy]) == nil)
    let english = PopupItem(role: "AXButton", label: "Copied", isTitle: false)
    precondition(closeButtonIndex([title, close, text, english]) == 1)
    precondition(popupTitles.contains("Copy last transcript") && popupTitles.contains("复制最后的转录"))
    precondition(destination(host: "core.tail1234.ts.net", identities: ids) == "core")
    print("21 guard checks passed")
    exit(0)
}
guard CommandLine.arguments.count == 5, let allowed = allowedDestinations(CommandLine.arguments[2]),
      AXIsProcessTrusted() else { print("NOT_READY"); exit(2) }
let heartbeatPath = CommandLine.arguments[1]
let identitiesPath = CommandLine.arguments[3]
let deliveredPath = CommandLine.arguments[4]

func heartbeatTime() -> TimeInterval? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: heartbeatPath)
    return (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
}
func targetIsConfiguredRemote() -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication,
          app.bundleIdentifier == "com.apple.ScreenSharing" else { return false }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    var window: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &window) == .success,
          let w = window, CFGetTypeID(w) == AXUIElementGetTypeID() else { return false }
    var document: CFTypeRef?
    guard AXUIElementCopyAttributeValue((w as! AXUIElement), kAXDocumentAttribute as CFString, &document) == .success,
          let value = document else { return false }
    let string = (value as? URL)?.absoluteString ?? (value as? String) ?? ""
    guard let file = connectionFile(string), let host = connectionName(file) else { return false }
    // Re-read each time: the sender refreshes the identities while we run.
    let identities = loadIdentities(FileManager.default.contents(atPath: identitiesPath)).filter { allowed.contains($0.key) }
    return destination(host: host, identities: identities) != nil
}

// MARK: copy popup
// Typeless shows its copy popup right after the paste we suppressed. The popup is closed only
// once the sender reports that this sentence was delivered (one line per delivery in the
// delivered file); otherwise it stays, as the user's sign to copy the text by hand.
// Closing is an Accessibility press of its close button: no keystroke, no click, focus stays
// in Screen Sharing. The popup's transcript text is never read.
let popupQueue = DispatchQueue(label: "copy-popup")
var popupDeadline: Date?      // all three touched only on popupQueue
var popupReason = "not-found"
var deliveriesUsed = 0
let popupWindow: TimeInterval = 20   // delivery over SSH can take up to 15 s

func deliveryTimes() -> [TimeInterval] {
    guard let text = try? String(contentsOfFile: deliveredPath, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { TimeInterval($0) }
}

func axValue(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var out: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &out) == .success ? out : nil
}
func axChildren(_ e: AXUIElement) -> [AXUIElement] { (axValue(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func axRole(_ e: AXUIElement) -> String { (axValue(e, kAXRoleAttribute) as? String) ?? "" }
func axParent(_ e: AXUIElement) -> AXUIElement? {
    guard let p = axValue(e, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
    return (p as! AXUIElement)
}
func axText(_ e: AXUIElement) -> String? {
    for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
        if let s = axValue(e, name) as? String, !s.isEmpty { return s }
    }
    return nil
}
func buttonLabel(_ button: AXUIElement) -> String? {
    if let t = axText(button) { return t }
    for c in axChildren(button) { if let t = buttonLabel(c) { return t } }
    return nil
}
func findPopupTitle(_ e: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 25 else { return nil }
    if axRole(e) == kAXStaticTextRole as String, popupTitles.contains(axText(e) ?? "") { return e }
    for c in axChildren(e) { if let m = findPopupTitle(c, depth: depth + 1) { return m } }
    return nil
}
enum PopupResult { case closed, notFound, skipped(String) }
func closeCopyPopup() -> PopupResult {
    guard let typeless = NSRunningApplication.runningApplications(withBundleIdentifier: "now.typeless.desktop").first
    else { return .notFound }
    let app = AXUIElementCreateApplication(typeless.processIdentifier)
    var title: AXUIElement?
    for w in (axValue(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        if let t = findPopupTitle(w) { title = t; break }
    }
    guard let title else { return .notFound }
    guard let row = axParent(title), let box = axParent(row) else { return .skipped("layout") }
    let children = axChildren(box)
    let items = children.map { child -> PopupItem in
        let role = axRole(child)
        return PopupItem(role: role, label: role == kAXButtonRole as String ? buttonLabel(child) : nil,
                         isTitle: CFEqual(child, row))
    }
    guard let index = closeButtonIndex(items) else { return .skipped("layout") }
    guard targetIsConfiguredRemote() else { return .skipped("target") }
    return AXUIElementPerformAction(children[index], kAXPressAction as CFString) == .success
        ? .closed : .skipped("press-failed")
}
func watchPopup() {
    guard let deadline = popupDeadline else { return }
    let deliveries = deliveryTimes()
    if deliveries.count > deliveriesUsed {
        switch closeCopyPopup() {
        case .closed:
            deliveriesUsed += 1
            print("POPUP_CLOSED"); fflush(stdout)
            // More sentences may still be on their way.
            if deliveries.count == deliveriesUsed { popupDeadline = nil; return }
        case .notFound: popupReason = "not-found"
        case .skipped(let reason): popupReason = reason
        }
    } else {
        popupReason = "not-delivered"
    }
    if Date() >= deadline {
        print("POPUP_LEFT", popupReason); fflush(stdout)
        deliveriesUsed = deliveries.count   // never let an old delivery close a later popup
        popupDeadline = nil
        return
    }
    popupQueue.asyncAfter(deadline: .now() + 0.015) { watchPopup() }
}
func expectPopup() {
    popupQueue.async {
        let now = Date()
        // A delivery can be reported just before the paste is suppressed, but not long before.
        let deliveries = deliveryTimes()
        while deliveriesUsed < deliveries.count && deliveries[deliveriesUsed] < now.timeIntervalSince1970 - 5 {
            deliveriesUsed += 1
        }
        let running = popupDeadline != nil
        popupDeadline = now.addingTimeInterval(popupWindow)
        if !running { popupReason = "not-found"; watchPopup() }
    }
}
// The sender touches the heartbeat every 0.2 s; stop when it has been gone for 5 s.
guard fresh(heartbeatTime(), now: Date().timeIntervalSince1970, within: 5) else { print("NOT_READY"); exit(2) }

final class Context {
    var droppedDown = false
    var isConfiguredRemote = false
    var tap: CFMachPort?
    var onSuppressed: () -> Void = {}   // the C callback cannot call top-level code that captures state
}
let context = Context()
context.onSuppressed = expectPopup
context.isConfiguredRemote = targetIsConfiguredRemote()
let callback: CGEventTapCallBack = { _, type, event, opaque in
    guard let opaque else { return Unmanaged.passUnretained(event) }
    let state = Unmanaged<Context>.fromOpaque(opaque).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // macOS disables a slow tap; turn it back on instead of leaving the bridge down.
        if let tap = state.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        print("TAP_REENABLED"); fflush(stdout)
        return Unmanaged.passUnretained(event)
    }
    let key = event.getIntegerValueField(.keyboardEventKeycode)
    let source = event.getIntegerValueField(.eventSourceUnixProcessID)
    let typeless = Int64(NSRunningApplication.runningApplications(withBundleIdentifier: "now.typeless.desktop").first?.processIdentifier ?? 0)
    if type == .keyUp && key == 9 && source == typeless && state.droppedDown {
        state.droppedDown = false
        return nil
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    if state.isConfiguredRemote && eligible(source: source, typeless: typeless, key: key,
        command: event.flags.contains(.maskCommand), front: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
        heartbeat: heartbeatTime(), now: Date().timeIntervalSince1970) {
        state.droppedDown = true
        print("TYPELESS_PASTE_SUPPRESSED"); fflush(stdout)
        state.onSuppressed()
        return nil
    }
    // Typeless' own paste let through: say why (yes/no answers only, nothing typed, no app names),
    // so a missed paste in the sender's log can be told apart from a guard that sees nothing.
    if key == 9 && source == typeless && typeless > 0 && event.flags.contains(.maskCommand) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.ScreenSharing"
        let alive = fresh(heartbeatTime(), now: Date().timeIntervalSince1970)
        print("TYPELESS_PASTE_PASSED screen-sharing=\(front ? "yes" : "no") remote=\(state.isConfiguredRemote ? "yes" : "no") heartbeat=\(alive ? "yes" : "no")")
        fflush(stdout)
    }
    return Unmanaged.passUnretained(event)
}
let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
let pointer = Unmanaged.passUnretained(context).toOpaque()
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
  options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: pointer) else { print("TAP_UNAVAILABLE"); exit(3) }
context.tap = tap
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
    if !fresh(heartbeatTime(), now: Date().timeIntervalSince1970, within: 5) { CFRunLoopStop(CFRunLoopGetMain()); return }
    context.isConfiguredRemote = targetIsConfiguredRemote()
}
RunLoop.current.add(timer, forMode: .common)
print("READY"); fflush(stdout)
CFRunLoopRun()
timer.invalidate()
CFMachPortInvalidate(tap)
