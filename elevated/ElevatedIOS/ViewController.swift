// ViewController.swift
// ElevatedIOS — fullscreen Metal playback, landscape-locked, no debug UI.

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
        renderer.onDemoEnd = {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
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

    // MARK: - Background/Foreground

    func pausePlayback() {
        guard !renderer.isPaused else { return }
        renderer.pause()
        synth.pause()
    }

    func resumePlayback() {
        guard renderer.isPaused else { return }
        renderer.resume()
        synth.resume()
    }

    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[ViewController] AVAudioSession setup failed: \(error)")
        }
    }

    public override var prefersStatusBarHidden: Bool { true }
    public override var prefersHomeIndicatorAutoHidden: Bool { true }
    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
}
#endif
