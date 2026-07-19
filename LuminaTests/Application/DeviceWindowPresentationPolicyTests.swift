import AppKit
import Testing
@testable import Lumina

@MainActor
struct DeviceWindowPresentationPolicyTests {
    @Test("AirPlay controls join the receiver's full-screen Space")
    func airPlayOverlayBehavior() {
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

        #expect(behavior.contains(.canJoinAllApplications))
        #expect(behavior.contains(.canJoinAllSpaces))
        #expect(behavior.contains(.fullScreenAuxiliary))
        #expect(behavior.contains(.transient))
        #expect(behavior.contains(.ignoresCycle))
        #expect(!behavior.contains(.primary))
        #expect(!behavior.contains(.managed))
        #expect(!behavior.contains(.participatesInCycle))
        #expect(!behavior.contains(.fullScreenPrimary))
        #expect(!behavior.contains(.moveToActiveSpace))
    }

    @Test("Direct controls keep the window's original desktop behavior")
    func directWindowBehavior() {
        let base: NSWindow.CollectionBehavior = [.managed, .participatesInCycle]

        #expect(DeviceWindowPresentationPolicy.collectionBehavior(for: .direct, base: base) == base)
    }
}
