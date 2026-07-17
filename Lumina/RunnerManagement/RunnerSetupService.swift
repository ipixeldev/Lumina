import Foundation

nonisolated final class RunnerSetupService: RunnerSetupManaging, @unchecked Sendable {
    private let processRunner: any ProcessRunning
    private let streamingProcess: any StreamingProcessLaunching
    private let healthChecker: any WebDriverAgentHealthChecking
    private let temporaryDirectory: URL
    private let now: @Sendable () -> Date
    private let logger: StructuredLogging

    init(
        processRunner: any ProcessRunning,
        streamingProcess: any StreamingProcessLaunching,
        healthChecker: any WebDriverAgentHealthChecking,
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        now: @escaping @Sendable () -> Date = Date.init,
        logger: StructuredLogging = StructuredLogger()
    ) {
        self.processRunner = processRunner
        self.streamingProcess = streamingProcess
        self.healthChecker = healthChecker
        self.temporaryDirectory = temporaryDirectory
        self.now = now
        self.logger = logger
    }

    func install(configuration: RunnerSetupConfiguration) async throws {
        try validate(configuration)
        let resultURL = temporaryDirectory
            .appendingPathComponent("lumina-runner-install-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { removeTemporaryFile(resultURL) }

        let result = try await processRunner.run(Self.installCommand(for: configuration, resultURL: resultURL))
        let combinedOutput = result.standardOutput + "\n" + result.standardError
        guard result.succeeded else {
            throw RunnerSetupError.installationFailed(RunnerSetupLogParser.installationIssue(for: combinedOutput))
        }
        guard let data = try? Data(contentsOf: resultURL),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw RunnerSetupError.installationFailed(
                RunnerSetupIssue(
                    code: "LUM-INSTALL-007",
                    title: "Installation result is unavailable",
                    explanation: "Apple's device tool did not return a valid structured installation result.",
                    recovery: "Reconnect the iPhone and retry installation.",
                    retryIsSafe: true
                )
            )
        }
    }

    func isInstalled(configuration: RunnerSetupConfiguration) async -> Bool {
        let resultURL = temporaryDirectory
            .appendingPathComponent("lumina-runner-query-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { removeTemporaryFile(resultURL) }
        do {
            let result = try await processRunner.run(Self.installedAppCommand(for: configuration, resultURL: resultURL))
            guard result.succeeded, let data = try? Data(contentsOf: resultURL) else { return false }
            return String(decoding: data, as: UTF8.self).contains(configuration.bundleIdentifier)
        } catch {
            return false
        }
    }

    func launchAndConnect(configuration: RunnerSetupConfiguration) async throws -> RunnerConnection {
        try validate(configuration)
        let stream: AsyncThrowingStream<String, Error>
        do {
            stream = try streamingProcess.start(Self.launchCommand(for: configuration))
        } catch {
            throw RunnerSetupError.launchFailed(RunnerSetupLogParser.launchIssue(for: error.localizedDescription))
        }

        do {
            return try await withTaskCancellationHandler {
                try await waitForConnection(stream: stream, configuration: configuration)
            } onCancel: {
                streamingProcess.terminate()
            }
        } catch is CancellationError {
            streamingProcess.terminate()
            throw CancellationError()
        } catch let error as RunnerSetupError {
            streamingProcess.terminate()
            throw error
        } catch {
            streamingProcess.terminate()
            throw RunnerSetupError.launchFailed(RunnerSetupLogParser.launchIssue(for: error.localizedDescription))
        }
    }

    func stop() {
        streamingProcess.terminate()
    }

    static func installCommand(for configuration: RunnerSetupConfiguration, resultURL: URL) -> CommandRequest {
        CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "devicectl", "device", "install", "app",
                "--device", configuration.deviceIdentifier,
                configuration.productURL.path,
                "--timeout", "90",
                "--json-output", resultURL.path,
                "--quiet"
            ],
            timeout: .seconds(100)
        )
    }

    static func installedAppCommand(for configuration: RunnerSetupConfiguration, resultURL: URL) -> CommandRequest {
        CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "devicectl", "device", "info", "apps",
                "--device", configuration.deviceIdentifier,
                "--bundle-id", configuration.bundleIdentifier,
                "--timeout", "20",
                "--json-output", resultURL.path,
                "--quiet"
            ],
            timeout: .seconds(30)
        )
    }

    static func launchCommand(for configuration: RunnerSetupConfiguration) -> CommandRequest {
        CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: [
                "test-without-building",
                "-xctestrun", configuration.xctestrunURL.path,
                "-destination", "id=\(configuration.deviceIdentifier)",
                "-destination-timeout", "60"
            ],
            environment: [
                "USE_PORT": String(configuration.serverPort),
                "MJPEG_SERVER_PORT": "9100",
                "WDA_PRODUCT_BUNDLE_IDENTIFIER": configuration.productBundleIdentifier
            ],
            timeout: .seconds(86_400)
        )
    }

    static func endpoint(from output: String) -> URL? {
        let startMarker = "ServerURLHere->"
        let endMarker = "<-ServerURLHere"
        guard let start = output.range(of: startMarker)?.upperBound,
              let end = output.range(of: endMarker, range: start..<output.endIndex)?.lowerBound else {
            return nil
        }
        return URL(string: String(output[start..<end]))
    }

    private func waitForConnection(
        stream: AsyncThrowingStream<String, Error>,
        configuration: RunnerSetupConfiguration
    ) async throws -> RunnerConnection {
        let knownEndpoints = configuration.developerConnectionHosts.compactMap {
            Self.endpoint(host: $0, port: configuration.serverPort)
        }

        return try await withThrowingTaskGroup(of: RunnerConnection.self) { group in
            for endpoint in knownEndpoints {
                group.addTask { [healthChecker, now] in
                    // A just-terminated XCTest process can leave its old WDA socket alive briefly.
                    // Prefer the new process marker and avoid creating a session on that stale server.
                    try await Task.sleep(for: .seconds(5))
                    return try await Self.waitUntilHealthy(
                        endpoint: endpoint,
                        expectedBundleIdentifier: configuration.productBundleIdentifier,
                        healthChecker: healthChecker,
                        now: now
                    )
                }
            }

            group.addTask { [healthChecker, now] in
                var output = ""
                for try await chunk in stream {
                    try Task.checkCancellation()
                    output = String((output + chunk).suffix(65_536))
                    guard let endpoint = Self.endpoint(from: output) else { continue }
                    return try await Self.waitUntilHealthy(
                        endpoint: endpoint,
                        expectedBundleIdentifier: configuration.productBundleIdentifier,
                        healthChecker: healthChecker,
                        now: now
                    )
                }
                throw RunnerSetupError.launchFailed(RunnerSetupLogParser.launchIssue(for: output))
            }

            group.addTask {
                try await Task.sleep(for: .seconds(90))
                throw RunnerSetupError.connectionFailed(RunnerSetupLogParser.connectionIssue)
            }

            guard let connection = try await group.next() else {
                throw RunnerSetupError.connectionFailed(RunnerSetupLogParser.connectionIssue)
            }
            group.cancelAll()
            return connection
        }
    }

    private static func waitUntilHealthy(
        endpoint: URL,
        expectedBundleIdentifier: String,
        healthChecker: any WebDriverAgentHealthChecking,
        now: @escaping @Sendable () -> Date
    ) async throws -> RunnerConnection {
        while !Task.isCancelled {
            do {
                let status = try await healthChecker.status(at: endpoint)
                guard status.productBundleIdentifier == nil ||
                        status.productBundleIdentifier == expectedBundleIdentifier else {
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                }
                return RunnerConnection(endpoint: endpoint, status: status, connectedAt: now())
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw CancellationError()
    }

    private static func endpoint(host: String, port: UInt16) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        return components.url
    }

    private func validate(_ configuration: RunnerSetupConfiguration) throws {
        guard !configuration.deviceIdentifier.isEmpty,
              !configuration.bundleIdentifier.isEmpty,
              FileManager.default.fileExists(atPath: configuration.productURL.path),
              FileManager.default.fileExists(atPath: configuration.xctestrunURL.path) else {
            throw RunnerSetupError.invalidConfiguration(
                RunnerSetupIssue(
                    code: "LUM-INSTALL-001",
                    title: "Runner setup is incomplete",
                    explanation: "A connected iPhone and verified runner build are required before installation.",
                    recovery: "Reconnect the iPhone and build the signed runner again.",
                    retryIsSafe: true
                )
            )
        }
    }

    private func removeTemporaryFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.error("A temporary runner installation result could not be removed", category: .security)
        }
    }
}
