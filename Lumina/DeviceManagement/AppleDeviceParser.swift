import Foundation

nonisolated enum AppleDeviceParser {
    static func parseDevices(deviceControlData: Data, xcodeDeviceData: Data) -> [Device]? {
        guard let deviceControl = try? JSONDecoder.lumina.decode(DeviceControlEnvelope.self, from: deviceControlData),
              let xcodeDevices = try? JSONDecoder.lumina.decode([XcodeDevice].self, from: xcodeDeviceData) else {
            return nil
        }

        let physicalIPhones = deviceControl.result.devices.filter {
            $0.hardwareProperties.deviceType == "iPhone" &&
                $0.hardwareProperties.platform == "iOS" &&
                $0.hardwareProperties.reality == "physical"
        }

        return physicalIPhones.compactMap { source in
            guard let identifier = source.hardwareProperties.udid,
                  let xcodeDevice = xcodeDevices.first(where: { $0.identifier == identifier }),
                  xcodeDevice.representsConnectedDevice else { return nil }

            let transport: DeviceConnectionTransport = switch xcodeDevice.interface?.lowercased() {
            case "usb": .usb
            case "wifi", "network": .wifi
            default: .unknown
            }
            let pairing: DevicePairingState = switch source.connectionProperties.pairingState {
            case "paired": .paired
            case "unpaired": .unpaired
            default: .unknown
            }
            let developerMode: DeveloperModeState = switch source.deviceProperties.developerModeStatus {
            case "enabled": .enabled
            case "disabled": .disabled
            default: .unknown
            }
            var developerConnectionHosts: [String] = []
            if let tunnelAddress = source.connectionProperties.tunnelIPAddress {
                developerConnectionHosts.append(tunnelAddress)
            }
            for hostname in source.connectionProperties.potentialHostnames ?? []
            where !developerConnectionHosts.contains(hostname) {
                developerConnectionHosts.append(hostname)
            }

            return Device(
                id: identifier,
                name: source.deviceProperties.name ?? xcodeDevice.name,
                model: source.hardwareProperties.marketingName ?? xcodeDevice.modelName,
                productType: source.hardwareProperties.productType,
                operatingSystemVersion: source.deviceProperties.osVersionNumber ?? xcodeDevice.operatingSystemVersion,
                connectionTransport: transport,
                pairingState: pairing,
                developerModeState: developerMode,
                lockState: .unknown,
                isAvailableOverNetwork: source.connectionProperties.transportType == "localNetwork" &&
                    source.connectionProperties.tunnelState == "connected",
                developerConnectionHosts: developerConnectionHosts,
                developerServicesAvailable: source.deviceProperties.ddiServicesAvailable ?? false,
                lastConnectionDate: parseDate(source.connectionProperties.lastConnectionDate)
            )
        }
    }

    static func parseLockState(_ data: Data) -> DeviceLockState? {
        guard let response = try? JSONDecoder.lumina.decode(LockStateEnvelope.self, from: data) else {
            return nil
        }
        return response.result.passcodeRequired ? .locked : .unlocked
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private nonisolated struct DeviceControlEnvelope: Decodable {
    let result: Result

    struct Result: Decodable {
        let devices: [SourceDevice]
    }
}

private nonisolated struct SourceDevice: Decodable {
    let deviceProperties: DeviceProperties
    let hardwareProperties: HardwareProperties
    let connectionProperties: ConnectionProperties
}

private nonisolated struct DeviceProperties: Decodable {
    let name: String?
    let developerModeStatus: String?
    let osVersionNumber: String?
    let ddiServicesAvailable: Bool?
}

private nonisolated struct HardwareProperties: Decodable {
    let deviceType: String
    let platform: String
    let reality: String
    let marketingName: String?
    let productType: String?
    let udid: String?
}

private nonisolated struct ConnectionProperties: Decodable {
    let pairingState: String?
    let transportType: String?
    let tunnelState: String?
    let tunnelIPAddress: String?
    let potentialHostnames: [String]?
    let lastConnectionDate: String?
}

private nonisolated struct XcodeDevice: Decodable {
    let available: Bool
    let identifier: String
    let interface: String?
    let modelName: String
    let name: String
    let operatingSystemVersion: String
    let platform: String
    let simulator: Bool
    let error: XcodeDeviceError?

    var representsConnectedDevice: Bool {
        guard platform == "com.apple.platform.iphoneos", !simulator else { return false }
        if available { return true }
        let errorText = [error?.description, error?.failureReason, error?.recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return interface == "usb" && ["trust", "pair", "unlock"].contains { errorText.contains($0) }
    }
}

private nonisolated struct XcodeDeviceError: Decodable {
    let description: String?
    let failureReason: String?
    let recoverySuggestion: String?
}

private nonisolated struct LockStateEnvelope: Decodable {
    let result: Result

    struct Result: Decodable {
        let passcodeRequired: Bool
    }
}

private nonisolated extension JSONDecoder {
    static var lumina: JSONDecoder {
        JSONDecoder()
    }
}
