import Testing
@testable import MirrorBridge

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
        #expect(presentation.diagnostics == ["MB-BUILD-004"])
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
}

private struct TestLogger: StructuredLogging {
    func debug(_: String, category _: LogCategory) {}
    func info(_: String, category _: LogCategory) {}
    func error(_: String, category _: LogCategory) {}
}
