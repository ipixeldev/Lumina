import Foundation

nonisolated struct RunnerBuildConfiguration: Equatable, Sendable {
    let sourceURL: URL
    let deviceIdentifier: String
    let teamIdentifier: String
    let bundleIdentifier: String
    let derivedDataURL: URL
    let resultBundleURL: URL
    let allowProvisioningUpdates: Bool
}

nonisolated struct RunnerCodeSignature: Equatable, Sendable {
    let identifier: String
    let teamIdentifier: String
}

nonisolated struct RunnerBuildResult: Equatable, Sendable {
    let productURL: URL
    let xctestrunURL: URL
    let resultBundleURL: URL
    let bundleIdentifier: String
    let duration: Duration
    let signature: RunnerCodeSignature
}

nonisolated struct RunnerBuildIssue: Error, Equatable, Sendable {
    let code: String
    let title: String
    let explanation: String
    let recovery: String
    let retryIsSafe: Bool
}

nonisolated enum RunnerBuildError: Error, Equatable, Sendable {
    case invalidConfiguration(RunnerBuildIssue)
    case sourceValidation(RunnerBuildIssue)
    case buildFailed(RunnerBuildIssue)
    case productMissing(RunnerBuildIssue)
    case invalidSignature(RunnerBuildIssue)

    var issue: RunnerBuildIssue {
        switch self {
        case let .invalidConfiguration(issue), let .sourceValidation(issue),
             let .buildFailed(issue), let .productMissing(issue), let .invalidSignature(issue):
            issue
        }
    }
}

nonisolated enum WebDriverAgentPin {
    static let repository = "https://github.com/appium/WebDriverAgent.git"
    static let version = "15.1.6"
    static let commit = "5f8280e761dc0b5b9b28368e63a8f0cc8d868346"
    static let licenseSHA256 = "d9910c6ba5e4c29ae415ee3ce875c9e18a60d8bc4d7fe2c2d104db2a718b1bb4"
}
