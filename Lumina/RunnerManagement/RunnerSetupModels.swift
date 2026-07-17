import Foundation

nonisolated struct RunnerSetupConfiguration: Equatable, Sendable {
    let deviceIdentifier: String
    let productURL: URL
    let xctestrunURL: URL
    let bundleIdentifier: String
    let developerConnectionHosts: [String]
    let serverPort: UInt16

    var productBundleIdentifier: String {
        let testRunnerSuffix = ".xctrunner"
        guard bundleIdentifier.hasSuffix(testRunnerSuffix) else { return bundleIdentifier }
        return String(bundleIdentifier.dropLast(testRunnerSuffix.count))
    }

    init(
        deviceIdentifier: String,
        productURL: URL,
        xctestrunURL: URL,
        bundleIdentifier: String,
        developerConnectionHosts: [String],
        serverPort: UInt16 = 8100
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.productURL = productURL
        self.xctestrunURL = xctestrunURL
        self.bundleIdentifier = bundleIdentifier
        self.developerConnectionHosts = developerConnectionHosts
        self.serverPort = serverPort
    }
}

nonisolated struct WebDriverAgentStatus: Equatable, Sendable {
    let ready: Bool
    let message: String
    let device: String?
    let operatingSystemName: String?
    let operatingSystemVersion: String?
    let productBundleIdentifier: String?
}

nonisolated struct RunnerConnection: Equatable, Sendable {
    let endpoint: URL
    let status: WebDriverAgentStatus
    let connectedAt: Date
}

nonisolated struct RunnerSetupIssue: Error, Equatable, Sendable {
    let code: String
    let title: String
    let explanation: String
    let recovery: String
    let retryIsSafe: Bool
}

nonisolated enum RunnerSetupError: Error, Equatable, Sendable {
    case invalidConfiguration(RunnerSetupIssue)
    case installationFailed(RunnerSetupIssue)
    case launchFailed(RunnerSetupIssue)
    case connectionFailed(RunnerSetupIssue)

    var issue: RunnerSetupIssue {
        switch self {
        case let .invalidConfiguration(issue), let .installationFailed(issue),
             let .launchFailed(issue), let .connectionFailed(issue):
            issue
        }
    }
}

nonisolated protocol RunnerSetupManaging: Sendable {
    func install(configuration: RunnerSetupConfiguration) async throws
    func launchAndConnect(configuration: RunnerSetupConfiguration) async throws -> RunnerConnection
    func stop()
}
