import CryptoKit
import Foundation

nonisolated protocol WebDriverAgentSourceValidating: Sendable {
    func validate(sourceURL: URL) async throws
}

nonisolated struct WebDriverAgentSourceValidator: WebDriverAgentSourceValidating {
    private let processRunner: any ProcessRunning

    init(processRunner: any ProcessRunning) {
        self.processRunner = processRunner
    }

    func validate(sourceURL: URL) async throws {
        let projectURL = sourceURL.appendingPathComponent("WebDriverAgent.xcodeproj", isDirectory: true)
        let licenseURL = sourceURL.appendingPathComponent("LICENSE")
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            throw RunnerBuildError.sourceValidation(Self.issue("Pinned WebDriverAgent source is incomplete"))
        }
        let licenseData: Data
        do {
            licenseData = try Data(contentsOf: licenseURL)
        } catch {
            throw RunnerBuildError.sourceValidation(Self.issue("Pinned WebDriverAgent license is unavailable"))
        }

        let digest = SHA256.hash(data: licenseData).map { String(format: "%02x", $0) }.joined()
        guard digest == WebDriverAgentPin.licenseSHA256 else {
            throw RunnerBuildError.sourceValidation(Self.issue("WebDriverAgent license integrity check failed"))
        }

        let result = try await processRunner.run(
            CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", sourceURL.path, "rev-parse", "HEAD"]
            )
        )
        let revision = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, revision == WebDriverAgentPin.commit else {
            throw RunnerBuildError.sourceValidation(Self.issue("WebDriverAgent revision does not match the pinned release"))
        }

        let status = try await processRunner.run(
            CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", sourceURL.path, "status", "--porcelain", "--untracked-files=no"]
            )
        )
        guard status.succeeded,
              status.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunnerBuildError.sourceValidation(Self.issue("WebDriverAgent source contains unreviewed modifications"))
        }
    }

    private static func issue(_ title: String) -> RunnerBuildIssue {
        RunnerBuildIssue(
            code: "MB-BUILD-001",
            title: title,
            explanation: "MirrorBridge only builds the reviewed Appium WebDriverAgent revision and matching license.",
            recovery: "Initialize the repository submodules and restore WebDriverAgent v\(WebDriverAgentPin.version).",
            retryIsSafe: true
        )
    }
}
