import Foundation
import Observation

nonisolated enum VisualSourceSelectionPolicy {
    static func allowsSelection(
        in state: ApplicationState,
        isChecking: Bool,
        isBuildingRunner: Bool,
        isSettingUpRunner: Bool
    ) -> Bool {
        guard !isChecking, !isBuildingRunner, !isSettingUpRunner else { return false }
        return switch state {
        case .checkingEnvironment,
             .runnerBuilding,
             .runnerInstalling,
             .runnerLaunching,
             .connectingAutomation,
             .stopping:
            false
        default:
            true
        }
    }
}

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
    private(set) var airPlayReceiverReport: AirPlayReceiverDiscoverabilityReport?
    private(set) var airPlayDiscoveryError: String?

    private let environmentChecker: any EnvironmentChecking
    private let deviceConnectionMonitor: any DeviceConnectionMonitoring
    private let runnerBuilder: any RunnerBuilding
    private let runnerSetupManager: any RunnerSetupManaging
    private let installationIdentityProvider: any InstallationIdentityProviding
    private let airPlayReceiverChecker: any AirPlayReceiverDiscoverabilityChecking
    private let webDriverAgentSourceURL: URL?
    private let automationWorkspace: AutomationWorkspaceModel
    private let logger: StructuredLogging
    private var checkTask: Task<Void, Never>?
    private var deviceMonitorTask: Task<Void, Never>?
    private var runnerBuildTask: Task<Void, Never>?
    private var runnerSetupTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var airPlayCheckTask: Task<Void, Never>?
    private var airPlayCheckID: UUID?
    private var lastRunnerSetupConfiguration: RunnerSetupConfiguration?
    private var automaticStartAttemptedDeviceID: String?

    init(
        stateMachine: ApplicationStateMachine,
        environmentChecker: any EnvironmentChecking,
        deviceConnectionMonitor: any DeviceConnectionMonitoring,
        runnerBuilder: any RunnerBuilding,
        runnerSetupManager: any RunnerSetupManaging,
        installationIdentityProvider: any InstallationIdentityProviding,
        airPlayReceiverChecker: any AirPlayReceiverDiscoverabilityChecking,
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
        self.airPlayReceiverChecker = airPlayReceiverChecker
        self.webDriverAgentSourceURL = webDriverAgentSourceURL
        self.automationWorkspace = automationWorkspace
        self.logger = logger
        automationWorkspace.onVisualChannelStarted = { [weak self] source in
            self?.visualChannelDidStart(source)
        }
        automationWorkspace.onVisualChannelStopped = { [weak self] source in
            self?.visualChannelDidStop(source)
        }
        automationWorkspace.onControlChannelStopped = { [weak self] in
            self?.controlChannelDidStop()
        }
    }

    var isChecking: Bool { checkTask != nil }

    func checkThisMac() {
        guard checkTask == nil, isSelectedVisualSourceReadyToConnect else { return }
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
    var isCheckingAirPlayReceiver: Bool { airPlayCheckTask != nil }
    var visualSource: VisualSource { automationWorkspace.visualSource }
    var hasSelectedVisualSource: Bool { automationWorkspace.hasSelectedVisualSource }
    var isChoosingAirPlaySource: Bool { automationWorkspace.isChoosingAirPlaySource }
    var hasScreenCapturePermission: Bool { automationWorkspace.hasScreenCapturePermission }
    var screenCapturePermissionNeedsRelaunch: Bool {
        automationWorkspace.screenCapturePermissionNeedsRelaunch
    }
    var screenCapturePermissionRequestWasDenied: Bool {
        automationWorkspace.screenCapturePermissionRequestWasDenied
    }
    var isAirPlayVideoActive: Bool {
        visualSource == .airPlay && automationWorkspace.isStreaming && automationWorkspace.airPlayFrame != nil
    }
    var isAirPlayControlReady: Bool {
        visualSource == .airPlay && automationWorkspace.isControlReady
    }
    var airPlayIssue: String? { automationWorkspace.issue }
    var airPlayReceiverName: String {
        airPlayReceiverReport?.macDisplayName ?? Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
    var isSelectedVisualSourceReadyToConnect: Bool {
        // Bonjour discovery is a useful AirPlay diagnostic, but it is not a
        // prerequisite for XCTest control. Some macOS releases omit or delay
        // the receiver advertisement even while system mirroring works.
        hasSelectedVisualSource
    }
    var hasReadyDevice: Bool { selectedBuildDevice != nil }
    var canSelectVisualSource: Bool {
        VisualSourceSelectionPolicy.allowsSelection(
            in: stateMachine.state,
            isChecking: isChecking,
            isBuildingRunner: isBuildingRunner,
            isSettingUpRunner: isSettingUpRunner
        )
    }

    func selectVisualSource(_ source: VisualSource) {
        guard canSelectVisualSource else { return }
        let isChangingSource = source != visualSource
        if isChangingSource, stateMachine.state == .connected {
            transitionIfPossible(to: .startingMirror, category: .mirroring)
        }
        automationWorkspace.selectVisualSource(source)
        if source == .airPlay {
            checkAirPlayReceiver()
        } else {
            airPlayCheckTask?.cancel()
            airPlayCheckTask = nil
            airPlayCheckID = nil
            airPlayDiscoveryError = nil
        }
        beginAutomaticSetupIfNeeded()
    }

    func checkAirPlayReceiver() {
        airPlayCheckTask?.cancel()
        airPlayReceiverReport = nil
        airPlayDiscoveryError = nil
        let checkID = UUID()
        airPlayCheckID = checkID
        airPlayCheckTask = Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await airPlayReceiverChecker.check(timeout: .seconds(2.5))
                try Task.checkCancellation()
                guard airPlayCheckID == checkID, visualSource == .airPlay else { return }
                airPlayReceiverReport = report
                airPlayCheckTask = nil
                airPlayCheckID = nil
                if report.isScreenMirroringAdvertised {
                    logger.info("macOS AirPlay Receiver is discoverable", category: .mirroring)
                } else {
                    logger.error("macOS AirPlay Receiver is not advertising screen mirroring", category: .mirroring)
                }
                if stateMachine.state == .appStarting || stateMachine.state == .stopped {
                    checkThisMac()
                }
                beginAutomaticSetupIfNeeded()
            } catch is CancellationError {
                guard airPlayCheckID == checkID else { return }
                airPlayCheckTask = nil
                airPlayCheckID = nil
            } catch {
                guard airPlayCheckID == checkID else { return }
                airPlayCheckTask = nil
                airPlayCheckID = nil
                airPlayDiscoveryError = "Lumina could not check AirPlay discovery: \(error.localizedDescription)"
                logger.error("AirPlay Receiver discovery check failed", category: .mirroring)
                if stateMachine.state == .appStarting || stateMachine.state == .stopped {
                    checkThisMac()
                }
            }
        }
    }

    func chooseAirPlaySource() {
        automationWorkspace.chooseAirPlaySource()
    }

    func waitForAirPlaySource() {
        automationWorkspace.waitForAirPlaySource()
    }

    func openAirPlayReceiverSettings() {
        automationWorkspace.openAirPlayReceiverSettings()
    }

    func requestScreenCapturePermission() {
        automationWorkspace.requestScreenCapturePermission()
    }

    func openScreenCaptureSettings() {
        automationWorkspace.openScreenCaptureSettings()
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
        guard transitionToBuilding() else {
            if continueAutomatically { automaticStartAttemptedDeviceID = nil }
            return
        }
        logger.info(reuseCache ? "Looking for a reusable signed runner" : "WebDriverAgent build started", category: .build)

        runnerBuildTask = Task { [weak self] in
            guard let self else { return }
            do {
                let builder = runnerBuilder
                let (result, reusedCache) = try await Task.detached(priority: .userInitiated) {
                    if reuseCache,
                       let cached = try await builder.cachedBuild(configuration: configuration) {
                        return (cached, true)
                    }
                    return (try await builder.build(configuration: configuration), false)
                }.value
                try Task.checkCancellation()
                runnerBuildResult = result
                runnerBuildTask = nil
                isCheckingRunnerCache = false
                try stateMachine.transition(to: .runnerBuilt)
                logger.info(reusedCache ? "Reusable signed runner verified" : "WebDriverAgent build and signature verification completed", category: .build)
                if continueAutomatically { installAndLaunchRunner() }
            } catch is CancellationError {
                runnerBuildTask = nil
                isCheckingRunnerCache = false
                if continueAutomatically { automaticStartAttemptedDeviceID = nil }
                transitionIfPossible(to: .runnerNotInstalled, category: .build)
                logger.info("WebDriverAgent build cancelled", category: .build)
            } catch let error as RunnerBuildError {
                runnerBuildTask = nil
                isCheckingRunnerCache = false
                if continueAutomatically { automaticStartAttemptedDeviceID = nil }
                runnerBuildIssue = error.issue
                transitionIfPossible(to: .runnerBuildFailed(message: error.issue.explanation), category: .build)
                logger.error("WebDriverAgent build failed with \(error.issue.code)", category: .build)
            } catch {
                runnerBuildTask = nil
                isCheckingRunnerCache = false
                if continueAutomatically { automaticStartAttemptedDeviceID = nil }
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
            artifactIdentity: buildResult.artifactIdentity,
            developerConnectionHosts: device.developerConnectionHosts
        )
        lastRunnerSetupConfiguration = configuration
        let markerKey = installationMarkerKey(for: configuration)
        runnerConnection = nil
        runnerSetupIssue = nil
        runnerIsInstalled = nil
        runnerSetupTask = Task { [weak self] in
            guard let self else { return }
            do {
                // A marker is written only after this exact Lumina control
                // extension revision has been installed. An older WDA bundle
                // may share the identifier but cannot serve the overlay-safe
                // AirPlay input routes, so it must be replaced once.
                let installed = UserDefaults.standard.bool(forKey: markerKey)
                runnerIsInstalled = installed
                if !installed {
                    guard transitionIfPossible(to: .runnerInstalling(progress: nil), category: .build) else {
                        runnerSetupTask = nil
                        automaticStartAttemptedDeviceID = nil
                        return
                    }
                    logger.info("WebDriverAgent installation started", category: .build)
                    try await runnerSetupManager.install(configuration: configuration)
                    // devicectl success proves that this exact verified artifact
                    // is installed. Keep that fact across transient launch or
                    // Wi-Fi tunnel failures; only a stale live extension
                    // handshake invalidates it below.
                    UserDefaults.standard.set(true, forKey: markerKey)
                    runnerIsInstalled = true
                    try Task.checkCancellation()
                }
                guard transitionIfPossible(to: .runnerLaunching, category: .build) else {
                    runnerSetupTask = nil
                    automaticStartAttemptedDeviceID = nil
                    runnerSetupManager.stop()
                    return
                }
                logger.info("WebDriverAgent launch started", category: .build)
                let connection = try await runnerSetupManager.launchAndConnect(configuration: configuration)
                try Task.checkCancellation()
                guard transitionIfPossible(to: .connectingAutomation, category: .build) else { return }
                try await automationWorkspace.connect(to: connection.endpoint)
                try Task.checkCancellation()
                // Reaffirm the installed marker after the live runner proves
                // that it exposes Lumina's current control extension.
                UserDefaults.standard.set(true, forKey: markerKey)
                runnerIsInstalled = true
                runnerConnection = connection
                guard transitionIfPossible(to: .automationReady, category: .automation),
                      transitionIfPossible(to: .startingMirror, category: .mirroring) else { return }
                automationWorkspace.startSelectedVisualSource()
                if visualSource == .direct {
                    transitionIfPossible(to: .connected, category: .mirroring)
                    logger.info("iPhone control and Direct video are ready", category: .automation)
                } else {
                    logger.info("iPhone control is ready; waiting for the AirPlay window", category: .automation)
                }
                runnerSetupTask = nil
            } catch is CancellationError {
                runnerSetupTask = nil
                automaticStartAttemptedDeviceID = nil
                await automationWorkspace.disconnect()
                runnerSetupManager.stop()
                transitionIfPossible(to: .runnerBuilt, category: .build)
                logger.info("Runner setup cancelled", category: .build)
            } catch let error as RunnerSetupError {
                runnerSetupTask = nil
                automaticStartAttemptedDeviceID = nil
                runnerSetupIssue = error.issue
                transitionIfPossible(to: .runnerInstallFailed(message: error.issue.explanation), category: .build)
                logger.error("Runner setup failed with \(error.issue.code)", category: .build)
            } catch {
                runnerSetupTask = nil
                automaticStartAttemptedDeviceID = nil
                if let issue = error as? WebDriverAgentIssue, issue.code == "LUM-WDA-105" {
                    // Only a failed live extension handshake invalidates an
                    // existing exact-artifact marker. Transient launch, tunnel,
                    // or Wi-Fi errors must not force a reinstall on the next run.
                    UserDefaults.standard.removeObject(forKey: markerKey)
                    runnerIsInstalled = false
                }
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
                if stateMachine.state == .connected || stateMachine.state == .startingMirror {
                    try stateMachine.transition(to: .temporarilyDisconnected)
                }
                try stateMachine.transition(to: .reconnecting(attempt: 1))
                let connection: RunnerConnection
                if let activeConnection = runnerConnection {
                    do {
                        try await automationWorkspace.connect(to: activeConnection.endpoint)
                        connection = activeConnection
                        logger.info("Existing WebDriverAgent session endpoint is still available", category: .automation)
                    } catch {
                        runnerSetupManager.stop()
                        connection = try await runnerSetupManager.launchAndConnect(configuration: configuration)
                        try await automationWorkspace.connect(to: connection.endpoint)
                    }
                } else {
                    runnerSetupManager.stop()
                    connection = try await runnerSetupManager.launchAndConnect(configuration: configuration)
                    try await automationWorkspace.connect(to: connection.endpoint)
                }
                try Task.checkCancellation()
                try stateMachine.transition(to: .connectingAutomation)
                try stateMachine.transition(to: .automationReady)
                try stateMachine.transition(to: .startingMirror)
                automationWorkspace.startSelectedVisualSource()
                if visualSource == .direct {
                    try stateMachine.transition(to: .connected)
                    logger.info("iPhone control and Direct video were restored", category: .automation)
                } else {
                    logger.info("iPhone control was restored; waiting for the AirPlay window", category: .automation)
                }
                runnerConnection = connection
                reconnectTask = nil
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
                if let issue = error as? WebDriverAgentIssue, issue.code == "LUM-WDA-105" {
                    UserDefaults.standard.removeObject(
                        forKey: installationMarkerKey(for: configuration)
                    )
                    runnerIsInstalled = false
                }
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
        automaticStartAttemptedDeviceID = nil
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

        if stateMachine.state == .connected || stateMachine.state == .startingMirror {
            // Once WebDriverAgent has answered, its health checks own control
            // readiness. A transient empty devicectl snapshot must not discard
            // a healthy session or block the first AirPlay frame.
            if automationWorkspace.isControlReady { return }
            if selectedBuildDevice != nil { return }
            transitionIfPossible(to: .temporarilyDisconnected, category: .device)
            return
        }

        if stateMachine.state == .temporarilyDisconnected, selectedBuildDevice != nil {
            reconnectRunner()
            return
        }

        // Keep discovery active for reconnects without letting a polling
        // update overwrite build, launch, or automation states.
        let discoveryStates: [ApplicationState] = [
            .noDevice, .deviceConnectedUSB, .deviceConnectedWiFi,
            .deviceNeedsTrust, .developerModeDisabled, .deviceLocked
        ]
        guard discoveryStates.contains(stateMachine.state) else { return }

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

        guard stateMachine.state != nextState else {
            beginAutomaticSetupIfNeeded()
            return
        }
        do {
            try stateMachine.transition(to: nextState)
        } catch {
            logger.error("Device discovery could not update the application state", category: .device)
        }
        beginAutomaticSetupIfNeeded()
    }

    private func beginAutomaticSetupIfNeeded() {
        guard ProcessInfo.processInfo.environment["LUMINA_DISABLE_AUTOSTART"] != "1" else { return }
        guard isSelectedVisualSourceReadyToConnect else {
            logger.debug("Automatic runner start is waiting for a video method", category: .automation)
            return
        }
        guard let device = selectedBuildDevice else {
            logger.debug("Automatic runner start is waiting for a ready developer device", category: .automation)
            return
        }
        guard automaticStartAttemptedDeviceID != device.id else {
            logger.debug("Automatic runner start already ran for the current iPhone", category: .automation)
            return
        }
        guard runnerBuildTask == nil, runnerSetupTask == nil else {
            logger.debug("Automatic runner setup is already in progress", category: .automation)
            return
        }
        guard stateMachine.state == .deviceConnectedUSB || stateMachine.state == .deviceConnectedWiFi else {
            logger.debug("Automatic runner start is waiting for a stable device state", category: .automation)
            return
        }
        guard runnerBuildConfiguration() != nil else {
            // Do not consume the one automatic attempt while an environment,
            // signing, or bundled-source prerequisite is still arriving.
            logger.debug("Automatic runner start is waiting for complete build configuration", category: .automation)
            return
        }
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
            artifactIdentity: buildResult.artifactIdentity,
            developerConnectionHosts: device.developerConnectionHosts
        )
    }

    private func installationMarkerKey(for configuration: RunnerSetupConfiguration) -> String {
        configuration.installationTrustKey
    }

    private func visualChannelDidStart(_ source: VisualSource) {
        guard source == visualSource else { return }
        switch stateMachine.state {
        case .startingMirror:
            transitionIfPossible(to: .connected, category: .mirroring)
        case .temporarilyDisconnected where automationWorkspace.isControlReady:
            transitionIfPossible(to: .connected, category: .mirroring)
        case .connected:
            break
        default:
            return
        }
        logger.info("Selected visual channel is active", category: .mirroring)
    }

    private func visualChannelDidStop(_ source: VisualSource) {
        guard source == visualSource, stateMachine.state == .connected else { return }
        transitionIfPossible(to: .startingMirror, category: .mirroring)
        logger.info("Selected video channel stopped; the XCTest control channel remains connected", category: .mirroring)
    }

    private func controlChannelDidStop() {
        switch stateMachine.state {
        case .connected:
            transitionIfPossible(to: .runnerCrashed, category: .automation)
        case .startingMirror:
            transitionIfPossible(to: .temporarilyDisconnected, category: .automation)
        default:
            break
        }
        logger.error("The XCTest control channel stopped responding", category: .automation)
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
