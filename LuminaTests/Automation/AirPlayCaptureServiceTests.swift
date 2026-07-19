import AppKit
import ScreenCaptureKit
import Testing
@testable import Lumina

@MainActor
struct AirPlayCaptureServiceTests {
    @Test("Control Center's video layer is selected without capturing its black backing window")
    func controlCenterReceiverLayers() throws {
        let screen = try #require(NSScreen.main)
        let video = candidate(
            bundleIdentifier: "com.apple.controlcenter",
            layer: 0,
            size: screen.frame.size
        )
        let backing = candidate(
            bundleIdentifier: "com.apple.controlcenter",
            layer: -1,
            size: screen.frame.size
        )

        #expect(AirPlayCaptureService.isAutomaticAirPlayWindow(video))
        #expect(!AirPlayCaptureService.isAutomaticAirPlayWindow(backing))
    }

    @Test("The dedicated AirPlay receiver remains supported")
    func dedicatedReceiver() throws {
        let screen = try #require(NSScreen.main)
        let candidate = candidate(
            bundleIdentifier: "com.apple.airplayuiagent",
            layer: 0,
            size: screen.frame.size
        )

        #expect(AirPlayCaptureService.isAutomaticAirPlayWindow(candidate))
    }

    @Test("Capture permission failures wait for user action instead of retrying")
    func nonrecoverableCaptureFailures() {
        let denied = NSError(domain: SCStreamErrorDomain, code: -3_801)
        let missingEntitlement = NSError(domain: SCStreamErrorDomain, code: -3_803)
        let receiverRestarted = NSError(domain: SCStreamErrorDomain, code: -3_805)

        #expect(!AirPlayCaptureService.allowsAutomaticRecovery(after: denied))
        #expect(!AirPlayCaptureService.allowsAutomaticRecovery(after: missingEntitlement))
        #expect(AirPlayCaptureService.allowsAutomaticRecovery(after: receiverRestarted))
        #expect(!AirPlayCaptureService.allowsAutomaticRecovery(after: nil))
    }

    @Test("A granted Screen Recording request hides the request button until relaunch")
    func grantedPermissionRequiresRelaunch() {
        let resolution = ScreenCapturePermissionRequestResolution.resolve(
            requestGranted: true,
            preflightAfterRequest: false
        )

        #expect(!resolution.hasPermission)
        #expect(resolution.needsRelaunch)
        #expect(!resolution.requestWasDenied)
    }

    @Test("A denied Screen Recording request directs the user to Settings without a relaunch loop")
    func deniedPermissionOpensSettings() {
        let resolution = ScreenCapturePermissionRequestResolution.resolve(
            requestGranted: false,
            preflightAfterRequest: false
        )

        #expect(!resolution.hasPermission)
        #expect(!resolution.needsRelaunch)
        #expect(resolution.requestWasDenied)
    }

    @Test("An already-visible TCC grant wins over a stale request result")
    func visiblePermissionWins() {
        let resolution = ScreenCapturePermissionRequestResolution.resolve(
            requestGranted: false,
            preflightAfterRequest: true
        )

        #expect(resolution.hasPermission)
        #expect(!resolution.needsRelaunch)
        #expect(!resolution.requestWasDenied)
    }

    private func candidate(
        bundleIdentifier: String,
        layer: Int,
        size: CGSize
    ) -> AirPlayCaptureService.WindowCandidate {
        AirPlayCaptureService.WindowCandidate(
            id: 1,
            applicationName: "System Receiver",
            bundleIdentifier: bundleIdentifier,
            windowTitle: nil,
            width: Int(size.width),
            height: Int(size.height),
            windowLayer: layer,
            isLikelyAirPlay: true
        )
    }
}
