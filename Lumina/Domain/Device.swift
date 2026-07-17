import Foundation

nonisolated enum DeviceConnectionTransport: String, Codable, Sendable {
    case usb
    case wifi
    case unknown

    var displayName: String {
        switch self {
        case .usb: "USB"
        case .wifi: "Wi-Fi"
        case .unknown: "Unknown"
        }
    }
}

nonisolated enum DevicePairingState: String, Codable, Sendable {
    case paired
    case unpaired
    case unknown
}

nonisolated enum DeveloperModeState: String, Codable, Sendable {
    case enabled
    case disabled
    case unknown
}

nonisolated enum DeviceLockState: String, Codable, Sendable {
    case locked
    case unlocked
    case unknown
}

nonisolated struct Device: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let model: String
    let productType: String?
    let operatingSystemVersion: String
    let connectionTransport: DeviceConnectionTransport
    let pairingState: DevicePairingState
    let developerModeState: DeveloperModeState
    let lockState: DeviceLockState
    let isAvailableOverNetwork: Bool
    let developerConnectionHosts: [String]
    let developerServicesAvailable: Bool
    let lastConnectionDate: Date?

    var redactedIdentifier: String {
        let compact = id.replacingOccurrences(of: "-", with: "")
        guard compact.count > 8 else { return "••••" }
        return "\(compact.prefix(4))••••\(compact.suffix(4))"
    }

    func withLockState(_ lockState: DeviceLockState) -> Device {
        Device(
            id: id,
            name: name,
            model: model,
            productType: productType,
            operatingSystemVersion: operatingSystemVersion,
            connectionTransport: connectionTransport,
            pairingState: pairingState,
            developerModeState: developerModeState,
            lockState: lockState,
            isAvailableOverNetwork: isAvailableOverNetwork,
            developerConnectionHosts: developerConnectionHosts,
            developerServicesAvailable: developerServicesAvailable,
            lastConnectionDate: lastConnectionDate
        )
    }
}

nonisolated struct DeviceDiscoverySnapshot: Equatable, Sendable {
    let devices: [Device]
    let discoveredAt: Date
}
