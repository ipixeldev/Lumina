import Foundation
import Observation

@MainActor
@Observable
final class DependencyContainer {
    let stateMachine: ApplicationStateMachine
    let logger: StructuredLogging

    init(stateMachine: ApplicationStateMachine, logger: StructuredLogging) {
        self.stateMachine = stateMachine
        self.logger = logger
    }

    static var live: DependencyContainer {
        let logger = StructuredLogger()
        return DependencyContainer(
            stateMachine: ApplicationStateMachine(logger: logger),
            logger: logger
        )
    }
}
