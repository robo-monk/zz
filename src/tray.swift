import AppKit

@_silgen_name("zig_on_set_task_name")
func zig_on_set_task_name(_ name: UnsafePointer<CChar>)
@_silgen_name("zig_on_start_pause")
func zig_on_start_pause()
@_silgen_name("zig_on_end_task")
func zig_on_end_task()
@_silgen_name("zig_on_tick_write_title")
func zig_on_tick_write_title(_ buf: UnsafeMutablePointer<CChar>, _ len: Int) -> Int
@_silgen_name("zig_on_focus_changed_stable")
func zig_on_focus_changed_stable(_ app: UnsafePointer<CChar>)
@_silgen_name("zig_on_periodic_screenshot")
func zig_on_periodic_screenshot()
@_silgen_name("zig_get_tasks_root_path")
func zig_get_tasks_root_path(_ buf: UnsafeMutablePointer<CChar>, _ len: Int) -> Int

private var globalStatusItem: NSStatusItem?

@_cdecl("ui_set_tray_title")
public func ui_set_tray_title(_ title: UnsafePointer<CChar>) {
    let s = String(cString: title)
    DispatchQueue.main.async {
        globalStatusItem?.button?.title = s
    }
}

// private func takeScreenshot() { guard let folder = screenshotsFolderURL() else { return }
//     guard let cgImage = CGWindowListCreateImage(.infinite, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else { return }
//     let rep = NSBitmapImageRep(cgImage: cgImage)
//     guard let data = rep.representation(using: .png, properties: [:]) else { return } let df = DateFormatter() df.dateFormat = "yyyyMMdd_HHmmss"
//     let name = "screenshot_\(df.string(from: Date())).png"
//     let url = folder.appendingPathComponent(name, isDirectory: false) do { try data.write(to: url) } catch { NSLog("Failed to write screenshot: \(error.localizedDescription)") } }

@_cdecl("ui_take_screenshot_at")
public func ui_take_screenshot_at(_ cpath: UnsafePointer<CChar>) -> Bool {
    let path = String(cString: cpath)
    let url = URL(fileURLWithPath: path, isDirectory: false)
    let dir = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let cgImage = CGWindowListCreateImage(.infinite, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else { return false }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.2]) else { return false }
    do { try data.write(to: url); return true } catch { NSLog("Write screenshot failed: \(error.localizedDescription)"); return false }
}



private class AppDelegate: NSObject, NSApplicationDelegate {
    // UI-only state
    private var isRunning = false
    private var taskName: String = ""

    // Timers
    private var tickTimer: Timer? = nil
    private var periodicShotTimer: Timer? = nil
    private var focusShotTimer: Timer? = nil
    private var focusShotTargetApp: String? = nil

    // UI references
    private var statusItem: NSStatusItem?
    private var startPauseItem: NSMenuItem?
    private var taskNameItem: NSMenuItem?

    // Focus tracking (UI debounce only)
    private var focusObserver: NSObjectProtocol?
    private var lastActiveAppName: String? = nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        installFocusObserver()
    }

    // MARK: - Menu Actions
    @objc func setTaskName(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Set Task Name"
        alert.informativeText = "Enter a name for the current task"
        alert.alertStyle = .informational
        let input = NSTextField(string: taskName)
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            taskName = input.stringValue
            taskNameItem?.title = taskName.isEmpty ? "Set Task Name" : taskName
            taskNameItem?.isEnabled = taskName.isEmpty
            taskName.withCString { zig_on_set_task_name($0) }
        }
    }

    @objc func toggleStartPause(_ sender: Any?) {
        zig_on_start_pause()
        isRunning.toggle()
        updateStartPauseTitle()
        if isRunning {
            scheduleTick()
            schedulePeriodicScreenshots()
            // seed focus name
            if let app = NSWorkspace.shared.frontmostApplication {
                lastActiveAppName = app.localizedName ?? app.bundleIdentifier ?? "UnknownApp"
            }
        } else {
            tickTimer?.invalidate(); tickTimer = nil
            periodicShotTimer?.invalidate(); periodicShotTimer = nil
            focusShotTimer?.invalidate(); focusShotTimer = nil
            focusShotTargetApp = nil
        }
    }

    @objc func endTask(_ sender: Any?) {
        zig_on_end_task()
        isRunning = false
        updateStartPauseTitle()
        tickTimer?.invalidate(); tickTimer = nil
        periodicShotTimer?.invalidate(); periodicShotTimer = nil
        focusShotTimer?.invalidate(); focusShotTimer = nil
        focusShotTargetApp = nil
        taskName = ""
        taskNameItem?.title = "Set Task Name"
        taskNameItem?.isEnabled = true
    }

    @objc func sayHello(_ sender: Any?) { NSLog("Hello from the tray menu!") }

    @objc func doFingerprint(_ sender: Any?) {
        let success = fingerprint()
        NSLog("Fingerprint auth result: \(success)")
    }

    @objc func openTasksFolder(_ sender: Any?) {
        var buf = [CChar](repeating: 0, count: 1024)
        _ = zig_get_tasks_root_path(&buf, buf.count)
        let path = String(cString: &buf)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - Timers
    private func scheduleTick() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            var buf = [CChar](repeating: 0, count: 64)
            _ = zig_on_tick_write_title(&buf, buf.count)
            let title = String(cString: &buf)
            self.statusItem?.button?.title = title
        }
        if let tickTimer { RunLoop.main.add(tickTimer, forMode: .common) }
    }

    private func schedulePeriodicScreenshots() {
        periodicShotTimer?.invalidate()
        periodicShotTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { _ in
            zig_on_periodic_screenshot()
        }
        if let periodicShotTimer { RunLoop.main.add(periodicShotTimer, forMode: .common) }
        // also request an immediate screenshot
        zig_on_periodic_screenshot()
    }

    private func updateStartPauseTitle() {
        startPauseItem?.title = isRunning ? "Pause" : "Start"
    }

    // MARK: - Focus observer
    private func installFocusObserver() {
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let name = app.localizedName ?? app.bundleIdentifier ?? "UnknownApp"
            if name == self.lastActiveAppName { return }
            self.lastActiveAppName = name
            NSLog("Active app changed: \(name)")
            // Only track screenshots when a task is running
            guard self.isRunning else { return }
            self.focusShotTimer?.invalidate()
            self.focusShotTargetApp = name
            self.focusShotTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
                guard self.isRunning else { return }
                let current = NSWorkspace.shared.frontmostApplication
                let currentName = current?.localizedName ?? current?.bundleIdentifier ?? "UnknownApp"
                if currentName == self.focusShotTargetApp {
                    name.withCString { zig_on_focus_changed_stable($0) }
                }
            }
            if let t = self.focusShotTimer { RunLoop.main.add(t, forMode: .common) }
        }
    }

    // Setup helpers
    func attachStatusItem(_ item: NSStatusItem) {
        self.statusItem = item
        globalStatusItem = item
    }
    func setStartPauseItem(_ item: NSMenuItem) { self.startPauseItem = item; updateStartPauseTitle() }
    func setTaskNameItem(_ item: NSMenuItem) { self.taskNameItem = item }
}

private let appDelegate = AppDelegate()

@_cdecl("startTray")
public func startTray() {
    let app = NSApplication.shared
    app.delegate = appDelegate
    app.setActivationPolicy(.accessory)

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.toolTip = ""
        button.title = "00:00"
    }

    let menu = NSMenu()
    let nameItem = NSMenuItem(title: "Set Task Name", action: #selector(AppDelegate.setTaskName(_:)), keyEquivalent: "")
    nameItem.target = appDelegate
    menu.addItem(nameItem)

    let startPauseItem = NSMenuItem(title: "Start", action: #selector(AppDelegate.toggleStartPause(_:)), keyEquivalent: "")
    startPauseItem.target = appDelegate
    menu.addItem(startPauseItem)

    let endItem = NSMenuItem(title: "End Task", action: #selector(AppDelegate.endTask(_:)), keyEquivalent: "")
    endItem.target = appDelegate
    menu.addItem(endItem)

    menu.addItem(NSMenuItem.separator())
    let openTasks = NSMenuItem(title: "Open Tasks Folder", action: #selector(AppDelegate.openTasksFolder(_:)), keyEquivalent: "")
    openTasks.target = appDelegate
    menu.addItem(openTasks)

    // menu.addItem(NSMenuItem.separator())
    // let helloItem = NSMenuItem(title: "Say Hello", action: #selector(AppDelegate.sayHello(_:)), keyEquivalent: "")
    // helloItem.target = appDelegate
    // menu.addItem(helloItem)

    // let fingerprintItem = NSMenuItem(title: "Fingerprint", action: #selector(AppDelegate.doFingerprint(_:)), keyEquivalent: "")
    // fingerprintItem.target = appDelegate
    // menu.addItem(fingerprintItem)

    menu.addItem(NSMenuItem.separator())
    menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

    item.menu = menu
    appDelegate.attachStatusItem(item)
    appDelegate.setStartPauseItem(startPauseItem)
    appDelegate.setTaskNameItem(nameItem)

    app.run()
}
