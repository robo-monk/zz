import AppKit
import Foundation

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
@_silgen_name("zig_get_app_times")
func zig_get_app_times(_ buf: UnsafeMutablePointer<CChar>, _ len: Int) -> Int

private var globalStatusItem: NSStatusItem?

// MARK: - Control Center–style UI
private final class ModuleView: NSVisualEffectView {
    init() {
        super.init(frame: .zero)
        material = .popover
        state = .active
        blendingMode = .withinWindow
        wantsLayer = true
        layer?.cornerRadius = 12
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// Simple list of usage rows, custom styled
private final class UsageRowView: NSView {
    let iconView = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let timeLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        iconView.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.font = .systemFont(ofSize: 13)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor

        let h = NSStackView(views: [iconView, nameLabel, NSView(), timeLabel])
        h.orientation = .horizontal
        h.spacing = 8
        h.alignment = .centerY
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            h.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            h.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            h.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            h.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 22)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class UsageListView: NSView {
    private let stack = NSStackView()
    private let placeholder = NSTextField(labelWithString: "No app usage yet")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])

        setRows([])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setRows(_ rows: [(String, Int)]) {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        if rows.isEmpty {
            placeholder.isHidden = false
            return
        }
        placeholder.isHidden = true
        for (name, secs) in rows {
            let row = UsageRowView()
            row.nameLabel.stringValue = name
            row.timeLabel.stringValue = format(secs: secs)
            stack.addArrangedSubview(row)
        }
    }
}

private func format(secs: Int) -> String {
    if secs <= 0 { return "0m" }
    let h = secs / 3600
    let m = (secs % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

private final class ControlCenterViewController: NSViewController, NSTextFieldDelegate {
    // Outlets used by AppDelegate to update state
    let nameField = NSTextField(string: "") // edit field (hidden by default)
    let titleLabel = NSTextField(labelWithString: "")
    let timerLabel = NSTextField(labelWithString: "00:00")
    let startPauseButton = NSButton(title: "Start", target: nil, action: nil)
    let endButton = NSButton(title: "End", target: nil, action: nil)
    let moreButton = NSButton(title: "More ▾", target: nil, action: nil)

    // Called when the user commits a title edit (Enter or focus loss)
    var onCommitName: ((String) -> Void)?

    // Timer card reference for font fitting
    private let timerCard = ModuleView()
    // Custom usage list
    private let usageList = UsageListView()

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        // Root stack mimicking Control Center sections
        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.distribution = .gravityAreas
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 320)
        ])

        // Title (outside cards)
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.alignment = .left
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        rootStack.addArrangedSubview(titleLabel)

        // Make title editable on double-click by showing an editor field
        let dbl = NSClickGestureRecognizer(target: self, action: #selector(beginTitleEdit))
        dbl.numberOfClicksRequired = 2
        titleLabel.addGestureRecognizer(dbl)
        titleLabel.isSelectable = false
        titleLabel.isEditable = false
        titleLabel.isEnabled = true
        titleLabel.allowsDefaultTighteningForTruncation = true
        titleLabel.nextKeyView = nameField

        // Hidden editor field positioned in stack (swapped with label)
        nameField.placeholderString = "Double-click to set task name"
        nameField.isBezeled = false
        nameField.focusRingType = .none
        nameField.drawsBackground = false
        nameField.font = .systemFont(ofSize: 18, weight: .semibold)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.isHidden = true
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(commitTitleEditAction)
        rootStack.addArrangedSubview(nameField)

        // Row: Timer module (left) + Usage module (right)
        let timerRow = NSStackView()
        timerRow.orientation = .horizontal
        timerRow.spacing = 12
        timerRow.alignment = .top
        timerRow.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(timerRow)

        // Left: Timer module
        let timerModule = timerCard
        let timerStack = NSStackView()
        timerStack.orientation = .vertical
        timerStack.spacing = 10
        timerStack.alignment = .centerX
        timerStack.translatesAutoresizingMaskIntoConstraints = false
        timerModule.addSubview(timerStack)
        NSLayoutConstraint.activate([
            timerStack.topAnchor.constraint(equalTo: timerModule.topAnchor, constant: 12),
            timerStack.leadingAnchor.constraint(equalTo: timerModule.leadingAnchor, constant: 12),
            timerStack.trailingAnchor.constraint(equalTo: timerModule.trailingAnchor, constant: -12),
            timerStack.bottomAnchor.constraint(equalTo: timerModule.bottomAnchor, constant: -12),
        ])
        // Fixed comfortable width for the timer card
        // Hug content: don't force a fixed width
        // Larger, prettier monospaced digits
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 36, weight: .semibold)
        timerLabel.alignment = .center
        timerLabel.setContentHuggingPriority(.required, for: .horizontal)
        // Side-by-side icon buttons
        let actionsRow = NSStackView(views: [startPauseButton, endButton])
        actionsRow.orientation = .horizontal
        actionsRow.spacing = 8
        actionsRow.alignment = .centerY
        actionsRow.setContentHuggingPriority(.required, for: .horizontal)
        timerStack.addArrangedSubview(timerLabel)
        timerStack.addArrangedSubview(actionsRow)
        // Minimum width so the card doesn't become too small
        timerModule.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        // Keep timer hugging its content so usage expands
        timerModule.setContentHuggingPriority(.required, for: .horizontal)
        timerModule.setContentCompressionResistancePriority(.required, for: .horizontal)
        timerRow.addArrangedSubview(timerModule)

        // Right: Usage module
        let usageModule = ModuleView()
        usageModule.addSubview(usageList)
        usageList.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            usageList.topAnchor.constraint(equalTo: usageModule.topAnchor, constant: 12),
            usageList.leadingAnchor.constraint(equalTo: usageModule.leadingAnchor, constant: 12),
            usageList.trailingAnchor.constraint(equalTo: usageModule.trailingAnchor, constant: -12),
            usageList.bottomAnchor.constraint(equalTo: usageModule.bottomAnchor, constant: -12),
            usageList.heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        ])
        timerRow.addArrangedSubview(usageModule)
        // Expand to fill remaining width
        usageModule.setContentHuggingPriority(.defaultLow, for: .horizontal)
        usageModule.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        usageModule.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        // Bottom bar with trailing "More" dropdown
        moreButton.bezelStyle = .rounded
        let bottomBar = NSStackView()
        bottomBar.orientation = .horizontal
        bottomBar.alignment = .centerY
        bottomBar.spacing = 8
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addArrangedSubview(spacer)
        bottomBar.addArrangedSubview(moreButton)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        moreButton.setContentHuggingPriority(.required, for: .horizontal)
        rootStack.addArrangedSubview(bottomBar)

        // Default button styles and icons
        startPauseButton.bezelStyle = .rounded
        endButton.bezelStyle = .rounded
        startPauseButton.imagePosition = .imageOnly
        endButton.imagePosition = .imageOnly
        // No explicit buttons for utilities here; they live in the More menu

        // Better default size
        view.widthAnchor.constraint(equalToConstant: 360).isActive = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        fitTimerFont()
    }

    // Adjust timer font to fit within the timer card without clipping
    func fitTimerFont() {
        view.layoutSubtreeIfNeeded()
        let padding: CGFloat = 24 // matches inner constraints
        let available = max(10, timerCard.bounds.width - padding)
        // Worst-case sample when hours appear
        let sample = "88:88:88"
        var lo: CGFloat = 14
        var hi: CGFloat = 60
        for _ in 0..<12 {
            let mid = (lo + hi) / 2
            let font = NSFont.monospacedDigitSystemFont(ofSize: mid, weight: .semibold)
            let w = (sample as NSString).size(withAttributes: [.font: font]).width
            if w <= available { lo = mid } else { hi = mid }
        }
        let finalFont = NSFont.monospacedDigitSystemFont(ofSize: lo, weight: .semibold)
        if timerLabel.font?.pointSize != finalFont.pointSize {
            timerLabel.font = finalFont
        }
    }

    // MARK: - Title editing
    @objc private func beginTitleEdit() {
        titleLabel.isHidden = true
        nameField.isHidden = false
        nameField.stringValue = titleLabel.stringValue
        view.window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    @objc private func commitTitleEditAction() {
        commitTitleEdit()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitTitleEdit()
    }

    private func commitTitleEdit() {
        let text = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        setTitle(text)
        onCommitName?(text)
        titleLabel.isHidden = false
        nameField.isHidden = true
    }

    func setTitle(_ s: String) {
        titleLabel.stringValue = s.isEmpty ? "Task" : s
        nameField.stringValue = s
    }

    // MARK: - App usage table
    func refreshAppUsage() {
        var buf = [CChar](repeating: 0, count: 16 * 1024)
        let n = zig_get_app_times(&buf, buf.count)
        guard n > 0 else { usageList.setRows([]); return }
        let data = Data(bytes: buf, count: min(n, buf.count))
        guard let s = String(data: data, encoding: .utf8) else { usageList.setRows([]); return }
        var tmp: [(String, Int)] = []
        for line in s.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2, let secs = Int(parts[1]) {
                tmp.append((String(parts[0]), secs))
            }
        }
        tmp.sort { $0.1 > $1.1 }
        let total = tmp.reduce(0) { $0 + $1.1 }
        var rows: [(String, Int)] = []
        if total > 0 { rows.append(("All Usage", total)) }
        rows.append(contentsOf: tmp.prefix(6))
        usageList.setRows(rows)
    }
}

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
    private var popover: NSPopover?
    private var cc: ControlCenterViewController?

    // Focus tracking (UI debounce only)
    private var focusObserver: NSObjectProtocol?
    private var lastActiveAppName: String? = nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        installFocusObserver()
    }

    // MARK: - Actions from UI
    @objc func saveTaskName(_ sender: Any?) {
        let newName = cc?.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        commitTaskName(newName)
    }

    private func commitTaskName(_ newName: String) {
        taskName = newName
        taskName.withCString { zig_on_set_task_name($0) }
        cc?.setTitle(newName)
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
        cc?.setTitle("")
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
            self.cc?.timerLabel.stringValue = title
            self.cc?.refreshAppUsage()
            self.cc?.fitTimerFont()
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
        guard let btn = cc?.startPauseButton, let end = cc?.endButton else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let play = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Start")?.withSymbolConfiguration(config)
        let pause = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")?.withSymbolConfiguration(config)
        let stop = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "End")?.withSymbolConfiguration(config)
        btn.title = ""
        btn.image = isRunning ? pause : play
        btn.toolTip = isRunning ? "Pause" : "Start"
        end.title = ""
        end.image = stop
        end.toolTip = "End Task"
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
            self.focusShotTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
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

    private func ensurePopover() {
        if popover != nil { return }
        let vc = ControlCenterViewController()
        self.cc = vc
        // Wire actions
        vc.startPauseButton.target = self
        vc.startPauseButton.action = #selector(toggleStartPause(_:))
        vc.endButton.target = self
        vc.endButton.action = #selector(endTask(_:))
        vc.moreButton.target = self
        vc.moreButton.action = #selector(showMoreMenu(_:))
        // Title edit commit callback
        vc.onCommitName = { [weak self] text in self?.commitTaskName(text) }
        vc.setTitle(taskName)
        // Create popover
        let p = NSPopover()
        p.animates = false
        p.behavior = .transient
        p.contentViewController = vc
        p.contentSize = NSSize(width: 360, height: 260)
        self.popover = p
        updateStartPauseTitle()
        vc.refreshAppUsage()
    }

    @objc func showMoreMenu(_ sender: Any?) {
        guard let vc = cc, let button = vc.moreButton as NSButton? else { return }
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Tasks Folder", action: #selector(openTasksFolder(_:)), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        let point = NSPoint(x: button.bounds.maxX - 8, y: -4)
        menu.popUp(positioning: nil, at: point, in: button)
    }

    @objc func togglePopover(_ sender: Any?) {
        ensurePopover()
        guard let button = statusItem?.button, let pop = popover else { return }
        if pop.isShown {
            pop.performClose(sender)
        } else {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            cc?.refreshAppUsage()
        }
    }
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
        button.target = appDelegate
        button.action = #selector(AppDelegate.togglePopover(_:))
    }
    appDelegate.attachStatusItem(item)

    app.run()
}
