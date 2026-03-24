// AppDelegate.swift
// Elevated Mac — entry point, menu bar, transport bar

import Cocoa
import MetalKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let releaseStartupDelay: TimeInterval = 5

    var window: NSWindow!
    var renderer: Renderer!
    let synth = SynthPlayer()
    private var transportBar: TransportBar!
    private var debugActive = false
    private var debugMenuItem: NSMenuItem?
    private var muteMenuItem: NSMenuItem?
    private var captureMode = false
    private var launchTime: CFTimeInterval = 0
    private var fullscreenCursorMonitor: Any?
    private var fullscreenCursorHidden = false

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
        window.title = "Elevated — rgba/tbc (Metal port)"
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

    // ── Menu bar ───────────────────────────────────────────────────────────

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // ── App menu ──
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu

        appMenu.addItem(NSMenuItem(title: "About Elevated",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
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

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { endFullscreenCursorHide() }

    private func beginFullscreenCursorHide() {
        guard !fullscreenCursorHidden else { return }
        fullscreenCursorHidden = true
        NSCursor.hide()

        guard fullscreenCursorMonitor == nil else { return }
        fullscreenCursorMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        ) { [weak self] event in
            self?.endFullscreenCursorHide()
            return event
        }
    }

    private func endFullscreenCursorHide() {
        guard fullscreenCursorHidden else { return }
        fullscreenCursorHidden = false
        NSCursor.unhide()
        if let monitor = fullscreenCursorMonitor {
            NSEvent.removeMonitor(monitor)
            fullscreenCursorMonitor = nil
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        beginFullscreenCursorHide()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        beginFullscreenCursorHide()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        endFullscreenCursorHide()
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
