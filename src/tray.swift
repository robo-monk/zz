import AppKit

private class AppDelegate: NSObject, NSApplicationDelegate {
    // Task state
    private var taskName: String = ""
    private var isRunning: Bool = false
    private var baseElapsed: TimeInterval = 0 // seconds accumulated while paused
    private var startDate: Date? = nil        // when currently running
    private var tickTimer: Timer? = nil
    private var screenshotTimer: Timer? = nil

    // UI references
    private var statusItem: NSStatusItem?
    private var startPauseItem: NSMenuItem?
    private var taskNameItem: NSMenuItem?

    // Session + persistence
    private var currentSessionFolderName: String? = nil
    private var sessionStart: Date? = nil

    // Focused app tracking
    private var focusObserver: NSObjectProtocol?
    private var lastActiveAppName: String? = nil
    private var lastFocusChange: Date? = nil
    private var appDurations: [String: TimeInterval] = [:]
    private var focusShotTimer: Timer? = nil
    private var focusShotTargetApp: String? = nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateStatusItemTitle() // initialize title
        installFocusObserver()
    }

    // MARK: - Menu Actions
    // @objc func sayHello(_ sender: Any?) {
    //     NSLog("Hello from the tray menu!")
    // }

    // @objc func doFingerprint(_ sender: Any?) {
    //     let success = fingerprint()
    //     NSLog("Fingerprint auth result: \(success)")
    // }

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
        if let window = NSApp.windows.first {
            alert.beginSheetModal(for: window) { [weak self] resp in
                guard let self = self else { return }
                if resp == .alertFirstButtonReturn {
                    self.taskName = input.stringValue
                    self.updateTooltip()
                    self.updateTaskNameItem()
                }
            }
        } else {
            let resp = alert.runModal()
            if resp == .alertFirstButtonReturn {
                taskName = input.stringValue
                updateTooltip()
                updateTaskNameItem()
            }
        }
    }

    @objc func toggleStartPause(_ sender: Any?) {
        if isRunning { pause() } else { start() }
    }

    @objc func endTask(_ sender: Any?) {
        // Stop and reset
        // First, finalize elapsed time
        if isRunning, let started = startDate {
            baseElapsed += Date().timeIntervalSince(started)
        }

        // Persist task if any time was recorded or name set
        if baseElapsed > 0 || !taskName.isEmpty {
            persistTask()
        }

        tickTimer?.invalidate(); tickTimer = nil
        screenshotTimer?.invalidate(); screenshotTimer = nil
        isRunning = false
        baseElapsed = 0
        startDate = nil
        taskName = ""
        sessionStart = nil
        updateStatusItemTitle()
        updateStartPauseTitle()
        updateTooltip()
        updateTaskNameItem()
        currentSessionFolderName = nil
    }

    // MARK: - Timer / State Helpers
    private func start() {
        if !isRunning {
            // Prepare a session folder and screenshots directory when starting
            prepareSessionFolderIfNeeded()
            if sessionStart == nil { sessionStart = Date() }
            startDate = Date()
            // Seed focus tracking at start
            if let app = NSWorkspace.shared.frontmostApplication {
                lastActiveAppName = app.localizedName ?? app.bundleIdentifier ?? "UnknownApp"
            }
            lastFocusChange = Date()
            isRunning = true
            scheduleTick()
            scheduleScreenshotTick()
            updateStartPauseTitle()
        }
    }

    private func pause() {
        if isRunning {
            if let started = startDate { baseElapsed += Date().timeIntervalSince(started) }
            // Account for focus time until pause
            if let name = lastActiveAppName, let changed = lastFocusChange {
                let delta = Date().timeIntervalSince(changed)
                appDurations[name, default: 0] += max(0, delta)
                lastFocusChange = Date()
            }
            startDate = nil
            isRunning = false
            tickTimer?.invalidate(); tickTimer = nil
            screenshotTimer?.invalidate(); screenshotTimer = nil
            focusShotTimer?.invalidate(); focusShotTimer = nil
            focusShotTargetApp = nil
            updateStartPauseTitle()
            updateStatusItemTitle()
        }
    }

    private func scheduleTick() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStatusItemTitle()
        }
        if let tickTimer { RunLoop.main.add(tickTimer, forMode: .common) }
    }

    private func scheduleScreenshotTick() {
        screenshotTimer?.invalidate()
        screenshotTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.takeScreenshot()
        }
        if let screenshotTimer { RunLoop.main.add(screenshotTimer, forMode: .common) }
        // Capture immediately on start
        takeScreenshot()
    }

    private func currentElapsed() -> TimeInterval {
        if isRunning, let started = startDate {
            return baseElapsed + Date().timeIntervalSince(started)
        }
        return baseElapsed
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }

    private func updateStatusItemTitle() {
        let secs = Int(currentElapsed().rounded())
        let title = formatElapsed(secs)
        statusItem?.button?.title = title
    }

    private func updateStartPauseTitle() {
        startPauseItem?.title = isRunning ? "Pause" : "Start"
    }

    private func updateTooltip() {
        if taskName.isEmpty {
            statusItem?.button?.toolTip = ""
        } else {
            statusItem?.button?.toolTip = "Task: \(taskName)"
        }
    }

    // MARK: - Setup
    func attachStatusItem(_ item: NSStatusItem) {
        self.statusItem = item
        updateStatusItemTitle()
        updateTooltip()
    }

    func setStartPauseItem(_ item: NSMenuItem) {
        self.startPauseItem = item
        updateStartPauseTitle()
    }

    func setTaskNameItem(_ item: NSMenuItem) {
        self.taskNameItem = item
        updateTaskNameItem()
    }

    private func updateTaskNameItem() {
        guard let item = taskNameItem else { return }
        if taskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.title = "Set Task Name"
            item.action = #selector(AppDelegate.setTaskName(_:))
            item.isEnabled = true
        } else {
            item.title = taskName
            item.action = nil
            item.isEnabled = false
        }
    }

    // MARK: - Focused app tracking
    private func installFocusObserver() {
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                let name = app.localizedName ?? app.bundleIdentifier ?? "UnknownApp"
                if name != self.lastActiveAppName {
                    if self.isRunning, let prev = self.lastActiveAppName, let changed = self.lastFocusChange {
                        let delta = Date().timeIntervalSince(changed)
                        self.appDurations[prev, default: 0] += max(0, delta)
                    }
                    self.lastActiveAppName = name
                    self.lastFocusChange = Date()
                    NSLog("Active app changed: \(name)")
                    // Debounce screenshot by 5 seconds; only capture if still focused
                    self.focusShotTimer?.invalidate()
                    self.focusShotTargetApp = name
                    self.focusShotTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                        guard let self = self else { return }
                        guard self.isRunning else { return }
                        let current = NSWorkspace.shared.frontmostApplication
                        let currentName = current?.localizedName ?? current?.bundleIdentifier ?? "UnknownApp"
                        if currentName == self.focusShotTargetApp {
                            self.takeScreenshot()
                        }
                    }
                    if let t = self.focusShotTimer { RunLoop.main.add(t, forMode: .common) }
                }
            }
        }
    }

    // MARK: - Persistence
    private func tasksRootURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".zz", isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
    }

    private func ensureTasksRoot() {
        let root = tasksRootURL()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func sanitizedFolderName(from name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return "task" }
        return cleaned
    }

    private func prepareSessionFolderIfNeeded() {
        if currentSessionFolderName == nil {
            let dfStamp = DateFormatter()
            dfStamp.dateFormat = "yyyyMMdd_HHmmss"
            let stamp = dfStamp.string(from: Date())
            let base = sanitizedFolderName(from: taskName.isEmpty ? "task" : taskName)
            currentSessionFolderName = "\(base)_\(stamp)"
        }
        ensureTasksRoot()
        if let name = currentSessionFolderName {
            let folderURL = tasksRootURL().appendingPathComponent(name, isDirectory: true)
            let shotsURL = folderURL.appendingPathComponent("screenshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: shotsURL, withIntermediateDirectories: true)
        }
    }

    private func screenshotsFolderURL() -> URL? {
        guard let name = currentSessionFolderName else { return nil }
        return tasksRootURL().appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("screenshots", isDirectory: true)
    }

    private func takeScreenshot() {
        guard let folder = screenshotsFolderURL() else { return }
        guard let cgImage = CGWindowListCreateImage(.infinite, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .jpeg, properties: [
            .compressionFactor: 0.2
        ]) else { return }

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let name = "screenshot_\(df.string(from: Date())).jpeg"
        let url = folder.appendingPathComponent(name, isDirectory: false)
        do {
            try data.write(to: url)
        } catch {
            NSLog("Failed to write screenshot: \(error.localizedDescription)")
        }

        NSLog("Captured screenshot: \(name)")
    }

    private func persistTask() {
        ensureTasksRoot()
        // Use existing session folder if available; otherwise create a fresh one
        let folderURL: URL = {
            if let name = currentSessionFolderName {
                return tasksRootURL().appendingPathComponent(name, isDirectory: true)
            }
            let dfStamp = DateFormatter()
            dfStamp.dateFormat = "yyyyMMdd_HHmmss"
            let stamp = dfStamp.string(from: Date())
            let base = sanitizedFolderName(from: taskName.isEmpty ? "task" : taskName)
            let folderName = "\(base)_\(stamp)"
            currentSessionFolderName = folderName
            return tasksRootURL().appendingPathComponent(folderName, isDirectory: true)
        }()
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let fileURL = folderURL.appendingPathComponent("TASK.md", isDirectory: false)

            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let startStr = sessionStart != nil ? df.string(from: sessionStart!) : df.string(from: Date())
            let endStr = df.string(from: Date())

            let secs = Int(baseElapsed.rounded())
            let timeStr = formatElapsed(secs)

            let title = taskName.isEmpty ? "task" : taskName
            // finalize app focus time for last segment
            if let prev = lastActiveAppName, let changed = lastFocusChange {
                let delta = Date().timeIntervalSince(changed)
                appDurations[prev, default: 0] += max(0, delta)
            }
            var appLines: [String] = []
            for (appName, dur) in appDurations.sorted(by: { $0.value > $1.value }) {
                let t = formatElapsed(Int(dur.rounded()))
                appLines.append("  - \(appName): \(t)")
            }
            let appsSection = appLines.isEmpty ? "  - (no focus changes recorded)" : appLines.joined(separator: "\n")
            let content = "# \(title)\n\n- Start: \(startStr)\n- End: \(endStr)\n- Duration: \(timeStr)\n- Screenshots: ./screenshots/\n\n## App Time\n\(appsSection)\n"
            try content.write(to: fileURL, atomically: true, encoding: String.Encoding.utf8)
        } catch {
            NSLog("Failed to persist task: \(error.localizedDescription)")
        }
    }

    @objc func openTasksFolder(_ sender: Any?) {
        ensureTasksRoot()
        NSWorkspace.shared.open(tasksRootURL())
    }
}

// Keep strong references to objects that must live for the app lifetime
private let appDelegate = AppDelegate()

@_cdecl("startTray")
public func startTray() {
    let app = NSApplication.shared
    app.delegate = appDelegate
    app.setActivationPolicy(.accessory) // Hide from Dock; keep only status item

    // Create a status bar item; title will display elapsed time
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.toolTip = ""
    }

    let menu = NSMenu()

    // Task controls
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

    // Existing demo items
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

    // Start the app run loop
    app.run()
}
