import Foundation
import Observation

@MainActor
@Observable
final class DependencyContainer {
    let stateMachine: ApplicationStateMachine
    let setupAssistantModel: SetupAssistantModel
    let automationWorkspace: AutomationWorkspaceModel
    let logger: StructuredLogging

    init(
        stateMachine: ApplicationStateMachine,
        environmentChecker: any EnvironmentChecking,
        deviceConnectionMonitor: any DeviceConnectionMonitoring,
        runnerBuilder: any RunnerBuilding,
        runnerSetupManager: any RunnerSetupManaging,
        installationIdentityProvider: any InstallationIdentityProviding,
        airPlayReceiverChecker: any AirPlayReceiverDiscoverabilityChecking,
        webDriverAgentSourceURL: URL?,
        logger: StructuredLogging
    ) {
        self.stateMachine = stateMachine
        automationWorkspace = AutomationWorkspaceModel(logger: logger)
        setupAssistantModel = SetupAssistantModel(
            stateMachine: stateMachine,
            environmentChecker: environmentChecker,
            deviceConnectionMonitor: deviceConnectionMonitor,
            runnerBuilder: runnerBuilder,
            runnerSetupManager: runnerSetupManager,
            installationIdentityProvider: installationIdentityProvider,
            airPlayReceiverChecker: airPlayReceiverChecker,
            webDriverAgentSourceURL: webDriverAgentSourceURL,
            automationWorkspace: automationWorkspace,
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
        let runnerSetupManager = RunnerSetupService(
            processRunner: processRunner,
            streamingProcess: LocalStreamingProcess(),
            healthChecker: URLSessionWebDriverAgentHealthChecker(),
            logger: logger
        )
        let sourceURL = webDriverAgentSourceURL()
        return DependencyContainer(
            stateMachine: ApplicationStateMachine(logger: logger),
            environmentChecker: environmentChecker,
            deviceConnectionMonitor: PollingDeviceConnectionMonitor(discoveryService: deviceDiscoveryService),
            runnerBuilder: runnerBuilder,
            runnerSetupManager: runnerSetupManager,
            installationIdentityProvider: KeychainInstallationIdentityProvider(),
            airPlayReceiverChecker: AirPlayReceiverDiscoverabilityChecker(),
            webDriverAgentSourceURL: sourceURL,
            logger: logger
        )
    }

    private static func webDriverAgentSourceURL() -> URL? {
        if let resourcesURL = Bundle.main.resourceURL {
            let bundledSource = resourcesURL.appendingPathComponent("WebDriverAgent", isDirectory: true)
            let bundledProject = bundledSource.appendingPathComponent("WebDriverAgent.xcodeproj", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundledProject.path) {
                return bundledSource
            }
        }

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
