// AppDelegate.swift
// Elevated Mac — entry point, menu bar, transport bar

import Cocoa
import MetalKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let releaseStartupDelay: TimeInterval = 5
    private static let fullscreenCursorIdleDelay: TimeInterval = 0.1

    var window: NSWindow!
    var aboutWindow: NSWindow?
    var helpWindow: NSWindow?
    var renderer: Renderer!
    let synth = SynthPlayer()
    private var transportBar: TransportBar!
    private var debugActive = false
    private var debugMenuItem: NSMenuItem?
    private var helpMenuItem: NSMenuItem?
    private var muteMenuItem: NSMenuItem?
    private var captureMode = false
    private var launchTime: CFTimeInterval = 0
    private var fullscreenCursorMonitor: Any?
    private var fullscreenCursorHidden = false
    private var fullscreenCursorHideTimer: Timer?
    private var fullscreenCursorActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available on this device")
        }

        launchTime = CACurrentMediaTime()
        debugActive = CommandLine.arguments.contains("--debug")
        captureMode = CommandLine.arguments.contains("--capture")

        // --icon-at=T  renders one clean frame at time T, saves to --icon-out=path, exits
        let args = CommandLine.arguments
        func argVal(_ prefix: String) -> String? {
            args.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
        }
        let iconTime = argVal("--icon-at=").flatMap(Double.init)
        let iconOut  = argVal("--icon-out=") ?? "icon_source.png"
        let normalPresentation = !debugActive && !captureMode && iconTime == nil

        let mtkView = MTKView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), device: device)
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay     = false
        mtkView.isPaused                  = false
        mtkView.clearColor                = MTLClearColorMake(0, 0, 0, 1)

        renderer = Renderer(mtkView: mtkView, debug: debugActive || captureMode, capture: captureMode)
        mtkView.delegate = renderer

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Elevated"
        window.tabbingMode = .disallowed   // suppress "Show Tab Bar" menu item
        window.backgroundColor = .black
        window.delegate = self
        window.contentView = mtkView
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Always install both overlays; visibility controlled by debugActive
        renderer.installDebugOverlay(in: mtkView)
        if !captureMode {
            installTransportBar(in: mtkView)
            installKeyHandler()
        }
        setDebugActive(debugActive)

        setupMenuBar()
        NSApp.activate(ignoringOtherApps: true)
        if normalPresentation {
            DispatchQueue.main.async { [weak self] in
                self?.window.toggleFullScreen(nil)
            }
        }

        if let t = iconTime {
            // Icon mode: skip audio, start renderer directly, seek, capture one frame.
            renderer.start()
            renderer.seek(to: t)
            renderer.captureNextFramePath = iconOut
        } else {
            synth.synthesize { [weak self] ok in
                guard let self, ok else { print("Synthesis failed"); return }
                let elapsed = CACurrentMediaTime() - self.launchTime
                let delay = normalPresentation ? max(0, Self.releaseStartupDelay - elapsed) : 0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.renderer.start()
                    self.synth.play()
                }
            }
        }
    }

    // ── Debug visibility ───────────────────────────────────────────────────

    private func setDebugActive(_ on: Bool) {
        debugActive = on
        renderer.debugMode = on
        renderer.debugOverlay?.isHidden = !on
        transportBar?.isHidden = !on
        debugMenuItem?.state = on ? .on : .off
        helpMenuItem?.isHidden = !on
        if !on { helpWindow?.orderOut(nil) }
        refreshFullscreenCursorPolicy()
    }

    @objc private func toggleDebug() {
        setDebugActive(!debugActive)
    }

    @objc private func toggleMute() {
        synth.isMuted.toggle()
        muteMenuItem?.state = synth.isMuted ? .on : .off
    }

    // ── Transport bar ──────────────────────────────────────────────────────

    private func installTransportBar(in view: MTKView) {
        transportBar = TransportBar(frame: NSRect(x: 0, y: 0, width: view.bounds.width, height: 56))
        view.addSubview(transportBar)

        transportBar.onPlayPause  = { [weak self] in self?.togglePlayPause() }
        transportBar.onSeekVisual = { [weak self] t in self?.renderer.seek(to: t) }
        transportBar.onSeekFinal  = { [weak self] t in
            self?.renderer.seek(to: t)
            self?.synth.seek(to: t)
        }

        renderer.onDraw = { [weak self] in self?.onFrame() }
    }

    private func onFrame() {
        guard let tb = transportBar, let sv = tb.superview else { return }
        tb.frame = NSRect(x: 0, y: 0, width: sv.bounds.width, height: 56)
        tb.update(time: renderer.currentTime, isPaused: renderer.isPaused)
    }

    // ── Play / pause / seek ────────────────────────────────────────────────

    private func togglePlayPause() {
        if renderer.isPaused { renderer.resume(); synth.resume() }
        else                 { renderer.pause();  synth.pause()  }
    }

    private func seekBy(_ delta: Double) {
        let t = max(0, min(renderer.currentTime + delta, kDemoDuration))
        renderer.seek(to: t)
        synth.seek(to: t)
    }

    // ── Keyboard (mpv-style) ───────────────────────────────────────────────

    private func installKeyHandler() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Let Cmd+key combos pass through to the menu
            guard !event.modifierFlags.contains(.command) else { return event }
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    @discardableResult
    private func handleKey(_ event: NSEvent) -> Bool {
        let frame = 1.0 / 60.0
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 53:
            if window.styleMask.contains(.fullScreen) {
                NSApp.terminate(nil)                         // Esc
                return true
            }
            return false
        case 49:  togglePlayPause(); return true            // Space
        case 123: seekBy(shift ? -frame : -5); return true  // ←  (-1f / -5s)
        case 124: seekBy(shift ?  frame :  5); return true  // →  (+1f / +5s)
        case 125: seekBy(-60); return true                  // ↓  (-60s)
        case 126: seekBy( 60); return true                  // ↑  (+60s)
        case 47:
            if renderer.isPaused { seekBy(frame); return true } // .  step forward
            return false
        case 43:
            if renderer.isPaused { seekBy(-frame); return true } // ,  step backward
            return false
        default:
            return false
        }
    }

    @objc private func showAboutWindow() {
        if aboutWindow == nil {
            aboutWindow = buildAboutWindow()
        }
        guard let aboutWindow else { return }
        aboutWindow.center()
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow.makeKeyAndOrderFront(nil)
    }

    @objc private func showHelpWindow() {
        guard debugActive else { return }
        if helpWindow == nil {
            helpWindow = buildHelpWindow()
        }
        guard let helpWindow else { return }
        helpWindow.center()
        NSApp.activate(ignoringOtherApps: true)
        helpWindow.makeKeyAndOrderFront(nil)
    }

    // ── Menu bar ───────────────────────────────────────────────────────────

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // ── App menu ──
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu

        appMenu.addItem(NSMenuItem(title: "About Elevated",
                                   action: #selector(showAboutWindow),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Elevated",
                                   action: #selector(NSApplication.hide(_:)),
                                   keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All",
                                   action: #selector(NSApplication.unhideAllApplications(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Elevated",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))

        // ── Audio menu ──
        let audioItem = NSMenuItem()
        mainMenu.addItem(audioItem)
        let audioMenu = NSMenu(title: "Audio")
        audioItem.submenu = audioMenu

        let muteItem = NSMenuItem(title: "Mute",
                                  action: #selector(toggleMute),
                                  keyEquivalent: "m")
        muteItem.keyEquivalentModifierMask = [.command]
        muteItem.target = self
        audioMenu.addItem(muteItem)
        muteMenuItem = muteItem

        // ── View menu ──
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu

        let dbgItem = NSMenuItem(title: "Debug Overlay",
                                 action: #selector(toggleDebug),
                                 keyEquivalent: "d")
        dbgItem.keyEquivalentModifierMask = [.command]
        dbgItem.state = debugActive ? .on : .off
        dbgItem.target = self
        viewMenu.addItem(dbgItem)
        debugMenuItem = dbgItem

        viewMenu.addItem(.separator())
        let fsItem = NSMenuItem(title: "Enter Full Screen",
                                action: #selector(NSWindow.toggleFullScreen(_:)),
                                keyEquivalent: "f")
        fsItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fsItem)

        // ── Help menu ──
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        helpItem.isHidden = !debugActive
        helpMenuItem = helpItem
        let keysItem = NSMenuItem(title: "Keyboard Reference",
                                  action: #selector(showHelpWindow),
                                  keyEquivalent: "/")
        keysItem.keyEquivalentModifierMask = [.command]
        keysItem.target = self
        helpMenu.addItem(keysItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { deactivateFullscreenCursorPolicy() }

    private func shouldAutoHideFullscreenCursor() -> Bool {
        fullscreenCursorActive && !debugActive
    }

    private func refreshFullscreenCursorPolicy() {
        if shouldAutoHideFullscreenCursor() { activateFullscreenCursorPolicy() }
        else                               { deactivateFullscreenCursorPolicy() }
    }

    private func activateFullscreenCursorPolicy() {
        beginFullscreenCursorHide()

        guard fullscreenCursorMonitor == nil else { return }
        fullscreenCursorMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        ) { [weak self] event in
            self?.noteFullscreenCursorActivity()
            return event
        }
    }

    private func deactivateFullscreenCursorPolicy() {
        fullscreenCursorHideTimer?.invalidate()
        fullscreenCursorHideTimer = nil
        if let monitor = fullscreenCursorMonitor {
            NSEvent.removeMonitor(monitor)
            fullscreenCursorMonitor = nil
        }
        endFullscreenCursorHide()
    }

    private func noteFullscreenCursorActivity() {
        guard shouldAutoHideFullscreenCursor() else { return }
        if fullscreenCursorHidden {
            fullscreenCursorHidden = false
            NSCursor.unhide()
        }
        fullscreenCursorHideTimer?.invalidate()
        fullscreenCursorHideTimer = Timer.scheduledTimer(
            withTimeInterval: Self.fullscreenCursorIdleDelay,
            repeats: false
        ) { [weak self] _ in
            self?.beginFullscreenCursorHide()
        }
    }

    private func beginFullscreenCursorHide() {
        guard shouldAutoHideFullscreenCursor(), !fullscreenCursorHidden else { return }
        fullscreenCursorHidden = true
        NSCursor.hide()
    }

    private func endFullscreenCursorHide() {
        guard fullscreenCursorHidden else { return }
        fullscreenCursorHidden = false
        NSCursor.unhide()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        fullscreenCursorActive = true
        refreshFullscreenCursorPolicy()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        fullscreenCursorActive = true
        refreshFullscreenCursorPolicy()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        fullscreenCursorActive = false
        deactivateFullscreenCursorPolicy()
    }

    private func buildAboutWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "About Elevated"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false

        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = content

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
        ])

        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 64).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true
        stack.addArrangedSubview(iconView)

        let titleLabel = NSTextField(labelWithString: "Elevated")
        titleLabel.font = NSFont.systemFont(ofSize: 28, weight: .semibold)
        titleLabel.alignment = .center
        stack.addArrangedSubview(titleLabel)

        let bodyLabel = NSTextField(wrappingLabelWithString: loadAboutText())
        bodyLabel.font = NSFont.systemFont(ofSize: 13)
        bodyLabel.alignment = .center
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.preferredMaxLayoutWidth = 380
        stack.addArrangedSubview(bodyLabel)

        let versionLabel = NSTextField(labelWithString: aboutVersionString())
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        stack.addArrangedSubview(versionLabel)

        return window
    }

    private func buildHelpWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Elevated Debug Help"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false

        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = content

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
        ])

        let titleLabel = NSTextField(labelWithString: "Keyboard Reference")
        titleLabel.font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        stack.addArrangedSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "Debug-mode transport and app controls")
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(subtitleLabel)

        addHelpSection("Playback", items: [
            "Space              Play / Pause",
            "Left / Right       Seek -5s / +5s",
            "Shift+Left/Right   Seek -1f / +1f",
            "Up / Down          Seek -60s / +60s",
            ", / .              Step backward / forward when paused",
        ], to: stack)

        addHelpSection("App", items: [
            "Cmd+D              Toggle debug overlay",
            "Cmd+M              Mute",
            "Cmd+/              Open this help window",
            "Ctrl+Cmd+F         Toggle full screen",
            "Esc                Quit when in full screen",
            "Cmd+Q              Quit Elevated",
        ], to: stack)

        return window
    }

    private func loadAboutText() -> String {
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "LICENSE", withExtension: nil),
            Bundle.main.resourceURL?.appendingPathComponent("LICENSE"),
            execURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/LICENSE"),
            execURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("LICENSE"),
        ]

        for url in candidates.compactMap({ $0 }) {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return "LICENSE not found."
    }

    private func aboutVersionString() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    private func addHelpSection(_ title: String, items: [String], to stack: NSStackView) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(titleLabel)

        let bodyLabel = NSTextField(wrappingLabelWithString: items.joined(separator: "\n"))
        bodyLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.maximumNumberOfLines = 0
        stack.addArrangedSubview(bodyLabel)
    }
}

// ─── Transport bar overlay ─────────────────────────────────────────────────────

class TransportBar: NSView {
    var onPlayPause:  (() -> Void)?
    var onSeekVisual: ((Double) -> Void)?
    var onSeekFinal:  ((Double) -> Void)?

    private let playBtn      = NSButton()
    private let timeLabel    = makeMonoLabel(width: 110, align: .left)
    private let remainLabel  = makeMonoLabel(width: 120, align: .right)
    private let slider       = SeekSlider()
    private let totalDuration = kDemoDuration

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor

        playBtn.bezelStyle       = .inline
        playBtn.isBordered       = false
        playBtn.target           = self
        playBtn.action           = #selector(playPauseTapped)
        playBtn.image            = sfSymbol("pause.fill")
        playBtn.contentTintColor = .white

        slider.minValue     = 0
        slider.maxValue     = totalDuration
        slider.isContinuous = true
        slider.target       = self
        slider.action       = #selector(sliderMoved(_:))
        slider.onSeekEnd    = { [weak self] t in self?.onSeekFinal?(t) }

        for v in [playBtn, timeLabel, remainLabel, slider] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(time: Double, isPaused: Bool) {
        if !slider.isDragging { slider.doubleValue = time }
        timeLabel.stringValue   = Renderer.timecode(time)
        remainLabel.stringValue = "-" + Renderer.timecode(max(0, totalDuration - time))
        playBtn.image = sfSymbol(isPaused ? "play.fill" : "pause.fill")
    }

    override func layout() {
        super.layout()
        let cy = bounds.height / 2
        playBtn.frame     = NSRect(x: 12,                  y: cy - 16, width: 32,                          height: 32)
        timeLabel.frame   = NSRect(x: 52,                  y: cy - 9,  width: 110,                         height: 18)
        let slX: CGFloat = 170, slR: CGFloat = 140
        slider.frame      = NSRect(x: slX,                 y: cy - 10, width: bounds.width - slX - slR,    height: 20)
        remainLabel.frame = NSRect(x: bounds.width - slR + 4, y: cy - 9, width: 120,                       height: 18)
    }

    @objc private func playPauseTapped()          { onPlayPause?() }
    @objc private func sliderMoved(_ s: NSSlider) { onSeekVisual?(s.doubleValue) }
}

// ─── Seek slider ──────────────────────────────────────────────────────────────

class SeekSlider: NSSlider {
    var onSeekEnd: ((Double) -> Void)?
    private(set) var isDragging = false

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        super.mouseDown(with: event)
        isDragging = false
        onSeekEnd?(doubleValue)
    }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

private func makeMonoLabel(width: CGFloat, align: NSTextAlignment) -> NSTextField {
    let f = NSTextField()
    f.isEditable = false; f.isSelectable = false
    f.isBezeled  = false; f.drawsBackground = false
    f.textColor  = .white
    f.font       = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    f.alignment  = align
    f.frame      = NSRect(x: 0, y: 0, width: width, height: 18)
    return f
}

private func sfSymbol(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)
}
