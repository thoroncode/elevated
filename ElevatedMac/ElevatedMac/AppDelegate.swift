// AppDelegate.swift
// Elevated Mac — entry point

import Cocoa
import MetalKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var renderer: Renderer!
    let synth = SynthPlayer()
    var wavPlayer: AVAudioPlayer?

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

        // Try to play pre-rendered WAV immediately; fall back to live synthesis.
        // Look for elevated_music.wav next to the executable (or 3 levels up from source).
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        let candidates = [
            exeDir.appendingPathComponent("elevated_music.wav"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("src/elevated/elevated_music.wav"),
        ]
        let wavURL = candidates.first { FileManager.default.fileExists(atPath: $0.path) }

        if let wavURL = wavURL,
           let player = try? AVAudioPlayer(contentsOf: wavURL) {
            print("[AppDelegate] Playing WAV: \(wavURL.path)")
            wavPlayer = player
            player.play()
        } else {
            print("[AppDelegate] WAV not found, running live synthesis…")
            synth.synthesize { [weak self] ok in
                guard ok else { print("Synthesis failed"); return }
                self?.synth.play()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
