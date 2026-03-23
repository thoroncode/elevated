// AppDelegate.swift
// Elevated Mac — entry point

import Cocoa
import MetalKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var renderer: Renderer!
    let synth = SynthPlayer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available on this device")
        }

        let mtkView = MTKView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), device: device)
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay     = false
        mtkView.isPaused                  = false

        renderer = Renderer(mtkView: mtkView)
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

        NSApp.activate(ignoringOtherApps: true)

        // Synthesize in background (~1s); when done, sync renderer clock and start audio together.
        synth.synthesize { [weak self] ok in
            guard let self, ok else { print("Synthesis failed"); return }
            self.renderer.startTime = CACurrentMediaTime()
            self.synth.play()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
