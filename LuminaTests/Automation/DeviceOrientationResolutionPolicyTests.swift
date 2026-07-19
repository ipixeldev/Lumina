import Testing
@testable import Lumina

struct DeviceOrientationResolutionPolicyTests {
    @Test
    func keepsKnownDeviceOrientation() {
        let screen = DeviceScreenInfo.Size(width: 430, height: 932)

        #expect(
            DeviceOrientationResolutionPolicy.resolve(
                reported: .landscapeRight,
                screen: screen
            ) == .landscapeRight
        )
    }

    @Test
    func infersPortraitFromUnknownDeviceOrientation() {
        let screen = DeviceScreenInfo.Size(width: 430, height: 932)

        #expect(
            DeviceOrientationResolutionPolicy.resolve(
                reported: .unknown,
                screen: screen
            ) == .portrait
        )
    }

    @Test
    func infersLandscapeFromUnknownDeviceOrientation() {
        let screen = DeviceScreenInfo.Size(width: 932, height: 430)

        #expect(
            DeviceOrientationResolutionPolicy.resolve(
                reported: .unknown,
                screen: screen
            ) == .landscapeLeft
        )
    }

    @Test
    func confirmsOnlyRenderedTargetGeometry() {
        let portrait = DeviceScreenInfo.Size(width: 430, height: 932)
        let landscape = DeviceScreenInfo.Size(width: 932, height: 430)

        #expect(DeviceOrientationResolutionPolicy.screen(portrait, matches: .portrait))
        #expect(DeviceOrientationResolutionPolicy.screen(landscape, matches: .landscapeLeft))
        #expect(!DeviceOrientationResolutionPolicy.screen(portrait, matches: .landscapeLeft))
        #expect(!DeviceOrientationResolutionPolicy.screen(landscape, matches: .portrait))
    }
}
