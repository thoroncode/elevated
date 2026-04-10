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
        activeTouch = touch
        origin = touch.location(in: self)
        showStick(at: origin)
        // Don't send any value on touch-down — wait for movement
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
}
#endif
