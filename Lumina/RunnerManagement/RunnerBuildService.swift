import Foundation

nonisolated protocol RunnerBuilding: Sendable {
    func build(configuration: RunnerBuildConfiguration) async throws -> RunnerBuildResult
    func cachedBuild(configuration: RunnerBuildConfiguration) async throws -> RunnerBuildResult?
}

nonisolated struct RunnerBuildService: RunnerBuilding {
    private let processRunner: any ProcessRunning
    private let sourceValidator: any WebDriverAgentSourceValidating
    private let signatureVerifier: any CodeSignatureVerifying
    private let clock = ContinuousClock()

    init(
        processRunner: any ProcessRunning,
        sourceValidator: any WebDriverAgentSourceValidating,
        signatureVerifier: any CodeSignatureVerifying
    ) {
        self.processRunner = processRunner
        self.sourceValidator = sourceValidator
        self.signatureVerifier = signatureVerifier
    }

    func build(configuration: RunnerBuildConfiguration) async throws -> RunnerBuildResult {
        try validate(configuration)
        try await sourceValidator.validate(sourceURL: configuration.sourceURL)

        if FileManager.default.fileExists(atPath: configuration.resultBundleURL.path) {
            try FileManager.default.removeItem(at: configuration.resultBundleURL)
        }
        try FileManager.default.createDirectory(
            at: configuration.derivedDataURL,
            withIntermediateDirectories: true
        )

        let start = clock.now
        let result = try await processRunner.run(Self.command(for: configuration))
        let duration = start.duration(to: clock.now)
        guard result.succeeded else {
            let output = result.standardOutput + "\n" + result.standardError
            throw RunnerBuildError.buildFailed(BuildLogParser.issue(for: output))
        }

        let productURL = configuration.derivedDataURL
            .appendingPathComponent("Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: productURL.path) else {
            throw RunnerBuildError.productMissing(
                RunnerBuildIssue(
                    code: "LUM-BUILD-007",
                    title: "Runner product is missing",
                    explanation: "Xcode reported success but the expected WebDriverAgent runner app was not produced.",
                    recovery: "Clean the WebDriverAgent derived data and build again.",
                    retryIsSafe: true
                )
            )
        }
        let xctestrunURL = try locateXCTestRun(in: configuration.derivedDataURL)
        let signedIdentifier = configuration.bundleIdentifier + ".xctrunner"
        let signature = try signatureVerifier.verify(
            appURL: productURL,
            expectedTeamIdentifier: configuration.teamIdentifier,
            expectedBundleIdentifier: signedIdentifier
        )
        return RunnerBuildResult(
            productURL: productURL,
            xctestrunURL: xctestrunURL,
            resultBundleURL: configuration.resultBundleURL,
            bundleIdentifier: signedIdentifier,
            duration: duration,
            signature: signature
        )
    }

    func cachedBuild(configuration: RunnerBuildConfiguration) async throws -> RunnerBuildResult? {
        try validate(configuration)
        let productURL = configuration.derivedDataURL
            .appendingPathComponent("Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: productURL.path) else { return nil }
        let xctestrunURL: URL
        do {
            xctestrunURL = try locateXCTestRun(in: configuration.derivedDataURL)
        } catch {
            return nil
        }
        let signedIdentifier = configuration.bundleIdentifier + ".xctrunner"
        let signature: RunnerCodeSignature
        do {
            signature = try signatureVerifier.verify(
                appURL: productURL,
                expectedTeamIdentifier: configuration.teamIdentifier,
                expectedBundleIdentifier: signedIdentifier
            )
        } catch {
            return nil
        }
        return RunnerBuildResult(
            productURL: productURL,
            xctestrunURL: xctestrunURL,
            resultBundleURL: configuration.resultBundleURL,
            bundleIdentifier: signedIdentifier,
            duration: .zero,
            signature: signature
        )
    }

    private func locateXCTestRun(in derivedDataURL: URL) throws -> URL {
        let productsURL = derivedDataURL.appendingPathComponent("Build/Products", isDirectory: true)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: productsURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            throw RunnerBuildError.productMissing(Self.xctestrunIssue)
        }

        let candidates = enumerator.compactMap { item -> (url: URL, modified: Date)? in
            guard let url = item as? URL,
                  url.pathExtension == "xctestrun",
                  url.lastPathComponent.contains("WebDriverAgentRunner"),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        guard let newest = candidates.max(by: { $0.modified < $1.modified }) else {
            throw RunnerBuildError.productMissing(Self.xctestrunIssue)
        }
        return newest.url
    }

    private static let xctestrunIssue = RunnerBuildIssue(
        code: "LUM-BUILD-010",
        title: "Runner launch metadata is missing",
        explanation: "Xcode built the runner app but did not produce the XCTest launch configuration.",
        recovery: "Clean the WebDriverAgent derived data and build the runner again.",
        retryIsSafe: true
    )

    static func command(for configuration: RunnerBuildConfiguration) -> CommandRequest {
        var arguments = [
            "build-for-testing",
            "-project", configuration.sourceURL.appendingPathComponent("WebDriverAgent.xcodeproj").path,
            "-scheme", "WebDriverAgentRunner",
            "-configuration", "Debug",
            "-destination", "id=\(configuration.deviceIdentifier)",
            "-derivedDataPath", configuration.derivedDataURL.path,
            "-resultBundlePath", configuration.resultBundleURL.path,
            "DEVELOPMENT_TEAM=\(configuration.teamIdentifier)",
            "CODE_SIGN_STYLE=Automatic",
            "PRODUCT_BUNDLE_IDENTIFIER=\(configuration.bundleIdentifier)",
            "WDA_PRODUCT_BUNDLE_IDENTIFIER=\(configuration.bundleIdentifier)",
            "COMPILER_INDEX_STORE_ENABLE=NO",
            "GCC_TREAT_WARNINGS_AS_ERRORS=NO"
        ]
        if configuration.allowProvisioningUpdates {
            arguments.append("-allowProvisioningUpdates")
        }
        return CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: arguments,
            timeout: .seconds(900)
        )
    }

    private func validate(_ configuration: RunnerBuildConfiguration) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !configuration.deviceIdentifier.isEmpty,
              configuration.teamIdentifier.count >= 4,
              configuration.bundleIdentifier.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw RunnerBuildError.invalidConfiguration(
                RunnerBuildIssue(
                    code: "LUM-BUILD-008",
                    title: "Runner configuration is invalid",
                    explanation: "A device, development team, and valid unique bundle identifier are required.",
                    recovery: "Reconnect the iPhone and run the Mac and signing checks again.",
                    retryIsSafe: true
                )
            )
        }
    }
}
