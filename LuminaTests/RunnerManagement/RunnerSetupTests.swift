import Foundation
import Testing
@testable import Lumina

struct RunnerSetupTests {
    @Test("Installation trust is scoped to the exact signed runner artifact")
    func installationTrustIdentity() throws {
        let fixture = try configuration()
        defer { cleanup(fixture.root) }
        let original = fixture.configuration
        let replacement = RunnerSetupConfiguration(
            deviceIdentifier: original.deviceIdentifier,
            productURL: original.productURL,
            xctestrunURL: original.xctestrunURL,
            bundleIdentifier: original.bundleIdentifier,
            artifactIdentity: original.artifactIdentity + ":replacement-signature",
            developerConnectionHosts: original.developerConnectionHosts
        )

        #expect(original.installationTrustKey != replacement.installationTrustKey)
    }

    @Test("Installation uses structured devicectl output and literal arguments")
    func installCommand() throws {
        let fixture = try configuration()
        defer { cleanup(fixture.root) }
        let resultURL = fixture.root.appendingPathComponent("install.json")

        let command = RunnerSetupService.installCommand(for: fixture.configuration, resultURL: resultURL)

        #expect(command.executableURL.path == "/usr/bin/xcrun")
        #expect(command.arguments.contains("devicectl"))
        #expect(command.arguments.contains("TEST-DEVICE"))
        #expect(command.arguments.contains(fixture.configuration.productURL.path))
        #expect(command.arguments.contains(resultURL.path))
        #expect(command.arguments.contains(where: { $0.contains(";") }) == false)
    }

    @Test("Launch uses the built XCTest configuration and fixed local ports")
    func launchCommand() throws {
        let fixture = try configuration()
        defer { cleanup(fixture.root) }

        let command = RunnerSetupService.launchCommand(for: fixture.configuration)

        #expect(command.executableURL.path == "/usr/bin/xcodebuild")
        #expect(command.arguments.contains("test-without-building"))
        #expect(command.arguments.contains(fixture.configuration.xctestrunURL.path))
        #expect(command.arguments.contains("id=TEST-DEVICE"))
        #expect(command.environment?["USE_PORT"] == "8100")
        #expect(command.environment?["WDA_PRODUCT_BUNDLE_IDENTIFIER"] == fixture.configuration.productBundleIdentifier)
    }

    @Test("WebDriverAgent endpoint markers are parsed without log assumptions")
    func endpointParsing() throws {
        let endpoint = try #require(
            RunnerSetupService.endpoint(
                from: "noise ServerURLHere->http://test-iphone.coredevice.local:8100<-ServerURLHere more"
            )
        )

        #expect(endpoint.absoluteString == "http://test-iphone.coredevice.local:8100")
    }

    @Test("Status parsing validates the real WebDriverAgent response shape")
    func statusParsing() throws {
        let data = Data(
            """
            {"value":{"ready":true,"message":"WebDriverAgent is ready to accept commands","device":"iphone","os":{"name":"iOS","version":"18.5"},"build":{"productBundleIdentifier":"com.iPixeldev.Lumina.runner.xctrunner"}}}
            """.utf8
        )

        let status = try URLSessionWebDriverAgentHealthChecker.decodeStatus(data)

        #expect(status.ready)
        #expect(status.operatingSystemVersion == "18.5")
        #expect(status.productBundleIdentifier == "com.iPixeldev.Lumina.runner.xctrunner")
    }

    @Test("Successful setup installs, launches, and verifies the matching runner")
    func successfulSetup() async throws {
        let fixture = try configuration(developerConnectionHosts: [])
        defer { cleanup(fixture.root) }
        let service = RunnerSetupService(
            processRunner: StructuredInstallRunner(),
            streamingProcess: MarkerStreamingProcess(),
            healthChecker: ReadyHealthChecker(bundleIdentifier: fixture.configuration.productBundleIdentifier),
            temporaryDirectory: fixture.root,
            now: { Date(timeIntervalSince1970: 1_000) },
            logger: TestRunnerLogger()
        )

        try await service.install(configuration: fixture.configuration)
        let connection = try await service.launchAndConnect(configuration: fixture.configuration)

        #expect(connection.endpoint.host == "test-iphone.coredevice.local")
        #expect(connection.status.ready)
        #expect(connection.status.productBundleIdentifier == fixture.configuration.productBundleIdentifier)
        #expect(connection.connectedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test("Common installation failures produce actionable diagnostics", arguments: [
        ("Device is locked with a passcode", "LUM-INSTALL-002"),
        ("Developer Mode is disabled", "LUM-INSTALL-003"),
        ("ApplicationVerificationFailed: signature invalid", "LUM-INSTALL-004"),
        ("Device is not connected", "LUM-INSTALL-005"),
        ("Unexpected CoreDevice failure", "LUM-INSTALL-006")
    ])
    func installationFailureParsing(output: String, expectedCode: String) {
        #expect(RunnerSetupLogParser.installationIssue(for: output).code == expectedCode)
    }

    private func configuration(
        developerConnectionHosts: [String] = ["test-iphone.coredevice.local"]
    ) throws -> (root: URL, configuration: RunnerSetupConfiguration) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuminaSetupTests-\(UUID().uuidString)", isDirectory: true)
        let product = root.appendingPathComponent("WebDriverAgentRunner-Runner.app", isDirectory: true)
        let xctestrun = root.appendingPathComponent("WebDriverAgentRunner_iphoneos-arm64.xctestrun")
        try FileManager.default.createDirectory(at: product, withIntermediateDirectories: true)
        try Data("test configuration".utf8).write(to: xctestrun)
        return (
            root,
            RunnerSetupConfiguration(
                deviceIdentifier: "TEST-DEVICE",
                productURL: product,
                xctestrunURL: xctestrun,
                bundleIdentifier: "com.iPixeldev.Lumina.user.utest.WebDriverAgentRunner.xctrunner",
                artifactIdentity: "pinned-source:control-extension:team:code-directory-hash",
                developerConnectionHosts: developerConnectionHosts
            )
        )
    }

    private func cleanup(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("Could not remove test fixture: \(error.localizedDescription)")
        }
    }
}

private nonisolated struct StructuredInstallRunner: ProcessRunning {
    func run(_ request: CommandRequest) async throws -> CommandResult {
        guard let marker = request.arguments.firstIndex(of: "--json-output"),
              request.arguments.indices.contains(marker + 1) else {
            return CommandResult(standardOutput: "", standardError: "Missing result path", exitCode: 1)
        }
        try Data("{\"result\":{}}".utf8).write(to: URL(fileURLWithPath: request.arguments[marker + 1]))
        return CommandResult(standardOutput: "", standardError: "", exitCode: 0)
    }
}

private nonisolated struct MarkerStreamingProcess: StreamingProcessLaunching {
    func start(_: CommandRequest) throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(
                "ServerURLHere->http://test-iphone.coredevice.local:8100<-ServerURLHere"
            )
        }
    }

    func terminate() {}
}

private nonisolated struct ReadyHealthChecker: WebDriverAgentHealthChecking {
    let bundleIdentifier: String

    func status(at _: URL) async throws -> WebDriverAgentStatus {
        WebDriverAgentStatus(
            ready: true,
            message: "WebDriverAgent is ready to accept commands",
            device: "iphone",
            operatingSystemName: "iOS",
            operatingSystemVersion: "18.5",
            productBundleIdentifier: bundleIdentifier
        )
    }
}

private struct TestRunnerLogger: StructuredLogging {
    func debug(_: String, category _: LogCategory) {}
    func info(_: String, category _: LogCategory) {}
    func error(_: String, category _: LogCategory) {}
}
