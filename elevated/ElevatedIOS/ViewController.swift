// ViewController.swift
// ElevatedIOS — fullscreen Metal playback with touch-based transport scrubber.

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

    deinit {
        setIdleTimerDisabled(false)
    }

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
            self.setIdleTimerDisabled(true)
        }

        setupTransport()
        setupGestures()

        synth.synthesize { [weak self] ok in
            guard let self, ok else { return }
            self.renderer.start()
            self.synth.play()
            self.setIdleTimerDisabled(true)
        }

        let link = CADisplayLink(target: self, selector: #selector(updateTransport))
        link.add(to: .main, forMode: .common)
    }

    // MARK: - Transport Bar

    private func setupTransport() {
        transportView.translatesAutoresizingMaskIntoConstraints = false
        transportView.alpha = 0
        view.addSubview(transportView)

        let bg = UIView()
        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        bg.layer.cornerRadius = 10
        transportView.addSubview(bg)

        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        progressTrack.layer.cornerRadius = 2
        transportView.addSubview(progressTrack)

        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressFill.backgroundColor = .white
        progressFill.layer.cornerRadius = 2
        transportView.addSubview(progressFill)

        elapsedLabel.translatesAutoresizingMaskIntoConstraints = false
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        elapsedLabel.textColor = .white
        elapsedLabel.text = "0:00"
        transportView.addSubview(elapsedLabel)

        remainingLabel.translatesAutoresizingMaskIntoConstraints = false
        remainingLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        remainingLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        remainingLabel.textAlignment = .right
        remainingLabel.text = "-3:37"
        transportView.addSubview(remainingLabel)

        NSLayoutConstraint.activate([
            transportView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            transportView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            transportView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            transportView.heightAnchor.constraint(equalToConstant: 44),

            bg.leadingAnchor.constraint(equalTo: transportView.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: transportView.trailingAnchor),
            bg.topAnchor.constraint(equalTo: transportView.topAnchor),
            bg.bottomAnchor.constraint(equalTo: transportView.bottomAnchor),

            elapsedLabel.leadingAnchor.constraint(equalTo: transportView.leadingAnchor, constant: 12),
            elapsedLabel.centerYAnchor.constraint(equalTo: transportView.centerYAnchor, constant: -8),

            remainingLabel.trailingAnchor.constraint(equalTo: transportView.trailingAnchor, constant: -12),
            remainingLabel.centerYAnchor.constraint(equalTo: elapsedLabel.centerYAnchor),

            progressTrack.leadingAnchor.constraint(equalTo: transportView.leadingAnchor, constant: 12),
            progressTrack.trailingAnchor.constraint(equalTo: transportView.trailingAnchor, constant: -12),
            progressTrack.topAnchor.constraint(equalTo: elapsedLabel.bottomAnchor, constant: 6),
            progressTrack.heightAnchor.constraint(equalToConstant: 4),

            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
        ])

        progressFill.widthAnchor.constraint(equalToConstant: 0).isActive = true
    }

    @objc private func updateTransport() {
        guard transportView.alpha > 0 else { return }
        let t = isScrubbing ? scrubTime : renderer.currentTime
        let duration = kDemoDuration
        let fraction = CGFloat(t / duration)

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
        UIView.animate(withDuration: 0.25) { self.transportView.alpha = 1 }
        scheduleHideTransport()
    }

    private func hideTransport() {
        guard !isScrubbing else { return }
        UIView.animate(withDuration: 0.4) { self.transportView.alpha = 0 }
    }

    private func scheduleHideTransport() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            self?.hideTransport()
        }
    }

    // MARK: - Gestures

    private var wasPausedBeforeScrub = false

    private func setupGestures() {
        // Single tap: show transport, second tap toggles pause
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        view.addGestureRecognizer(tap)

        // Pan: scrub (only activates in bottom third or when transport is visible)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: view)
        let inBottomArea = location.y > view.bounds.height * 0.7

        if transportView.alpha < 0.5 {
            // Transport hidden — show it (and pause if tapped in main area)
            showTransport()
            if !inBottomArea {
                if renderer.isPaused { renderer.resume(); synth.resume() }
                else                 { renderer.pause(); synth.pause() }
                updateIdleTimerForPlayback()
            }
        } else {
            // Transport visible — tap toggles play/pause
            if renderer.isPaused { renderer.resume(); synth.resume() }
            else                 { renderer.pause(); synth.pause() }
            updateIdleTimerForPlayback()
            scheduleHideTransport()
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: view)
        let fraction = Double((location.x - 20) / (view.bounds.width - 40))
        let time = max(0, min(fraction * kDemoDuration, kDemoDuration))

        switch gesture.state {
        case .began:
            isScrubbing = true
            wasPausedBeforeScrub = renderer.isPaused
            scrubTime = time
            showTransport()
            hideTimer?.invalidate()
            if !renderer.isPaused {
                renderer.pause()
                synth.pause()
            }
            updateIdleTimerForPlayback()

        case .changed:
            scrubTime = time
            renderer.seek(to: scrubTime)

        case .ended, .cancelled:
            isScrubbing = false
            synth.seek(to: scrubTime)
            if !wasPausedBeforeScrub {
                renderer.resume()
                synth.resume()
            }
            updateIdleTimerForPlayback()
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
        setIdleTimerDisabled(false)
        // Stop GPU work entirely when backgrounded
        (view.subviews.first as? MTKView)?.isPaused = true
    }

    func resumePlayback() {
        (view.subviews.first as? MTKView)?.isPaused = false
        if wasPlayingBeforeBackground {
            renderer.resume()
            synth.resume()
        }
        updateIdleTimerForPlayback()
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

    private func updateIdleTimerForPlayback() {
        setIdleTimerDisabled(!renderer.isPaused)
    }

    // Custom Metal playback does not get AVPlayer's automatic sleep prevention.
    private func setIdleTimerDisabled(_ isDisabled: Bool) {
        guard UIApplication.shared.isIdleTimerDisabled != isDisabled else { return }
        UIApplication.shared.isIdleTimerDisabled = isDisabled
    }

    public override var prefersStatusBarHidden: Bool { true }
    public override var prefersHomeIndicatorAutoHidden: Bool { true }
    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
}

extension ViewController: UIGestureRecognizerDelegate {
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIPanGestureRecognizer else { return true }
        // Only allow pan/scrub when transport is visible
        return transportView.alpha > 0.5
    }
}
#endif
