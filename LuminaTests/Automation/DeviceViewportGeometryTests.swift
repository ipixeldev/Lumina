import CoreGraphics
import Testing
@testable import Lumina

struct DeviceViewportGeometryTests {
    private let portrait = DeviceScreenInfo.Size(width: 430, height: 932)

    @Test("A full-screen AirPlay frame center-crops to the iPhone aspect ratio")
    func portraitCenterCrop() {
        let crop = DeviceViewportGeometry.centerCropRect(
            source: CGSize(width: 3_456, height: 2_234),
            device: portrait
        )

        #expect(abs(crop.width - 1_030.71) < 0.1)
        #expect(crop.height == 2_234)
        #expect(abs(crop.midX - 1_728) < 0.01)
        #expect(crop.minY == 0)
    }

    @Test("A landscape receiver frame removes top and bottom letterboxing")
    func landscapeCenterCrop() {
        let landscape = DeviceScreenInfo.Size(width: 932, height: 430)
        let crop = DeviceViewportGeometry.centerCropRect(
            source: CGSize(width: 1_920, height: 1_200),
            device: landscape
        )

        #expect(crop.width == 1_920)
        #expect(crop.height < 1_200)
        #expect(abs(crop.midY - 600) < 0.01)
    }

    @Test("Viewport coordinates map to WebDriverAgent coordinates")
    func coordinateMapping() throws {
        let display = CGSize(width: 430, height: 932)
        let center = try #require(DeviceViewportGeometry.map(
            CGPoint(x: 215, y: 466),
            from: display,
            to: portrait
        ))
        let clamped = try #require(DeviceViewportGeometry.map(
            CGPoint(x: 500, y: -20),
            from: display,
            to: portrait
        ))

        #expect(center == AutomationPoint(x: 215, y: 466))
        #expect(clamped.x == portrait.width.nextDown)
        #expect(clamped.x < portrait.width)
        #expect(clamped.y == 0)
    }

    @Test("Device-sized presentation stays within the visible screen")
    func fittedDisplaySize() {
        let size = DeviceViewportGeometry.fittedDisplaySize(
            device: portrait,
            available: CGSize(width: 1_418, height: 800)
        )

        #expect(size.height == 800)
        #expect(size.width == 369)
    }
}
