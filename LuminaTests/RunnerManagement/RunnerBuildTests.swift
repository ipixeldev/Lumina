import Foundation
import Testing
@testable import MirrorBridge

struct RunnerBuildTests {
    @Test("Build command uses typed arguments and unique signing values")
    func commandConstruction() {
        let configuration = configuration()

        let command = RunnerBuildService.command(for: configuration)

        #expect(command.executableURL.path == "/usr/bin/xcodebuild")
        #expect(command.arguments.contains("id=TEST-DEVICE"))
        #expect(command.arguments.contains("DEVELOPMENT_TEAM=TESTTEAM1"))
        #expect(command.arguments.contains("PRODUCT_BUNDLE_IDENTIFIER=com.mirrorbridge.user.utest.WebDriverAgentRunner"))
        #expect(command.arguments.contains("-allowProvisioningUpdates"))
        #expect(command.arguments.contains(where: { $0.contains(";") }) == false)
    }

    @Test("Common signing and device failures produce actionable codes", arguments: [
        ("No profiles for 'example' were found: Xcode couldn't find any provisioning profiles", "MB-BUILD-004"),
        ("Developer Mode is disabled", "MB-DEV-003"),
        ("The device is locked with a passcode", "MB-DEV-002"),
        ("Ineligible destinations: device is not connected", "MB-DEV-004"),
        ("unexpected compiler failure", "MB-BUILD-006")
    ])
    func buildFailureParsing(output: String, expectedCode: String) {
        #expect(BuildLogParser.issue(for: output).code == expectedCode)
    }

    @Test("Signing resolver selects a usable current identity")
    func signingResolution() throws {
        let expired = certificate(id: "expired", expiration: .distantPast, valid: false)
        let current = certificate(id: "current", expiration: Date(timeIntervalSince1970: 2_000_000_000), valid: true)

        let resolved = try #require(SigningIdentityResolver().resolve(from: [expired, current]))

        #expect(resolved.id == "current")
        #expect(resolved.teamID == "TESTTEAM1")
    }

    @Test("Successful builds require and return a matching verified signature")
    func successfulBuild() async throws {
        let configuration = configuration()
        let productURL = configuration.derivedDataURL
            .appendingPathComponent("Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app", isDirectory: true)
        try FileManager.default.createDirectory(at: productURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configuration.derivedDataURL.deletingLastPathComponent()) }

        let service = RunnerBuildService(
            processRunner: SuccessfulBuildRunner(),
            sourceValidator: AcceptingSourceValidator(),
            signatureVerifier: MatchingSignatureVerifier()
        )

        let result = try await service.build(configuration: configuration)

        #expect(result.productURL == productURL)
        #expect(result.signature.teamIdentifier == "TESTTEAM1")
        #expect(result.bundleIdentifier.hasSuffix(".xctrunner"))
    }

    @Test("Source validation enforces the pinned revision, license, and clean tree")
    func sourceValidation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirrorBridgeSourceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("WebDriverAgent.xcodeproj", isDirectory: true),
            withIntermediateDirectories: true
        )
        let bundledLicense = try #require(Bundle.main.url(forResource: "WebDriverAgent-LICENSE", withExtension: "txt"))
        try FileManager.default.copyItem(at: bundledLicense, to: root.appendingPathComponent("LICENSE"))
        defer { try? FileManager.default.removeItem(at: root) }

        let validator = WebDriverAgentSourceValidator(
            processRunner: SourceGitRunner(dirty: false)
        )

        try await validator.validate(sourceURL: root)
    }

    private func configuration() -> RunnerBuildConfiguration {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirrorBridgeRunnerTests-\(UUID().uuidString)", isDirectory: true)
        return RunnerBuildConfiguration(
            sourceURL: root.appendingPathComponent("Source", isDirectory: true),
            deviceIdentifier: "TEST-DEVICE",
            teamIdentifier: "TESTTEAM1",
            bundleIdentifier: "com.mirrorbridge.user.utest.WebDriverAgentRunner",
            derivedDataURL: root.appendingPathComponent("DerivedData", isDirectory: true),
            resultBundleURL: root.appendingPathComponent("Result.xcresult", isDirectory: true),
            allowProvisioningUpdates: true
        )
    }

    private func certificate(id: String, expiration: Date, valid: Bool) -> DeveloperCertificateIdentity {
        DeveloperCertificateIdentity(
            id: id,
            displayName: "Apple Development: Test",
            teamID: "TESTTEAM1",
            expirationDate: expiration,
            hasPrivateKey: true,
            isCurrentlyValid: valid
        )
    }
}

private nonisolated struct SuccessfulBuildRunner: ProcessRunning {
    func run(_: CommandRequest) async throws -> CommandResult {
        CommandResult(standardOutput: "** BUILD SUCCEEDED **", standardError: "", exitCode: 0)
    }
}

private nonisolated struct AcceptingSourceValidator: WebDriverAgentSourceValidating {
    func validate(sourceURL _: URL) async throws {}
}

private nonisolated struct MatchingSignatureVerifier: CodeSignatureVerifying {
    func verify(appURL _: URL, expectedTeamIdentifier: String, expectedBundleIdentifier: String) throws -> RunnerCodeSignature {
        RunnerCodeSignature(identifier: expectedBundleIdentifier, teamIdentifier: expectedTeamIdentifier)
    }
}

private nonisolated struct SourceGitRunner: ProcessRunning {
    let dirty: Bool

    func run(_ request: CommandRequest) async throws -> CommandResult {
        if request.arguments.contains("rev-parse") {
            return CommandResult(standardOutput: WebDriverAgentPin.commit + "\n", standardError: "", exitCode: 0)
        }
        return CommandResult(
            standardOutput: dirty ? " M WebDriverAgentLib/Changed.m\n" : "",
            standardError: "",
            exitCode: 0
        )
    }
}
