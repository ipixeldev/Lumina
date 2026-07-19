import AppKit
import Testing
@testable import Lumina

@MainActor
struct DeviceWindowPresentationPolicyTests {
    @Test("AirPlay controls stay on Lumina's desktop Space")
    func airPlayDesktopWindowBehavior() {
        let base: NSWindow.CollectionBehavior = [
            .primary,
            .managed,
            .participatesInCycle,
            .fullScreenPrimary,
            .moveToActiveSpace
        ]

        let behavior = DeviceWindowPresentationPolicy.collectionBehavior(
            for: .airPlay,
            base: base
        )

        #expect(behavior.contains(.primary))
        #expect(behavior.contains(.managed))
        #expect(behavior.contains(.participatesInCycle))
        #expect(behavior.contains(.moveToActiveSpace))
        #expect(!behavior.contains(.canJoinAllApplications))
        #expect(!behavior.contains(.canJoinAllSpaces))
        #expect(!behavior.contains(.fullScreenAuxiliary))
        #expect(!behavior.contains(.fullScreenPrimary))
    }

    @Test("Direct controls keep the window's original desktop behavior")
    func directWindowBehavior() {
        let base: NSWindow.CollectionBehavior = [.managed, .participatesInCycle]

        #expect(DeviceWindowPresentationPolicy.collectionBehavior(for: .direct, base: base) == base)
    }

    @Test("AirPlay waits for a visible active-Space desktop anchor")
    func airPlayDesktopAnchorReadiness() {
        #expect(AirPlayDesktopHandoffPolicy.anchorIsReady(
            applicationIsActive: true,
            anchorIsVisible: true,
            anchorIsOnActiveSpace: true,
            anchorIsKeyWindow: true
        ))

        #expect(!AirPlayDesktopHandoffPolicy.anchorIsReady(
            applicationIsActive: false,
            anchorIsVisible: true,
            anchorIsOnActiveSpace: true,
            anchorIsKeyWindow: true
        ))
        #expect(!AirPlayDesktopHandoffPolicy.anchorIsReady(
            applicationIsActive: true,
            anchorIsVisible: false,
            anchorIsOnActiveSpace: true,
            anchorIsKeyWindow: true
        ))
        #expect(!AirPlayDesktopHandoffPolicy.anchorIsReady(
            applicationIsActive: true,
            anchorIsVisible: true,
            anchorIsOnActiveSpace: false,
            anchorIsKeyWindow: true
        ))
        #expect(!AirPlayDesktopHandoffPolicy.anchorIsReady(
            applicationIsActive: true,
            anchorIsVisible: true,
            anchorIsOnActiveSpace: true,
            anchorIsKeyWindow: false
        ))
    }
}
