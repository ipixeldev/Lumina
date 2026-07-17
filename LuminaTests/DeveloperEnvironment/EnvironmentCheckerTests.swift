import Foundation
import Security
import Testing
@testable import Lumina

struct EnvironmentCheckerTests {
    @Test("Nested Security.framework certificate values expose the team identifier")
    func nestedCertificateTeamIdentifier() {
        let value: NSArray = [[
            kSecPropertyKeyLabel as String: "2.5.4.11",
            kSecPropertyKeyValue as String: "TESTTEAM1"
        ]]

        #expect(
            KeychainDeveloperCertificateProvider.certificateString(
                in: value,
                matchingLabel: "2.5.4.11"
            ) == "TESTTEAM1"
        )
    }

    @Test("A complete environment advances to device discovery")
    func completeEnvironment() async throws {
        let checker = makeChecker()

        let report = try await checker.checkEnvironment()

        #expect(report.checks.map(\.requirement) == EnvironmentRequirement.allCases)
        #expect(report.checks.allSatisfy { $0.status == .passed })
        #expect(report.certificates.count == 1)
        #expect(report.recommendedState == .noDevice)
        #expect(report.result(for: .xcode)?.summary == "Xcode 26.1.1 (17B100)")
        #expect(report.result(for: .iOSSDK)?.summary == "iOS 26.1")
    }

    @Test("A missing physical-device iOS SDK produces the SDK state")
    func missingIOSSDK() async throws {
        var commands = passingCommands
        commands[.init("/usr/bin/xcodebuild", ["-showsdks", "-json"])] = .success("[]")
        let checker = makeChecker(commands: commands)

        let report = try await checker.checkEnvironment()

        #expect(report.result(for: .iOSSDK)?.status == .failed)
        #expect(report.result(for: .iOSSDK)?.errorCode == "LUM-ENV-002")
        #expect(report.recommendedState == .sdkMissing)
    }

    @Test("A missing certificate remains visible without blocking device discovery")
    func missingCertificate() async throws {
        let checker = makeChecker(certificates: [])

        let report = try await checker.checkEnvironment()

        #expect(report.result(for: .developmentCertificate)?.status == .failed)
        #expect(report.recommendedState == .noDevice)
    }

    @Test("An unavailable Xcode installation takes priority over later failures")
    func missingXcode() async throws {
        var commands = passingCommands
        commands[.init("/usr/bin/xcodebuild", ["-version"])] = .failure("xcode-select: error", exitCode: 1)
        let checker = makeChecker(commands: commands, certificates: [])

        let report = try await checker.checkEnvironment()

        #expect(report.result(for: .xcode)?.status == .failed)
        #expect(report.recommendedState == .xcodeMissing)
    }

    @Test("Critically low disk space requires user action")
    func lowDiskSpace() async throws {
        let checker = makeChecker(availableDiskSpace: 1_000_000_000)

        let report = try await checker.checkEnvironment()

        #expect(report.result(for: .diskSpace)?.status == .failed)
        guard case let .requiresUserAction(message) = report.recommendedState else {
            Issue.record("Expected a requiresUserAction state")
            return
        }
        #expect(message.contains("Free at least 2 GB"))
    }

    @Test("Xcode version parsing validates both expected lines")
    func xcodeVersionParsing() {
        let valid = EnvironmentChecker.parseXcodeVersion("Xcode 16.4\nBuild version 16F6\n")
        let invalid = EnvironmentChecker.parseXcodeVersion("Xcode 16.4\n")

        #expect(valid?.version == "16.4")
        #expect(valid?.build == "16F6")
        #expect(invalid == nil)
    }

    @Test("SDK parsing keeps structured platform data")
    func sdkParsing() {
        let sdks = EnvironmentChecker.parseSDKs(sdkJSON)

        #expect(sdks.count == 2)
        #expect(sdks.first { $0.platform == "iphoneos" }?.sdkVersion == "26.1")
    }

    private func makeChecker(
        commands: [CommandKey: CommandResult] = passingCommands,
        certificates: [DeveloperCertificateIdentity] = [usableCertificate],
        availableDiskSpace: Int64 = 20_000_000_000
    ) -> EnvironmentChecker {
        EnvironmentChecker(
            processRunner: StubProcessRunner(results: commands),
            systemInformationProvider: StubSystemInformationProvider(
                value: SystemSnapshot(
                    operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 1),
                    architecture: "Apple silicon (arm64)",
                    availableDiskSpace: availableDiskSpace
                )
            ),
            certificateProvider: StubCertificateProvider(certificates: certificates),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }
}

struct LocalProcessRunnerTests {
    @Test("Arguments are passed without shell interpretation")
    func literalArguments() async throws {
        let result = try await LocalProcessRunner().run(
            CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: ["%s", "$(not-a-shell-command)"]
            )
        )

        #expect(result.succeeded)
        #expect(result.standardOutput == "$(not-a-shell-command)")
    }

    @Test("Commands have a bounded timeout")
    func timeout() async {
        await #expect(throws: CommandRunnerError.self) {
            try await LocalProcessRunner().run(
                CommandRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["2"],
                    timeout: .milliseconds(20)
                )
            )
        }
    }

    @Test("Command environment overrides retain the inherited process environment")
    func environmentMerge() async throws {
        let result = try await LocalProcessRunner().run(
            CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                environment: ["LUMINA_TEST_VALUE": "present"]
            )
        )

        #expect(result.succeeded)
        #expect(result.standardOutput.contains("LUMINA_TEST_VALUE=present"))
        #expect(result.standardOutput.contains("PATH="))
    }
}

private nonisolated struct CommandKey: Hashable, Sendable {
    let executable: String
    let arguments: [String]

    init(_ executable: String, _ arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

private nonisolated struct StubProcessRunner: ProcessRunning {
    let results: [CommandKey: CommandResult]

    func run(_ request: CommandRequest) async throws -> CommandResult {
        let key = CommandKey(request.executableURL.path, request.arguments)
        guard let result = results[key] else {
            throw StubError.missingCommand(key.executable, key.arguments)
        }
        return result
    }
}

private nonisolated struct StubSystemInformationProvider: SystemInformationProviding {
    let value: SystemSnapshot

    func snapshot() throws -> SystemSnapshot { value }
}

private nonisolated struct StubCertificateProvider: DeveloperCertificateProviding {
    let certificates: [DeveloperCertificateIdentity]

    func developmentCertificates() async throws -> [DeveloperCertificateIdentity] { certificates }
}

private nonisolated enum StubError: Error {
    case missingCommand(String, [String])
}

private let sdkJSON = """
[
  {"canonicalName":"iphoneos26.1","displayName":"iOS 26.1","platform":"iphoneos","sdkVersion":"26.1"},
  {"canonicalName":"iphonesimulator26.1","displayName":"Simulator - iOS 26.1","platform":"iphonesimulator","sdkVersion":"26.1"}
]
"""

private let passingCommands: [CommandKey: CommandResult] = [
    .init("/usr/bin/xcode-select", ["-p"]): .success("/Applications/Xcode.app/Contents/Developer\n"),
    .init("/usr/bin/xcodebuild", ["-version"]): .success("Xcode 26.1.1\nBuild version 17B100\n"),
    .init("/usr/bin/xcodebuild", ["-checkFirstLaunchStatus"]): .success(""),
    .init("/usr/bin/xcodebuild", ["-showsdks", "-json"]): .success(sdkJSON),
    .init("/usr/bin/xcrun", ["--find", "clang"]): .success("/Applications/Xcode.app/clang\n")
]

private let usableCertificate = DeveloperCertificateIdentity(
    id: "certificate",
    displayName: "Apple Development: Test Developer (ABCDEFGHIJ)",
    teamID: "ABCDEFGHIJ",
    expirationDate: Date(timeIntervalSince1970: 2_000_000_000),
    hasPrivateKey: true,
    isCurrentlyValid: true
)

private extension CommandResult {
    static func success(_ output: String) -> CommandResult {
        CommandResult(standardOutput: output, standardError: "", exitCode: 0)
    }

    static func failure(_ error: String, exitCode: Int32) -> CommandResult {
        CommandResult(standardOutput: "", standardError: error, exitCode: exitCode)
    }
}
