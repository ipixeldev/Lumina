import Foundation

nonisolated protocol DeviceDiscovering: Sendable {
    func discoverDevices() async throws -> DeviceDiscoverySnapshot
}

nonisolated enum DeviceDiscoveryError: Error, Equatable, Sendable {
    case appleToolFailed(tool: String, exitCode: Int32)
    case resultFileMissing
    case invalidStructuredOutput(tool: String)

    var userMessage: String {
        switch self {
        case let .appleToolFailed(tool, _):
            "\(tool) could not inspect connected devices. Confirm Xcode is selected and try again."
        case .resultFileMissing:
            "Apple's device tool did not create its structured result file."
        case let .invalidStructuredOutput(tool):
            "\(tool) returned a device format this MirrorBridge version does not understand."
        }
    }
}

nonisolated struct AppleDeviceDiscoveryService: DeviceDiscovering {
    private let processRunner: any ProcessRunning
    private let temporaryDirectory: URL
    private let now: @Sendable () -> Date
    private let logger: StructuredLogging

    init(
        processRunner: any ProcessRunning,
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        now: @escaping @Sendable () -> Date = Date.init,
        logger: StructuredLogging = StructuredLogger()
    ) {
        self.processRunner = processRunner
        self.temporaryDirectory = temporaryDirectory
        self.now = now
        self.logger = logger
    }

    func discoverDevices() async throws -> DeviceDiscoverySnapshot {
        let resultURL = temporaryDirectory
            .appendingPathComponent("mirrorbridge-devices-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { removeTemporaryFile(resultURL) }

        async let deviceControl = processRunner.run(
            CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: [
                    "devicectl", "list", "devices", "--timeout", "10",
                    "--json-output", resultURL.path, "--quiet"
                ],
                timeout: .seconds(15)
            )
        )
        async let xcodeDevices = processRunner.run(
            CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["xcdevice", "list", "--timeout", "1"],
                timeout: .seconds(8)
            )
        )

        let deviceControlResult = try await deviceControl
        guard deviceControlResult.succeeded else {
            throw DeviceDiscoveryError.appleToolFailed(tool: "devicectl", exitCode: deviceControlResult.exitCode)
        }
        let xcodeDeviceResult = try await xcodeDevices
        guard xcodeDeviceResult.succeeded else {
            throw DeviceDiscoveryError.appleToolFailed(tool: "xcdevice", exitCode: xcodeDeviceResult.exitCode)
        }
        guard FileManager.default.fileExists(atPath: resultURL.path) else {
            throw DeviceDiscoveryError.resultFileMissing
        }

        let deviceControlData = try Data(contentsOf: resultURL)
        guard let devices = AppleDeviceParser.parseDevices(
            deviceControlData: deviceControlData,
            xcodeDeviceData: Data(xcodeDeviceResult.standardOutput.utf8)
        ) else {
            throw DeviceDiscoveryError.invalidStructuredOutput(tool: "devicectl/xcdevice")
        }

        let devicesWithLockState = await withTaskGroup(of: Device.self) { group in
            for device in devices {
                group.addTask {
                    let lockState = await lockState(for: device.id)
                    return device.withLockState(lockState)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        return DeviceDiscoverySnapshot(
            devices: devicesWithLockState.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            discoveredAt: now()
        )
    }

    private func lockState(for identifier: String) async -> DeviceLockState {
        let resultURL = temporaryDirectory
            .appendingPathComponent("mirrorbridge-lock-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { removeTemporaryFile(resultURL) }

        do {
            let result = try await processRunner.run(
                CommandRequest(
                    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                    arguments: [
                        "devicectl", "device", "info", "lockState", "--device", identifier,
                        "--timeout", "5", "--json-output", resultURL.path, "--quiet"
                    ],
                    timeout: .seconds(10)
                )
            )
            guard result.succeeded else {
                logger.debug("Current iPhone lock state is unavailable", category: .device)
                return .unknown
            }
            let data = try Data(contentsOf: resultURL)
            return AppleDeviceParser.parseLockState(data) ?? .unknown
        } catch {
            logger.debug("Current iPhone lock state could not be queried", category: .device)
            return .unknown
        }
    }

    private func removeTemporaryFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.error("A temporary Apple device result could not be removed", category: .security)
        }
    }
}
