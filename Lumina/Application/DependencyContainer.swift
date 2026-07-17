import Foundation
import Observation

@MainActor
@Observable
final class DependencyContainer {
    let stateMachine: ApplicationStateMachine
    let setupAssistantModel: SetupAssistantModel
    let logger: StructuredLogging

    init(
        stateMachine: ApplicationStateMachine,
        environmentChecker: any EnvironmentChecking,
        logger: StructuredLogging
    ) {
        self.stateMachine = stateMachine
        setupAssistantModel = SetupAssistantModel(
            stateMachine: stateMachine,
            environmentChecker: environmentChecker,
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
        return DependencyContainer(
            stateMachine: ApplicationStateMachine(logger: logger),
            environmentChecker: environmentChecker,
            logger: logger
        )
    }
}
