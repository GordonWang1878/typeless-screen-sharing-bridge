// Screen Sharing Bridge for Typeless: the setup window.
//
//   Screen Sharing Bridge Setup <repo folder>
//   Screen Sharing Bridge Setup --snapshot <output folder>   (renders every page to PNG, for design review)
//
// A step-by-step window over `setup --step …` (the same steps the terminal wizard uses). It only
// presents and asks; all real work happens in those steps. The password typed here goes to ssh
// for one login through the environment of that one process, and is never stored.
import AppKit
import SwiftUI

let zh = (ProcessInfo.processInfo.environment["TB_LANG"] ?? Locale.preferredLanguages.first ?? "").hasPrefix("zh")
func L(_ chinese: String, _ english: String) -> String { zh ? curlyQuotes(chinese) : english }
/// Chinese text uses “ ” rather than straight quotes.
func curlyQuotes(_ s: String) -> String {
    var open = true
    return String(s.map { c -> Character in
        guard c == "\"" else { return c }
        defer { open.toggle() }
        return open ? "\u{201C}" : "\u{201D}"
    })
}

// MARK: running steps
struct StepResult { let code: Int32; let output: String
    func value(_ key: String) -> String? {
        output.split(separator: "\n").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }
    var text: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
}

final class Runner {
    let repo: String
    private var running = Set<Process>()
    private let lock = NSLock()
    init(repo: String) { self.repo = repo }

    func run(_ args: [String], password: String? = nil) async -> StepResult {
        await withCheckedContinuation { done in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [repo + "/setup", "--step"] + args
            var env = ProcessInfo.processInfo.environment
            if let password { env["TB_PASSWORD"] = password }
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { [weak self] p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                self?.forget(p)
                done.resume(returning: StepResult(code: p.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
            do { try process.run(); remember(process) } catch { done.resume(returning: StepResult(code: 127, output: "")) }
        }
    }
    private func remember(_ p: Process) { lock.lock(); running.insert(p); lock.unlock() }
    private func forget(_ p: Process) { lock.lock(); running.remove(p); lock.unlock() }
    /// Closing the window mid-way stops whatever step is still running.
    func stopAll() { lock.lock(); let all = running; lock.unlock(); all.forEach { $0.terminate() } }
}

// MARK: model
/// Internal stages, in the order the work happens.
enum Stage: Int { case check, choose, connect, installRemote, grantRemote, installLocal, grantLocal, test, done }

struct Mac: Identifiable, Hashable { let name: String; let host: String; let added: Bool; var id: String { name } }

/// Something the machine is doing; `expected` seconds gives an estimated bar instead of an open-ended one.
struct Activity: Equatable { let text: String; let since: Date; let expected: Double? }

/// Something only the user can do, possibly on the other Mac. Shown as the hero of the page.
struct UserAction: Equatable {
    let title: String
    let steps: [String]
    var apps: [String] = []            // switches to turn on, each ticked as soon as it is on
    var remote = false                 // it happens in the Screen Sharing window
    var footnote = ""
}

enum ItemState { case pending, active, needsYou, done, failed }
struct Item: Identifiable, Equatable { let id: Int; let title: String; var state: ItemState = .pending }

@MainActor
final class Model: ObservableObject {
    let runner: Runner
    let version: String
    @Published var menu = false             // already installed: the home page
    @Published var controlled: [String] = []
    @Published var stage: Stage = .check
    @Published var busy = false              // a flow is running: buttons that start another are disabled
    @Published var activity: Activity?       // what the machine is doing now
    @Published var action: UserAction?       // what the user must do now
    @Published var items: [Item] = []        // the checklist of the current page
    @Published var granted: Set<String> = [] // switches already on (live ticks)
    @Published var hint = ""                 // shown when a wait takes long
    @Published var problem = ""              // something the user must know; Retry appears with it
    @Published var macs: [Mac] = []
    @Published var scanning = false
    @Published var picked: Mac?
    @Published var manualHost = "" { didSet { if !manualHost.isEmpty { picked = nil } } }
    @Published var showAddress = false
    @Published var account = NSUserName()
    @Published var password = ""
    @Published var needPassword = false
    @Published var missingLocal: [String] = []
    @Published var openedSettings = false
    @Published var testHeard = false
    @Published var operation: String?        // remove / uninstall in progress: its page title
    @Published var finishedTitle = ""
    @Published var finished = ""             // text of the final screen
    @Published var finishedAdded = false     // the final screen teaches how to use it
    @Published var alsoRemote = true         // home: also uninstall the receiver over there
    @Published var confirmRemove: String?
    @Published var confirmUninstall = false
    @Published var upgrading = false
    @Published var reinstalling = false      // the upgrade button was "Reinstall" (already up to date)
    // Versions: what was just downloaded, what this Mac and each controlled Mac have installed.
    // "" = installed before versions were recorded (1.0.0 or earlier); "unreachable" = not asked.
    @Published var versionsKnown = false
    @Published var installedHere = ""
    @Published var installedThere: [String: String] = [:]
    @Published var currentRemote = ""        // the controlled Mac being installed or updated
    var dest = ""
    var abandon = false                      // the user went back during a wait
    var manual = false                       // the Mac was typed in, not picked from the list
    var built = false
    var retry: (() async -> Void)?           // what Retry does after a problem

    init(repo: String) {
        runner = Runner(repo: repo)
        version = (try? String(contentsOfFile: repo + "/VERSION", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The Mac being added, as the user knows it.
    var targetName: String { picked?.name ?? (manualHost.isEmpty ? dest : manualHost) }

    /// Start a flow from a button; ignored while another one runs (no double clicks).
    func act(_ flow: @escaping () async -> Void) {
        guard !busy else { return }
        busy = true; problem = ""; hint = ""
        Task { await flow(); busy = false }
    }
    func doing(_ text: String, expected: Double? = nil) { activity = Activity(text: text, since: Date(), expected: expected) }
    /// A pause so a change can be seen before the next one (quick steps would otherwise flash by).
    func beat(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    /// Run `work`, but let it take at least `seconds` on screen.
    func atLeast<T>(_ seconds: Double, _ work: () async -> T) async -> T {
        let start = Date(); let result = await work()
        let left = seconds - Date().timeIntervalSince(start)
        if left > 0 { await beat(left) }
        return result
    }
    func fail(_ message: String, retry: (() async -> Void)?) {
        activity = nil; action = nil; hint = ""; problem = message; self.retry = retry
        if let i = items.firstIndex(where: { $0.state == .active || $0.state == .needsYou }) { items[i].state = .failed }
        upgrading = upgrading && retry != nil
    }
    func mark(_ index: Int, _ state: ItemState) { if items.indices.contains(index) { items[index].state = state } }

    /// Poll a step until it succeeds; after ~30 s show `slowHint`.
    func waitFor(_ args: [String], slowHint: String) async {
        var polls = 0
        while await runner.run(args).code != 0 {
            polls += 1
            if polls == 15 { hint = slowHint }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        hint = ""
    }

    func start() async {
        controlled = await runner.run(["destinations"]).output.split(separator: "\n").map(String.init)
        if controlled.isEmpty { await check() } else { menu = true; await loadVersions() }
    }

    func loadVersions() async {
        versionsKnown = false
        let r = await runner.run(["versions"])
        installedHere = r.value("local") ?? ""
        var there: [String: String] = [:]
        for line in r.output.split(separator: "\n") where line.hasPrefix("remote ") {
            let rest = line.dropFirst("remote ".count)
            if let eq = rest.firstIndex(of: "=") { there[String(rest[..<eq])] = String(rest[rest.index(after: eq)...]) }
        }
        installedThere = there
        versionsKnown = true
    }
    /// Everything installed is the version that was just downloaded.
    var upToDate: Bool {
        versionsKnown && !version.isEmpty && installedHere == version && controlled.allSatisfy { installedThere[$0] == version }
    }
    func versionLabel(_ v: String?) -> String {
        switch v {
        case nil: return "…"
        case "": return L("1.0.0 或更早", "1.0.0 or earlier")
        case "unreachable": return L("连不上", "not reachable")
        default: return v!
        }
    }

    /// Back to the beginning for another Mac, without reopening the window.
    func addAnother() async {
        picked = nil; manualHost = ""; manual = false; dest = ""; password = ""; needPassword = false
        finished = ""; finishedAdded = false; testHeard = false; operation = nil; upgrading = false
        await check()
    }

    // ---- shared steps
    func check() async {
        menu = false; stage = .check; problem = ""; operation = nil; action = nil
        items = [Item(id: 0, title: "Typeless"), Item(id: 1, title: L("命令行开发工具", "Command Line Tools"))]
        mark(0, .active); doing(L("正在检查这台 Mac…", "Checking this Mac…"))
        // The window has only just appeared: let each check be seen before it ticks.
        var pre = await atLeast(1.2) { await runner.run(["preflight"]) }
        if pre.value("typeless") != "1" {
            fail(L("这台 Mac 上没找到 Typeless。请在你说话的那台 Mac（装了 Typeless 并已登录）上运行本安装。",
                   "Typeless was not found on this Mac. Run this on the Mac you talk to (with Typeless signed in)."), retry: nil)
            return
        }
        mark(0, .done); mark(1, .active)
        await beat(0.8)
        if pre.value("tools") != "1" {
            _ = await runner.run(["install-tools"])
            mark(1, .needsYou); activity = nil
            action = UserAction(title: L("安装命令行开发工具", "Install the Command Line Tools"),
                                steps: [L("在刚弹出的窗口里点\"安装\"。", "Click Install in the window that just opened."),
                                        L("装好后这里会自动继续，可能要几分钟。", "This continues by itself when it is done; it can take a few minutes.")])
            repeat { try? await Task.sleep(nanoseconds: 3_000_000_000); pre = await runner.run(["preflight"]) } while pre.value("tools") != "1"
            action = nil
        }
        mark(1, .done); activity = nil
        await beat(0.9)
        if upgrading { await upgradeAll(); return }
        await discover()
    }

    func discover() async {
        stage = .choose; picked = nil; activity = nil; items = []
        scanning = true
        let out = await runner.run(["discover"]).output
        macs = out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return f.count == 3 ? Mac(name: f[0], host: f[1], added: f[2] == "added") : nil
        }
        scanning = false
        if macs.allSatisfy({ $0.added }) { showAddress = true }
    }

    /// Back from the Remote Login wait or the password to the list of Macs.
    func goBack() {
        abandon = true; needPassword = false; password = ""; action = nil; activity = nil; hint = ""; problem = ""
        stage = .choose; picked = nil; manual = false
    }

    func backToChoose(_ message: String) {
        stage = .choose; needPassword = false; picked = nil; action = nil
        fail(message, retry: nil)
    }

    func connect() async {
        if picked == nil {
            let typed = manualHost.trimmingCharacters(in: .whitespaces)
            guard !typed.isEmpty else { return }
            manual = true
            picked = Mac(name: String(typed.split(separator: ".").first ?? ""), host: typed, added: false)
        }
        let host = picked!.host, name = picked!.name
        stage = .connect; problem = ""; abandon = false
        doing(L("正在连接 \(name)…", "Reaching \(name)…"))
        var polls = 0
        while true {
            let open = await runner.run(["ssh-open", host] + (manual ? [] : ["discovered"])).code
            if abandon { return }
            if open == 0 { break }
            if open == 3 {
                backToChoose(L("找不到\"\(host)\"这台电脑，请检查地址。", "No computer called \"\(host)\" was found; check the address."))
                return
            }
            activity = nil
            action = UserAction(title: L("在 \(name) 上打开\"远程登录\"", "Turn on Remote Login on \(name)"),
                                steps: [L("切到 \(name) 的屏幕共享窗口。", "Switch to the Screen Sharing window of \(name)."),
                                        L("打开 系统设置 → 通用 → 共享。", "Open System Settings → General → Sharing."),
                                        L("打开\"远程登录\"。", "Turn on Remote Login.")],
                                remote: true)
            polls += 1
            if polls == 15 { hint = L("如果远程登录已经打开：请确认这两台 Mac 在同一个网络里，地址也没有填错。",
                                       "If Remote Login is already on: check that both Macs are on the same network and the address is right.") }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if abandon { return }
        }
        action = nil; hint = ""
        doing(L("正在连接 \(name)…", "Connecting to \(name)…"))
        let result = await runner.run(["connect", name, host, account] + (manual ? [] : ["check-name"]),
                                      password: needPassword ? password : nil)
        password = ""
        switch result.code {
        case 0:
            dest = result.value("dest") ?? ""; needPassword = false
            guard await installRemote(dest), await installLocal() else { return }
            await grantLocal()   // continues to the test by itself, possibly after the user's button
        case 2:
            activity = nil
            if needPassword { problem = L("账户或密码不对，请再试一次。", "The account or password is not right; please try again.") }
            needPassword = true
        case 3:
            backToChoose(L("连上的是\"\(result.value("remote") ?? "?")\"，不是你选的\"\(name)\"，已停止。",
                           "Reached \"\(result.value("remote") ?? "?")\", not \"\(name)\"; stopped."))
        case 5:
            backToChoose(L("\(name) 已经添加过了。", "\(name) is already added."))
        case 6:
            backToChoose(L("地址格式不对。", "That address is not valid."))
        case 7:
            backToChoose(L("你的 SSH 配置里已经有一个叫\"\(result.value("dest") ?? name)\"的别名，指向别的机器。为了不装错，已停止。请改用这台 Mac 的地址，或先修改那个别名。",
                           "Your SSH config already has an alias \"\(result.value("dest") ?? name)\" pointing at another machine. Stopped so nothing is installed on the wrong Mac. Use this Mac's address instead, or change that alias."))
        default:
            needPassword = false   // a retry first tries without one; it asks again if needed
            fail(L("连不上 \(name)。", "Cannot reach \(name)."), retry: { [unowned self] in await self.connect() })
        }
    }

    @discardableResult
    func installRemote(_ name: String) async -> Bool {
        stage = .installRemote; currentRemote = name
        let shown = upgrading ? name : targetName
        items = [Item(id: 0, title: L("准备程序", "Prepare the apps")),
                 Item(id: 1, title: L("把接收端装到 \(shown)", "Install the receiver on \(shown)")),
                 Item(id: 2, title: L("在 \(shown) 上打开开关", "Switch it on on \(shown)")),
                 Item(id: 3, title: L("启动接收端", "Start the receiver"))]
        let again: () async -> Void = { [unowned self] in
            if self.upgrading { await self.upgradeAll(); return }
            if await self.installRemote(name), await self.installLocal() { await self.grantLocal() }
        }
        if !built {
            mark(0, .active)
            doing(L("正在准备程序，第一次大约需要 1 分钟…", "Preparing the apps; the first time takes about a minute…"), expected: 60)
            built = await runner.run(["build"]).code == 0
            guard built else { fail(L("程序没能编译成功。", "Building the apps failed."), retry: again); return false }
        }
        mark(0, .done); mark(1, .active)
        doing(L("正在把接收端装到 \(shown)…", "Installing the receiver on \(shown)…"), expected: 12)
        guard await runner.run(["install-remote", name]).code == 0 else {
            fail(L("在 \(shown) 上安装失败。", "Installing on \(shown) failed."), retry: again); return false
        }
        mark(1, .done); mark(2, .active)
        stage = .grantRemote
        if await runner.run(["remote-trusted", name]).code != 0 {
            doing(L("正在打开 \(shown) 上的设置…", "Opening the settings on \(shown)…"))
            let missing = (await runner.run(["remote-prepare", name]).value("missing") ?? "")
                .split(separator: ",").map(String.init)
            granted = []; activity = nil; mark(2, .needsYou)
            action = UserAction(title: L("在 \(shown) 上打开这个开关", "Allow it on \(shown)"),
                                steps: [L("切到 \(shown) 的屏幕共享窗口，那边的\"设备控制\"已经打开了。",
                                          "Switch to the Screen Sharing window of \(shown); Device Control is already open there."),
                                        L("在列表里找到下面这个 App，打开它的开关。", "Find the app below in the list and switch it on.")],
                                apps: missing.isEmpty ? ["TypelessBridgeReceiver"] : missing, remote: true,
                                footnote: L("它是蓝绿色的麦克风图标。打开后这里会自动继续。", "It has a blue-green microphone icon. This continues by itself once it is on."))
            await waitFor(["remote-trusted", name], slowHint: L(
                "找不到它，或打开后这里没反应？在 \(shown) 上用\"−\"删掉它，它会自动重新出现，再打开一次。",
                "Cannot find it, or nothing happens after switching it on? Remove it with − on \(shown); it reappears, then switch it on again."))
            granted = Set(action?.apps ?? [])
            try? await Task.sleep(nanoseconds: 600_000_000)   // let the tick be seen
            action = nil
            NSApp.activate(ignoringOtherApps: true)
        }
        mark(2, .done); mark(3, .active)
        doing(L("正在启动 \(shown) 上的接收端…", "Starting the receiver on \(shown)…"))
        guard await runner.run(["remote-start", name]).code == 0 else {
            fail(L("\(shown) 上的接收端没能启动。", "The receiver on \(shown) did not start."), retry: again); return false
        }
        mark(3, .done); activity = nil
        await beat(0.8)
        return true
    }

    func installLocal() async -> Bool {
        stage = .installLocal
        items = [Item(id: 0, title: L("安装到这台 Mac", "Install on this Mac")),
                 Item(id: 1, title: L("在这台 Mac 上打开开关", "Switch them on on this Mac")),
                 Item(id: 2, title: L("启动桥接", "Start the bridge"))]
        mark(0, .active)
        doing(L("正在安装到这台 Mac…", "Installing on this Mac…"), expected: 8)
        guard await runner.run(["install-local", upgrading ? "-" : dest]).code == 0 else {
            fail(L("安装失败。", "Install failed."), retry: { [unowned self] in
                if self.upgrading { await self.upgradeAll(); return }
                if await self.installLocal() { await self.grantLocal() } })
            return false
        }
        mark(0, .done)
        return true
    }

    func grantLocal() async {
        stage = .grantLocal; mark(1, .active)
        missingLocal = await runner.run(["local-missing"]).output.split(separator: "\n").map(String.init)
        if missingLocal.isEmpty { mark(1, .done); await startLocal(); return }
        activity = nil; granted = []; openedSettings = false; mark(1, .needsYou)
        action = UserAction(title: L("在这台 Mac 上打开 \(missingLocal.count) 个开关", "Switch on \(missingLocal.count) apps on this Mac"),
                            steps: [L("点\"打开系统设置\"，会打开\"隐私与安全性 → 设备控制\"。", "Click Open System Settings; it opens Privacy & Security → Device Control."),
                                    L("在列表里打开下面这些 App 的开关，它们排在 Typeless 旁边。", "Switch on the apps below; they sit next to Typeless in the list.")],
                            apps: missingLocal,
                            footnote: L("macOS 可能会提示\"已添加后台项目\"，这是正常的。", "macOS may say a background item was added; that is expected."))
    }

    func openLocalSettings() async {
        _ = await runner.run(["local-prepare"] + missingLocal)
        openedSettings = true
        var polls = 0
        while granted.count < missingLocal.count {
            for app in missingLocal where !granted.contains(app) {
                if await runner.run(["local-trusted", app]).code == 0 { granted.insert(app) }
            }
            if granted.count == missingLocal.count { break }
            polls += 1
            if polls == 15 { hint = L("开关已经打开但这里没反应？用\"−\"删掉对应的 App，它会自动重新出现，再打开一次。",
                                       "Switched on but nothing happens? Remove the app with −; it reappears, then switch it on again.") }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        hint = ""
        try? await Task.sleep(nanoseconds: 600_000_000)
        NSApp.activate(ignoringOtherApps: true)
        action = nil; missingLocal = []; mark(1, .done)
        await startLocal()
    }

    func startLocal() async {
        mark(2, .active)
        doing(L("正在启动桥接，大约 10 到 30 秒…", "Starting the bridge; 10–30 seconds…"), expected: 20)
        guard await runner.run(["local-start"]).code == 0 else {
            fail(L("桥接没能启动。", "The bridge did not start."), retry: { [unowned self] in await self.startLocal() }); return
        }
        mark(2, .done); activity = nil
        await beat(0.8)
        if upgrading {
            if reinstalling {
                finish(L("已重新安装", "Reinstalled"), L("已重新安装 \(version)，可以继续使用了。", "\(version) is reinstalled. Ready to use."), added: false)
            } else {
                finish(L("已升级", "Upgraded"), L("已升级到 \(version)，可以继续使用了。", "Upgraded to \(version). Ready to use."), added: false)
            }
            return
        }
        await test()
    }

    func test() async {
        guard stage != .done else { return }
        stage = .test; activity = nil; testHeard = false
        let name = targetName
        var from = await runner.run(["log-mark"]).text
        while stage == .test {
            let r = await runner.run(["test-result", from]).text
            guard stage == .test else { return }
            if r == "delivered" {
                testHeard = true
                try? await Task.sleep(nanoseconds: 900_000_000)
                finish(L("设置完成", "You're ready"),
                       L("以后在 \(name) 的屏幕共享窗口里，直接用 Typeless 说话就行。", "From now on, just dictate with Typeless in the Screen Sharing window of \(name)."),
                       added: true); return
            }
            if r != "none" {
                switch r {
                case "local": problem = L("刚才说话时，前台不是 \(name) 的窗口。点一下 \(name) 的屏幕共享窗口，再说一次。",
                                          "Screen Sharing was not in front: click the window of \(name), then try again.")
                case "other-window": problem = L("刚才那个屏幕共享窗口连的不是 \(name)：切到 \(name) 的窗口再说一次。",
                                                 "That Screen Sharing window is not \(name): switch to the window of \(name) and try again.")
                default: problem = L("这句没送到，请再说一次。", "That one was not delivered; please try again.")
                }
                from = await runner.run(["log-mark"]).text
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    func skipTest() {
        finish(L("设置完成", "You're ready"),
               L("以后在 \(targetName) 的屏幕共享窗口里，直接用 Typeless 说话就行。", "From now on, just dictate with Typeless in the Screen Sharing window of \(targetName)."),
               added: true)
    }

    func finish(_ title: String, _ text: String, added: Bool) {
        guard stage != .done else { return }
        stage = .done; activity = nil; action = nil; hint = ""; problem = ""; retry = nil
        finishedTitle = title; finished = text; finishedAdded = added; upgrading = false
        NSApp.activate(ignoringOtherApps: true)
        Chime.ding()
    }

    // ---- home actions
    func remove(_ name: String, remote: Bool) async {
        menu = false; operation = L("移除 \(name)", "Removing \(name)"); items = []
        doing(L("正在移除 \(name)…", "Removing \(name)…"))
        let r = await runner.run(["remove", name] + (remote ? ["--remote"] : []))
        let left = r.value("unreachable").map { L("\n不过连不上 \($0)，那边的接收端还在，可以以后在那台 Mac 上卸载。",
                                                   "\n\($0) could not be reached, so its receiver is still installed there.") } ?? ""
        if r.code == 0 { finish(L("已移除", "Removed"), L("已移除 \(name)。", "\(name) is removed.") + left, added: false) }
        else { fail(L("移除 \(name) 失败。", "Removing \(name) failed."), retry: { [unowned self] in await self.remove(name, remote: remote) }) }
    }

    func uninstallAll(remote: Bool) async {
        menu = false; operation = L("全部卸载", "Uninstalling"); items = []
        doing(L("正在卸载…", "Uninstalling…"))
        let r = await runner.run(["uninstall-all"] + (remote ? ["--remote"] : []))
        let left = r.value("unreachable").map { L("\n不过连不上 \($0)，那边的接收端还在。", "\nCould not reach \($0); receivers are still installed there.") } ?? ""
        if r.code == 0 { finish(L("已卸载", "Uninstalled"), L("这台 Mac 上的桥接已全部卸载。", "The bridge is fully uninstalled from this Mac.") + left, added: false) }
        else { fail(L("卸载没有全部完成。", "Uninstalling did not finish."), retry: { [unowned self] in await self.uninstallAll(remote: remote) }) }
    }

    func upgradeAll() async {
        for name in controlled { guard await installRemote(name) else { return } }
        guard await installLocal() else { return }
        await grantLocal()
    }

    // ---- the sidebar
    var outline: [String] {
        if upgrading { return [L("检查这台 Mac", "Check this Mac")] + controlled.map { L("更新 \($0)", "Update \($0)") } + [L("更新这台 Mac", "Update this Mac")] }
        let there = picked == nil ? L("设置要控制的 Mac", "Set up the other Mac") : L("设置 \(targetName)", "Set up \(targetName)")
        return [L("检查这台 Mac", "Check this Mac"), L("选择要控制的 Mac", "Choose a Mac"), there,
                L("设置这台 Mac", "Set up this Mac"), L("试一试", "Try it")]
    }
    var outlineIndex: Int {
        if stage == .done { return outline.count }
        if upgrading {
            switch stage {
            case .check, .choose, .connect: return 0
            case .installRemote, .grantRemote: return 1 + (controlled.firstIndex(of: currentRemote) ?? 0)
            default: return outline.count - 1
            }
        }
        switch stage {
        case .check: return 0
        case .choose, .connect: return 1
        case .installRemote, .grantRemote: return 2
        case .installLocal, .grantLocal: return 3
        case .test, .done: return 4
        }
    }
}

// MARK: sound
/// The "ding" of a finished microwave: a small bell, synthesised so no sound file has to ship.
@MainActor
enum Chime {
    private static var playing: NSSound?   // NSSound must be kept alive while it plays

    static func ding() {
        playing = NSSound(data: wav()) ?? NSSound(named: "Glass")
        playing?.volume = 0.8
        playing?.play()
    }

    static func wav() -> Data {
        let rate = 44_100.0, seconds = 1.8, base = 1_568.0        // G6, about a kitchen-timer bell
        // (frequency ratio, loudness, how fast it fades): a bell's partials are not harmonic.
        let partials: [(Double, Double, Double)] = [(1, 1.0, 2.4), (1.003, 0.5, 2.6), (2.76, 0.30, 4.8),
                                                    (5.40, 0.10, 9.0), (0.5, 0.06, 3.0)]
        var pcm = Data(capacity: Int(rate * seconds) * 2)
        for i in 0..<Int(rate * seconds) {
            let t = Double(i) / rate
            var v = 0.0
            for (ratio, loud, fade) in partials { v += loud * exp(-fade * t) * sin(2 * .pi * base * ratio * t) }
            let attack = min(1, t / 0.003)
            let sample = Int16(max(-1, min(1, v * 0.28 * attack)) * 32_767)
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var out = Data()
        func text(_ s: String) { out.append(s.data(using: .ascii)!) }
        func u32(_ x: UInt32) { withUnsafeBytes(of: x.littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ x: UInt16) { withUnsafeBytes(of: x.littleEndian) { out.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + pcm.count)); text("WAVE")
        text("fmt "); u32(16); u16(1); u16(1); u32(44_100); u32(88_200); u16(2); u16(16)
        text("data"); u32(UInt32(pcm.count)); out.append(pcm)
        return out
    }
}

// MARK: design pieces
enum Metric {
    static let window = CGSize(width: 840, height: 620)
    static let titleBar: CGFloat = 28
    static let sidebar: CGFloat = 240
    static let content: CGFloat = 520
}

/// The colours of the app icon: sky blue to teal.
enum Brand {
    static let sky = Color(red: 0x20 / 255, green: 0xB1 / 255, blue: 0xDF / 255)
    static let teal = Color(red: 0x03 / 255, green: 0xCB / 255, blue: 0xB3 / 255)
    /// For text and buttons: darker in light mode so white text and small type stay readable.
    static let ink = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x3C / 255, green: 0xC4 / 255, blue: 0xEA / 255, alpha: 1)
            : NSColor(red: 0x08 / 255, green: 0x86 / 255, blue: 0xB8 / 255, alpha: 1)
    })
    /// Deeper stops for small solid shapes that carry white text or symbols.
    static let skyDeep = Color(red: 0x14 / 255, green: 0x98 / 255, blue: 0xD2 / 255)
    static let tealDeep = Color(red: 0x05 / 255, green: 0xAE / 255, blue: 0x98 / 255)
    static let gradient = LinearGradient(colors: [skyDeep, tealDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let glow = LinearGradient(colors: [sky, teal], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let along = LinearGradient(colors: [sky, teal], startPoint: .leading, endPoint: .trailing)
}

/// Light and dark values of one colour.
func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
}
enum Surface {
    static let card = adaptive(.white, NSColor(white: 1, alpha: 0.06))
    static let edge = adaptive(NSColor(white: 0, alpha: 0.07), NSColor(white: 1, alpha: 0.10))
    static let shadow = adaptive(NSColor(white: 0, alpha: 0.07), .clear)
    static let tile = adaptive(.white, NSColor(white: 1, alpha: 0.09))
}

extension View {
    /// A soft raised card: continuous corners, hairline edge, faint shadow (none in dark mode).
    func card(radius: CGFloat = 16, padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Surface.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Surface.edge, lineWidth: 0.5))
            .shadow(color: Surface.shadow, radius: 14, x: 0, y: 5)
    }
}

/// The primary action: a brand-gradient capsule with a soft glow.
struct BrandButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 20).frame(minWidth: 96, minHeight: 34)
            .background(Capsule().fill(Brand.gradient))
            .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.15 : 0)))
            .shadow(color: Brand.sky.opacity(enabled ? 0.35 : 0), radius: 8, x: 0, y: 3)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

/// Quiet actions (Quit, Back, Skip): text only.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundColor(.secondary)
            .padding(.horizontal, 10).frame(minHeight: 34)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0)))
            .contentShape(Capsule())
    }
}

struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = .sidebar; v.blendingMode = .behindWindow; v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// A slow "breathing" phase between 0 and 1, from the clock (no view state needed).
func breath(_ date: Date, period: Double = 2.4) -> Double {
    (sin(date.timeIntervalSinceReferenceDate * 2 * .pi / period) + 1) / 2
}

/// "Waiting for you": a dot with a ring that keeps expanding.
struct PulseDot: View {
    var color: Color = Brand.sky
    var size: CGFloat = 8
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            ZStack {
                Circle().stroke(color.opacity(0.6 * (1 - t)), lineWidth: 1.5).frame(width: size * (1 + 1.6 * t), height: size * (1 + 1.6 * t))
                Circle().fill(color).frame(width: size, height: size)
            }
            .frame(width: size * 2.8, height: size * 2.8)
        }
    }
}

/// A slim brand-coloured bar: estimated when `expected` is known, else a gliding segment.
struct BrandBar: View {
    let since: Date
    let expected: Double?
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if let expected {
                        let e = ctx.date.timeIntervalSince(since)
                        Capsule().fill(Brand.along).frame(width: max(8, w * min(0.95, 1 - exp(-1.6 * e / expected))))
                    } else {
                        let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                        Capsule().fill(Brand.along).frame(width: w * 0.3).offset(x: (w * 1.3) * t - w * 0.3)
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 6)
    }
}

struct NumberBadge: View {
    let n: Int
    var body: some View {
        Text("\(n)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white)
            .frame(width: 20, height: 20).background(Circle().fill(Brand.gradient))
    }
}

// ---- the hero: this Mac → the other Mac
enum DeviceLook { case quiet, active, done, unknown }
enum LineLook { case idle, working, flowing, solid }

struct DeviceTile: View {
    let symbol: String
    let label: String
    let look: DeviceLook
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if look == .active {
                    TimelineView(.animation) { ctx in
                        let b = breath(ctx.date, period: 2.2)
                        RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Brand.glow)
                            .frame(width: 88, height: 88).blur(radius: 8).opacity(0.18 + 0.20 * b).scaleEffect(0.96 + 0.06 * b)
                    }
                }
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Surface.tile)
                    .frame(width: 72, height: 72)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Surface.edge, lineWidth: 0.5))
                    .shadow(color: Surface.shadow.opacity(1.4), radius: 12, x: 0, y: 6)
                Image(systemName: symbol).font(.system(size: 30, weight: .medium))
                    .foregroundStyle(look == .unknown ? AnyShapeStyle(Color(nsColor: .tertiaryLabelColor)) : AnyShapeStyle(Brand.gradient))
                if look == .unknown {
                    Image(systemName: "questionmark").font(.system(size: 11, weight: .bold)).foregroundColor(.secondary).offset(y: -3)
                }
                if look == .done {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
                        .foregroundStyle(.white, Brand.teal)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)).padding(1))
                        .offset(x: 32, y: -32)
                }
            }
            .frame(width: 92, height: 92)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 110)
        }
    }
}

struct FlowLine: View {
    let look: LineLook
    let symbol: String?
    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.gradient)
                } else { Color.clear }
            }
            .frame(height: 14)
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                Canvas { gc, size in
                    let y = size.height / 2
                    var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                    if look == .solid {
                        gc.stroke(line, with: .linearGradient(Gradient(colors: [Brand.sky, Brand.teal]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)), lineWidth: 2)
                    } else {
                        gc.stroke(line, with: .linearGradient(Gradient(colors: [Brand.sky.opacity(0.5), Brand.teal.opacity(0.5)]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                                  style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.5, 7]))
                    }
                    guard look == .working || look == .flowing else { return }
                    let period = look == .flowing ? 1.4 : 2.4
                    let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                    for i in 0..<3 {
                        let p = (t + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        let x = size.width * p
                        let fade = min(1, min(p, 1 - p) * 6)
                        let r: CGFloat = look == .flowing ? 3.5 : 3
                        let color = Color(red: 0.12 * (1 - p) + 0.01 * p, green: 0.69 * (1 - p) + 0.80 * p, blue: 0.87 * (1 - p) + 0.70 * p)
                        gc.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(color.opacity(fade)))
                    }
                }
            }
            .frame(height: 12)
            Color.clear.frame(height: 14)
        }
        .frame(width: 140)
        .padding(.bottom, 24)
    }
}

struct BridgeScene: View {
    @ObservedObject var model: Model
    var body: some View {
        let s = look
        HStack(spacing: 6) {
            DeviceTile(symbol: "laptopcomputer", label: L("这台 Mac", "This Mac"), look: s.here)
            FlowLine(look: s.line, symbol: s.symbol)
            DeviceTile(symbol: "desktopcomputer", label: s.thereLabel, look: s.there)
        }
    }

    var look: (here: DeviceLook, there: DeviceLook, line: LineLook, symbol: String?, thereLabel: String) {
        let name = model.upgrading ? (model.currentRemote.isEmpty ? L("被控的 Mac", "Your Macs") : model.currentRemote)
                                   : (model.picked == nil ? L("要控制的 Mac", "The other Mac") : model.targetName)
        if model.menu { return (.quiet, .quiet, .solid, nil, model.controlled.count == 1 ? model.controlled[0] : L("\(model.controlled.count) 台 Mac", "\(model.controlled.count) Macs")) }
        if model.operation != nil { return (.quiet, .active, .working, nil, model.controlled.count == 1 ? model.controlled[0] : L("被控的 Mac", "Your Macs")) }
        switch model.stage {
        case .check: return (.active, .unknown, .idle, nil, name)
        case .choose: return (.quiet, model.picked == nil ? .unknown : .active, .idle, nil, name)
        case .connect: return (.quiet, .active, .working, "lock.fill", name)
        case .installRemote, .grantRemote: return (.quiet, .active, .working, nil, name)
        case .installLocal, .grantLocal: return (.active, model.upgrading ? .quiet : .done, .solid, nil, name)
        case .test: return (.active, .active, .flowing, "waveform", name)
        case .done: return (.done, .done, .solid, nil, name)
        }
    }
}

// ---- cards
struct ProgressCard: View {
    let items: [Item]
    let activity: Activity?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !items.isEmpty { Checklist(items: items) }
            if let activity {
                VStack(alignment: .leading, spacing: 9) {
                    Text(activity.text).font(.system(size: 12)).foregroundColor(.secondary)
                    BrandBar(since: activity.since, expected: activity.expected)
                }
            }
        }
        .card(padding: 20)
    }
}

struct AppChip: View {
    let name: String
    let on: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
            Text(name).font(.system(size: 13, weight: .semibold))
            Spacer()
            if on {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Brand.teal)
                    Text(L("已打开", "On")).foregroundColor(Brand.teal)
                }.font(.system(size: 12, weight: .semibold))
            } else {
                HStack(spacing: 2) { PulseDot(size: 6); Text(L("等你打开", "Waiting")).font(.system(size: 12)).foregroundColor(.secondary) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
    }
}

/// Something only the user can do: the hero of the page.
struct ActionCard: View {
    let action: UserAction
    let granted: Set<String>
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 2) {
                PulseDot(color: Brand.ink, size: 5)
                Text(action.remote ? L("轮到你了 · 在屏幕共享窗口里", "Your turn · in the Screen Sharing window") : L("轮到你了", "Your turn"))
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(Brand.ink)
            }
            .padding(.leading, 2).padding(.trailing, 10).padding(.vertical, 1)
            .background(Capsule().fill(Brand.sky.opacity(0.14)))
            Text(action.title).font(.system(size: 17, weight: .semibold)).padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(action.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        NumberBadge(n: i + 1).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        Text(step).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !action.apps.isEmpty {
                VStack(spacing: 6) { ForEach(action.apps, id: \.self) { AppChip(name: $0, on: granted.contains($0)) } }
            }
            if !action.footnote.isEmpty { Text(action.footnote).font(.system(size: 11)).foregroundColor(.secondary) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Surface.card))
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.sky.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.sky.opacity(0.35), lineWidth: 1))
        .shadow(color: Surface.shadow, radius: 14, x: 0, y: 5)
    }
}

struct Banner: View {
    let text: String
    let symbol: String
    let color: Color
    var tinted = true
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundColor(color)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tinted ? color.opacity(0.10) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tinted ? color.opacity(0.25) : Surface.edge, lineWidth: 0.5))
    }
}

struct Checklist: View {
    let items: [Item]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                HStack(spacing: 11) {
                    Group {
                        switch item.state {
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Brand.teal)
                        case .active: ProgressView().controlSize(.small).scaleEffect(0.8)
                        case .needsYou: PulseDot(size: 7)
                        case .pending: Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 1.2).frame(width: 15, height: 15)
                        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .red)
                        }
                    }
                    .font(.system(size: 16)).frame(width: 20, height: 20)
                    Text(item.title)
                        .font(.system(size: 13, weight: item.state == .active || item.state == .needsYou ? .semibold : .regular))
                        .foregroundColor(item.state == .pending ? .secondary : item.state == .active || item.state == .needsYou ? Brand.ink : .primary)
                }
            }
        }
    }
}

/// Every page starts the same way: the scene, then a centred title and one line of explanation.
struct PageHeader: View {
    @ObservedObject var model: Model
    let title: String
    var subtitle = ""
    var body: some View {
        VStack(spacing: 0) {
            BridgeScene(model: model).padding(.bottom, 12)
            Text(title).font(.system(size: 26, weight: .semibold)).tracking(zh ? 0.5 : -0.3).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 13.5)).foregroundColor(.secondary).lineSpacing(3)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440).padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }
}

// MARK: views
struct ContentView: View {
    @ObservedObject var model: Model

    var page: String {
        if model.menu { return "home" }
        if model.stage == .done { return "done" }
        if model.operation != nil { return "op" }
        if model.stage == .connect && model.needPassword { return "password" }
        return "\(model.stage)"
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: Metric.sidebar)
            Rectangle().fill(Surface.edge).frame(width: 0.5)
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0).frame(maxHeight: 26)
                    ZStack(alignment: .top) {
                        pageView
                            .frame(maxWidth: Metric.content)
                            .id(page)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 40).padding(.top, 20)
                .animation(.easeOut(duration: 0.3), value: page)
                Footer(model: model)
            }
            .background(
                ZStack(alignment: .top) {
                    Color(nsColor: .windowBackgroundColor)
                    LinearGradient(colors: [Brand.sky.opacity(0.10), Brand.teal.opacity(0.05), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 260)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()      // fill the hidden title bar too (the scene sizes the area below it)
        .tint(Brand.ink)
        .confirmationDialog(L("移除 \(model.confirmRemove ?? "")？", "Remove \(model.confirmRemove ?? "")?"),
                            isPresented: Binding(get: { model.confirmRemove != nil }, set: { if !$0 { model.confirmRemove = nil } })) {
            Button(L("移除", "Remove"), role: .destructive) {
                let name = model.confirmRemove ?? ""; model.confirmRemove = nil
                model.act { await model.remove(name, remote: model.alsoRemote) }
            }
        } message: {
            Text(model.alsoRemote ? L("同时会卸载那台 Mac 上的接收端。", "Its receiver will be uninstalled there too.")
                                  : L("那台 Mac 上的接收端会保留。", "Its receiver stays installed there."))
        }
        .confirmationDialog(L("卸载全部？", "Uninstall everything?"), isPresented: $model.confirmUninstall) {
            Button(L("全部卸载", "Uninstall"), role: .destructive) { model.act { await model.uninstallAll(remote: model.alsoRemote) } }
        } message: {
            Text(model.alsoRemote ? L("这台 Mac 和所有被控 Mac 上的桥接都会被卸载。", "The bridge is removed from this Mac and from every Mac it controls.")
                                  : L("只卸载这台 Mac 上的桥接。", "Only this Mac's part is removed."))
        }
    }

    @ViewBuilder var pageView: some View {
        switch page {
        case "home": HomeView(model: model)
        case "done": DoneView(model: model)
        case "op": WorkPage(model: model, title: model.operation ?? "")
        case "password": PasswordView(model: model)
        default:
            switch model.stage {
            case .check: WorkPage(model: model, title: L("检查这台 Mac", "Checking this Mac"),
                                  subtitle: L("先确认这台 Mac 上有 Typeless 和需要的工具。", "First, making sure this Mac has Typeless and the tools it needs."))
            case .choose: ChooseView(model: model)
            case .connect: WorkPage(model: model, title: L("连接 \(model.targetName)", "Connecting to \(model.targetName)"),
                                    subtitle: L("两台 Mac 之间走加密的 SSH 连接，不经过任何第三方。", "The two Macs talk over encrypted SSH, never through a third party."))
            case .installRemote, .grantRemote:
                WorkPage(model: model,
                         title: model.upgrading ? L("更新 \(model.currentRemote)", "Updating \(model.currentRemote)")
                                                : L("设置 \(model.targetName)", "Setting up \(model.targetName)"),
                         subtitle: L("接收端装在那台 Mac 上，你说的话会在那里打出来。", "The receiver goes on that Mac; it types what you say over there."))
            case .installLocal, .grantLocal:
                WorkPage(model: model,
                         title: model.upgrading ? L("更新这台 Mac", "Updating this Mac") : L("设置这台 Mac", "Setting up this Mac"),
                         subtitle: L("这台 Mac 负责听写，并把文字送进屏幕共享窗口。", "This Mac takes your dictation and sends it into the Screen Sharing window."))
            case .test: TestView(model: model)
            default: EmptyView()
            }
        }
    }
}

struct Sidebar: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 38, height: 38)
                    .shadow(color: Brand.teal.opacity(0.25), radius: 6, x: 0, y: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Sharing Bridge").font(.system(size: 13, weight: .semibold))
                    Text("for Typeless").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            .padding(.top, 54).padding(.bottom, 30).padding(.horizontal, 20)
            if !(model.menu || model.operation != nil) {
                let index = model.outlineIndex
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.outline.enumerated()), id: \.offset) { i, title in
                        StepRow(number: i + 1, title: title, state: i < index ? .done : i == index ? .active : .pending,
                                last: i == model.outline.count - 1)
                    }
                }
                .padding(.horizontal, 12)
                .animation(.easeOut(duration: 0.3), value: index)
            }
            Spacer()
            if !model.version.isEmpty {
                Text(L("版本 ", "Version ") + model.version).font(.system(size: 11)).foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SidebarMaterial())
    }
}

struct StepRow: View {
    let number: Int
    let title: String
    let state: ItemState
    let last: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 0) {
                ZStack {
                    switch state {
                    case .done:
                        Circle().fill(Brand.gradient).frame(width: 20, height: 20)
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundColor(.white)
                    case .active, .needsYou, .failed:
                        Circle().fill(Brand.gradient).frame(width: 20, height: 20)
                            .shadow(color: Brand.sky.opacity(0.45), radius: 5, x: 0, y: 1)
                        Text("\(number)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white)
                    case .pending:
                        Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1.2).frame(width: 20, height: 20)
                        Text("\(number)").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.secondary)
                    }
                }
                .frame(width: 22, height: 22)
                if !last {
                    Rectangle().fill(state == .done ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.12)))
                        .frame(width: 1.5, height: 20).clipShape(Capsule())
                }
            }
            Text(title)
                .font(.system(size: 13, weight: state == .active ? .semibold : .regular))
                .foregroundColor(state == .pending ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
                .padding(.top, 3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
    }
}

/// The bottom bar: secondary actions on the left, the primary one at the right (HIG).
struct Footer: View {
    @ObservedObject var model: Model
    var body: some View {
        HStack(spacing: 10) {
            leading
            Spacer()
            trailing
        }
        .controlSize(.large)
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 22)
    }

    @ViewBuilder var leading: some View {
        if model.menu {
            Button(role: .destructive) { model.confirmUninstall = true } label: { Text(L("全部卸载…", "Uninstall…")).foregroundColor(.red) }.disabled(model.busy)
        } else if model.stage != .done {
            Button(L("退出", "Quit")) { NSApp.terminate(nil) }.buttonStyle(QuietButtonStyle())
            if model.stage == .connect && (model.needPassword || model.action != nil) {
                Button { model.goBack() } label: { Label(L("返回", "Back"), systemImage: "chevron.left") }.buttonStyle(QuietButtonStyle())
            }
        }
    }

    @ViewBuilder var trailing: some View {
        if !model.problem.isEmpty && !model.busy, let retry = model.retry {
            Button(L("重试", "Try again")) { model.act(retry) }.keyboardShortcut(.defaultAction).buttonStyle(BrandButtonStyle())
        } else if model.menu {
            // An upgrade on offer becomes the main action; once everything is current it only reinstalls.
            if model.versionsKnown && !model.upToDate {
                Button(L("添加一台 Mac", "Add a Mac")) { model.act { await model.addAnother() } }.disabled(model.busy)
                Button(L("升级到 \(model.version)", "Upgrade to \(model.version)")) {
                    model.reinstalling = false; model.upgrading = true; model.act { await model.check() }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(BrandButtonStyle()).disabled(model.busy)
            } else {
                Button(model.upToDate ? L("重新安装", "Reinstall") : L("全部升级", "Upgrade")) {
                    model.reinstalling = model.upToDate; model.upgrading = true; model.act { await model.check() }
                }
                .disabled(model.busy || !model.versionsKnown)
                Button(L("添加一台 Mac", "Add a Mac")) { model.act { await model.addAnother() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(BrandButtonStyle()).disabled(model.busy)
            }
        } else if model.stage == .done {
            if model.finishedAdded {
                Button(L("再添加一台 Mac", "Add another Mac")) { model.act { await model.addAnother() } }
            }
            Button(L("完成", "Done")) { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction).buttonStyle(BrandButtonStyle())
        } else if model.stage == .choose && model.operation == nil {
            Button(L("继续", "Continue")) { model.act { await model.connect() } }
                .keyboardShortcut(.defaultAction).buttonStyle(BrandButtonStyle())
                .disabled(model.busy || model.scanning || (model.picked == nil && model.manualHost.trimmingCharacters(in: .whitespaces).isEmpty))
        } else if model.stage == .connect && model.needPassword {
            Button(L("连接", "Connect")) { model.act { await model.connect() } }
                .keyboardShortcut(.defaultAction).buttonStyle(BrandButtonStyle())
                .disabled(model.busy || model.password.isEmpty || model.account.isEmpty)
        } else if model.action?.remote == true {
            Button(L("切到屏幕共享", "Show Screen Sharing")) {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ScreenSharing") {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            }.buttonStyle(BrandButtonStyle())
        } else if model.stage == .test {
            Button(L("跳过测试", "Skip the test")) { model.skipTest() }.buttonStyle(QuietButtonStyle())
        } else if model.stage == .grantLocal && !model.missingLocal.isEmpty && model.activity == nil {
            if model.openedSettings {
                Button(L("再次打开系统设置", "Open System Settings Again")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            } else {
                Button(L("打开系统设置", "Open System Settings")) { model.act { await model.openLocalSettings() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(BrandButtonStyle()).disabled(model.busy)
            }
        }
    }
}

/// The page used while work happens: header, then either the user's task or the machine's progress.
struct WorkPage: View {
    @ObservedObject var model: Model
    let title: String
    var subtitle = ""
    var body: some View {
        VStack(spacing: 16) {
            PageHeader(model: model, title: title, subtitle: subtitle)
            if let action = model.action {
                ActionCard(action: action, granted: model.granted)
            } else if !model.items.isEmpty || model.activity != nil {
                ProgressCard(items: model.items, activity: model.activity)
            }
            Notes(model: model)
        }
    }
}

struct Notes: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(spacing: 8) {
            if !model.problem.isEmpty { Banner(text: model.problem, symbol: "exclamationmark.triangle.fill", color: .orange) }
            if !model.hint.isEmpty { Banner(text: model.hint, symbol: "lightbulb.fill", color: .yellow, tinted: false) }
        }
        .animation(.easeOut(duration: 0.2), value: model.problem)
        .animation(.easeOut(duration: 0.2), value: model.hint)
    }
}

struct HomeView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(spacing: 18) {
            PageHeader(model: model, title: L("桥接已经装好", "The bridge is installed"),
                       subtitle: L("在下面这些 Mac 的屏幕共享窗口里，直接用 Typeless 说话就行。", "Dictate with Typeless in the Screen Sharing window of these Macs."))
            VStack(spacing: 0) {
                ForEach(Array(model.controlled.enumerated()), id: \.offset) { i, name in
                    if i > 0 { Divider().padding(.leading, 54) }
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer").font(.system(size: 17)).foregroundStyle(Brand.gradient)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.sky.opacity(0.10)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name).font(.system(size: 13, weight: .medium))
                            if model.versionsKnown {
                                Text(L("版本 ", "Version ") + model.versionLabel(model.installedThere[name]))
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Button(L("移除…", "Remove…")) { model.confirmRemove = name }
                            .buttonStyle(.borderless).foregroundColor(.secondary).disabled(model.busy)
                    }
                    .padding(.vertical, 9)
                }
            }
            .card(padding: 12)
            VersionLine(model: model)
            Toggle(L("移除或卸载时，同时卸载那台 Mac 上的接收端", "When removing, also uninstall the receiver on that Mac"), isOn: $model.alsoRemote)
                .toggleStyle(.checkbox).font(.system(size: 12)).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Notes(model: model)
        }
    }
}

/// Home: are the installed versions the one just downloaded?
struct VersionLine: View {
    @ObservedObject var model: Model
    var body: some View {
        HStack(spacing: 8) {
            if !model.versionsKnown {
                ProgressView().controlSize(.small).scaleEffect(0.8)
                Text(L("正在检查版本…", "Checking versions…")).foregroundColor(.secondary)
            } else if model.upToDate {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.white, Brand.teal)
                Text(L("已是最新版本 \(model.version)", "Up to date: \(model.version)"))
            } else {
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(.white, Brand.sky)
                Text(L("可升级到 \(model.version)", "\(model.version) is available")).fontWeight(.semibold)
                Text(L("· 这台 Mac：\(model.versionLabel(model.installedHere))", "· this Mac: \(model.versionLabel(model.installedHere))"))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(model.versionsKnown && !model.upToDate ? Brand.sky.opacity(0.08) : Color.primary.opacity(0.04)))
    }
}

struct ChooseView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(spacing: 14) {
            PageHeader(model: model, title: L("选择要控制的 Mac", "Choose the Mac to control"),
                       subtitle: L("下面是局域网里开了屏幕共享的 Mac，选你要远程控制的那台。",
                                   "These Macs on your network have Screen Sharing on. Pick the one you control remotely."))
            VStack(spacing: 0) {
                if model.scanning {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text(L("正在查找…", "Looking…")).foregroundColor(.secondary) }
                        .font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 92)
                } else if model.macs.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 20)).foregroundStyle(Brand.gradient)
                        Text(L("没找到开了屏幕共享的 Mac", "No Mac with Screen Sharing found")).font(.system(size: 13, weight: .medium))
                        Text(L("可以在下面直接填它的地址。", "You can type its address below.")).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 104)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(model.macs) { mac in
                                MacRow(mac: mac, selected: model.picked == mac) {
                                    model.picked = mac; model.manualHost = ""; model.manual = false; model.problem = ""
                                }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(model.macs.count) * 56 - 2, 166))
                }
            }
            .card(padding: 6)
            HStack(spacing: 10) {
                if model.showAddress || model.macs.isEmpty {
                    Text(L("地址", "Address")).font(.system(size: 12)).foregroundColor(.secondary)
                    TextField("studio.local", text: $model.manualHost).textFieldStyle(.roundedBorder).frame(width: 200)
                } else {
                    Button(L("不在列表里？输入地址…", "Not listed? Enter an address…")) { model.showAddress = true }
                        .buttonStyle(.link).font(.system(size: 12))
                }
                Spacer()
                Button { model.act { await model.discover() } } label: { Label(L("重新查找", "Look again"), systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless).font(.system(size: 12)).foregroundColor(.secondary).disabled(model.busy || model.scanning)
            }
            .padding(.horizontal, 4)
            Notes(model: model)
        }
    }
}

struct MacRow: View {
    let mac: Mac
    let selected: Bool
    let pick: () -> Void
    var body: some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer").font(.system(size: 17))
                    .foregroundStyle(mac.added ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(Brand.gradient))
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Brand.sky.opacity(selected ? 0.16 : 0.10)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(mac.name).font(.system(size: 13, weight: .semibold))
                    Text(mac.host).font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                if mac.added {
                    Text(L("已添加", "Added")).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Color.primary.opacity(0.07)))
                } else if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundColor(.white)
                        .frame(width: 20, height: 20).background(Circle().fill(Brand.gradient))
                }
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 10).frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(selected ? Brand.sky.opacity(0.10) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(selected ? Brand.sky.opacity(0.45) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(mac.added).opacity(mac.added ? 0.55 : 1)
    }
}

struct PasswordView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(spacing: 16) {
            PageHeader(model: model, title: L("登录到 \(model.targetName)", "Sign in to \(model.targetName)"),
                       subtitle: L("第一次连接需要它的账户和开机密码，只需要这一次。", "The first connection needs its account and login password, just this once."))
            VStack(spacing: 14) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text(L("账户", "Account")).font(.system(size: 13)).foregroundColor(.secondary).gridColumnAlignment(.trailing)
                        TextField("", text: $model.account).textFieldStyle(.roundedBorder).frame(width: 260)
                    }
                    GridRow {
                        Text(L("密码", "Password")).font(.system(size: 13)).foregroundColor(.secondary)
                        SecureField("", text: $model.password).textFieldStyle(.roundedBorder).frame(width: 260)
                    }
                }
                Label(L("密码只用于这次登录，不会被保存，之后改用专用密钥。", "Used for this login only and never stored; a dedicated key is used after that."),
                      systemImage: "lock.shield.fill")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .card(padding: 20)
            Notes(model: model)
            if let activity = model.activity { ProgressCard(items: [], activity: activity) }
        }
    }
}

/// Listening for the test sentence: a breathing microphone.
struct TestView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(spacing: 16) {
            PageHeader(model: model, title: L("说一句话试试", "Say something"),
                       subtitle: L("确认文字真的能送到 \(model.targetName)。", "To make sure your words reach \(model.targetName)."))
            HStack(spacing: 22) {
                TimelineView(.animation) { ctx in
                    let b = breath(ctx.date)
                    ZStack {
                        Circle().fill(Brand.glow).frame(width: 84, height: 84).opacity(0.14 + 0.14 * b).scaleEffect(0.9 + 0.1 * b)
                        Circle().fill(Brand.gradient).frame(width: 56, height: 56)
                            .shadow(color: Brand.sky.opacity(0.4), radius: 8, x: 0, y: 3)
                        Image(systemName: model.testHeard ? "checkmark" : "mic.fill").font(.system(size: 22, weight: .semibold)).foregroundColor(.white)
                    }
                }
                .frame(width: 88, height: 88)
                VStack(alignment: .leading, spacing: 11) {
                    TestStep(n: 1, text: L("切到 \(model.targetName) 的屏幕共享窗口", "Switch to the Screen Sharing window of \(model.targetName)"))
                    TestStep(n: 2, text: L("点进任意一个输入框", "Click into any text field"))
                    TestStep(n: 3, text: L("用 Typeless 说一句话", "Dictate a sentence with Typeless"))
                }
                Spacer(minLength: 0)
            }
            .card(radius: 16, padding: 18)
            HStack(spacing: 4) {
                if model.testHeard {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Brand.teal)
                    Text(L("收到了！", "Got it!")).font(.system(size: 14, weight: .semibold))
                } else {
                    PulseDot(size: 7)
                    Text(L("正在等你说话…", "Listening for your sentence…")).font(.system(size: 14, weight: .medium))
                }
            }
            Notes(model: model)
        }
    }
}

struct TestStep: View {
    let n: Int
    let text: String
    var body: some View {
        HStack(spacing: 9) {
            NumberBadge(n: n)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DoneView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(spacing: 0) {
            if model.finishedAdded {
                BridgeScene(model: model).padding(.bottom, 12)
            } else {
                ZStack {
                    Circle().fill(Brand.gradient).frame(width: 72, height: 72).shadow(color: Brand.teal.opacity(0.4), radius: 14, x: 0, y: 5)
                    Image(systemName: "checkmark").font(.system(size: 30, weight: .bold)).foregroundColor(.white)
                }
                .padding(.top, 20).padding(.bottom, 22)
            }
            Text(model.finishedTitle).font(.system(size: 28, weight: .semibold))
            Text(model.finished).font(.system(size: 14)).foregroundColor(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440).padding(.top, 6)
            if model.finishedAdded {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("记住一件事", "One thing to remember")).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary).textCase(.uppercase)
                    Rule(symbol: "checkmark.circle.fill", color: Brand.teal,
                         text: L("Typeless 的\"复制\"弹窗自动关掉 = 文字已经送到。", "Typeless' Copy popup closes by itself = the text arrived."))
                    Rule(symbol: "exclamationmark.circle.fill", color: .orange,
                         text: L("弹窗一直不关 = 这句没送到。点\"复制\"，再手动粘贴就行。", "The popup stays open = that sentence did not arrive. Click Copy and paste it yourself."))
                }
                .card(radius: 16, padding: 18)
                .padding(.top, 20)
                Text(L("以后想添加、移除、升级或卸载，再运行一次当初那行安装命令，就会回到这里。", "To add, remove, upgrade or uninstall later, run the same install command again; it brings you back here."))
                    .font(.system(size: 11)).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct Rule: View {
    let symbol: String
    let color: Color
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.white, color).font(.system(size: 16))
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: snapshots (design review): every page, light and dark, rendered offscreen
@MainActor
enum Snapshots {
    static func render(to folder: String, repo: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let mac = Mac(name: "Core", host: "Core.local", added: false)
        func base() -> Model { let m = Model(repo: repo); m.controlled = []; return m }
        let pages: [(String, (Model) -> Void)] = [
            ("01-check", { m in m.stage = .check; m.items = [Item(id: 0, title: "Typeless", state: .done), Item(id: 1, title: L("命令行开发工具", "Command Line Tools"), state: .active)]
                m.doing(L("正在检查这台 Mac…", "Checking this Mac…")) }),
            ("02-choose", { m in m.stage = .choose; m.macs = [mac, Mac(name: "Hub", host: "Hub.local", added: false), Mac(name: "Studio", host: "Studio.local", added: true)]; m.picked = mac }),
            ("03-choose-empty", { m in m.stage = .choose; m.macs = [] }),
            ("04-remote-login", { m in m.picked = mac; m.stage = .connect
                m.action = UserAction(title: L("在 Core 上打开\"远程登录\"", "Turn on Remote Login on Core"),
                                      steps: [L("切到 Core 的屏幕共享窗口。", "Switch to the Screen Sharing window of Core."),
                                              L("打开 系统设置 → 通用 → 共享。", "Open System Settings → General → Sharing."),
                                              L("打开\"远程登录\"。", "Turn on Remote Login.")], remote: true) }),
            ("05-password", { m in m.picked = mac; m.stage = .connect; m.needPassword = true; m.password = "xxxxxx"
                m.problem = L("账户或密码不对，请再试一次。", "The account or password is not right; please try again.") }),
            ("06-build", { m in m.picked = mac; m.stage = .installRemote
                m.items = [Item(id: 0, title: L("准备程序", "Prepare the apps"), state: .active), Item(id: 1, title: L("把接收端装到 Core", "Install the receiver on Core")),
                           Item(id: 2, title: L("在 Core 上打开开关", "Switch it on on Core")), Item(id: 3, title: L("启动接收端", "Start the receiver"))]
                m.activity = Activity(text: L("正在准备程序，第一次大约需要 1 分钟…", "Preparing the apps; the first time takes about a minute…"), since: Date().addingTimeInterval(-25), expected: 60) }),
            ("07-remote-grant", { m in m.picked = mac; m.stage = .grantRemote
                m.items = [Item(id: 0, title: "a", state: .done)]
                m.action = UserAction(title: L("在 Core 上打开这个开关", "Allow it on Core"),
                                      steps: [L("切到 Core 的屏幕共享窗口，那边的\"设备控制\"已经打开了。", "Switch to the Screen Sharing window of Core; Device Control is already open there."),
                                              L("在列表里找到下面这个 App，打开它的开关。", "Find the app below in the list and switch it on.")],
                                      apps: ["TypelessBridgeReceiver"], remote: true,
                                      footnote: L("它是蓝绿色的麦克风图标。打开后这里会自动继续。", "It has a blue-green microphone icon. This continues by itself once it is on."))
                m.hint = L("找不到它，或打开后这里没反应？在 Core 上用\"−\"删掉它，它会自动重新出现，再打开一次。", "Cannot find it? Remove it with − on Core; it reappears, then switch it on again.") }),
            ("08-local-grant", { m in m.picked = mac; m.stage = .grantLocal; m.missingLocal = ["TypelessBridgeGuard", "TypelessBridgeProbe"]; m.granted = ["TypelessBridgeGuard"]; m.openedSettings = true
                m.items = [Item(id: 0, title: "a", state: .done)]
                m.action = UserAction(title: L("在这台 Mac 上打开 2 个开关", "Switch on 2 apps on this Mac"),
                                      steps: [L("点\"打开系统设置\"，会打开\"隐私与安全性 → 设备控制\"。", "Click Open System Settings; it opens Privacy & Security → Device Control."),
                                              L("在列表里打开下面这些 App 的开关，它们排在 Typeless 旁边。", "Switch on the apps below; they sit next to Typeless in the list.")],
                                      apps: m.missingLocal, footnote: L("macOS 可能会提示\"已添加后台项目\"，这是正常的。", "macOS may say a background item was added; that is expected.")) }),
            ("09-start", { m in m.picked = mac; m.stage = .grantLocal
                m.items = [Item(id: 0, title: L("安装到这台 Mac", "Install on this Mac"), state: .done), Item(id: 1, title: L("在这台 Mac 上打开开关", "Switch them on on this Mac"), state: .done),
                           Item(id: 2, title: L("启动桥接", "Start the bridge"), state: .active)]
                m.activity = Activity(text: L("正在启动桥接，大约 10 到 30 秒…", "Starting the bridge; 10–30 seconds…"), since: Date().addingTimeInterval(-8), expected: 20) }),
            ("10-test", { m in m.picked = mac; m.stage = .test
                m.problem = L("刚才说话时，前台不是 Core 的窗口。点一下 Core 的屏幕共享窗口，再说一次。", "Screen Sharing was not in front: click the window of Core, then try again.") }),
            ("11-done", { m in m.picked = mac; m.stage = .done; m.finishedAdded = true; m.finishedTitle = L("设置完成", "You're ready")
                m.finished = L("以后在 Core 的屏幕共享窗口里，直接用 Typeless 说话就行。", "From now on, just dictate with Typeless in the Screen Sharing window of Core.") }),
            ("12-home", { m in m.menu = true; m.controlled = ["core", "hub"]; m.versionsKnown = true
                m.installedHere = ""; m.installedThere = ["core": "", "hub": m.version] }),
            ("12b-home-current", { m in m.menu = true; m.controlled = ["core", "hub"]; m.versionsKnown = true
                m.installedHere = m.version; m.installedThere = ["core": m.version, "hub": m.version] }),
            ("13-failed", { m in m.picked = mac; m.stage = .installRemote
                m.items = [Item(id: 0, title: L("准备程序", "Prepare the apps"), state: .done), Item(id: 1, title: L("把接收端装到 Core", "Install the receiver on Core")),
                           Item(id: 2, title: L("在 Core 上打开开关", "Switch it on on Core")), Item(id: 3, title: L("启动接收端", "Start the receiver"))]
                m.items[1].state = .failed; m.problem = L("在 Core 上安装失败。", "Installing on Core failed."); m.retry = {} }),
        ]
        for (name, setup) in pages {
            for dark in [false, true] {
                let m = base(); setup(m)
                let view = NSHostingView(rootView: ContentView(model: m).frame(width: Metric.window.width, height: Metric.window.height))
                view.frame = NSRect(origin: .zero, size: Metric.window)
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = view
                view.frame = NSRect(origin: .zero, size: Metric.window)
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let file = "\(folder)/\(name)\(dark ? "-dark" : "").png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
            }
        }
    }
}

// MARK: app
var sharedRunner: Runner?

/// TB_WINDOW_CHECK=<png>: open the real window invisibly, render it with its frame, print sizes, quit.
@MainActor func windowCheck(_ file: String) async {
    guard let window = NSApp.windows.first(where: { $0.isVisible }) else { exit(2) }
    window.alphaValue = 0
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    let view = window.contentView!.superview ?? window.contentView!
    print("window", window.frame.size, "content", window.contentView!.frame.size, "layout", window.contentLayoutRect.size)
    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
    }
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { sharedRunner?.stopAll() }
}

struct SetupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model: Model = {
        let repo = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) ?? FileManager.default.currentDirectoryPath
        let model = Model(repo: repo)
        sharedRunner = model.runner
        return model
    }()
    var body: some Scene {
        WindowGroup("Screen Sharing Bridge for Typeless") {
            // The hidden title bar is a safe area on top of this frame; ContentView extends into it,
            // so the window is exactly Metric.window tall with no empty strip at the bottom.
            ContentView(model: model)
                .frame(width: Metric.window.width, height: Metric.window.height - Metric.titleBar)
                .task {
                    if let preview = ProcessInfo.processInfo.environment["TB_WINDOW_CHECK"] { await windowCheck(preview); return }
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.isVisible {
                        window.makeKeyAndOrderFront(nil); window.orderFrontRegardless()
                    }
                    model.act { await model.start() }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

@main
enum Entry {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--write-ding"), i + 1 < args.count {
            try? Chime.wav().write(to: URL(fileURLWithPath: args[i + 1])); exit(0)
        }
        #if README_ART
        if let i = args.firstIndex(of: "--readme-art"), i + 1 < args.count {
            ReadmeArt.render(to: args[i + 1], repo: FileManager.default.currentDirectoryPath); exit(0)
        }
        #endif
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let repo = FileManager.default.currentDirectoryPath
            Snapshots.render(to: args[i + 1], repo: repo)
            exit(0)
        }
        // One window only: a second launch hands over to the first and leaves.
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != me }) {
            other.activate(options: [.activateAllWindows])
            exit(0)
        }
        SetupApp.main()
    }
}
