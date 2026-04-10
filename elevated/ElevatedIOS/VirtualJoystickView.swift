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
    private var useCount: Int = 0
    private let hideAfterUses: Int = 5

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

    private var showVisuals: Bool { useCount < hideAfterUses }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        if isGhostPlaying { cancelGhostHint() }
        activeTouch = touch
        origin = touch.location(in: self)
        useCount += 1
        if showVisuals { showStick(at: origin) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        let loc = touch.location(in: self)
        value = computeValue(origin: origin, current: loc)
        if showVisuals { updateKnob(value: value) }
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
        if showVisuals { hideStick() }
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
    private var ghostGlow: CAGradientLayer?
    private var ghostTimer: Timer?

    var isGhostPlaying: Bool { ghostTimer != nil }

    /// Play a ghost joystick animation: appears, drifts, returns, fades away.
    /// Returns simulated stick values via the delegate during the animation.
    func playGhostHint() {
        guard ghostTimer == nil else { return }

        // Position: right side of screen, vertically centered
        let cx = bounds.width * 0.80
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

        // Animated conic gradient glow around the base
        let glowSpread: CGFloat = 14
        let glowSize = (br + glowSpread) * 2
        let glow = CAGradientLayer()
        glow.type = .conic
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 0.5, y: 0)
        glow.colors = [
            UIColor(red: 0.60, green: 0.30, blue: 0.90, alpha: 1.0).cgColor,  // purple
            UIColor(red: 0.30, green: 0.50, blue: 1.00, alpha: 1.0).cgColor,  // blue
            UIColor(red: 0.20, green: 0.80, blue: 0.80, alpha: 1.0).cgColor,  // teal
            UIColor(red: 0.30, green: 0.85, blue: 0.40, alpha: 1.0).cgColor,  // green
            UIColor(red: 1.00, green: 0.65, blue: 0.20, alpha: 1.0).cgColor,  // orange
            UIColor(red: 0.95, green: 0.35, blue: 0.55, alpha: 1.0).cgColor,  // pink
            UIColor(red: 0.60, green: 0.30, blue: 0.90, alpha: 1.0).cgColor,  // purple (wrap)
        ]
        glow.frame = CGRect(x: cx - br - glowSpread, y: cy - br - glowSpread,
                            width: glowSize, height: glowSize)
        glow.cornerRadius = glowSize / 2
        glow.opacity = 0

        // Mask: ring shape (cut out the inside to show only the border glow)
        let maskLayer = CAShapeLayer()
        let outerPath = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: glowSize, height: glowSize))
        let innerInset = glowSpread - 4  // thin ring with soft outer edge
        let innerPath = UIBezierPath(ovalIn: CGRect(x: innerInset, y: innerInset,
                                                     width: glowSize - innerInset * 2,
                                                     height: glowSize - innerInset * 2))
        outerPath.append(innerPath.reversing())
        maskLayer.path = outerPath.cgPath
        maskLayer.fillRule = .evenOdd
        glow.mask = maskLayer

        // Spin animation
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Float.pi * 2
        spin.duration = 3.0
        spin.repeatCount = .infinity
        glow.add(spin, forKey: "spin")

        layer.insertSublayer(glow, below: ghostBase)
        ghostGlow = glow

        // 4 seconds: single smooth arc. Peak at 2s, symmetric fade in/out.

        var elapsed: Float = 0
        let interval: Float = 1.0 / 60.0

        ghostTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            elapsed += interval

            guard elapsed < 4.0 else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.ghostBase.opacity = 0
                self.ghostKnob.opacity = 0
                self.ghostGlow?.opacity = 0
                CATransaction.commit()
                self.ghostBase.removeFromSuperlayer()
                self.ghostKnob.removeFromSuperlayer()
                self.ghostGlow?.removeFromSuperlayer()
                self.ghostGlow = nil
                timer.invalidate()
                self.ghostTimer = nil
                return
            }

            // Two smoothstep halves: 0→1 over first 2s, 1→0 over last 2s
            let fade: Float
            if elapsed < 2.0 {
                let t = elapsed / 2.0
                fade = t * t * (3 - 2 * t)
            } else {
                let t = (elapsed - 2.0) / 2.0
                fade = 1.0 - t * t * (3 - 2 * t)
            }

            // Disable implicit animations for all property changes
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            self.ghostBase.opacity = fade * 0.4
            self.ghostKnob.opacity = fade * 0.5
            self.ghostGlow?.opacity = fade * 0.7

            // Knob drifts with same arc
            let maxD = self.maxDisplacement
            let dx = CGFloat(fade) * maxD * 0.45
            let dy = CGFloat(fade) * maxD * -0.12
            let rect = CGRect(x: cx + dx - kr, y: cy + dy - kr, width: kr * 2, height: kr * 2)
            self.ghostKnob.path = UIBezierPath(ovalIn: rect).cgPath

            CATransaction.commit()
        }
    }

    func cancelGhostHint() {
        ghostTimer?.invalidate()
        ghostTimer = nil
        ghostBase.removeFromSuperlayer()
        ghostKnob.removeFromSuperlayer()
        ghostGlow?.removeFromSuperlayer()
        ghostGlow = nil
        delegate?.joystickDidUpdate(value: .zero)
    }
}
#endif
