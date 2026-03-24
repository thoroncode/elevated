// AppDelegate.swift
// Elevated Mac — entry point + transport bar

import Cocoa
import MetalKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var renderer: Renderer!
    let synth = SynthPlayer()
    private var transportBar: TransportBar!
    private var hideTimer: Timer?
    private var captureMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available on this device")
        }

        let mtkView = MTKView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), device: device)
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay     = false
        mtkView.isPaused                  = false

        let debugMode = CommandLine.arguments.contains("--debug")
        captureMode   = CommandLine.arguments.contains("--capture")
        renderer = Renderer(mtkView: mtkView, debug: debugMode || captureMode, capture: captureMode)
        mtkView.delegate = renderer

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Elevated — rgba (Metal port)"
        window.contentView = mtkView
        window.center()
        window.makeKeyAndOrderFront(nil)

        if debugMode {
            renderer.installDebugOverlay(in: mtkView)
        }

        if !captureMode {
            installTransportBar(in: mtkView)
            installKeyHandler()
        }

        NSApp.activate(ignoringOtherApps: true)

        synth.synthesize { [weak self] ok in
            guard let self, ok else { print("Synthesis failed"); return }
            self.renderer.start()
            self.synth.play()
        }
    }

    // ── Transport bar ──────────────────────────────────────────────────────

    private func installTransportBar(in view: MTKView) {
        transportBar = TransportBar(frame: NSRect(x: 0, y: 0, width: view.bounds.width, height: 56))
        transportBar.alphaValue = 0
        view.addSubview(transportBar)

        transportBar.onPlayPause  = { [weak self] in self?.togglePlayPause() }
        transportBar.onSeekVisual = { [weak self] t in self?.renderer.seek(to: t) }
        transportBar.onSeekFinal  = { [weak self] t in
            self?.renderer.seek(to: t)
            self?.synth.seek(to: t)
        }

        // Show bar on any mouse activity
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            self?.showTransportBar()
            return event
        }

        // Plug into render loop
        renderer.onDraw = { [weak self] in self?.onFrame() }
    }

    private func onFrame() {
        guard let tb = transportBar, let sv = tb.superview else { return }
        tb.frame = NSRect(x: 0, y: 0, width: sv.bounds.width, height: 56)
        tb.update(time: renderer.currentTime, isPaused: renderer.isPaused)
    }

    // ── Play / pause / seek ────────────────────────────────────────────────

    private func togglePlayPause() {
        if renderer.isPaused {
            renderer.resume(); synth.resume()
        } else {
            renderer.pause(); synth.pause()
        }
        showTransportBar()
    }

    private func seekBy(_ delta: Double) {
        let t = max(0, min(renderer.currentTime + delta, 217.0))
        renderer.seek(to: t)
        synth.seek(to: t)
        showTransportBar()
    }

    // ── Transport bar show / hide ──────────────────────────────────────────

    private func showTransportBar() {
        hideTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            transportBar.animator().alphaValue = 1
        }
        guard !renderer.isPaused else { return }   // keep visible while paused
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.hideTransportBar()
        }
    }

    private func hideTransportBar() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            transportBar.animator().alphaValue = 0
        }
    }

    // ── Keyboard (mpv-style) ───────────────────────────────────────────────

    private func installKeyHandler() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
            return nil
        }
    }

    private func handleKey(_ event: NSEvent) {
        let frame = 1.0 / 60.0
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49:  togglePlayPause()                          // Space
        case 123: seekBy(shift ? -frame : -5)                // ←  / Shift←  (-1f / -5s)
        case 124: seekBy(shift ?  frame :  5)                // →  / Shift→  (+1f / +5s)
        case 125: seekBy(-60)                                // ↓  (-60s)
        case 126: seekBy( 60)                                // ↑  (+60s)
        case 47:  if renderer.isPaused { seekBy( frame) }   // .  step forward
        case 43:  if renderer.isPaused { seekBy(-frame) }   // ,  step backward
        default:  break
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
    private let totalDuration = 217.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor

        // Play/pause button
        playBtn.bezelStyle   = .inline
        playBtn.isBordered   = false
        playBtn.target       = self
        playBtn.action       = #selector(playPauseTapped)
        playBtn.image        = sfSymbol("pause.fill")
        playBtn.contentTintColor = .white

        // Seek slider
        slider.minValue    = 0
        slider.maxValue    = totalDuration
        slider.isContinuous = true
        slider.target      = self
        slider.action      = #selector(sliderMoved(_:))
        slider.onSeekEnd   = { [weak self] t in self?.onSeekFinal?(t) }

        for v in [playBtn, timeLabel, remainLabel, slider] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    // Update called every frame from AppDelegate.onFrame()
    func update(time: Double, isPaused: Bool) {
        if !slider.isDragging {
            slider.doubleValue = time
        }
        timeLabel.stringValue   = Renderer.timecode(time)
        let rem = max(0, totalDuration - time)
        remainLabel.stringValue = "-" + Renderer.timecode(rem)
        playBtn.image = sfSymbol(isPaused ? "play.fill" : "pause.fill")
    }

    override func layout() {
        super.layout()
        let cy = bounds.height / 2
        playBtn.frame    = NSRect(x: 12, y: cy - 16, width: 32, height: 32)
        timeLabel.frame  = NSRect(x: 52, y: cy - 9,  width: 110, height: 18)
        let slX: CGFloat = 170, slR: CGFloat = 140
        slider.frame     = NSRect(x: slX, y: cy - 10, width: bounds.width - slX - slR, height: 20)
        remainLabel.frame = NSRect(x: bounds.width - slR + 4, y: cy - 9, width: 120, height: 18)
    }

    @objc private func playPauseTapped()        { onPlayPause?() }
    @objc private func sliderMoved(_ s: NSSlider) { onSeekVisual?(s.doubleValue) }
}

// ─── Seek slider — detects drag end via blocking mouseDown ────────────────────

class SeekSlider: NSSlider {
    var onSeekEnd: ((Double) -> Void)?
    private(set) var isDragging = false

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        super.mouseDown(with: event)   // blocks in tracking loop until mouse-up
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
