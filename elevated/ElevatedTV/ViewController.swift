// ViewController.swift
// ElevatedTV — fullscreen Metal playback with native-feeling transport scrubber.

#if canImport(UIKit)
import UIKit
import MetalKit
import AVFoundation
import ElevatedCore

public class ViewController: UIViewController {
    private var renderer: Renderer!
    private let synth = SynthPlayer()

    // Transport overlay
    private let transportView = UIView()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private var hideTimer: Timer?
    private var isScrubbing = false
    private var scrubTime: Double = 0

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        activateAudioSession()

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not available")
        }

        let mtkView = MTKView(frame: view.bounds, device: device)
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mtkView.contentScaleFactor = 1.0  // render at 1080p, not native 4K
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

        setupTransport()
        setupGestures()

        synth.synthesize { [weak self] ok in
            guard let self, ok else { return }
            self.renderer.start()
            self.synth.play()
        }

        // Update progress bar every frame via display link
        let link = CADisplayLink(target: self, selector: #selector(updateTransport))
        link.add(to: .main, forMode: .common)
    }

    // MARK: - Transport Bar

    private func setupTransport() {
        // Container at bottom of screen
        transportView.translatesAutoresizingMaskIntoConstraints = false
        transportView.alpha = 0
        view.addSubview(transportView)

        // Semi-transparent background gradient
        let bg = UIView()
        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        bg.layer.cornerRadius = 12
        transportView.addSubview(bg)

        // Progress track (gray bar)
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        progressTrack.layer.cornerRadius = 3
        transportView.addSubview(progressTrack)

        // Progress fill (white bar)
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressFill.backgroundColor = .white
        progressFill.layer.cornerRadius = 3
        transportView.addSubview(progressFill)

        // Elapsed time label
        elapsedLabel.translatesAutoresizingMaskIntoConstraints = false
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .medium)
        elapsedLabel.textColor = .white
        elapsedLabel.text = "0:00"
        transportView.addSubview(elapsedLabel)

        // Remaining time label
        remainingLabel.translatesAutoresizingMaskIntoConstraints = false
        remainingLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .medium)
        remainingLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        remainingLabel.textAlignment = .right
        remainingLabel.text = "-3:37"
        transportView.addSubview(remainingLabel)

        NSLayoutConstraint.activate([
            transportView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 80),
            transportView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -80),
            transportView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -60),
            transportView.heightAnchor.constraint(equalToConstant: 80),

            bg.leadingAnchor.constraint(equalTo: transportView.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: transportView.trailingAnchor),
            bg.topAnchor.constraint(equalTo: transportView.topAnchor),
            bg.bottomAnchor.constraint(equalTo: transportView.bottomAnchor),

            elapsedLabel.leadingAnchor.constraint(equalTo: transportView.leadingAnchor, constant: 24),
            elapsedLabel.centerYAnchor.constraint(equalTo: transportView.centerYAnchor, constant: -14),

            remainingLabel.trailingAnchor.constraint(equalTo: transportView.trailingAnchor, constant: -24),
            remainingLabel.centerYAnchor.constraint(equalTo: elapsedLabel.centerYAnchor),

            progressTrack.leadingAnchor.constraint(equalTo: transportView.leadingAnchor, constant: 24),
            progressTrack.trailingAnchor.constraint(equalTo: transportView.trailingAnchor, constant: -24),
            progressTrack.topAnchor.constraint(equalTo: elapsedLabel.bottomAnchor, constant: 10),
            progressTrack.heightAnchor.constraint(equalToConstant: 6),

            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
        ])

        // Width constraint for fill — updated each frame
        progressFill.widthAnchor.constraint(equalToConstant: 0).isActive = true
    }

    @objc private func updateTransport() {
        guard transportView.alpha > 0 else { return }
        let t = isScrubbing ? scrubTime : renderer.currentTime
        let duration = kDemoDuration
        let fraction = CGFloat(t / duration)

        // Update fill width
        let trackWidth = progressTrack.bounds.width
        if trackWidth > 0 {
            for c in progressFill.constraints where c.firstAttribute == .width {
                c.constant = trackWidth * min(1, max(0, fraction))
            }
        }

        elapsedLabel.text = formatTime(t)
        remainingLabel.text = "-\(formatTime(duration - t))"
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Transport Show/Hide

    private func showTransport() {
        hideTimer?.invalidate()
        UIView.animate(withDuration: 0.3) { self.transportView.alpha = 1 }
        scheduleHideTransport()
    }

    private func hideTransport() {
        guard !isScrubbing else { return }
        UIView.animate(withDuration: 0.5) { self.transportView.alpha = 0 }
    }

    private func scheduleHideTransport() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            self?.hideTransport()
        }
    }

    // MARK: - Gestures

    private func setupGestures() {
        // Tap: toggle play/pause + show transport
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        view.addGestureRecognizer(tap)

        // Play/Pause button on remote
        let playPause = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        playPause.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
        view.addGestureRecognizer(playPause)

        // Pan: scrub through the demo
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        view.addGestureRecognizer(pan)
    }

    @objc private func handleTap() {
        if renderer.isPaused {
            renderer.resume(); synth.resume()
        } else {
            renderer.pause(); synth.pause()
        }
        showTransport()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .began:
            isScrubbing = true
            scrubTime = renderer.currentTime
            showTransport()
            hideTimer?.invalidate()

        case .changed:
            // Map horizontal velocity to seek speed
            // Siri Remote touchpad is small, so velocity-based scrubbing feels natural
            let speed = Double(velocity.x) / 800.0  // seconds per point of velocity
            scrubTime += speed * (1.0 / 60.0)  // per-frame delta
            scrubTime = max(0, min(scrubTime, kDemoDuration))
            renderer.seek(to: scrubTime)

        case .ended, .cancelled:
            isScrubbing = false
            synth.seek(to: scrubTime)
            scheduleHideTransport()

        default:
            break
        }
    }

    // MARK: - Background/Foreground

    private var wasPlayingBeforeBackground = false

    func pausePlayback() {
        wasPlayingBeforeBackground = !renderer.isPaused
        if !renderer.isPaused {
            renderer.pause()
            synth.pause()
        }
        // Stop GPU work entirely when backgrounded
        (view.subviews.first as? MTKView)?.isPaused = true
    }

    func resumePlayback() {
        // Restart GPU rendering
        (view.subviews.first as? MTKView)?.isPaused = false
        if wasPlayingBeforeBackground {
            renderer.resume()
            synth.resume()
        }
    }

    // MARK: - Audio Session

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
