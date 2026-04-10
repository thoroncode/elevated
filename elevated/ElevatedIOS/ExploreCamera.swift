// ExploreCamera.swift
// Look-around camera for Explore Mode.
// Produces a rotation matrix applied to the demo VP inside draw(in:).
// At zero offset the rotation is identity — demo camera is untouched.

#if canImport(UIKit)
import simd

final class ExploreCamera {
    /// Raw joystick input: x = look left/right, y = look up/down.
    var stick: SIMD2<Float> = .zero

    /// Current yaw/pitch offset from demo direction (radians).
    private var yawOffset: Float = 0
    private var pitchOffset: Float = 0

    private let maxYaw: Float = 0.9      // ±52°
    private let maxPitch: Float = 0.55   // ±31°
    private let followSpeed: Float = 0.45
    private let holdDelay: Float = 5.0
    private var idleTimer: Float = 0

    var isActive: Bool { length(stick) > 0.05 }

    /// Returns a rotation matrix, or nil (= identity, no change to demo VP).
    func update(dt: Float) -> simd_float4x4? {

        if isActive {
            idleTimer = 0
            let targetYaw = stick.x * maxYaw
            let targetPitch = stick.y * maxPitch
            let blend = min(1.0, followSpeed * dt)
            yawOffset += (targetYaw - yawOffset) * blend
            pitchOffset += (targetPitch - pitchOffset) * blend
        } else {
            if abs(yawOffset) < 0.001 && abs(pitchOffset) < 0.001 {
                yawOffset = 0
                pitchOffset = 0
                return nil  // identity — demo VP untouched
            }

            idleTimer += dt
            if idleTimer > holdDelay {
                let t = idleTimer - holdDelay
                let blend = min(1.0, 0.3 * t * t)
                yawOffset *= (1.0 - blend * dt * 2)
                pitchOffset *= (1.0 - blend * dt * 2)
            }
        }

        let cosY = cos(yawOffset), sinY = sin(yawOffset)
        let cosP = cos(pitchOffset), sinP = sin(pitchOffset)

        let yawRot = simd_float4x4(columns: (
            SIMD4( cosY, 0, sinY, 0),
            SIMD4(    0, 1,    0, 0),
            SIMD4(-sinY, 0, cosY, 0),
            SIMD4(    0, 0,    0, 1)
        ))
        let pitchRot = simd_float4x4(columns: (
            SIMD4(1,    0,     0, 0),
            SIMD4(0, cosP, -sinP, 0),
            SIMD4(0, sinP,  cosP, 0),
            SIMD4(0,    0,     0, 1)
        ))
        return yawRot * pitchRot
    }
}
#endif
