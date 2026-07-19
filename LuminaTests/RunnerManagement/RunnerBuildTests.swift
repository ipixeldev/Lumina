import Foundation
import Testing
@testable import Lumina

struct RunnerBuildTests {
    @Test("Bundled control extension advertises the cache revision")
    func patchRevisionMatchesRuntimeHandshake() throws {
        let patch = try String(contentsOf: LuminaWebDriverAgentPatch.url(), encoding: .utf8)

        #expect(
            patch.contains(
                "@\"revision\": @\"\(LuminaWebDriverAgentPatch.revision)\""
            )
        )
    }

    @Test("Control-extension identity includes the patch contents")
    func patchContentsChangeCacheIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuminaPatchIdentityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First.patch")
        let second = root.appendingPathComponent("Second.patch")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)

        #expect(
            LuminaWebDriverAgentPatch.cacheIdentity(for: first) !=
                LuminaWebDriverAgentPatch.cacheIdentity(for: second)
        )
    }

    @Test("Build command uses typed arguments and unique signing values")
    func commandConstruction() {
        let configuration = configuration()

        let command = RunnerBuildService.command(for: configuration)

        #expect(command.executableURL.path == "/usr/bin/xcodebuild")
        #expect(command.arguments.contains("id=TEST-DEVICE"))
        #expect(command.arguments.contains("DEVELOPMENT_TEAM=TESTTEAM1"))
        #expect(command.arguments.contains("PRODUCT_BUNDLE_IDENTIFIER=com.iPixeldev.Lumina.user.utest.WebDriverAgentRunner"))
        #expect(command.arguments.contains("-allowProvisioningUpdates"))
        #expect(command.arguments.contains(where: { $0.contains(";") }) == false)
    }

    @Test("Common signing and device failures produce actionable codes", arguments: [
        ("No Accounts: Add a new account in Accounts settings. No profiles for 'example' were found.", "LUM-BUILD-011"),
        ("No profiles for 'example' were found: Xcode couldn't find any provisioning profiles", "LUM-BUILD-004"),
        ("Developer Mode is disabled", "LUM-DEV-003"),
        ("The device is locked with a passcode", "LUM-DEV-002"),
        ("Ineligible destinations: device is not connected", "LUM-DEV-004"),
        ("unexpected compiler failure", "LUM-BUILD-006")
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
        let (productURL, xctestrunURL) = try prepareBuildProducts(for: configuration)
        defer { try? FileManager.default.removeItem(at: configuration.derivedDataURL.deletingLastPathComponent()) }

        let service = RunnerBuildService(
            processRunner: SuccessfulBuildRunner(),
            sourceValidator: AcceptingSourceValidator(),
            signatureVerifier: MatchingSignatureVerifier()
        )

        let result = try await service.build(configuration: configuration)

        #expect(result.productURL == productURL)
        #expect(result.xctestrunURL.resolvingSymlinksInPath() == xctestrunURL.resolvingSymlinksInPath())
        #expect(result.signature.teamIdentifier == "TESTTEAM1")
        #expect(result.bundleIdentifier.hasSuffix(".xctrunner"))
        #expect(result.artifactIdentity.contains(LuminaWebDriverAgentPatch.cacheIdentity))
        #expect(result.artifactIdentity.contains("TESTTEAM1"))
        #expect(result.artifactIdentity.contains("test-code-directory-hash"))
    }

    @Test("Build applies the Lumina patch to an isolated source cache")
    func patchedSourceCache() async throws {
        let configuration = configuration()
        let root = configuration.derivedDataURL.deletingLastPathComponent()
        let patchURL = root.appendingPathComponent("Lumina.patch")
        try FileManager.default.createDirectory(
            at: configuration.sourceURL.appendingPathComponent("WebDriverAgent.xcodeproj", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("before\n".utf8).write(
            to: configuration.sourceURL.appendingPathComponent("Target.txt")
        )
        try Data("gitdir: an-untrusted-original-location\n".utf8).write(
            to: configuration.sourceURL.appendingPathComponent(".git")
        )
        try Data(Self.testPatch.utf8).write(to: patchURL)
        _ = try prepareBuildProducts(for: configuration)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = RunnerBuildService(
            processRunner: PatchApplyingBuildRunner(),
            sourceValidator: AcceptingSourceValidator(),
            signatureVerifier: MatchingSignatureVerifier(),
            patchURL: patchURL
        )

        _ = try await service.build(configuration: configuration)

        let preparedURL = RunnerBuildService.preparedSourceURL(for: configuration)
        let patchedContents = try String(
            contentsOf: preparedURL.appendingPathComponent("Target.txt"),
            encoding: .utf8
        )
        #expect(patchedContents == "after\n")
        #expect(FileManager.default.fileExists(atPath: preparedURL.appendingPathComponent(".git").path) == false)
        #expect(
            try String(
                contentsOf: preparedURL.appendingPathComponent(".lumina-source-revision"),
                encoding: .utf8
            ) == LuminaWebDriverAgentPatch.cacheIdentity(for: patchURL)
        )
        #expect(try await service.cachedBuild(configuration: configuration) != nil)
    }

    @Test("Cached runner is rejected when its Lumina patch revision is stale")
    func stalePatchedBuildIsNotReused() async throws {
        let configuration = configuration()
        let root = configuration.derivedDataURL.deletingLastPathComponent()
        let patchURL = root.appendingPathComponent("Lumina.patch")
        _ = try prepareBuildProducts(for: configuration)
        try Data("unused patch".utf8).write(to: patchURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = RunnerBuildService(
            processRunner: SuccessfulBuildRunner(),
            sourceValidator: AcceptingSourceValidator(),
            signatureVerifier: MatchingSignatureVerifier(),
            patchURL: patchURL
        )
        let markerURL = RunnerBuildService.buildRevisionMarkerURL(for: configuration)

        try Data("stale-revision".utf8).write(to: markerURL)
        #expect(try await service.cachedBuild(configuration: configuration) == nil)

        try Data(LuminaWebDriverAgentPatch.cacheIdentity(for: patchURL).utf8).write(to: markerURL)
        #expect(try await service.cachedBuild(configuration: configuration) != nil)
    }

    @Test("Source validation enforces the pinned revision, license, and clean tree")
    func sourceValidation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuminaSourceTests-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("LuminaRunnerTests-\(UUID().uuidString)", isDirectory: true)
        return RunnerBuildConfiguration(
            sourceURL: root.appendingPathComponent("Source", isDirectory: true),
            deviceIdentifier: "TEST-DEVICE",
            teamIdentifier: "TESTTEAM1",
            bundleIdentifier: "com.iPixeldev.Lumina.user.utest.WebDriverAgentRunner",
            derivedDataURL: root.appendingPathComponent("DerivedData", isDirectory: true),
            resultBundleURL: root.appendingPathComponent("Result.xcresult", isDirectory: true),
            allowProvisioningUpdates: true
        )
    }

    private func prepareBuildProducts(
        for configuration: RunnerBuildConfiguration
    ) throws -> (productURL: URL, xctestrunURL: URL) {
        let productURL = configuration.derivedDataURL
            .appendingPathComponent("Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app", isDirectory: true)
        try FileManager.default.createDirectory(at: productURL, withIntermediateDirectories: true)
        let xctestrunURL = configuration.derivedDataURL
            .appendingPathComponent("Build/Products/WebDriverAgentRunner_iphoneos-arm64.xctestrun")
        try Data("test configuration".utf8).write(to: xctestrunURL)
        return (productURL, xctestrunURL)
    }

    private static let testPatch = """
    diff --git a/Target.txt b/Target.txt
    --- a/Target.txt
    +++ b/Target.txt
    @@ -1 +1 @@
    -before
    +after
    """

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

private nonisolated struct PatchApplyingBuildRunner: ProcessRunning {
    func run(_ request: CommandRequest) async throws -> CommandResult {
        if request.executableURL.path == "/usr/bin/git" {
            if !request.arguments.contains("--check"),
               let sourceIndex = request.arguments.firstIndex(of: "-C"),
               request.arguments.indices.contains(sourceIndex + 1) {
                let sourceURL = URL(fileURLWithPath: request.arguments[sourceIndex + 1], isDirectory: true)
                try Data("after\n".utf8).write(to: sourceURL.appendingPathComponent("Target.txt"))
            }
            return CommandResult(standardOutput: "", standardError: "", exitCode: 0)
        }
        return CommandResult(standardOutput: "** BUILD SUCCEEDED **", standardError: "", exitCode: 0)
    }
}

private nonisolated struct AcceptingSourceValidator: WebDriverAgentSourceValidating {
    func validate(sourceURL _: URL) async throws {}
}

private nonisolated struct MatchingSignatureVerifier: CodeSignatureVerifying {
    func verify(appURL _: URL, expectedTeamIdentifier: String, expectedBundleIdentifier: String) throws -> RunnerCodeSignature {
        RunnerCodeSignature(
            identifier: expectedBundleIdentifier,
            teamIdentifier: expectedTeamIdentifier,
            codeDirectoryHash: "test-code-directory-hash"
        )
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
