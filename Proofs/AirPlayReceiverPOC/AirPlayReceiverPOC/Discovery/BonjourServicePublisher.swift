@preconcurrency import Foundation
import Network

enum BonjourPublisherEvent: Sendable {
    case listenerReady(port: UInt16)
    case listenerWaiting(message: String)
    case servicePublished(type: String)
    case requestReceived(requestLine: String)
    case diagnostic(message: String)
    case failure(message: String)
    case stopped
}

@MainActor
final class BonjourServicePublisher: NSObject, NetServiceDelegate {
    private let receiverName: String
    private let identity: ReceiverIdentity
    private let onEvent: @MainActor @Sendable (BonjourPublisherEvent) -> Void

    private var listener: NWListener?
    private var airPlayService: NetService?
    private var raopService: NetService?
    private var activeGeneration: UUID?
    private var probes: [UUID: ReceiverConnectionProbe] = [:]

    private static let maximumConcurrentProbes = 4

    init(
        receiverName: String,
        identity: ReceiverIdentity,
        onEvent: @escaping @MainActor @Sendable (BonjourPublisherEvent) -> Void
    ) {
        self.receiverName = receiverName
        self.identity = identity
        self.onEvent = onEvent
    }

    func start() {
        guard listener == nil else { return }

        do {
            let listener = try NWListener(using: .tcp, on: .any)
            let generation = UUID()
            self.listener = listener
            activeGeneration = generation

            listener.stateUpdateHandler = { [weak self, weak listener] state in
                let snapshot: ListenerStateSnapshot
                switch state {
                case .ready:
                    if let port = listener?.port?.rawValue {
                        snapshot = .ready(port)
                    } else {
                        snapshot = .failed("The listener started without a published port.")
                    }
                case let .failed(error):
                    snapshot = .failed(error.localizedDescription)
                case let .waiting(error):
                    snapshot = .waiting(error.localizedDescription)
                case .cancelled:
                    snapshot = .cancelled
                default:
                    return
                }

                Task { @MainActor [weak self] in
                    self?.handle(snapshot, generation: generation)
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection, generation: generation)
                }
            }

            listener.start(queue: DispatchQueue(label: "com.ipixeldev.Lumina.AirPlayReceiverPOC.listener"))
        } catch {
            onEvent(.failure(message: error.localizedDescription))
        }
    }

    func stop() {
        activeGeneration = nil
        tearDownResources()
        onEvent(.stopped)
    }

    private func handle(_ state: ListenerStateSnapshot, generation: UUID) {
        guard activeGeneration == generation else { return }

        switch state {
        case let .ready(port):
            onEvent(.listenerReady(port: port))
            publishServices(port: Int32(port))
        case let .waiting(message):
            stopPublishedServices()
            onEvent(.listenerWaiting(message: message))
        case let .failed(message):
            fail("Listener failed: \(message)")
        case .cancelled:
            activeGeneration = nil
            tearDownResources()
            onEvent(.stopped)
        }
    }

    private func accept(_ connection: NWConnection, generation: UUID) {
        guard activeGeneration == generation else {
            connection.cancel()
            return
        }
        guard probes.count < Self.maximumConcurrentProbes else {
            connection.cancel()
            onEvent(.diagnostic(message: "Rejected a sender connection because the proof limit is active."))
            return
        }

        let identifier = UUID()
        let eventSink = onEvent
        let probe = ReceiverConnectionProbe(
            connection: connection,
            report: { event in
                Task { @MainActor in
                    eventSink(event)
                }
            },
            didFinish: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.probes.removeValue(forKey: identifier)
                }
            }
        )
        probes[identifier] = probe
        probe.start()
    }

    private func publishServices(port: Int32) {
        stopPublishedServices()

        do {
            let airPlay = NetService(
                domain: "local.",
                type: "\(AirPlayServiceDescriptor.airPlayType).",
                name: receiverName,
                port: port
            )
            airPlay.delegate = self
            airPlay.setTXTRecord(NetService.data(fromTXTRecord: try AirPlayTXTRecord.airPlay(identity: identity)))

            let raop = NetService(
                domain: "local.",
                type: "\(AirPlayServiceDescriptor.raopType).",
                name: AirPlayTXTRecord.raopInstanceName(
                    receiverName: receiverName,
                    deviceID: identity.deviceID
                ),
                port: port
            )
            raop.delegate = self
            raop.setTXTRecord(NetService.data(fromTXTRecord: try AirPlayTXTRecord.raop(identity: identity)))

            airPlayService = airPlay
            raopService = raop
            airPlay.publish()
            raop.publish()
        } catch {
            fail("Could not encode the Bonjour records: \(error.localizedDescription)")
        }
    }

    nonisolated func netServiceDidPublish(_ sender: NetService) {
        let identifier = ObjectIdentifier(sender)
        let type = sender.type.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentService(identifier) else { return }
            self.onEvent(.servicePublished(type: type))
        }
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let identifier = ObjectIdentifier(sender)
        let type = sender.type.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let code = errorDict[NetService.errorCode]?.stringValue ?? "unknown"
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentService(identifier) else { return }
            self.fail("Could not publish \(type) (code \(code)).")
        }
    }

    private func isCurrentService(_ identifier: ObjectIdentifier) -> Bool {
        airPlayService.map(ObjectIdentifier.init) == identifier
            || raopService.map(ObjectIdentifier.init) == identifier
    }

    private func fail(_ message: String) {
        activeGeneration = nil
        tearDownResources()
        onEvent(.failure(message: message))
    }

    private func tearDownResources() {
        stopPublishedServices()
        listener?.cancel()
        listener = nil
        probes.values.forEach { $0.cancel() }
        probes.removeAll()
    }

    private func stopPublishedServices() {
        airPlayService?.stop()
        raopService?.stop()
        airPlayService = nil
        raopService = nil
    }
}

private enum ListenerStateSnapshot: Sendable {
    case ready(UInt16)
    case waiting(String)
    case failed(String)
    case cancelled
}

private final class ReceiverConnectionProbe: @unchecked Sendable {
    private static let queue = DispatchQueue(
        label: "com.ipixeldev.Lumina.AirPlayReceiverPOC.probe",
        attributes: .concurrent
    )
    private static let maximumRequestBytes = 16 * 1_024
    private static let timeout: Duration = .seconds(5)

    private let connection: NWConnection
    private let report: @Sendable (BonjourPublisherEvent) -> Void
    private let didFinish: @Sendable () -> Void
    private let finishLock = NSLock()
    private var state: State = .waitingForRequest
    private var timeoutWorkItem: DispatchWorkItem?

    init(
        connection: NWConnection,
        report: @escaping @Sendable (BonjourPublisherEvent) -> Void,
        didFinish: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.report = report
        self.didFinish = didFinish
    }

    func start() {
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.timeOut()
        }
        self.timeoutWorkItem = timeoutWorkItem
        Self.queue.asyncAfter(
            deadline: .now() + Self.timeout.timeInterval,
            execute: timeoutWorkItem
        )

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let path = self.connection.currentPath
                let peerEndpoint = path?.remoteEndpoint ?? self.connection.endpoint
                guard LocalPeerPolicy.permits(
                    remoteEndpoint: peerEndpoint,
                    localEndpoint: path?.localEndpoint
                ) else {
                    if self.finish() {
                        self.report(.diagnostic(message: "Rejected a sender connection from outside the local network."))
                    }
                    return
                }
                self.receiveFirstRequest()
            case let .failed(error):
                if self.finish() {
                    self.report(.diagnostic(message: "An incoming sender connection failed: \(error.localizedDescription)"))
                }
            default:
                break
            }
        }
        connection.start(queue: Self.queue)
    }

    func cancel() {
        _ = finish()
    }

    private func receiveFirstRequest() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maximumRequestBytes
        ) { [weak self] content, _, _, error in
            guard let self else { return }
            if let error {
                if self.finish() {
                    self.report(.diagnostic(message: "Could not read the sender's first request: \(error.localizedDescription)"))
                }
                return
            }

            guard self.beginResponse() else { return }
            let requestLine = Self.sanitizedRequestLine(from: content)
            self.report(.requestReceived(requestLine: requestLine))
            self.sendUnsupportedResponse(requestData: content)
        }
    }

    private static func sanitizedRequestLine(from data: Data?) -> String {
        guard
            let data,
            let request = String(data: data.prefix(1_024), encoding: .utf8),
            let firstLine = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first
        else {
            return "<binary or incomplete request>"
        }

        let printable = firstLine.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
        return String(String.UnicodeScalarView(printable)).prefix(256).description
    }

    private func sendUnsupportedResponse(requestData: Data?) {
        let cseq = Self.cseqValue(in: requestData) ?? "1"
        let response = """
        RTSP/1.0 501 Not Implemented\r
        CSeq: \(cseq)\r
        Server: Lumina-AirPlayReceiverPOC/0.1\r
        Content-Length: 0\r
        Connection: close\r
        \r
        """

        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                if self.finish() {
                    self.report(.diagnostic(message: "Could not send the proof response: \(error.localizedDescription)"))
                }
            } else {
                _ = self.finish()
            }
        })
    }

    private func timeOut() {
        if finish() {
            report(.diagnostic(message: "Closed a sender connection after the five-second proof deadline."))
        }
    }

    private func beginResponse() -> Bool {
        finishLock.lock()
        defer { finishLock.unlock() }
        guard state == .waitingForRequest else { return false }
        state = .responding
        return true
    }

    @discardableResult
    private func finish() -> Bool {
        finishLock.lock()
        guard state != .finished else {
            finishLock.unlock()
            return false
        }
        state = .finished
        let timeoutWorkItem = timeoutWorkItem
        self.timeoutWorkItem = nil
        finishLock.unlock()

        timeoutWorkItem?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        didFinish()
        return true
    }

    private static func cseqValue(in data: Data?) -> String? {
        guard
            let data,
            let request = String(data: data.prefix(4_096), encoding: .utf8)
        else {
            return nil
        }

        for line in request.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0].caseInsensitiveCompare("CSeq") == .orderedSame else {
                continue
            }
            let candidate = parts[1].trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, candidate.count <= 20, candidate.allSatisfy(\.isNumber) else {
                return nil
            }
            return candidate
        }
        return nil
    }

    private enum State {
        case waitingForRequest
        case responding
        case finished
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
