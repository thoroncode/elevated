// ExploreCamera.swift
// Look-around camera for Explore Mode.
// Follows the demo flight path exactly. Stick gives a direction to look.
// Offset smoothly follows the stick, smoothly returns when released.

#if canImport(UIKit)
import simd
import ElevatedCore

final class ExploreCamera {
    /// Raw joystick input: x = look left/right, y = look up/down.
    var stick: SIMD2<Float> = .zero

    /// Current yaw/pitch offset from demo direction (radians).
    private var yawOffset: Float = 0
    private var pitchOffset: Float = 0

    // How far the stick can turn the camera (radians at full deflection)
    private let maxYaw: Float = 0.8        // ±46°
    private let maxPitch: Float = 0.5      // ±29°

    // Smoothing: how fast offset follows the target (per second)
    private let followSpeed: Float = 0.4   // slow, cinematic
    private let returnSpeed: Float = 0.15  // even slower return
    private let holdDelay: Float = 5.0     // seconds before returning to demo
    private var idleTimer: Float = 0

    var isActive: Bool { length(stick) > 0.05 }

    /// Returns VP with look-around applied, or nil for exact demo camera.
    func update(dt: Float, aspect: Float, demoFov: Float,
                demoPos: SIMD3<Float>, demoTarget: SIMD3<Float>) -> simd_float4x4? {

        if isActive {
            idleTimer = 0

            // Target offset from stick (stick already has cubic curve)
            let targetYaw = stick.x * maxYaw
            let targetPitch = stick.y * maxPitch

            // Smoothly move toward target
            let blend = min(1.0, followSpeed * dt)
            yawOffset += (targetYaw - yawOffset) * blend
            pitchOffset += (targetPitch - pitchOffset) * blend
        } else {
            idleTimer += dt

            if idleTimer > holdDelay {
                // Smoothly ease offsets back to zero
                let t = idleTimer - holdDelay
                let blend = min(1.0, 0.3 * t * t)  // quadratic ramp: slow start, accelerates
                yawOffset *= (1.0 - blend * dt * 2)
                pitchOffset *= (1.0 - blend * dt * 2)

                if abs(yawOffset) < 0.001 && abs(pitchOffset) < 0.001 {
                    yawOffset = 0
                    pitchOffset = 0
                    return nil
                }
            }
            // Within hold period — keep the offset where user left it
        }

        // Build VP from raw demo position + offset look direction
        let demoFwd = normalize(demoTarget - demoPos)
        let demoRight = normalize(cross(SIMD3<Float>(0, 1, 0), demoFwd))
        let demoUp = cross(demoFwd, demoRight)

        // Apply yaw (rotate around up)
        let cosY = cos(yawOffset), sinY = sin(yawOffset)
        let yawedFwd = demoFwd * cosY + demoRight * sinY
        let yawedRight = demoRight * cosY - demoFwd * sinY

        // Apply pitch (rotate around right)
        let cosP = cos(pitchOffset), sinP = sin(pitchOffset)
        let forward = yawedFwd * cosP + demoUp * sinP
        let up = demoUp * cosP - yawedFwd * sinP
        let right = yawedRight

        let viewMatrix = simd_float4x4(columns: (
            SIMD4(right.x, up.x, forward.x, 0),
            SIMD4(right.y, up.y, forward.y, 0),
            SIMD4(right.z, up.z, forward.z, 0),
            SIMD4(-dot(right, demoPos), -dot(up, demoPos), -dot(forward, demoPos), 1)
        ))

        let fov = demoFov > 0.01 ? demoFov : (75.0 * .pi / 180.0)
        let proj = projectionMatrixLH(fovY: fov, aspect: aspect, near: 0.03125, far: 256.0)
        return proj * viewMatrix
    }
}
#endif
