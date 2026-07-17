import Foundation

nonisolated protocol EnvironmentChecking: Sendable {
    func checkEnvironment() async throws -> EnvironmentReport
}

nonisolated struct EnvironmentChecker: EnvironmentChecking {
    private let processRunner: any ProcessRunning
    private let systemInformationProvider: any SystemInformationProviding
    private let certificateProvider: any DeveloperCertificateProviding
    private let now: @Sendable () -> Date

    init(
        processRunner: any ProcessRunning,
        systemInformationProvider: any SystemInformationProviding,
        certificateProvider: any DeveloperCertificateProviding,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.processRunner = processRunner
        self.systemInformationProvider = systemInformationProvider
        self.certificateProvider = certificateProvider
        self.now = now
    }

    func checkEnvironment() async throws -> EnvironmentReport {
        let systemSnapshot = try systemInformationProvider.snapshot()
        var checks = systemChecks(from: systemSnapshot)

        let developerDirectory = try await processRunner.run(
            CommandRequest(executableURL: URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["-p"])
        )
        checks.append(developerDirectoryCheck(developerDirectory))

        async let xcodeVersion = processRunner.run(
            CommandRequest(executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"), arguments: ["-version"])
        )
        async let firstLaunch = processRunner.run(
            CommandRequest(executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"), arguments: ["-checkFirstLaunchStatus"])
        )
        async let installedSDKs = processRunner.run(
            CommandRequest(executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"), arguments: ["-showsdks", "-json"])
        )
        async let commandLineTools = processRunner.run(
            CommandRequest(executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["--find", "clang"])
        )
        async let certificates = certificateResult()

        let versionResult = try await xcodeVersion
        checks.append(xcodeCheck(versionResult))
        checks.append(firstLaunchCheck(try await firstLaunch))
        checks.append(commandLineToolsCheck(try await commandLineTools))
        checks.append(iOSSDKCheck(try await installedSDKs))
        checks.append(
            EnvironmentCheckResult(
                requirement: .helper,
                status: .passed,
                summary: "No external environment-check helper is required",
                details: "Helper selection and integrity validation begin with device transport work.",
                remediation: nil,
                errorCode: nil
            )
        )

        let certificateOutcome = await certificates
        checks.append(certificateOutcome.check)

        return EnvironmentReport(
            checks: EnvironmentRequirement.allCases.compactMap { requirement in
                checks.first { $0.requirement == requirement }
            },
            certificates: certificateOutcome.certificates,
            completedAt: now()
        )
    }

    private func certificateResult() async -> (check: EnvironmentCheckResult, certificates: [DeveloperCertificateIdentity]) {
        do {
            let certificates = try await certificateProvider.developmentCertificates()
            let usable = certificates.filter(\.canSign)
            if usable.isEmpty {
                return (
                    EnvironmentCheckResult(
                        requirement: .developmentCertificate,
                        status: .failed,
                        summary: "No usable Apple Development identity found",
                        details: certificates.isEmpty
                            ? "No Apple Development certificates are present in the login keychain."
                            : "Certificates were found, but none are both current and backed by a private key.",
                        remediation: "Open Xcode Settings → Accounts, select your team, choose Manage Certificates, and create an Apple Development certificate.",
                        errorCode: "LUM-SIGN-003"
                    ),
                    certificates
                )
            }
            return (
                EnvironmentCheckResult(
                    requirement: .developmentCertificate,
                    status: .passed,
                    summary: usable.count == 1
                        ? "1 usable Apple Development identity"
                        : "\(usable.count) usable Apple Development identities",
                    details: "Private-key availability and certificate validity were verified locally.",
                    remediation: nil,
                    errorCode: nil
                ),
                certificates
            )
        } catch {
            return (
                EnvironmentCheckResult(
                    requirement: .developmentCertificate,
                    status: .failed,
                    summary: "Could not inspect development identities",
                    details: "The login keychain query failed.",
                    remediation: "Unlock the login keychain, then run the check again.",
                    errorCode: "LUM-SIGN-004"
                ),
                []
            )
        }
    }

    private func systemChecks(from snapshot: SystemSnapshot) -> [EnvironmentCheckResult] {
        let version = snapshot.operatingSystemVersion
        let versionText = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let macOSCheck = EnvironmentCheckResult(
            requirement: .macOS,
            status: version.majorVersion >= 14 ? .passed : .failed,
            summary: "macOS \(versionText)",
            details: version.majorVersion >= 14 ? "Meets the macOS 14 minimum." : "Lumina requires macOS 14 or newer.",
            remediation: version.majorVersion >= 14 ? nil : "Update macOS to version 14 or newer.",
            errorCode: version.majorVersion >= 14 ? nil : "LUM-ENV-003"
        )

        let architectureCheck = EnvironmentCheckResult(
            requirement: .architecture,
            status: snapshot.architecture == "Unknown" ? .warning : .passed,
            summary: snapshot.architecture,
            details: nil,
            remediation: nil,
            errorCode: nil
        )

        let diskCheck: EnvironmentCheckResult
        if let bytes = snapshot.availableDiskSpace {
            let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let minimum: Int64 = 2_000_000_000
            let recommended: Int64 = 10_000_000_000
            diskCheck = EnvironmentCheckResult(
                requirement: .diskSpace,
                status: bytes < minimum ? .failed : (bytes < recommended ? .warning : .passed),
                summary: "\(formatted) available",
                details: bytes < recommended ? "At least 10 GB is recommended for Xcode build products and result bundles." : nil,
                remediation: bytes < minimum ? "Free at least 2 GB before building the automation runner." : nil,
                errorCode: bytes < minimum ? "LUM-ENV-004" : nil
            )
        } else {
            diskCheck = EnvironmentCheckResult(
                requirement: .diskSpace,
                status: .warning,
                summary: "Available space could not be determined",
                details: nil,
                remediation: "Confirm that enough space is available for Xcode build products.",
                errorCode: nil
            )
        }
        return [macOSCheck, architectureCheck, diskCheck]
    }

    private func developerDirectoryCheck(_ result: CommandResult) -> EnvironmentCheckResult {
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let isXcodePath = result.succeeded && path.contains(".app/Contents/Developer")
        return EnvironmentCheckResult(
            requirement: .developerDirectory,
            status: isXcodePath ? .passed : .failed,
            summary: isXcodePath ? path : "A full Xcode developer directory is not selected",
            details: result.succeeded ? nil : redactedCommandFailure(result),
            remediation: isXcodePath ? nil : "Select Xcode in Xcode Settings → Locations, or explicitly select its Developer directory with xcode-select.",
            errorCode: isXcodePath ? nil : "LUM-ENV-005"
        )
    }

    private func xcodeCheck(_ result: CommandResult) -> EnvironmentCheckResult {
        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = Self.parseXcodeVersion(output)
        return EnvironmentCheckResult(
            requirement: .xcode,
            status: result.succeeded && version != nil ? .passed : .failed,
            summary: version.map { "Xcode \($0.version) (\($0.build))" } ?? "Xcode not available",
            details: result.succeeded ? nil : redactedCommandFailure(result),
            remediation: result.succeeded ? nil : "Install Xcode from the App Store, open it once, and finish installing components.",
            errorCode: result.succeeded ? nil : "LUM-ENV-001"
        )
    }

    private func firstLaunchCheck(_ result: CommandResult) -> EnvironmentCheckResult {
        EnvironmentCheckResult(
            requirement: .xcodeFirstLaunch,
            status: result.succeeded ? .passed : .failed,
            summary: result.succeeded ? "Xcode components and license are ready" : "Xcode first-launch setup is incomplete",
            details: result.succeeded ? nil : redactedCommandFailure(result),
            remediation: result.succeeded ? nil : "Open Xcode and complete its license and component installation prompts.",
            errorCode: result.succeeded ? nil : "LUM-ENV-006"
        )
    }

    private func commandLineToolsCheck(_ result: CommandResult) -> EnvironmentCheckResult {
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return EnvironmentCheckResult(
            requirement: .commandLineTools,
            status: result.succeeded && !path.isEmpty ? .passed : .failed,
            summary: result.succeeded && !path.isEmpty ? "clang is available" : "Command Line Tools are unavailable",
            details: result.succeeded ? path : redactedCommandFailure(result),
            remediation: result.succeeded ? nil : "Open Xcode Settings → Locations and select Command Line Tools.",
            errorCode: result.succeeded ? nil : "LUM-ENV-007"
        )
    }

    private func iOSSDKCheck(_ result: CommandResult) -> EnvironmentCheckResult {
        let sdks = result.succeeded ? Self.parseSDKs(result.standardOutput) : []
        let deviceSDKs = sdks.filter { $0.platform == "iphoneos" }
        return EnvironmentCheckResult(
            requirement: .iOSSDK,
            status: deviceSDKs.isEmpty ? .failed : .passed,
            summary: deviceSDKs.map(\.displayName).joined(separator: ", ").nilIfEmpty ?? "No physical-device iOS SDK installed",
            details: result.succeeded ? nil : redactedCommandFailure(result),
            remediation: deviceSDKs.isEmpty ? "Install the iOS platform from Xcode Settings → Components." : nil,
            errorCode: deviceSDKs.isEmpty ? "LUM-ENV-002" : nil
        )
    }

    private func redactedCommandFailure(_ result: CommandResult) -> String? {
        let text = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "The command exited with status \(result.exitCode)." : String(text.prefix(300))
    }

    static func parseXcodeVersion(_ output: String) -> (version: String, build: String)? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard let versionLine = lines.first(where: { $0.hasPrefix("Xcode ") }),
              let buildLine = lines.first(where: { $0.hasPrefix("Build version ") }) else {
            return nil
        }
        return (
            String(versionLine.dropFirst("Xcode ".count)),
            String(buildLine.dropFirst("Build version ".count))
        )
    }

    static func parseSDKs(_ output: String) -> [SDKDescriptor] {
        guard let data = output.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SDKDescriptor].self, from: data)) ?? []
    }
}

nonisolated struct SDKDescriptor: Codable, Equatable, Sendable {
    let canonicalName: String
    let displayName: String
    let platform: String
    let sdkVersion: String
}

private nonisolated extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
