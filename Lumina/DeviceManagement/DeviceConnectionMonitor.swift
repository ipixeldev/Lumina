import Foundation

nonisolated enum DeviceDiscoveryUpdate: Sendable {
    case snapshot(DeviceDiscoverySnapshot)
    case failed(message: String)
}

nonisolated protocol DeviceConnectionMonitoring: Sendable {
    func updates() -> AsyncStream<DeviceDiscoveryUpdate>
}

nonisolated struct PollingDeviceConnectionMonitor: DeviceConnectionMonitoring {
    private let discoveryService: any DeviceDiscovering
    private let interval: Duration
    private let maximumBackoff: Duration

    init(
        discoveryService: any DeviceDiscovering,
        interval: Duration = .seconds(2),
        maximumBackoff: Duration = .seconds(15)
    ) {
        self.discoveryService = discoveryService
        self.interval = interval
        self.maximumBackoff = maximumBackoff
    }

    func updates() -> AsyncStream<DeviceDiscoveryUpdate> {
        AsyncStream { continuation in
            let task = Task {
                var lastDevices: [Device]?
                var failureCount = 0

                while !Task.isCancelled {
                    do {
                        let snapshot = try await discoveryService.discoverDevices()
                        failureCount = 0
                        if snapshot.devices != lastDevices {
                            lastDevices = snapshot.devices
                            continuation.yield(.snapshot(snapshot))
                        }
                        try await Task.sleep(for: interval)
                    } catch is CancellationError {
                        break
                    } catch {
                        failureCount += 1
                        let message = (error as? DeviceDiscoveryError)?.userMessage
                            ?? "Connected iPhones could not be inspected."
                        continuation.yield(.failed(message: message))
                        let seconds = min(pow(2.0, Double(failureCount - 1)) * 2.0, maximumBackoff.secondsValue)
                        do {
                            try await Task.sleep(for: .seconds(seconds))
                        } catch {
                            break
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private nonisolated extension Duration {
    var secondsValue: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
