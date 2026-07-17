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
    private(set) var lastUnexpectedError: String?

    private let environmentChecker: any EnvironmentChecking
    private let deviceConnectionMonitor: any DeviceConnectionMonitoring
    private let runnerBuilder: any RunnerBuilding
    private let installationIdentityProvider: any InstallationIdentityProviding
    private let webDriverAgentSourceURL: URL?
    private let logger: StructuredLogging
    private var checkTask: Task<Void, Never>?
    private var deviceMonitorTask: Task<Void, Never>?
    private var runnerBuildTask: Task<Void, Never>?

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
        self.environmentChecker = environmentChecker
        self.deviceConnectionMonitor = deviceConnectionMonitor
        self.runnerBuilder = runnerBuilder
        self.installationIdentityProvider = installationIdentityProvider
        self.webDriverAgentSourceURL = webDriverAgentSourceURL
        self.logger = logger
    }

    var isChecking: Bool { checkTask != nil }

    func checkThisMac() {
        guard checkTask == nil else { return }
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

    var canBuildRunner: Bool {
        guard !isBuildingRunner,
              webDriverAgentSourceURL != nil,
              selectedBuildDevice != nil,
              selectedSigningIdentity != nil else { return false }
        return true
    }

    var runnerBundleIdentifier: String? {
        do {
            let suffix = try installationIdentityProvider.stableBundleSuffix()
            return "com.mirrorbridge.user.\(suffix).WebDriverAgentRunner"
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
        guard runnerBuildTask == nil,
              let sourceURL = webDriverAgentSourceURL,
              let device = selectedBuildDevice,
              let certificate = selectedSigningIdentity,
              let teamIdentifier = certificate.teamID,
              let bundleIdentifier = runnerBundleIdentifier else { return }

        let cachesURL: URL
        do {
            cachesURL = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("MirrorBridge/WebDriverAgent", isDirectory: true)
        } catch {
            runnerBuildIssue = RunnerBuildIssue(
                code: "MB-BUILD-009",
                title: "Build storage is unavailable",
                explanation: "MirrorBridge could not prepare its local runner build directory.",
                recovery: "Check available disk space and folder permissions, then retry.",
                retryIsSafe: true
            )
            return
        }

        let configuration = RunnerBuildConfiguration(
            sourceURL: sourceURL,
            deviceIdentifier: device.id,
            teamIdentifier: teamIdentifier,
            bundleIdentifier: bundleIdentifier,
            derivedDataURL: cachesURL.appendingPathComponent("DerivedData", isDirectory: true),
            resultBundleURL: cachesURL.appendingPathComponent("BuildResult.xcresult", isDirectory: true),
            allowProvisioningUpdates: true
        )
        runnerBuildIssue = nil
        runnerBuildResult = nil
        guard transitionToBuilding() else { return }
        logger.info("WebDriverAgent build started", category: .build)

        runnerBuildTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await runnerBuilder.build(configuration: configuration)
                try Task.checkCancellation()
                runnerBuildResult = result
                runnerBuildTask = nil
                try stateMachine.transition(to: .runnerBuilt)
                logger.info("WebDriverAgent build and signature verification completed", category: .build)
            } catch is CancellationError {
                runnerBuildTask = nil
                transitionIfPossible(to: .runnerNotInstalled, category: .build)
                logger.info("WebDriverAgent build cancelled", category: .build)
            } catch let error as RunnerBuildError {
                runnerBuildTask = nil
                runnerBuildIssue = error.issue
                transitionIfPossible(to: .runnerBuildFailed(message: error.issue.explanation), category: .build)
                logger.error("WebDriverAgent build failed with \(error.issue.code)", category: .build)
            } catch {
                runnerBuildTask = nil
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

    private var selectedBuildDevice: Device? {
        deviceSnapshot?.devices.first {
            $0.connectionTransport == .usb &&
                $0.pairingState == .paired &&
                $0.developerModeState == .enabled &&
                $0.lockState != .locked
        }
    }

    private var selectedSigningIdentity: DeveloperCertificateIdentity? {
        SigningIdentityResolver().resolve(from: environmentReport?.certificates ?? [])
    }

    private func transitionToBuilding() -> Bool {
        do {
            if stateMachine.state == .deviceConnectedUSB {
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

    private func transitionIfPossible(to state: ApplicationState, category: LogCategory) {
        do {
            try stateMachine.transition(to: state)
        } catch {
            logger.error("Application state could not transition to \(state.presentation.title)", category: category)
        }
    }

    private func updateApplicationState(for devices: [Device]) {
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
            } else {
                nextState = .requiresUserAction(message: "Connect this iPhone by USB for initial setup.")
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
    }
}
