import Foundation
import Observation

nonisolated enum StateTransitionError: Error, Equatable {
    case invalidTransition(from: ApplicationState, to: ApplicationState)
}

@MainActor
@Observable
final class ApplicationStateMachine {
    private(set) var state: ApplicationState
    private let logger: StructuredLogging

    init(initialState: ApplicationState = .appStarting, logger: StructuredLogging = StructuredLogger()) {
        state = initialState
        self.logger = logger
    }

    func transition(to nextState: ApplicationState) throws {
        guard Self.canTransition(from: state, to: nextState) else {
            logger.error("Rejected invalid application state transition", category: .app)
            throw StateTransitionError.invalidTransition(from: state, to: nextState)
        }

        logger.info("Application state changed to \(nextState.presentation.title)", category: .app)
        state = nextState
    }

    static func canTransition(from current: ApplicationState, to next: ApplicationState) -> Bool {
        if next == .stopping {
            return current != .stopped && current != .stopping
        }

        return switch (current, next) {
        case (.appStarting, .checkingEnvironment),
             (.stopped, .checkingEnvironment),
             (.checkingEnvironment, .xcodeMissing),
             (.checkingEnvironment, .sdkMissing),
             (.checkingEnvironment, .certificateMissing),
             (.checkingEnvironment, .noDevice),
             (.xcodeMissing, .checkingEnvironment),
             (.sdkMissing, .checkingEnvironment),
             (.certificateMissing, .checkingEnvironment),
             (.noDevice, .deviceConnectedUSB),
             (.deviceConnectedUSB, .deviceNeedsTrust),
             (.deviceConnectedUSB, .developerModeDisabled),
             (.deviceConnectedUSB, .devicePreparing),
             (.deviceNeedsTrust, .deviceConnectedUSB),
             (.developerModeDisabled, .devicePreparing),
             (.devicePreparing, .runnerNotInstalled),
             (.runnerNotInstalled, .runnerBuilding),
             (.runnerBuilding, .runnerBuildFailed),
             (.runnerBuilding, .runnerInstalling),
             (.runnerBuildFailed, .runnerBuilding),
             (.runnerInstalling, .runnerInstallFailed),
             (.runnerInstalling, .runnerLaunching),
             (.runnerInstallFailed, .runnerInstalling),
             (.runnerLaunching, .connectingAutomation),
             (.connectingAutomation, .automationReady),
             (.automationReady, .startingMirror),
             (.startingMirror, .connected),
             (.connected, .temporarilyDisconnected),
             (.connected, .deviceLocked),
             (.connected, .runnerCrashed),
             (.temporarilyDisconnected, .reconnecting),
             (.deviceLocked, .reconnecting),
             (.runnerCrashed, .reconnecting),
             (.reconnecting, .connectingAutomation),
             (.reconnecting, .requiresUserAction),
             (.requiresUserAction, .reconnecting),
             (.stopping, .stopped):
            true
        default:
            false
        }
    }
}
