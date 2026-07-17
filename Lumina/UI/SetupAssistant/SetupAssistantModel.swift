import Foundation
import Observation

@MainActor
@Observable
final class SetupAssistantModel {
    let stateMachine: ApplicationStateMachine
    private(set) var environmentReport: EnvironmentReport?
    private(set) var deviceSnapshot: DeviceDiscoverySnapshot?
    private(set) var deviceDiscoveryError: String?
    private(set) var lastUnexpectedError: String?

    private let environmentChecker: any EnvironmentChecking
    private let deviceConnectionMonitor: any DeviceConnectionMonitoring
    private let logger: StructuredLogging
    private var checkTask: Task<Void, Never>?
    private var deviceMonitorTask: Task<Void, Never>?

    init(
        stateMachine: ApplicationStateMachine,
        environmentChecker: any EnvironmentChecking,
        deviceConnectionMonitor: any DeviceConnectionMonitoring,
        logger: StructuredLogging
    ) {
        self.stateMachine = stateMachine
        self.environmentChecker = environmentChecker
        self.deviceConnectionMonitor = deviceConnectionMonitor
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
                    try? stateMachine.transition(to: .appStarting)
                }
                logger.info("Local developer environment check cancelled", category: .environment)
            } catch {
                checkTask = nil
                lastUnexpectedError = "The environment check could not finish. Run it again or inspect local logs."
                if stateMachine.state == .checkingEnvironment {
                    try? stateMachine.transition(
                        to: .requiresUserAction(message: "The environment check failed unexpectedly. Run it again or inspect local logs.")
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
