import Combine
import Foundation

@MainActor
final class ReceiverPOCModel: ObservableObject {
    @Published private(set) var receiverName = "Lumina"
    @Published private(set) var deviceID = "—"
    @Published private(set) var pairingIdentifier = "—"
    @Published private(set) var raopInstanceName = "—"
    @Published private(set) var portText = "—"
    @Published private(set) var statusText = "Not started"
    @Published private(set) var isActive = false
    @Published private(set) var isRunning = false
    @Published private(set) var hasFailure = false
    @Published private(set) var airPlayPublished = false
    @Published private(set) var raopPublished = false
    @Published private(set) var events: [String] = []

    private var publisher: BonjourServicePublisher?
    private var didStart = false

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        startAdvertising()
    }

    func toggleAdvertising() {
        isActive ? stopAdvertising() : startAdvertising()
    }

    private func startAdvertising() {
        guard publisher == nil else { return }

        do {
            let identity = try ReceiverIdentityStore.loadOrCreate()
            receiverName = ReceiverName.make()
            deviceID = identity.deviceID
            pairingIdentifier = identity.pairingIdentifier
            raopInstanceName = AirPlayTXTRecord.raopInstanceName(
                receiverName: receiverName,
                deviceID: identity.deviceID
            )

            hasFailure = false
            airPlayPublished = false
            raopPublished = false
            portText = "Starting…"
            statusText = "Opening an isolated listener"
            appendEvent("Starting advertisement")

            let publisher = BonjourServicePublisher(
                receiverName: receiverName,
                identity: identity
            ) { [weak self] event in
                self?.handle(event)
            }
            self.publisher = publisher
            isActive = true
            publisher.start()
        } catch {
            hasFailure = true
            statusText = "Could not create the experimental receiver identity"
            appendEvent("Identity error: \(error.localizedDescription)")
        }
    }

    private func stopAdvertising() {
        publisher?.stop()
        publisher = nil
        isActive = false
        isRunning = false
        airPlayPublished = false
        raopPublished = false
        portText = "—"
        statusText = "Advertisement stopped"
        appendEvent("Stopped both Bonjour services")
    }

    private func handle(_ event: BonjourPublisherEvent) {
        switch event {
        case let .listenerReady(port):
            isRunning = true
            portText = String(port)
            statusText = "Publishing receiver services"
            appendEvent("TCP listener ready on port \(port)")

        case let .listenerWaiting(message):
            isRunning = false
            airPlayPublished = false
            raopPublished = false
            portText = "Waiting…"
            statusText = "Waiting for the local network"
            appendEvent("Listener waiting: \(message)")

        case let .servicePublished(type):
            if type == AirPlayServiceDescriptor.airPlayType {
                airPlayPublished = true
            } else if type == AirPlayServiceDescriptor.raopType {
                raopPublished = true
            }
            statusText = airPlayPublished && raopPublished
                ? "Visible on the local network"
                : "Publishing receiver services"
            appendEvent("Published \(type)")

        case let .requestReceived(requestLine):
            appendEvent("iPhone request: \(requestLine)")
            statusText = "A sender reached the proof listener"

        case let .diagnostic(message):
            appendEvent(message)

        case let .failure(message):
            publisher = nil
            isActive = false
            isRunning = false
            airPlayPublished = false
            raopPublished = false
            hasFailure = true
            statusText = message
            appendEvent("Error: \(message)")

        case .stopped:
            publisher = nil
            isActive = false
            isRunning = false
        }
    }

    private func appendEvent(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        events.append("[\(formatter.string(from: Date()))] \(message)")
        if events.count > 30 {
            events.removeFirst(events.count - 30)
        }
    }
}
