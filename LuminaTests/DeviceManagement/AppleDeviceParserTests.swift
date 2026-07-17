import Foundation
import Testing
@testable import Lumina

struct AppleDeviceParserTests {
    @Test("Structured Apple results merge into one connected USB iPhone")
    func parsesConnectedIPhone() throws {
        let devices = try #require(
            AppleDeviceParser.parseDevices(
                deviceControlData: try fixture("devicectl-devices.json"),
                xcodeDeviceData: try fixture("xcdevice-devices.json")
            )
        )

        let device = try #require(devices.first)
        #expect(devices.count == 1)
        #expect(device.name == "Test iPhone")
        #expect(device.model == "iPhone 15")
        #expect(device.operatingSystemVersion == "18.5")
        #expect(device.connectionTransport == .usb)
        #expect(device.pairingState == .paired)
        #expect(device.developerModeState == .enabled)
        #expect(device.isAvailableOverNetwork)
        #expect(device.developerConnectionHosts == ["test-iphone.coredevice.local", "fd00::1"])
        #expect(device.redactedIdentifier == "0000••••0001")
    }

    @Test("Disconnected historical devices and non-iPhones are excluded")
    func filtersDeviceHistory() throws {
        let devices = try #require(
            AppleDeviceParser.parseDevices(
                deviceControlData: try fixture("devicectl-devices.json"),
                xcodeDeviceData: try fixture("xcdevice-devices.json")
            )
        )

        #expect(devices.map(\.name) == ["Test iPhone"])
    }

    @Test("Lock state uses the current passcode-required signal")
    func parsesLockState() throws {
        #expect(AppleDeviceParser.parseLockState(try fixture("devicectl-lock-state.json")) == .unlocked)
    }

    @Test("Invalid structured output is rejected")
    func invalidOutput() {
        #expect(AppleDeviceParser.parseDevices(deviceControlData: Data(), xcodeDeviceData: Data()) == nil)
        #expect(AppleDeviceParser.parseLockState(Data("{}".utf8)) == nil)
    }

    private func fixture(_ name: String) throws -> Data {
        let fileURL = try #require(
            Bundle(for: FixtureBundleToken.self)
                .url(forResource: name, withExtension: nil)
        )
        return try Data(contentsOf: fileURL)
    }
}

private final class FixtureBundleToken {}
