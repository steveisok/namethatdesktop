// Name That Desktop — a macOS menu bar app for naming your virtual desktop spaces.
//
// Compile:  swiftc -O -framework Cocoa NameThatDesktop.swift -o namethatdesktop
// Run:      open NameThatDesktop.app
//
// Features:
//   • Shows "[N]: name" in the menu bar for the current desktop space
//   • Manually name any space via the menu
//   • One-click "Name from Terminal CWD" grabs the working directory
//   • "Auto-detect" mode polls every 5 s and renames from the focused terminal
//   • Names persist in ~/.config/namethatdesktop/config.json

import Cocoa

// MARK: - Private CoreGraphics SPI (stable across macOS releases)

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ cid: Int32) -> Int

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray?

@_silgen_name("CGSManagedDisplaySetCurrentSpace")
func CGSManagedDisplaySetCurrentSpace(_ cid: Int32, _ display: CFString, _ space: Int)

// MARK: - Helpers

func sh(_ cmd: String) -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    p.standardOutput = pipe
    p.standardError  = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return (String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                   encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private let kTerminals: Set<String> = [
    "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
    "dev.warp.Warp-Stable", "co.zeit.hyper", "com.github.wez.wezterm",
    "net.kovidgoyal.kitty", "org.alacritty",
]

// MARK: - App

class DesktopNamer: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let version = "1.0.0"
    private var statusItem: NSStatusItem!
    private var spaceNames: [String: String] = [:]   // spaceID → name
    private var autoMode = false
    private var pollTimer: Timer?
    private var spaceCheckTimer: Timer?
    private var lastSpaceID: String = ""
    private let configPath =
        NSHomeDirectory() + "/.config/namethatdesktop/config.json"

    // MARK: Lifecycle

    func setup() {
        loadConfig()

        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)
        statusItem.button?.font =
            .monospacedSystemFont(ofSize: 12, weight: .medium)

        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(refresh),
                       name: NSWorkspace.activeSpaceDidChangeNotification,
                       object: nil)
        nc.addObserver(self, selector: #selector(refresh),
                       name: NSWorkspace.didActivateApplicationNotification,
                       object: nil)

        if autoMode { startPolling() }
        // Lightweight poll to catch space changes the notification misses
        spaceCheckTimer = Timer.scheduledTimer(
            withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let cur = self.activeSpaceID()
            if cur != self.lastSpaceID { self.refresh() }
        }
        refresh()
    }

    // MARK: Space helpers

    private var cid: Int32 { CGSMainConnectionID() }

    private func activeSpaceID() -> String {
        // "Current Space" from CGSCopyManagedDisplaySpaces reflects the
        // globally active space, unlike CGSGetActiveSpace which can be
        // stale for menu-bar-only apps.
        guard let arr = CGSCopyManagedDisplaySpaces(cid)
                as? [[String: Any]] else {
            return String(CGSGetActiveSpace(cid))
        }
        for display in arr {
            if let cur = display["Current Space"] as? [String: Any],
               let mid = cur["ManagedSpaceID"] as? Int {
                return String(mid)
            }
        }
        return String(CGSGetActiveSpace(cid))
    }

    /// All regular (non-fullscreen) desktop spaces with ordinal numbers.
    private func allSpaces() -> [(id: String, num: Int)] {
        guard let arr = CGSCopyManagedDisplaySpaces(cid)
                as? [[String: Any]] else { return [] }
        var result: [(String, Int)] = []
        var n = 1
        for display in arr {
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                if space["type"] as? Int == 2 { continue }   // fullscreen
                if let mid = space["ManagedSpaceID"] as? Int {
                    result.append((String(mid), n)); n += 1
                }
            }
        }
        return result
    }

    private func spaceNum(for sid: String) -> Int {
        allSpaces().first(where: { $0.id == sid })?.num ?? 0
    }

    /// Returns the display UUID that owns a given space ID.
    private func displayForSpace(_ spaceID: Int) -> CFString? {
        guard let arr = CGSCopyManagedDisplaySpaces(cid)
                as? [[String: Any]] else { return nil }
        for display in arr {
            let uuid = display["Display Identifier"] as? String ?? ""
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                if space["ManagedSpaceID"] as? Int == spaceID {
                    return uuid as CFString
                }
            }
        }
        return nil
    }

    // MARK: Display

    @objc private func refresh(_ note: Notification? = nil) {
        let sid   = activeSpaceID()
        lastSpaceID = sid
        if autoMode { autoName() }
        let n     = spaceNum(for: sid)
        let label = spaceNames[sid] ?? "Desktop \(n)"
        statusItem.button?.title = "\(n): \(label)"
    }

    // MARK: Terminal CWD detection

    /// Detects the working directory of the focused terminal app (if any).
    private func detectCWD() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bid = app.bundleIdentifier,
              kTerminals.contains(bid) else { return nil }

        // Build a pid→children map from one `ps` call.
        var children: [Int: [Int]] = [:]
        for line in sh("ps -axo pid=,ppid=").split(separator: "\n") {
            let p = line.split(separator: " ").compactMap { Int($0) }
            if p.count == 2 { children[p[1], default: []].append(p[0]) }
        }

        // BFS from the terminal PID to collect every descendant.
        var queue = [Int(app.processIdentifier)]
        var descendants: [Int] = []
        while !queue.isEmpty {
            let cur = queue.removeFirst()
            for child in children[cur] ?? [] {
                descendants.append(child)
                queue.append(child)
            }
        }
        guard !descendants.isEmpty else { return nil }

        // Batch-query CWDs with a single lsof invocation.
        let pids = descendants.map(String.init).joined(separator: ",")
        let out  = sh("lsof -a -d cwd -p \(pids) -Fn 2>/dev/null")
        let home = NSHomeDirectory()
        var fallback: String?

        for line in out.split(separator: "\n") where line.hasPrefix("n/") {
            let dir = String(line.dropFirst())
            if dir != "/" && dir != home { return dir }   // prefer non-home
            if fallback == nil { fallback = dir }
        }
        return fallback
    }

    private func autoName() {
        guard let dir = detectCWD() else { return }
        let name = "📂 " + URL(fileURLWithPath: dir).lastPathComponent
        let sid  = activeSpaceID()
        guard spaceNames[sid] != name else { return }
        spaceNames[sid] = name; saveConfig()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let current = activeSpaceID()

        for (id, num) in allSpaces() {
            let name = spaceNames[id] ?? "Desktop \(num)"
            let mark = id == current ? "▶ " : "   "
            let item = NSMenuItem(
                title: "\(mark)\(num): \(name)",
                action: #selector(switchSpace(_:)),
                keyEquivalent: "")
            item.target = self
            item.tag = Int(id) ?? 0
            if id == current { item.state = .on }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        add(menu, "Set Name…",              #selector(setName))
        add(menu, "Name from Terminal CWD", #selector(nameFromCWD))
        if spaceNames[current] != nil {
            add(menu, "Clear Name", #selector(clearName))
        }

        menu.addItem(.separator())
        let autoItem = NSMenuItem(
            title: "Auto-detect from Terminal",
            action: #selector(toggleAuto), keyEquivalent: "")
        autoItem.target = self
        autoItem.state  = autoMode ? .on : .off
        menu.addItem(autoItem)

        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state  = isLoginItem() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        add(menu, "About Name That Desktop",   #selector(showAbout))
        menu.addItem(NSMenuItem(
            title: "Quit Name That Desktop",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))
    }

    private func add(_ m: NSMenu, _ t: String, _ s: Selector) {
        let i = NSMenuItem(title: t, action: s, keyEquivalent: "")
        i.target = self; m.addItem(i)
    }

    // MARK: Actions

    @objc private func showAbout() {
        let a = NSAlert()
        a.messageText = "Name That Desktop v\(version)"
        a.informativeText =
            "A tiny menu bar app for naming your\n" +
            "macOS desktop Spaces.\n\n" +
            "Because Apple won't let you. 🖥️"
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    @objc private func switchSpace(_ sender: NSMenuItem) {
        let spaceID = sender.tag
        guard let display = displayForSpace(spaceID) else { return }
        CGSManagedDisplaySetCurrentSpace(cid, display, spaceID)
        refresh()
    }

    @objc private func setName() {
        let alert = NSAlert()
        alert.messageText = "Name This Desktop Space"
        alert.informativeText =
            "Enter a display name for Desktop \(spaceNum(for: activeSpaceID())):"
        let field = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = spaceNames[activeSpaceID()] ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeFirstResponder(field)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        spaceNames[activeSpaceID()] = name
        saveConfig(); refresh()
    }

    @objc private func nameFromCWD() {
        guard let dir = detectCWD() else {
            let a = NSAlert()
            a.messageText = "No Terminal Detected"
            a.informativeText =
                "Focus a terminal window on this space and try again."
            NSApp.activate(ignoringOtherApps: true); a.runModal(); return
        }
        spaceNames[activeSpaceID()] =
            "📂 " + URL(fileURLWithPath: dir).lastPathComponent
        saveConfig(); refresh()
    }

    @objc private func clearName() {
        spaceNames.removeValue(forKey: activeSpaceID())
        saveConfig(); refresh()
    }

    @objc private func toggleAuto() {
        autoMode.toggle()
        if autoMode { startPolling(); autoName() }
        else { pollTimer?.invalidate(); pollTimer = nil }
        saveConfig(); refresh()
    }

    // MARK: Login Item

    private func appPath() -> String {
        // Walk up from the executable to the .app bundle
        var url = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .standardized
        while url.pathExtension != "app" && url.path != "/" {
            url = url.deletingLastPathComponent()
        }
        return url.path
    }

    private func isLoginItem() -> Bool {
        let out = sh("osascript -e 'tell application \"System Events\" to get the path of every login item' 2>/dev/null")
        return out.contains(appPath())
    }

    @objc private func toggleLoginItem() {
        let path = appPath()
        if isLoginItem() {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            _ = sh("osascript -e 'tell application \"System Events\" to delete login item \"\(name)\"'")
        } else {
            _ = sh("osascript -e 'tell application \"System Events\" to make login item at end with properties {path:\"\(path)\", hidden:true}'")
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: Config persistence

    private func loadConfig() {
        guard let d = try? Data(contentsOf:
                    URL(fileURLWithPath: configPath)),
              let o = try? JSONSerialization.jsonObject(with: d)
                    as? [String: Any] else { return }
        spaceNames = o["names"]    as? [String: String] ?? [:]
        autoMode   = o["autoMode"] as? Bool ?? false
    }

    private func saveConfig() {
        let dir = (configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let obj: [String: Any] = [
            "names": spaceNames, "autoMode": autoMode]
        if let d = try? JSONSerialization.data(
            withJSONObject: obj, options: .prettyPrinted) {
            try? d.write(to: URL(fileURLWithPath: configPath))
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)          // no Dock icon
let delegate = DesktopNamer()
app.delegate = delegate
delegate.setup()
app.run()
