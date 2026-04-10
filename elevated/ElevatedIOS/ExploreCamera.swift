// ExploreCamera.swift
// CoreMotion gyroscope → free camera for Explore Mode.

#if canImport(UIKit)
import CoreMotion
import simd
import ElevatedCore

final class ExploreCamera {
    private let motionManager = CMMotionManager()
    private var referenceAttitude: CMAttitude?

    var position: SIMD3<Float>
    var leftStick: SIMD2<Float> = .zero   // x=strafe, y=forward
    var rightStick: Float = 0             // altitude

    private let boundsMin = SIMD3<Float>(-50, 0.5, -50)
    private let boundsMax = SIMD3<Float>(50, 15, 50)
    private let moveSpeed: Float = 8.0

    init(startPosition: SIMD3<Float>) {
        self.position = startPosition
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.recalibrate()
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        referenceAttitude = nil
    }

    func recalibrate() {
        referenceAttitude = motionManager.deviceMotion?.attitude.copy() as? CMAttitude
    }

    /// Returns the view-projection matrix for this frame.
    func update(dt: Float, aspect: Float) -> simd_float4x4 {
        let orient = currentOrientation()

        // Move camera based on joystick input in camera-relative directions
        let forward = SIMD3<Float>(orient.columns.2.x, 0, orient.columns.2.z)
        let right = SIMD3<Float>(orient.columns.0.x, 0, orient.columns.0.z)
        let fLen = length(forward)
        let rLen = length(right)
        let speed = moveSpeed * dt

        if fLen > 0.001 {
            position += (forward / fLen) * leftStick.y * speed
        }
        if rLen > 0.001 {
            position += (right / rLen) * leftStick.x * speed
        }
        position.y += rightStick * speed

        position = simd_clamp(position, boundsMin, boundsMax)

        return makeVP(orientation: orient, aspect: aspect)
    }

    // MARK: - Private

    private func currentOrientation() -> simd_float3x3 {
        guard let motion = motionManager.deviceMotion else {
            return matrix_identity_float3x3
        }
        let attitude = motion.attitude
        if let ref = referenceAttitude {
            attitude.multiply(byInverseOf: ref)
        }
        return deviceAttitudeToLH(attitude.rotationMatrix)
    }

    /// Convert CMRotationMatrix (device in landscape-right) to LH camera orientation.
    /// Landscape-right: device +X → screen up, device +Y → screen left.
    /// LH world: +X=right, +Y=up, +Z=forward (into screen).
    private func deviceAttitudeToLH(_ m: CMRotationMatrix) -> simd_float3x3 {
        // In landscape-right, the mapping from device axes to screen axes is:
        //   screen right = device -Y
        //   screen up    = device +X
        //   screen fwd   = device -Z (into screen)
        //
        // The rotation matrix m transforms from device frame to reference frame.
        // We remap: world = R * landscapeTransform, where landscapeTransform
        // swaps axes as above.
        let right   = SIMD3<Float>(Float(-m.m21), Float(-m.m22), Float(-m.m23))
        let up      = SIMD3<Float>(Float( m.m11), Float( m.m12), Float( m.m13))
        let forward = SIMD3<Float>(Float(-m.m31), Float(-m.m32), Float(-m.m33))
        return simd_float3x3(columns: (right, up, forward))
    }

    private func makeVP(orientation r: simd_float3x3, aspect: Float) -> simd_float4x4 {
        let viewMatrix = simd_float4x4(columns: (
            SIMD4(r.columns.0.x, r.columns.1.x, r.columns.2.x, 0),
            SIMD4(r.columns.0.y, r.columns.1.y, r.columns.2.y, 0),
            SIMD4(r.columns.0.z, r.columns.1.z, r.columns.2.z, 0),
            SIMD4(-dot(r.columns.0, position),
                   -dot(r.columns.1, position),
                   -dot(r.columns.2, position), 1)
        ))
        let proj = projectionMatrixLH(
            fovY: 75.0 * .pi / 180.0,
            aspect: aspect,
            near: 0.03125,
            far: 256.0
        )
        return proj * viewMatrix
    }
}
#endif
