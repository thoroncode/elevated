// VirtualJoystickView.swift
// Floating dual thumbstick overlay for Explore Mode.

#if canImport(UIKit)
import UIKit

protocol VirtualJoystickDelegate: AnyObject {
    func joystickDidUpdate(left: SIMD2<Float>, right: SIMD2<Float>)
}

final class VirtualJoystickView: UIView {
    weak var delegate: VirtualJoystickDelegate?

    private var leftTouch: UITouch?
    private var rightTouch: UITouch?
    private var leftOrigin: CGPoint = .zero
    private var rightOrigin: CGPoint = .zero
    private var leftValue: SIMD2<Float> = .zero
    private var rightValue: SIMD2<Float> = .zero

    private let leftBase = CAShapeLayer()
    private let leftKnob = CAShapeLayer()
    private let rightBase = CAShapeLayer()
    private let rightKnob = CAShapeLayer()

    private let baseRadius: CGFloat = 60
    private let knobRadius: CGFloat = 22
    private let maxDisplacement: CGFloat = 45

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        backgroundColor = .clear

        for base in [leftBase, rightBase] {
            base.fillColor = UIColor.white.withAlphaComponent(0.08).cgColor
            base.strokeColor = UIColor.white.withAlphaComponent(0.25).cgColor
            base.lineWidth = 1.5
            base.opacity = 0
            layer.addSublayer(base)
        }
        for knob in [leftKnob, rightKnob] {
            knob.fillColor = UIColor.white.withAlphaComponent(0.35).cgColor
            knob.strokeColor = UIColor.white.withAlphaComponent(0.5).cgColor
            knob.lineWidth = 1
            knob.opacity = 0
            layer.addSublayer(knob)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let loc = touch.location(in: self)
            let isLeft = loc.x < bounds.midX

            if isLeft && leftTouch == nil {
                leftTouch = touch
                leftOrigin = loc
                showStick(base: leftBase, knob: leftKnob, at: loc)
            } else if !isLeft && rightTouch == nil {
                rightTouch = touch
                rightOrigin = loc
                showStick(base: rightBase, knob: rightKnob, at: loc)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let loc = touch.location(in: self)

            if touch === leftTouch {
                leftValue = computeValue(origin: leftOrigin, current: loc)
                updateKnob(leftKnob, origin: leftOrigin, value: leftValue)
            } else if touch === rightTouch {
                rightValue = computeValue(origin: rightOrigin, current: loc)
                updateKnob(rightKnob, origin: rightOrigin, value: rightValue)
            }
        }
        delegate?.joystickDidUpdate(left: leftValue, right: rightValue)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    private func endTouches(_ touches: Set<UITouch>) {
        for touch in touches {
            if touch === leftTouch {
                leftTouch = nil
                leftValue = .zero
                hideStick(base: leftBase, knob: leftKnob)
            } else if touch === rightTouch {
                rightTouch = nil
                rightValue = .zero
                hideStick(base: rightBase, knob: rightKnob)
            }
        }
        delegate?.joystickDidUpdate(left: leftValue, right: rightValue)
    }

    // MARK: - Stick math

    private func computeValue(origin: CGPoint, current: CGPoint) -> SIMD2<Float> {
        let dx = current.x - origin.x
        let dy = current.y - origin.y
        let dist = sqrt(dx * dx + dy * dy)
        let clamped = min(dist, maxDisplacement)
        guard dist > 1 else { return .zero }
        let scale = Float(clamped / maxDisplacement)
        // Y inverted: drag up = positive (forward/ascend)
        return SIMD2(Float(dx / dist) * scale, Float(-dy / dist) * scale)
    }

    // MARK: - Drawing

    private func showStick(base: CAShapeLayer, knob: CAShapeLayer, at point: CGPoint) {
        let baseRect = CGRect(x: point.x - baseRadius, y: point.y - baseRadius,
                              width: baseRadius * 2, height: baseRadius * 2)
        base.path = UIBezierPath(ovalIn: baseRect).cgPath
        base.opacity = 1

        let knobRect = CGRect(x: point.x - knobRadius, y: point.y - knobRadius,
                              width: knobRadius * 2, height: knobRadius * 2)
        knob.path = UIBezierPath(ovalIn: knobRect).cgPath
        knob.opacity = 1
    }

    private func updateKnob(_ knob: CAShapeLayer, origin: CGPoint, value: SIMD2<Float>) {
        let dx = CGFloat(value.x) * maxDisplacement
        let dy = CGFloat(-value.y) * maxDisplacement  // un-invert for screen coords
        let cx = origin.x + dx
        let cy = origin.y + dy
        let knobRect = CGRect(x: cx - knobRadius, y: cy - knobRadius,
                              width: knobRadius * 2, height: knobRadius * 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        knob.path = UIBezierPath(ovalIn: knobRect).cgPath
        CATransaction.commit()
    }

    private func hideStick(base: CAShapeLayer, knob: CAShapeLayer) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        base.opacity = 0
        knob.opacity = 0
        CATransaction.commit()
    }
}
#endif
