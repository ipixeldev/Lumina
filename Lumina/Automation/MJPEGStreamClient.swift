import Foundation
import Network
import OSLog

nonisolated final class MJPEGStreamClient: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = MJPEGFrameParser()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var connection: NWConnection?
    private var responseBuffer = Data()
    private var receivedResponseHeader = false
    private var reportedFirstFrame = false
    private static let logger = Logger(subsystem: "com.iPixeldev.Lumina", category: "MJPEG")

    func frames(from endpoint: URL) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            guard let host = endpoint.host,
                  let portValue = endpoint.port,
                  let rawPort = UInt16(exactly: portValue),
                  let port = NWEndpoint.Port(rawValue: rawPort) else {
                continuation.finish(throwing: WebDriverAgentIssue(
                    code: "LUM-STREAM-001",
                    message: "The iPhone video endpoint is invalid."
                ))
                return
            }
            self.lock.lock()
            self.continuation = continuation
            self.parser.reset()
            self.responseBuffer.removeAll(keepingCapacity: true)
            self.receivedResponseHeader = false
            self.reportedFirstFrame = false
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            self.connection = connection
            self.lock.unlock()

            continuation.onTermination = { [weak self] _ in self?.stop() }
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                switch state {
                case .ready:
                    let path = endpoint.path.isEmpty ? "/" : endpoint.path
                    let request = "GET \(path) HTTP/1.1\r\nHost: \(host):\(portValue)\r\nAccept: multipart/x-mixed-replace\r\nConnection: keep-alive\r\n\r\n"
                    connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                        if let error { self.finish(throwing: error) }
                    })
                    self.receive(on: connection)
                case let .failed(error):
                    self.finish(throwing: error)
                case .cancelled:
                    break
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "com.iPixeldev.Lumina.mjpeg", qos: .userInteractive))
        }
    }

    func stop() {
        lock.lock()
        let connection = self.connection
        self.connection = nil
        continuation = nil
        responseBuffer.removeAll(keepingCapacity: false)
        receivedResponseHeader = false
        reportedFirstFrame = false
        parser.reset()
        lock.unlock()
        connection?.cancel()
    }

    private func process(_ data: Data) {
        lock.lock()
        let payload: Data
        if receivedResponseHeader {
            payload = data
        } else {
            responseBuffer.append(data)
            let separator = Data("\r\n\r\n".utf8)
            guard let range = responseBuffer.range(of: separator) else {
                lock.unlock()
                return
            }
            let header = String(decoding: responseBuffer[..<range.lowerBound], as: UTF8.self)
            guard header.contains(" 200 ") else {
                lock.unlock()
                finish(throwing: WebDriverAgentIssue(
                    code: "LUM-STREAM-001",
                    message: "The iPhone video stream could not be opened."
                ))
                return
            }
            payload = Data(responseBuffer[range.upperBound...])
            responseBuffer.removeAll(keepingCapacity: false)
            receivedResponseHeader = true
        }
        let frames = parser.append(payload)
        let shouldReportFirstFrame = !frames.isEmpty && !reportedFirstFrame
        if shouldReportFirstFrame { reportedFirstFrame = true }
        let continuation = self.continuation
        lock.unlock()
        if shouldReportFirstFrame { Self.logger.info("MJPEG stream decoded its first frame") }
        for frame in frames {
            continuation?.yield(frame)
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty { self.process(data) }
            if let error {
                self.finish(throwing: error)
            } else if complete {
                self.finish(throwing: WebDriverAgentIssue(
                    code: "LUM-STREAM-002",
                    message: "The iPhone video stream ended unexpectedly."
                ))
            } else {
                self.receive(on: connection)
            }
        }
    }

    private func finish(throwing error: Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish(throwing: error)
    }
}

nonisolated struct MJPEGFrameParser {
    private var buffer = Data()
    private var expectedFrameLength: Int?

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        let headerSeparator = Data("\r\n\r\n".utf8)

        while true {
            if let expectedFrameLength {
                guard buffer.count >= expectedFrameLength else { break }
                frames.append(buffer.prefix(expectedFrameLength))
                buffer.removeFirst(expectedFrameLength)
                self.expectedFrameLength = nil
                while buffer.starts(with: Data("\r\n".utf8)) { buffer.removeFirst(2) }
                continue
            }

            guard let headerRange = buffer.range(of: headerSeparator) else {
                if buffer.count > 65_536 { buffer.removeAll(keepingCapacity: true) }
                break
            }
            let headerData = buffer[..<headerRange.lowerBound]
            buffer.removeSubrange(..<headerRange.upperBound)
            guard let header = String(data: headerData, encoding: .utf8),
                  let lengthLine = header.components(separatedBy: .newlines).first(where: {
                      $0.lowercased().contains("content-length:")
                  }),
                  let length = Int(lengthLine.split(separator: ":", maxSplits: 1)[1]
                      .trimmingCharacters(in: .whitespacesAndNewlines)),
                  length > 0,
                  length <= 20_000_000 else { continue }
            expectedFrameLength = length
        }
        return frames
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        expectedFrameLength = nil
    }
}
