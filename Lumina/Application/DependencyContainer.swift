import Foundation
import Observation

@MainActor
@Observable
final class DependencyContainer {
    let stateMachine: ApplicationStateMachine
    let setupAssistantModel: SetupAssistantModel
    let logger: StructuredLogging

    init(
        stateMachine: ApplicationStateMachine,
        environmentChecker: any EnvironmentChecking,
        deviceConnectionMonitor: any DeviceConnectionMonitoring,
        runnerBuilder: any RunnerBuilding,
        installationIdentityProvider: any InstallationIdentityProviding,
        webDriverAgentSourceURL: URL?,
        logger: StructuredLogging
    ) {
        self.stateMachine = stateMachine
        setupAssistantModel = SetupAssistantModel(
            stateMachine: stateMachine,
            environmentChecker: environmentChecker,
            deviceConnectionMonitor: deviceConnectionMonitor,
            runnerBuilder: runnerBuilder,
            installationIdentityProvider: installationIdentityProvider,
            webDriverAgentSourceURL: webDriverAgentSourceURL,
            logger: logger
        )
        self.logger = logger
    }

    static var live: DependencyContainer {
        let logger = StructuredLogger()
        let environmentChecker = EnvironmentChecker(
            processRunner: LocalProcessRunner(),
            systemInformationProvider: LocalSystemInformationProvider(),
            certificateProvider: KeychainDeveloperCertificateProvider()
        )
        let deviceDiscoveryService = AppleDeviceDiscoveryService(
            processRunner: LocalProcessRunner(),
            logger: logger
        )
        let processRunner = LocalProcessRunner()
        let runnerBuilder = RunnerBuildService(
            processRunner: processRunner,
            sourceValidator: WebDriverAgentSourceValidator(processRunner: processRunner),
            signatureVerifier: SecurityCodeSignatureVerifier()
        )
        let sourceURL = developmentWebDriverAgentSourceURL()
        return DependencyContainer(
            stateMachine: ApplicationStateMachine(logger: logger),
            environmentChecker: environmentChecker,
            deviceConnectionMonitor: PollingDeviceConnectionMonitor(discoveryService: deviceDiscoveryService),
            runnerBuilder: runnerBuilder,
            installationIdentityProvider: KeychainInstallationIdentityProvider(),
            webDriverAgentSourceURL: sourceURL,
            logger: logger
        )
    }

    private static func developmentWebDriverAgentSourceURL() -> URL? {
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let repositoryURL = sourceFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidate = repositoryURL.appendingPathComponent("Vendor/WebDriverAgent", isDirectory: true)
        let project = candidate.appendingPathComponent("WebDriverAgent.xcodeproj", isDirectory: true)
        return FileManager.default.fileExists(atPath: project.path) ? candidate : nil
    }
}
