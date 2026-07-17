import Foundation
import Observation

@MainActor
@Observable
final class SetupAssistantModel {
    let stateMachine: ApplicationStateMachine
    private(set) var environmentReport: EnvironmentReport?
    private(set) var lastUnexpectedError: String?

    private let environmentChecker: any EnvironmentChecking
    private let logger: StructuredLogging
    private var checkTask: Task<Void, Never>?

    init(
        stateMachine: ApplicationStateMachine,
        environmentChecker: any EnvironmentChecking,
        logger: StructuredLogging
    ) {
        self.stateMachine = stateMachine
        self.environmentChecker = environmentChecker
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
}
