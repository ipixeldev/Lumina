import Foundation
import Observation

@MainActor
@Observable
final class SetupAssistantModel {
    let stateMachine: ApplicationStateMachine
    private(set) var environmentReport: EnvironmentReport?
    private(set) var deviceSnapshot: DeviceDiscoverySnapshot?
    private(set) var deviceDiscoveryError: String?
    private(set) var runnerBuildResult: RunnerBuildResult?
    private(set) var runnerBuildIssue: RunnerBuildIssue?
    private(set) var runnerConnection: RunnerConnection?
    private(set) var runnerSetupIssue: RunnerSetupIssue?
    private(set) var lastUnexpectedError: String?
    private(set) var runnerIsInstalled: Bool?
    private(set) var isCheckingRunnerCache = false

    private let environmentChecker: any EnvironmentChecking
    private let deviceConnectionMonitor: any DeviceConnectionMonitoring
    private let runnerBuilder: any RunnerBuilding
    private let runnerSetupManager: any RunnerSetupManaging
    private let installationIdentityProvider: any InstallationIdentityProviding
    private let webDriverAgentSourceURL: URL?
    private let automationWorkspace: AutomationWorkspaceModel
    private let logger: StructuredLogging
    private var checkTask: Task<Void, Never>?
    private var deviceMonitorTask: Task<Void, Never>?
    private var runnerBuildTask: Task<Void, Never>?
    private var runnerSetupTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var lastRunnerSetupConfiguration: RunnerSetupConfiguration?
    private var automaticStartAttemptedDeviceID: String?

    init(
        stateMachine: ApplicationStateMachine,
        environmentChecker: any EnvironmentChecking,
        deviceConnectionMonitor: any DeviceConnectionMonitoring,
        runnerBuilder: any RunnerBuilding,
        runnerSetupManager: any RunnerSetupManaging,
        installationIdentityProvider: any InstallationIdentityProviding,
        webDriverAgentSourceURL: URL?,
        automationWorkspace: AutomationWorkspaceModel,
        logger: StructuredLogging
    ) {
        self.stateMachine = stateMachine
        self.environmentChecker = environmentChecker
        self.deviceConnectionMonitor = deviceConnectionMonitor
        self.runnerBuilder = runnerBuilder
        self.runnerSetupManager = runnerSetupManager
        self.installationIdentityProvider = installationIdentityProvider
        self.webDriverAgentSourceURL = webDriverAgentSourceURL
        self.automationWorkspace = automationWorkspace
        self.logger = logger
    }

    var isChecking: Bool { checkTask != nil }

    func checkThisMac() {
        guard checkTask == nil, hasSelectedVisualSource else { return }
        do {
            try stateMachine.transition(to: .checkingEnvironment)
        } catch {
            logger.error("Environment check could not start from the current state", category: .environment)
            return
        }

        lastUnexpectedError = nil
        logger.info("Local developer environment check started", category: .environment)

        checkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await environmentChecker.checkEnvironment()
                try Task.checkCancellation()
                environmentReport = report
                checkTask = nil
                try stateMachine.transition(to: report.recommendedState)
                logger.info("Local developer environment check completed", category: .environment)
                if report.recommendedState == .noDevice {
                    startDeviceMonitoring()
                }
            } catch is CancellationError {
                checkTask = nil
                if stateMachine.state == .checkingEnvironment {
                    transitionIfPossible(to: .appStarting, category: .environment)
                }
                logger.info("Local developer environment check cancelled", category: .environment)
            } catch {
                checkTask = nil
                lastUnexpectedError = "The environment check could not finish. Run it again or inspect local logs."
                if stateMachine.state == .checkingEnvironment {
                    transitionIfPossible(
                        to: .requiresUserAction(message: "The environment check failed unexpectedly. Run it again or inspect local logs."),
                        category: .environment
                    )
                }
                logger.error("Local developer environment check failed", category: .environment)
            }
        }
    }

    func cancelCheck() {
        checkTask?.cancel()
    }

    var isMonitoringDevices: Bool { deviceMonitorTask != nil }
    var isBuildingRunner: Bool { runnerBuildTask != nil }
    var isSettingUpRunner: Bool { runnerSetupTask != nil }
    var isReconnecting: Bool { reconnectTask != nil }
    var visualSource: VisualSource { automationWorkspace.visualSource }
    var hasSelectedVisualSource: Bool { automationWorkspace.hasSelectedVisualSource }
    var hasReadyDevice: Bool { selectedBuildDevice != nil }
    var canSelectVisualSource: Bool {
        switch stateMachine.state {
        case .appStarting, .stopped, .xcodeMissing, .sdkMissing, .certificateMissing, .noDevice, .requiresUserAction:
            true
        default:
            false
        }
    }

    func selectVisualSource(_ source: VisualSource) {
        automationWorkspace.selectVisualSource(source)
    }

    var canBuildRunner: Bool {
        guard !isBuildingRunner,
              webDriverAgentSourceURL != nil,
              selectedBuildDevice != nil,
              selectedSigningIdentity != nil else { return false }
        return true
    }

    var canInstallRunner: Bool {
        !isSettingUpRunner && runnerBuildResult != nil && selectedBuildDevice != nil
    }

    var runnerBundleIdentifier: String? {
        do {
            let suffix = try installationIdentityProvider.stableBundleSuffix()
            return "com.iPixeldev.Lumina.user.\(suffix).WebDriverAgentRunner"
        } catch {
            logger.error("Stable runner identity is unavailable", category: .security)
            return nil
        }
    }

    func startDeviceMonitoring() {
        guard deviceMonitorTask == nil else { return }
        deviceDiscoveryError = nil
        logger.info("Physical iPhone monitoring started", category: .device)

        deviceMonitorTask = Task { [weak self] in
            guard let self else { return }
            for await update in deviceConnectionMonitor.updates() {
                guard !Task.isCancelled else { break }
                switch update {
                case let .snapshot(snapshot):
                    deviceSnapshot = snapshot
                    deviceDiscoveryError = nil
                    updateApplicationState(for: snapshot.devices)
                case let .failed(message):
                    deviceDiscoveryError = message
                    logger.error("Physical iPhone discovery failed: \(message)", category: .device)
                }
            }
            deviceMonitorTask = nil
        }
    }

    func stopDeviceMonitoring() {
        deviceMonitorTask?.cancel()
    }

    func buildRunner() {
        startRunnerBuild(reuseCache: false, continueAutomatically: false)
    }

    private func startRunnerBuild(reuseCache: Bool, continueAutomatically: Bool) {
        guard runnerBuildTask == nil, let configuration = runnerBuildConfiguration() else { return }
        runnerBuildIssue = nil
        runnerBuildResult = nil
        isCheckingRunnerCache = reuseCache
        guard transitionToBuilding() else { return }
        logger.info(reuseCache ? "Looking for a reusable signed runner" : "WebDriverAgent build started", category: .build)

        runnerBuildTask = Task { [weak self] in
            guard let self else { return }
            do {
                let cached = reuseCache ? try await runnerBuilder.cachedBuild(configuration: configuration) : nil
                let result: RunnerBuildResult
                if let cached {
                    result = cached
                } else {
                    result = try await runnerBuilder.build(configuration: configuration)
                }
                try Task.checkCancellation()
                runnerBuildResult = result
                runnerBuildTask = nil
                isCheckingRunnerCache = false
                try stateMachine.transition(to: .runnerBuilt)
                logger.info(cached == nil ? "WebDriverAgent build and signature verification completed" : "Reusable signed runner verified", category: .build)
                if continueAutomatically { installAndLaunchRunner() }
            } catch is CancellationError {
                runnerBuildTask = nil
                isCheckingRunnerCache = false
                transitionIfPossible(to: .runnerNotInstalled, category: .build)
                logger.info("WebDriverAgent build cancelled", category: .build)
            } catch let error as RunnerBuildError {
                runnerBuildTask = nil
                isCheckingRunnerCache = false
                runnerBuildIssue = error.issue
                transitionIfPossible(to: .runnerBuildFailed(message: error.issue.explanation), category: .build)
                logger.error("WebDriverAgent build failed with \(error.issue.code)", category: .build)
            } catch {
                runnerBuildTask = nil
                isCheckingRunnerCache = false
                let issue = BuildLogParser.issue(for: error.localizedDescription)
                runnerBuildIssue = issue
                transitionIfPossible(to: .runnerBuildFailed(message: issue.explanation), category: .build)
                logger.error("WebDriverAgent build failed unexpectedly", category: .build)
            }
        }
    }

    func cancelRunnerBuild() {
        runnerBuildTask?.cancel()
    }

    func installAndLaunchRunner() {
        guard runnerSetupTask == nil,
              let buildResult = runnerBuildResult,
              let device = selectedBuildDevice else { return }

        let configuration = RunnerSetupConfiguration(
            deviceIdentifier: device.id,
            productURL: buildResult.productURL,
            xctestrunURL: buildResult.xctestrunURL,
            bundleIdentifier: buildResult.bundleIdentifier,
            developerConnectionHosts: device.developerConnectionHosts
        )
        lastRunnerSetupConfiguration = configuration
        runnerConnection = nil
        runnerSetupIssue = nil
        runnerIsInstalled = nil
        runnerSetupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let markerKey = installationMarkerKey(for: configuration)
                var installed = UserDefaults.standard.bool(forKey: markerKey)
                if !installed {
                    installed = await runnerSetupManager.isInstalled(configuration: configuration)
                }
                runnerIsInstalled = installed
                if !installed {
                    guard transitionIfPossible(to: .runnerInstalling(progress: nil), category: .build) else {
                        runnerSetupTask = nil
                        return
                    }
                    logger.info("WebDriverAgent installation started", category: .build)
                    try await runnerSetupManager.install(configuration: configuration)
                    try Task.checkCancellation()
                    UserDefaults.standard.set(true, forKey: markerKey)
                    runnerIsInstalled = true
                } else {
                    UserDefaults.standard.set(true, forKey: markerKey)
                }
                guard transitionIfPossible(to: .runnerLaunching, category: .build) else {
                    runnerSetupTask = nil
                    runnerSetupManager.stop()
                    return
                }
                logger.info("WebDriverAgent launch started", category: .build)
                let connection = try await runnerSetupManager.launchAndConnect(configuration: configuration)
                try Task.checkCancellation()
                guard transitionIfPossible(to: .connectingAutomation, category: .build) else { return }
                try await automationWorkspace.connect(to: connection.endpoint)
                try Task.checkCancellation()
                runnerConnection = connection
                guard transitionIfPossible(to: .automationReady, category: .automation),
                      transitionIfPossible(to: .startingMirror, category: .mirroring) else { return }
                automationWorkspace.startStreaming()
                transitionIfPossible(to: .connected, category: .mirroring)
                runnerSetupTask = nil
                logger.info("iPhone automation and live screen are ready", category: .automation)
            } catch is CancellationError {
                runnerSetupTask = nil
                await automationWorkspace.disconnect()
                runnerSetupManager.stop()
                transitionIfPossible(to: .runnerBuilt, category: .build)
                logger.info("Runner setup cancelled", category: .build)
            } catch let error as RunnerSetupError {
                runnerSetupTask = nil
                runnerSetupIssue = error.issue
                transitionIfPossible(to: .runnerInstallFailed(message: error.issue.explanation), category: .build)
                logger.error("Runner setup failed with \(error.issue.code)", category: .build)
            } catch {
                runnerSetupTask = nil
                let issue = RunnerSetupLogParser.launchIssue(for: error.localizedDescription)
                runnerSetupIssue = issue
                transitionIfPossible(to: .runnerInstallFailed(message: issue.explanation), category: .build)
                logger.error("Runner setup failed unexpectedly", category: .build)
            }
        }
    }

    func cancelRunnerSetup() {
        runnerSetupTask?.cancel()
        runnerSetupManager.stop()
    }

    func reconnectRunner() {
        guard reconnectTask == nil,
              let configuration = lastRunnerSetupConfiguration else {
            runnerSetupIssue = RunnerSetupIssue(
                code: "LUM-WDA-007",
                title: "Reconnect is not ready",
                explanation: "Lumina needs one successful runner setup before it can reconnect without rebuilding.",
                recovery: "Return to Setup Assistant and start the iPhone connection once.",
                retryIsSafe: true
            )
            return
        }

        runnerSetupIssue = nil
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                if stateMachine.state == .connected {
                    try stateMachine.transition(to: .temporarilyDisconnected)
                }
                try stateMachine.transition(to: .reconnecting(attempt: 1))
                await automationWorkspace.disconnect()
                runnerSetupManager.stop()
                let connection = try await runnerSetupManager.launchAndConnect(configuration: configuration)
                try Task.checkCancellation()
                try stateMachine.transition(to: .connectingAutomation)
                try await automationWorkspace.connect(to: connection.endpoint)
                try stateMachine.transition(to: .automationReady)
                try stateMachine.transition(to: .startingMirror)
                automationWorkspace.startStreaming()
                try stateMachine.transition(to: .connected)
                runnerConnection = connection
                reconnectTask = nil
                logger.info("iPhone connection restored without rebuilding or reinstalling", category: .automation)
            } catch is CancellationError {
                reconnectTask = nil
                logger.info("iPhone reconnect cancelled", category: .automation)
            } catch let error as RunnerSetupError {
                reconnectTask = nil
                runnerSetupIssue = error.issue
                transitionIfPossible(to: .requiresUserAction(message: error.issue.explanation), category: .automation)
                logger.error("iPhone reconnect failed with \(error.issue.code)", category: .automation)
            } catch {
                reconnectTask = nil
                let issue = RunnerSetupLogParser.launchIssue(for: error.localizedDescription)
                runnerSetupIssue = issue
                transitionIfPossible(to: .requiresUserAction(message: issue.explanation), category: .automation)
                logger.error("iPhone reconnect failed unexpectedly", category: .automation)
            }
        }
    }

    func stopRunner() {
        runnerSetupTask?.cancel()
        runnerSetupTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        guard transitionIfPossible(to: .stopping, category: .build) else { return }
        Task { [weak self] in
            guard let self else { return }
            await automationWorkspace.disconnect()
            runnerSetupManager.stop()
            runnerConnection = nil
            transitionIfPossible(to: .stopped, category: .build)
            logger.info("Automation runner stopped", category: .build)
        }
    }

    private var selectedBuildDevice: Device? {
        let readyDevices = deviceSnapshot?.devices.filter {
                $0.pairingState == .paired &&
                $0.developerModeState == .enabled &&
                $0.lockState != .locked &&
                $0.developerServicesAvailable &&
                ($0.connectionTransport == .usb ||
                    ($0.connectionTransport == .wifi &&
                        $0.isAvailableOverNetwork &&
                        !$0.developerConnectionHosts.isEmpty))
        } ?? []
        return readyDevices.first(where: { $0.connectionTransport == .usb })
            ?? readyDevices.first(where: { $0.connectionTransport == .wifi })
    }

    private var selectedSigningIdentity: DeveloperCertificateIdentity? {
        SigningIdentityResolver().resolve(from: environmentReport?.certificates ?? [])
    }

    private func transitionToBuilding() -> Bool {
        do {
            if stateMachine.state == .deviceConnectedUSB || stateMachine.state == .deviceConnectedWiFi {
                try stateMachine.transition(to: .devicePreparing)
                try stateMachine.transition(to: .runnerNotInstalled)
            }
            try stateMachine.transition(to: .runnerBuilding(progress: nil))
            return true
        } catch {
            logger.error("Runner build could not enter the building state", category: .build)
            return false
        }
    }

    @discardableResult
    private func transitionIfPossible(to state: ApplicationState, category: LogCategory) -> Bool {
        do {
            try stateMachine.transition(to: state)
            return true
        } catch {
            logger.error("Application state could not transition to \(state.presentation.title)", category: category)
            return false
        }
    }

    private func updateApplicationState(for devices: [Device]) {
        refreshRunnerConfigurationForCurrentDevice()

        if stateMachine.state == .connected {
            if selectedBuildDevice != nil { return }
            transitionIfPossible(to: .temporarilyDisconnected, category: .device)
            return
        }

        if stateMachine.state == .temporarilyDisconnected, selectedBuildDevice != nil {
            reconnectRunner()
            return
        }

        let nextState: ApplicationState
        if let device = devices.first(where: { $0.connectionTransport == .usb }) ?? devices.first {
            if device.pairingState == .unpaired {
                nextState = .deviceNeedsTrust
            } else if device.developerModeState == .disabled {
                nextState = .developerModeDisabled
            } else if device.lockState == .locked {
                nextState = .deviceLocked
            } else if device.connectionTransport == .usb {
                nextState = .deviceConnectedUSB
            } else if device.connectionTransport == .wifi {
                nextState = .deviceConnectedWiFi
            } else {
                nextState = .requiresUserAction(message: "The iPhone is paired but its developer connection is not ready.")
            }
        } else {
            nextState = .noDevice
        }

        guard stateMachine.state != nextState else { return }
        do {
            try stateMachine.transition(to: nextState)
        } catch {
            logger.error("Device discovery could not update the application state", category: .device)
        }
        beginAutomaticSetupIfNeeded()
    }

    private func beginAutomaticSetupIfNeeded() {
        guard ProcessInfo.processInfo.environment["LUMINA_DISABLE_AUTOSTART"] != "1",
              hasSelectedVisualSource,
              let device = selectedBuildDevice,
              automaticStartAttemptedDeviceID != device.id,
              runnerBuildTask == nil,
              runnerSetupTask == nil,
              stateMachine.state == .deviceConnectedUSB || stateMachine.state == .deviceConnectedWiFi else { return }
        automaticStartAttemptedDeviceID = device.id
        startRunnerBuild(reuseCache: true, continueAutomatically: true)
    }

    private func refreshRunnerConfigurationForCurrentDevice() {
        guard let buildResult = runnerBuildResult,
              let device = selectedBuildDevice else { return }
        lastRunnerSetupConfiguration = RunnerSetupConfiguration(
            deviceIdentifier: device.id,
            productURL: buildResult.productURL,
            xctestrunURL: buildResult.xctestrunURL,
            bundleIdentifier: buildResult.bundleIdentifier,
            developerConnectionHosts: device.developerConnectionHosts
        )
    }

    private func installationMarkerKey(for configuration: RunnerSetupConfiguration) -> String {
        "installedRunner.\(configuration.deviceIdentifier).\(configuration.bundleIdentifier)"
    }

    private func runnerBuildConfiguration() -> RunnerBuildConfiguration? {
        guard let sourceURL = webDriverAgentSourceURL,
              let device = selectedBuildDevice,
              let certificate = selectedSigningIdentity,
              let teamIdentifier = certificate.teamID,
              let bundleIdentifier = runnerBundleIdentifier else { return nil }
        do {
            let cachesURL = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Lumina/WebDriverAgent", isDirectory: true)
            return RunnerBuildConfiguration(
                sourceURL: sourceURL,
                deviceIdentifier: device.id,
                teamIdentifier: teamIdentifier,
                bundleIdentifier: bundleIdentifier,
                derivedDataURL: cachesURL.appendingPathComponent("DerivedData", isDirectory: true),
                resultBundleURL: cachesURL.appendingPathComponent("BuildResult.xcresult", isDirectory: true),
                allowProvisioningUpdates: true
            )
        } catch {
            runnerBuildIssue = RunnerBuildIssue(
                code: "LUM-BUILD-009",
                title: "Build storage is unavailable",
                explanation: "Lumina could not prepare its local runner build directory.",
                recovery: "Check available disk space and folder permissions, then retry.",
                retryIsSafe: true
            )
            return nil
        }
    }
}
