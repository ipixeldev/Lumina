import Testing
@testable import Lumina

@MainActor
struct ApplicationStateMachineTests {
    @Test("Startup can advance to environment checking")
    func startupTransition() throws {
        let machine = ApplicationStateMachine(logger: TestLogger())

        try machine.transition(to: .checkingEnvironment)

        #expect(machine.state == .checkingEnvironment)
    }

    @Test("Invalid transitions are rejected without changing state")
    func invalidTransition() {
        let machine = ApplicationStateMachine(logger: TestLogger())

        #expect(throws: StateTransitionError.self) {
            try machine.transition(to: .connected)
        }
        #expect(machine.state == .appStarting)
    }

    @Test("Stopping is available from an active workflow state")
    func stopFromActiveState() throws {
        let machine = ApplicationStateMachine(initialState: .runnerBuilding(progress: 0.4), logger: TestLogger())

        try machine.transition(to: .stopping)
        try machine.transition(to: .stopped)

        #expect(machine.state == .stopped)
    }

    @Test("Failure states expose diagnostics and recovery actions")
    func failurePresentation() {
        let presentation = ApplicationState.runnerBuildFailed(message: "Provisioning failed").presentation

        #expect(presentation.title == "Runner build failed")
        #expect(presentation.explanation == "Provisioning failed")
        #expect(presentation.diagnostics == ["LUM-BUILD-004"])
        #expect(presentation.actions.contains(.retry))
        #expect(presentation.canRecoverAutomatically == false)
    }

    @Test("Progress is carried by progress states")
    func progressPresentation() {
        let presentation = ApplicationState.runnerInstalling(progress: 0.65).presentation

        #expect(presentation.progress == 0.65)
    }

    @Test("Environment checks can be rerun after reaching device discovery")
    func rerunEnvironmentChecks() throws {
        let machine = ApplicationStateMachine(initialState: .noDevice, logger: TestLogger())

        try machine.transition(to: .checkingEnvironment)
        try machine.transition(to: .noDevice)

        #expect(machine.state == .noDevice)
    }

    @Test("Device discovery states react to connection and readiness changes")
    func deviceDiscoveryTransitions() throws {
        let machine = ApplicationStateMachine(initialState: .noDevice, logger: TestLogger())

        try machine.transition(to: .deviceConnectedUSB)
        try machine.transition(to: .deviceLocked)
        try machine.transition(to: .developerModeDisabled)
        try machine.transition(to: .deviceNeedsTrust)
        try machine.transition(to: .noDevice)

        #expect(machine.state == .noDevice)
    }

    @Test("A verified runner advances from building to ready")
    func verifiedRunnerTransition() throws {
        let machine = ApplicationStateMachine(initialState: .runnerNotInstalled, logger: TestLogger())

        try machine.transition(to: .runnerBuilding(progress: nil))
        try machine.transition(to: .runnerBuilt)

        #expect(machine.state == .runnerBuilt)
        #expect(machine.state.presentation.actions == [.continueSetup])
    }

    @Test("Runner installation advances through launch and endpoint verification")
    func runnerSetupTransitions() throws {
        let machine = ApplicationStateMachine(initialState: .runnerBuilt, logger: TestLogger())

        try machine.transition(to: .runnerInstalling(progress: nil))
        try machine.transition(to: .runnerLaunching)
        try machine.transition(to: .connectingAutomation)
        try machine.transition(to: .automationReady)

        #expect(machine.state == .automationReady)
    }

    @Test("A control connection can recover while AirPlay is waiting for video")
    func airPlayWaitingRecovery() throws {
        let machine = ApplicationStateMachine(initialState: .automationReady, logger: TestLogger())

        try machine.transition(to: .startingMirror)
        try machine.transition(to: .temporarilyDisconnected)
        try machine.transition(to: .reconnecting(attempt: 1))
        try machine.transition(to: .connectingAutomation)

        #expect(machine.state == .connectingAutomation)
    }

    @Test("AirPlay video can restart without dropping XCTest control")
    func airPlayVideoRestart() throws {
        let machine = ApplicationStateMachine(initialState: .connected, logger: TestLogger())

        try machine.transition(to: .startingMirror)
        try machine.transition(to: .connected)

        #expect(machine.state == .connected)
    }

    @Test("A live visual channel can confirm a healthy control session after transient discovery loss")
    func airPlayFrameRecoversTransientDiscoveryLoss() throws {
        let machine = ApplicationStateMachine(initialState: .temporarilyDisconnected, logger: TestLogger())

        try machine.transition(to: .connected)

        #expect(machine.state == .connected)
    }
}

private struct TestLogger: StructuredLogging {
    func debug(_: String, category _: LogCategory) {}
    func info(_: String, category _: LogCategory) {}
    func error(_: String, category _: LogCategory) {}
}
