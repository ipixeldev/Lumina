import Foundation

nonisolated protocol RunnerBuilding: Sendable {
    func build(configuration: RunnerBuildConfiguration) async throws -> RunnerBuildResult
    func cachedBuild(configuration: RunnerBuildConfiguration) async throws -> RunnerBuildResult?
}

nonisolated struct RunnerBuildService: RunnerBuilding {
    private let processRunner: any ProcessRunning
    private let sourceValidator: any WebDriverAgentSourceValidating
    private let signatureVerifier: any CodeSignatureVerifying
    private let patchURL: URL?
    private let clock = ContinuousClock()

    init(
        processRunner: any ProcessRunning,
        sourceValidator: any WebDriverAgentSourceValidating,
        signatureVerifier: any CodeSignatureVerifying,
        patchURL: URL? = nil
    ) {
        self.processRunner = processRunner
        self.sourceValidator = sourceValidator
        self.signatureVerifier = signatureVerifier
        self.patchURL = patchURL
    }

    func build(configuration: RunnerBuildConfiguration) async throws -> RunnerBuildResult {
        try validate(configuration)
        try await sourceValidator.validate(sourceURL: configuration.sourceURL)
        let buildSourceURL = try await preparePatchedSource(for: configuration)

        if FileManager.default.fileExists(atPath: configuration.resultBundleURL.path) {
            try FileManager.default.removeItem(at: configuration.resultBundleURL)
        }
        try FileManager.default.createDirectory(
            at: configuration.derivedDataURL,
            withIntermediateDirectories: true
        )
        try removeBuildRevisionMarker(for: configuration)

        let start = clock.now
        let result = try await processRunner.run(
            Self.command(for: configuration, sourceURL: buildSourceURL)
        )
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
        try writeBuildRevisionMarker(for: configuration)
        return RunnerBuildResult(
            productURL: productURL,
            xctestrunURL: xctestrunURL,
            resultBundleURL: configuration.resultBundleURL,
            bundleIdentifier: signedIdentifier,
            duration: duration,
            signature: signature,
            controlExtensionIdentity: controlExtensionIdentity
        )
    }

    func cachedBuild(configuration: RunnerBuildConfiguration) async throws -> RunnerBuildResult? {
        try validate(configuration)
        guard buildRevisionIsCurrent(for: configuration) else { return nil }
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
            signature: signature,
            controlExtensionIdentity: controlExtensionIdentity
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
        command(for: configuration, sourceURL: configuration.sourceURL)
    }

    static func command(for configuration: RunnerBuildConfiguration, sourceURL: URL) -> CommandRequest {
        var arguments = [
            "build-for-testing",
            "-project", sourceURL.appendingPathComponent("WebDriverAgent.xcodeproj").path,
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

    static func preparedSourceURL(for configuration: RunnerBuildConfiguration) -> URL {
        configuration.derivedDataURL
            .deletingLastPathComponent()
            .appendingPathComponent("Source-\(LuminaWebDriverAgentPatch.revision)", isDirectory: true)
    }

    static func buildRevisionMarkerURL(for configuration: RunnerBuildConfiguration) -> URL {
        configuration.derivedDataURL.appendingPathComponent(".lumina-runner-revision")
    }

    private func preparePatchedSource(for configuration: RunnerBuildConfiguration) async throws -> URL {
        guard let patchURL else { return configuration.sourceURL }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: patchURL.path) else {
            throw RunnerBuildError.sourceValidation(Self.patchIssue(
                title: "Lumina's WebDriverAgent patch is missing",
                recovery: "Restore Lumina's bundled WebDriverAgent patch and build again."
            ))
        }

        let preparedURL = Self.preparedSourceURL(for: configuration)
        let expectedCacheIdentity = LuminaWebDriverAgentPatch.cacheIdentity(for: patchURL)
        let revisionMarkerURL = preparedURL.appendingPathComponent(".lumina-source-revision")
        let projectURL = preparedURL.appendingPathComponent("WebDriverAgent.xcodeproj", isDirectory: true)
        if fileManager.fileExists(atPath: projectURL.path),
           Self.marker(at: revisionMarkerURL) == expectedCacheIdentity {
            return preparedURL
        }

        let parentURL = preparedURL.deletingLastPathComponent()
        let stagingURL = parentURL.appendingPathComponent(
            ".Source-\(LuminaWebDriverAgentPatch.revision)-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
            try fileManager.copyItem(at: configuration.sourceURL, to: stagingURL)

            let copiedGitMetadata = stagingURL.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: copiedGitMetadata.path) {
                try fileManager.removeItem(at: copiedGitMetadata)
            }

            let check = try await processRunner.run(Self.patchCommand(
                sourceURL: stagingURL,
                patchURL: patchURL,
                checkOnly: true
            ))
            guard check.succeeded else {
                throw RunnerBuildError.sourceValidation(Self.patchIssue(
                    title: "Lumina's WebDriverAgent patch does not match the pinned source",
                    recovery: "Restore the pinned WebDriverAgent submodule and Lumina patch, then retry."
                ))
            }

            let application = try await processRunner.run(Self.patchCommand(
                sourceURL: stagingURL,
                patchURL: patchURL,
                checkOnly: false
            ))
            guard application.succeeded else {
                throw RunnerBuildError.sourceValidation(Self.patchIssue(
                    title: "Lumina could not prepare its WebDriverAgent control extension",
                    recovery: "Remove Lumina's WebDriverAgent cache and build the runner again."
                ))
            }

            try Data(expectedCacheIdentity.utf8).write(
                to: stagingURL.appendingPathComponent(".lumina-source-revision"),
                options: .atomic
            )
            if fileManager.fileExists(atPath: preparedURL.path) {
                try fileManager.removeItem(at: preparedURL)
            }
            try fileManager.moveItem(at: stagingURL, to: preparedURL)
            return preparedURL
        } catch let error as RunnerBuildError {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw RunnerBuildError.sourceValidation(Self.patchIssue(
                title: "Lumina could not prepare its WebDriverAgent source cache",
                recovery: "Check available disk space and folder permissions, then retry."
            ))
        }
    }

    private static func patchCommand(sourceURL: URL, patchURL: URL, checkOnly: Bool) -> CommandRequest {
        var arguments = ["-C", sourceURL.path, "apply", "--recount"]
        if checkOnly {
            arguments.append("--check")
        }
        arguments.append(patchURL.path)
        return CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            timeout: .seconds(30)
        )
    }

    private func buildRevisionIsCurrent(for configuration: RunnerBuildConfiguration) -> Bool {
        guard patchURL != nil else { return true }
        return Self.marker(at: Self.buildRevisionMarkerURL(for: configuration)) ==
            controlExtensionIdentity
    }

    private func removeBuildRevisionMarker(for configuration: RunnerBuildConfiguration) throws {
        guard patchURL != nil else { return }
        let markerURL = Self.buildRevisionMarkerURL(for: configuration)
        if FileManager.default.fileExists(atPath: markerURL.path) {
            try FileManager.default.removeItem(at: markerURL)
        }
    }

    private func writeBuildRevisionMarker(for configuration: RunnerBuildConfiguration) throws {
        guard patchURL != nil else { return }
        do {
            try Data(controlExtensionIdentity.utf8).write(
                to: Self.buildRevisionMarkerURL(for: configuration),
                options: .atomic
            )
        } catch {
            throw RunnerBuildError.buildFailed(
                RunnerBuildIssue(
                    code: "LUM-BUILD-013",
                    title: "Runner cache could not be finalized",
                    explanation: "The signed runner was built, but Lumina could not record its control-extension revision.",
                    recovery: "Check the Lumina cache folder permissions and build the runner again.",
                    retryIsSafe: true
                )
            )
        }
    }

    private static func marker(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var controlExtensionIdentity: String {
        guard let patchURL else { return LuminaWebDriverAgentPatch.cacheIdentity }
        return LuminaWebDriverAgentPatch.cacheIdentity(for: patchURL)
    }

    private static func patchIssue(title: String, recovery: String) -> RunnerBuildIssue {
        RunnerBuildIssue(
            code: "LUM-BUILD-012",
            title: title,
            explanation: "Lumina applies its reviewed input-event extension to a private copy of the pinned WebDriverAgent source.",
            recovery: recovery,
            retryIsSafe: true
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
