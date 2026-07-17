import Foundation
import Testing
@testable import Lumina

struct DeviceConnectionMonitorTests {
    @Test("Connection monitoring emits changes and suppresses identical polls")
    func emitsOnlyChanges() async throws {
        let connected = Device(
            id: "00008120-TESTDEVICE0001",
            name: "Test iPhone",
            model: "iPhone 15",
            productType: "iPhone15,4",
            operatingSystemVersion: "18.5",
            connectionTransport: .usb,
            pairingState: .paired,
            developerModeState: .enabled,
            lockState: .unlocked,
            isAvailableOverNetwork: true,
            developerConnectionHosts: ["test-iphone.coredevice.local"],
            developerServicesAvailable: true,
            lastConnectionDate: nil
        )
        let discovery = SequencedDiscovery(snapshots: [
            DeviceDiscoverySnapshot(devices: [connected], discoveredAt: Date(timeIntervalSince1970: 1)),
            DeviceDiscoverySnapshot(devices: [connected], discoveredAt: Date(timeIntervalSince1970: 2)),
            DeviceDiscoverySnapshot(devices: [], discoveredAt: Date(timeIntervalSince1970: 3))
        ])
        let monitor = PollingDeviceConnectionMonitor(
            discoveryService: discovery,
            interval: .milliseconds(1),
            maximumBackoff: .milliseconds(5)
        )

        var iterator = monitor.updates().makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()

        guard case let .snapshot(firstSnapshot) = first,
              case let .snapshot(secondSnapshot) = second else {
            Issue.record("Expected two device snapshots")
            return
        }
        #expect(firstSnapshot.devices == [connected])
        #expect(secondSnapshot.devices.isEmpty)
    }
}

private actor SequencedDiscovery: DeviceDiscovering {
    private let snapshots: [DeviceDiscoverySnapshot]
    private var index = 0

    init(snapshots: [DeviceDiscoverySnapshot]) {
        self.snapshots = snapshots
    }

    func discoverDevices() -> DeviceDiscoverySnapshot {
        let snapshot = snapshots[min(index, snapshots.count - 1)]
        index += 1
        return snapshot
    }
}
