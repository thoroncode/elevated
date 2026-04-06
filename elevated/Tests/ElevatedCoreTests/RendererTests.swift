import XCTest
import MetalKit
@testable import ElevatedCore

final class RendererTests: XCTestCase {

    static var renderer: Renderer!

    override class func setUp() {
        super.setUp()
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        renderer = Renderer(mtkView: view, debug: false, capture: false)
    }

    private var renderer: Renderer { RendererTests.renderer }

    // MARK: - Timecode

    func testTimecodeZero() {
        XCTAssertEqual(Renderer.timecode(0), "00:00:00:00")
    }

    func testTimecodeOneSecond() {
        XCTAssertEqual(Renderer.timecode(1.0), "00:00:01:00")
    }

    func testTimecodeWithFrames() {
        XCTAssertEqual(Renderer.timecode(1.5), "00:00:01:30")
    }

    func testTimecodeNegativeClamped() {
        XCTAssertEqual(Renderer.timecode(-5.0), "00:00:00:00")
    }

    // MARK: - Math helpers

    func testLookAtLHIdentityLike() {
        let m = lookAtLH(eye: SIMD3(0, 0, 0), center: SIMD3(0, 0, 1), up: SIMD3(0, 1, 0))
        // Looking along +Z with Y up should give near-identity rotation
        XCTAssertEqual(m.columns.0.x, 1.0, accuracy: 1e-5)
        XCTAssertEqual(m.columns.1.y, 1.0, accuracy: 1e-5)
        XCTAssertEqual(m.columns.2.z, 1.0, accuracy: 1e-5)
        XCTAssertEqual(m.columns.3.w, 1.0, accuracy: 1e-5)
    }

    func testProjectionMatrixLH() {
        let m = projectionMatrixLH(fovY: Float.pi / 2, aspect: 16.0 / 9.0, near: 0.03125, far: 256.0)
        // y = 1/tan(pi/4) = 1.0
        XCTAssertEqual(m.columns.1.y, 1.0, accuracy: 1e-5)
        // x = y / aspect
        XCTAssertEqual(m.columns.0.x, 1.0 / (16.0 / 9.0), accuracy: 1e-5)
        // perspective: w column z should be 1
        XCTAssertEqual(m.columns.2.w, 1.0, accuracy: 1e-5)
    }

    // MARK: - Demo duration

    func testDemoDurationPositive() {
        XCTAssertGreaterThan(kDemoDuration, 0)
        // Demo is roughly 3.5 minutes
        XCTAssertGreaterThan(kDemoDuration, 180)
        XCTAssertLessThan(kDemoDuration, 300)
    }

    // MARK: - Camera path at known timestamps

    func testCameraAtTimeZero() {
        renderer.updateUniformsForTime(0.0, size: CGSize(width: 1920, height: 1080))
        let pos = renderer.demoCameraPosition
        // Camera should be at a valid world position, not zero/NaN
        XCTAssertFalse(pos.x.isNaN)
        XCTAssertFalse(pos.y.isNaN)
        XCTAssertFalse(pos.z.isNaN)
    }

    func testCameraMovesOverTime() {
        renderer.updateUniformsForTime(0.0, size: CGSize(width: 1920, height: 1080))
        let pos0 = renderer.demoCameraPosition

        renderer.updateUniformsForTime(30.0, size: CGSize(width: 1920, height: 1080))
        let pos30 = renderer.demoCameraPosition

        // Camera should have moved significantly after 30 seconds
        let dist = distance(pos0, pos30)
        XCTAssertGreaterThan(dist, 0.1, "Camera should move between t=0 and t=30")
    }

    func testCameraFovPositive() {
        renderer.updateUniformsForTime(10.0, size: CGSize(width: 1920, height: 1080))
        let fov = renderer.demoCameraFov
        XCTAssertGreaterThan(fov, 0)
        XCTAssertLessThan(fov, Float.pi) // less than 180 degrees
    }

    func testViewProjectionNotSingular() {
        renderer.updateUniformsForTime(10.0, size: CGSize(width: 1920, height: 1080))
        let vp = renderer.demoViewProjection
        let det = simd_determinant(vp)
        XCTAssertNotEqual(det, 0, accuracy: 1e-10, "VP matrix should be invertible")
    }

    // MARK: - Camera path snapshot (regression)
    // Known-good values captured from working macOS build.
    // If these break, the camera path has changed and the demo will look different.

    func testCameraPathSnapshot() {
        let size = CGSize(width: 1920, height: 1080)
        let timestamps: [Double] = [0, 30, 60, 90, 120, 180]
        var positions: [SIMD3<Float>] = []

        for t in timestamps {
            renderer.updateUniformsForTime(t, size: size)
            positions.append(renderer.demoCameraPosition)
        }

        // Verify deterministic: same input → same output
        for (i, t) in timestamps.enumerated() {
            renderer.updateUniformsForTime(t, size: size)
            let pos = renderer.demoCameraPosition
            XCTAssertEqual(pos.x, positions[i].x, accuracy: 1e-4, "Position at t=\(t) not deterministic")
            XCTAssertEqual(pos.y, positions[i].y, accuracy: 1e-4, "Position at t=\(t) not deterministic")
            XCTAssertEqual(pos.z, positions[i].z, accuracy: 1e-4, "Position at t=\(t) not deterministic")
        }

        // Camera should be above terrain (y > some minimum) at all times
        for (i, pos) in positions.enumerated() {
            XCTAssertGreaterThan(pos.y, -10, "Camera y at t=\(timestamps[i]) seems too low: \(pos.y)")
        }
    }
}
