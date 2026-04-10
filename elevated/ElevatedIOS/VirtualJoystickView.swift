// VirtualJoystickView.swift
// Single floating thumbstick overlay for Explore Mode.

#if canImport(UIKit)
import UIKit

protocol VirtualJoystickDelegate: AnyObject {
    func joystickDidUpdate(value: SIMD2<Float>)
}

final class VirtualJoystickView: UIView {
    weak var delegate: VirtualJoystickDelegate?

    private var activeTouch: UITouch?
    private var origin: CGPoint = .zero
    private var value: SIMD2<Float> = .zero

    private let base = CAShapeLayer()
    private let knob = CAShapeLayer()

    private let baseRadius: CGFloat = 120
    private let knobRadius: CGFloat = 40
    private let maxDisplacement: CGFloat = 80

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        backgroundColor = .clear

        base.fillColor = UIColor.white.withAlphaComponent(0.08).cgColor
        base.strokeColor = UIColor.white.withAlphaComponent(0.25).cgColor
        base.lineWidth = 1.5
        base.opacity = 0
        layer.addSublayer(base)

        knob.fillColor = UIColor.white.withAlphaComponent(0.35).cgColor
        knob.strokeColor = UIColor.white.withAlphaComponent(0.5).cgColor
        knob.lineWidth = 1
        knob.opacity = 0
        layer.addSublayer(knob)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        // Cancel ghost hint if playing
        if isGhostPlaying { cancelGhostHint() }
        activeTouch = touch
        origin = touch.location(in: self)
        showStick(at: origin)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        let loc = touch.location(in: self)
        value = computeValue(origin: origin, current: loc)
        updateKnob(value: value)
        delegate?.joystickDidUpdate(value: value)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouch(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouch(touches)
    }

    private func endTouch(_ touches: Set<UITouch>) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        activeTouch = nil
        value = .zero
        delegate?.joystickDidUpdate(value: .zero)
        hideStick()
    }

    private let deadZone: CGFloat = 15  // pixels of movement before any output

    private func computeValue(origin: CGPoint, current: CGPoint) -> SIMD2<Float> {
        let dx = current.x - origin.x
        let dy = current.y - origin.y
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > deadZone else { return .zero }
        let effective = min(dist - deadZone, maxDisplacement)
        let linear = Float(effective / maxDisplacement)  // 0..1
        // Cubic curve: gentle at start, ramps up at the end
        let curved = linear * linear * linear
        return SIMD2(Float(dx / dist) * curved, Float(-dy / dist) * curved)
    }

    private func showStick(at point: CGPoint) {
        let baseRect = CGRect(x: point.x - baseRadius, y: point.y - baseRadius,
                              width: baseRadius * 2, height: baseRadius * 2)
        base.path = UIBezierPath(ovalIn: baseRect).cgPath
        base.opacity = 1

        let knobRect = CGRect(x: point.x - knobRadius, y: point.y - knobRadius,
                              width: knobRadius * 2, height: knobRadius * 2)
        knob.path = UIBezierPath(ovalIn: knobRect).cgPath
        knob.opacity = 1
    }

    private func updateKnob(value: SIMD2<Float>) {
        let dx = CGFloat(value.x) * maxDisplacement
        let dy = CGFloat(-value.y) * maxDisplacement
        let cx = origin.x + dx
        let cy = origin.y + dy
        let knobRect = CGRect(x: cx - knobRadius, y: cy - knobRadius,
                              width: knobRadius * 2, height: knobRadius * 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        knob.path = UIBezierPath(ovalIn: knobRect).cgPath
        CATransaction.commit()
    }

    private func hideStick() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        base.opacity = 0
        knob.opacity = 0
        CATransaction.commit()
    }

    // MARK: - Ghost hint animation

    private let ghostBase = CAShapeLayer()
    private let ghostKnob = CAShapeLayer()
    private var ghostTimer: Timer?

    var isGhostPlaying: Bool { ghostTimer != nil }

    /// Play a ghost joystick animation: appears, drifts, returns, fades away.
    /// Returns simulated stick values via the delegate during the animation.
    func playGhostHint() {
        guard ghostTimer == nil else { return }

        // Position: right side of screen, vertically centered
        let cx = bounds.width * 0.65
        let cy = bounds.height * 0.5

        ghostBase.fillColor = UIColor.white.withAlphaComponent(0.04).cgColor
        ghostBase.strokeColor = UIColor.white.withAlphaComponent(0.12).cgColor
        ghostBase.lineWidth = 1.5
        ghostBase.opacity = 0
        layer.addSublayer(ghostBase)

        ghostKnob.fillColor = UIColor.white.withAlphaComponent(0.15).cgColor
        ghostKnob.strokeColor = UIColor.white.withAlphaComponent(0.25).cgColor
        ghostKnob.lineWidth = 1
        ghostKnob.opacity = 0
        layer.addSublayer(ghostKnob)

        let br = baseRadius
        let kr = knobRadius
        ghostBase.path = UIBezierPath(ovalIn: CGRect(x: cx - br, y: cy - br,
                                                      width: br * 2, height: br * 2)).cgPath
        ghostKnob.path = UIBezierPath(ovalIn: CGRect(x: cx - kr, y: cy - kr,
                                                      width: kr * 2, height: kr * 2)).cgPath

        // Animation timeline (total ~6s):
        // 0-1.5s: fade in
        // 1.5-3.5s: drift right
        // 3.5-5s: drift back to center
        // 5-6s: fade out

        var elapsed: Float = 0
        let interval: Float = 1.0 / 60.0

        ghostTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            elapsed += interval
            let maxD = self.maxDisplacement

            if elapsed < 1.5 {
                // Fade in
                let alpha = elapsed / 1.5
                self.ghostBase.opacity = Float(alpha)
                self.ghostKnob.opacity = Float(alpha)
            } else if elapsed < 3.5 {
                // Drift right and slightly up
                self.ghostBase.opacity = 1
                self.ghostKnob.opacity = 1
                let t = (elapsed - 1.5) / 2.0  // 0→1
                let smooth = t * t * (3 - 2 * t)  // smoothstep
                let dx = CGFloat(smooth) * maxD * 0.6
                let dy = CGFloat(smooth) * maxD * -0.2
                let rect = CGRect(x: cx + dx - kr, y: cy + dy - kr, width: kr * 2, height: kr * 2)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.ghostKnob.path = UIBezierPath(ovalIn: rect).cgPath
                CATransaction.commit()
                // Send ghost input to camera
                self.delegate?.joystickDidUpdate(value: SIMD2(Float(smooth) * 0.3, Float(smooth) * 0.1))
            } else if elapsed < 5.0 {
                // Drift back
                let t = (elapsed - 3.5) / 1.5  // 0→1
                let smooth = t * t * (3 - 2 * t)
                let dx = CGFloat(1 - smooth) * maxD * 0.6
                let dy = CGFloat(1 - smooth) * maxD * -0.2
                let rect = CGRect(x: cx + dx - kr, y: cy + dy - kr, width: kr * 2, height: kr * 2)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.ghostKnob.path = UIBezierPath(ovalIn: rect).cgPath
                CATransaction.commit()
                self.delegate?.joystickDidUpdate(value: SIMD2(Float(1 - smooth) * 0.3, Float(1 - smooth) * 0.1))
            } else if elapsed < 6.0 {
                // Fade out
                let alpha = 1.0 - (elapsed - 5.0)
                self.ghostBase.opacity = Float(alpha)
                self.ghostKnob.opacity = Float(alpha)
                self.delegate?.joystickDidUpdate(value: .zero)
            } else {
                // Done
                self.ghostBase.removeFromSuperlayer()
                self.ghostKnob.removeFromSuperlayer()
                self.delegate?.joystickDidUpdate(value: .zero)
                timer.invalidate()
                self.ghostTimer = nil
            }
        }
    }

    func cancelGhostHint() {
        ghostTimer?.invalidate()
        ghostTimer = nil
        ghostBase.removeFromSuperlayer()
        ghostKnob.removeFromSuperlayer()
        delegate?.joystickDidUpdate(value: .zero)
    }
}
#endif
