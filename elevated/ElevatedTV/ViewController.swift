// ViewController.swift
// ElevatedTV — fullscreen Metal playback, loops on completion.

#if canImport(UIKit)
import UIKit
import MetalKit
import AVFoundation
import ElevatedCore

public class ViewController: UIViewController {
    private var renderer: Renderer!
    private let synth = SynthPlayer()

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        activateAudioSession()

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not available")
        }

        let mtkView = MTKView(frame: view.bounds, device: device)
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.addSubview(mtkView)

        renderer = Renderer(mtkView: mtkView, debug: false, capture: false)
        mtkView.delegate = renderer
        renderer.onDemoEnd = { [weak self] in
            guard let self else { return }
            self.synth.seek(to: 0)
            self.renderer.start()
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        view.addGestureRecognizer(tap)

        synth.synthesize { [weak self] ok in
            guard let self, ok else { return }
            self.renderer.start()
            self.synth.play()
        }
    }

    @objc private func handleTap() {
        if renderer.isPaused { renderer.resume(); synth.resume() }
        else                 { renderer.pause();  synth.pause()  }
    }

    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[ViewController] AVAudioSession setup failed: \(error)")
        }
    }
}
#endif
