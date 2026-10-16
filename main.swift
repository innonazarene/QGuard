// QGuard — blocks Cmd+Q so muscle-memory hotkeys don't quit your game.
// Menu-bar only app (LSUIElement). Needs Accessibility permission.

import Cocoa

// MARK: - logging
let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/QGuard.log")
let logQueue = DispatchQueue(label: "qguard.log")
func qlog(_ msg: String) {
    logQueue.async {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: logURL) {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

let kKeyQ: CGKeyCode = 12
let kKeyW: CGKeyCode = 13

struct Combo {
    let code: CGKeyCode
    let label: String   // shown in the menu
    let key: String     // UserDefaults key
}

let combos = [
    Combo(code: kKeyQ, label: "⌘Q", key: "blockCmdQ"),
    Combo(code: kKeyW, label: "⌘W", key: "blockCmdW"),
]

enum Mode: String {
    case off
    case game        // only while a target app is frontmost
    case everywhere  // always

    var label: String {
        switch self {
        case .off: return "Off"
        case .game: return "Only in my games"
        case .everywhere: return "Everywhere"
        }
    }
}

final class Blocker {
    static let shared = Blocker()

    private let defaults = UserDefaults.standard
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var blockedCount = 0
    var frontBundleID: String = ""
    var frontName: String = ""

    var mode: Mode {
        get { Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .game }
        set { defaults.set(newValue.rawValue, forKey: "mode") }
    }

    var targets: [String] {
        get {
            if let saved = defaults.array(forKey: "targets") as? [String], !saved.isEmpty {
                return saved
            }
            return ["com.valvesoftware.dota2"]
        }
        set { defaults.set(newValue, forKey: "targets") }
    }

    var shouldBlockNow: Bool {
        switch mode {
        case .off: return false
        case .everywhere: return true
        case .game: return matchesTarget
        }
    }

    /// Bundle-ID match, with a name fallback for Steam-launched games whose
    /// bundle ID macOS sometimes reports empty or oddly.
    var matchesTarget: Bool {
        if targets.contains(frontBundleID) { return true }
        let name = frontName.lowercased()
        guard !name.isEmpty else { return false }
        for t in targets {
            let leaf = t.split(separator: ".").last.map(String.init)?.lowercased() ?? t.lowercased()
            if !leaf.isEmpty && name.contains(leaf) { return true }
        }
        return false
    }

    func isEnabled(_ c: Combo) -> Bool {
        if defaults.object(forKey: c.key) == nil { return true } // both on by default
        return defaults.bool(forKey: c.key)
    }

    func setEnabled(_ c: Combo, _ on: Bool) {
        defaults.set(on, forKey: c.key)
    }

    /// Combos currently being swallowed, e.g. "⌘Q, ⌘W"
    var activeLabel: String {
        let on = combos.filter { isEnabled($0) }.map { $0.label }
        return on.isEmpty ? "nothing" : on.joined(separator: ", ")
    }

    func blocks(code: CGKeyCode) -> Bool {
        guard let c = combos.first(where: { $0.code == code }) else { return false }
        return isEnabled(c)
    }

    // MARK: tap lifecycle

    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                        place: .headInsertEventTap,
                                        options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask),
                                        callback: tapCallback,
                                        userInfo: nil) else {
            qlog("TAP CREATE FAILED (trusted=\(AXIsProcessTrusted()))")
            return false
        }
        tap = t
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        qlog("TAP INSTALLED ok (trusted=\(AXIsProcessTrusted()))")
        return true
    }

    func reEnable() {
        qlog("tap was disabled by system — re-enabling")
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
    }
}

private func tapCallback(proxy: CGEventTapProxy,
                         type: CGEventType,
                         event: CGEvent,
                         refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let b = Blocker.shared

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        b.reEnable()
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown || type == .keyUp else {
        return Unmanaged.passUnretained(event)
    }

    let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags
    let isPlainCmd = flags.contains(.maskCommand)
        && !flags.contains(.maskAlternate)
        && !flags.contains(.maskControl)

    if isPlainCmd && b.blocks(code: code) {
        let decision = b.shouldBlockNow ? "BLOCKED" : "passed"
        qlog("cmd+\(code == kKeyQ ? "Q" : "W") seen -> \(decision) (front=\(b.frontBundleID.isEmpty ? "?" : b.frontBundleID), mode=\(b.mode.rawValue))")
        if b.shouldBlockNow {
            if type == .keyDown {
                b.blockedCount += 1
                DispatchQueue.main.async { AppDelegate.shared?.refreshMenu() }
            }
            return nil // swallow it
        }
    }

    return Unmanaged.passUnretained(event)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    var statusItem: NSStatusItem!
    let menu = NSMenu()

    func applicationDidFinishLaunching(_ note: Notification) {
        AppDelegate.shared = self
        qlog("=== QGuard launched (trusted=\(AXIsProcessTrusted())) ===")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        menu.delegate = self

        trackFrontmostApp()
        refreshIcon()
        refreshMenu()

        if !AXIsProcessTrusted() {
            promptForAccessibility()
        } else if !Blocker.shared.start() {
            armTrustWatchdog() // keep retrying in the background
            alert("Could not install the keyboard tap",
                  "Remove QGuard from System Settings → Privacy & Security → Accessibility, re-add it, then relaunch.")
        }
    }

    // MARK: frontmost app

    private func trackFrontmostApp() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                       object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Blocker.shared.frontBundleID = app?.bundleIdentifier ?? ""
            Blocker.shared.frontName = app?.localizedName ?? ""
            qlog("front app -> name=\"\(Blocker.shared.frontName)\" bundle=\(Blocker.shared.frontBundleID) match=\(Blocker.shared.matchesTarget)")
            self?.refreshIcon()
        }
        let front = NSWorkspace.shared.frontmostApplication
        Blocker.shared.frontBundleID = front?.bundleIdentifier ?? ""
        Blocker.shared.frontName = front?.localizedName ?? ""
    }

    // MARK: UI

    func refreshIcon() {
        let b = Blocker.shared
        let armed = b.shouldBlockNow && combos.contains(where: { b.isEnabled($0) })
        let name = armed ? "lock.shield.fill" : (b.mode == .off ? "lock.open" : "lock.shield")
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "QGuard")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.toolTip = armed ? "Blocking \(b.activeLabel)" : "Not blocking anything right now"
    }

    func refreshMenu() {
        let b = Blocker.shared
        menu.removeAllItems()

        let status = NSMenuItem(title: b.shouldBlockNow ? "Blocking \(b.activeLabel) right now"
                                                        : "\(b.activeLabel) allowed right now",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let count = NSMenuItem(title: "Accidents prevented: \(b.blockedCount)", action: nil, keyEquivalent: "")
        count.isEnabled = false
        menu.addItem(count)
        menu.addItem(.separator())

        let keysHeader = NSMenuItem(title: "Keys to block", action: nil, keyEquivalent: "")
        keysHeader.isEnabled = false
        menu.addItem(keysHeader)
        for c in combos {
            let item = NSMenuItem(title: "  \(c.label)", action: #selector(toggleCombo(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.key
            item.state = b.isEnabled(c) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        for m in [Mode.game, .everywhere, .off] {
            let item = NSMenuItem(title: m.label, action: #selector(pickMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.rawValue
            item.state = (b.mode == m) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let header = NSMenuItem(title: "Protected apps", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for id in b.targets {
            let item = NSMenuItem(title: "  \(prettyName(id))", action: #selector(removeTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.toolTip = "\(id) — click to remove"
            if id == b.frontBundleID { item.state = .on }
            menu.addItem(item)
        }
        let add = NSMenuItem(title: "Add frontmost app…", action: #selector(addFrontmost(_:)), keyEquivalent: "")
        add.target = self
        menu.addItem(add)

        menu.addItem(.separator())
        if !AXIsProcessTrusted() {
            let fix = NSMenuItem(title: "⚠︎ Grant Accessibility permission", action: #selector(openAX(_:)), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        }
        let login = NSMenuItem(title: "Open Login Items settings", action: #selector(openLoginItems(_:)), keyEquivalent: "")
        login.target = self
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit QGuard", action: #selector(quitApp(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    private func prettyName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    // MARK: actions

    @objc func toggleCombo(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let c = combos.first(where: { $0.key == key }) else { return }
        Blocker.shared.setEnabled(c, !Blocker.shared.isEnabled(c))
        refreshIcon()
        refreshMenu()
    }

    @objc func pickMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = Mode(rawValue: raw) {
            Blocker.shared.mode = m
        }
        refreshIcon()
        refreshMenu()
    }

    @objc func addFrontmost(_ sender: NSMenuItem) {
        // The menu is open, so "frontmost" is QGuard itself; use the last app we saw.
        let id = Blocker.shared.frontBundleID
        guard !id.isEmpty, id != Bundle.main.bundleIdentifier else {
            alert("Nothing to add", "Switch to the app you want protected, then come back and pick this again.")
            return
        }
        var t = Blocker.shared.targets
        if !t.contains(id) { t.append(id); Blocker.shared.targets = t }
        refreshMenu()
    }

    @objc func removeTarget(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Blocker.shared.targets = Blocker.shared.targets.filter { $0 != id }
        refreshIcon()
        refreshMenu()
    }

    @objc func openAX(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func openLoginItems(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    @objc func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        qlog("not trusted — prompting, watchdog armed")

        // Arm the watchdog FIRST. A modal alert blocks the run loop, so a timer
        // scheduled after runModal() would never exist while the alert is up.
        armTrustWatchdog()

        alert("QGuard needs Accessibility access",
              "Enable QGuard in System Settings → Privacy & Security → Accessibility. QGuard arms itself a second later, no relaunch needed.")
    }

    /// Keeps checking until macOS trusts us, then installs the tap.
    func armTrustWatchdog() {
        let t = Timer(timeInterval: 1.5, repeats: true) { timer in
            guard AXIsProcessTrusted() else { return }
            if Blocker.shared.start() {
                timer.invalidate()
                DispatchQueue.main.async {
                    self.refreshIcon()
                    self.refreshMenu()
                }
            }
        }
        // .common so it keeps firing even while a modal alert or menu is open.
        RunLoop.main.add(t, forMode: .common)
    }

    private func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn { openAX(nil) }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
