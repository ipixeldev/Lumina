import Foundation

nonisolated enum EnvironmentRequirement: String, CaseIterable, Identifiable, Sendable {
    case macOS
    case architecture
    case diskSpace
    case xcode
    case developerDirectory
    case xcodeFirstLaunch
    case commandLineTools
    case iOSSDK
    case helper
    case developmentCertificate

    var id: Self { self }

    var title: String {
        switch self {
        case .macOS: "macOS"
        case .architecture: "Mac architecture"
        case .diskSpace: "Available disk space"
        case .xcode: "Xcode"
        case .developerDirectory: "Active developer directory"
        case .xcodeFirstLaunch: "Xcode components and license"
        case .commandLineTools: "Command Line Tools"
        case .iOSSDK: "iOS platform SDK"
        case .helper: "Local helper"
        case .developmentCertificate: "Apple Development signing"
        }
    }
}

nonisolated enum EnvironmentCheckStatus: String, Equatable, Sendable {
    case passed
    case warning
    case failed
}

nonisolated struct EnvironmentCheckResult: Equatable, Identifiable, Sendable {
    let requirement: EnvironmentRequirement
    let status: EnvironmentCheckStatus
    let summary: String
    let details: String?
    let remediation: String?
    let errorCode: String?

    var id: EnvironmentRequirement { requirement }
}

nonisolated struct DeveloperCertificateIdentity: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let teamID: String?
    let expirationDate: Date?
    let hasPrivateKey: Bool
    let isCurrentlyValid: Bool

    var canSign: Bool { hasPrivateKey && isCurrentlyValid }
}

nonisolated struct EnvironmentReport: Equatable, Sendable {
    let checks: [EnvironmentCheckResult]
    let certificates: [DeveloperCertificateIdentity]
    let completedAt: Date

    func result(for requirement: EnvironmentRequirement) -> EnvironmentCheckResult? {
        checks.first { $0.requirement == requirement }
    }

    var recommendedState: ApplicationState {
        if result(for: .xcode)?.status == .failed {
            return .xcodeMissing
        }
        if result(for: .iOSSDK)?.status == .failed {
            return .sdkMissing
        }
        let blockingOrder: [EnvironmentRequirement] = [
            .macOS,
            .diskSpace,
            .developerDirectory,
            .xcodeFirstLaunch,
            .commandLineTools
        ]
        if let blocking = blockingOrder.compactMap({ result(for: $0) }).first(where: { $0.status == .failed }) {
            return .requiresUserAction(message: blocking.remediation ?? blocking.summary)
        }
        return .noDevice
    }
}

nonisolated struct SystemSnapshot: Sendable {
    let operatingSystemVersion: OperatingSystemVersion
    let architecture: String
    let availableDiskSpace: Int64?
}

nonisolated protocol SystemInformationProviding: Sendable {
    func snapshot() throws -> SystemSnapshot
}

nonisolated struct LocalSystemInformationProvider: SystemInformationProviding {
    func snapshot() throws -> SystemSnapshot {
        let capacity = try URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage

        return SystemSnapshot(
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion,
            architecture: architecture,
            availableDiskSpace: capacity
        )
    }

    private var architecture: String {
        #if arch(arm64)
        "Apple silicon (arm64)"
        #elseif arch(x86_64)
        "Intel (x86_64)"
        #else
        "Unknown"
        #endif
    }
}
