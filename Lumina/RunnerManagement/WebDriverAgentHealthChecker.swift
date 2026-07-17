import Foundation

nonisolated enum WebDriverAgentHealthError: Error, Equatable, Sendable {
    case invalidResponse
    case notReady(message: String)
}

nonisolated protocol WebDriverAgentHealthChecking: Sendable {
    func status(at endpoint: URL) async throws -> WebDriverAgentStatus
}

nonisolated final class URLSessionWebDriverAgentHealthChecker: WebDriverAgentHealthChecking, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 2
            configuration.timeoutIntervalForResource = 3
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func status(at endpoint: URL) async throws -> WebDriverAgentStatus {
        let statusURL = endpoint.appendingPathComponent("status")
        var request = URLRequest(url: statusURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw WebDriverAgentHealthError.invalidResponse
        }
        return try Self.decodeStatus(data)
    }

    static func decodeStatus(_ data: Data) throws -> WebDriverAgentStatus {
        guard let envelope = try? JSONDecoder().decode(StatusEnvelope.self, from: data) else {
            throw WebDriverAgentHealthError.invalidResponse
        }
        guard envelope.value.ready else {
            throw WebDriverAgentHealthError.notReady(message: envelope.value.message)
        }
        return WebDriverAgentStatus(
            ready: envelope.value.ready,
            message: envelope.value.message,
            device: envelope.value.device,
            operatingSystemName: envelope.value.os?.name,
            operatingSystemVersion: envelope.value.os?.version,
            productBundleIdentifier: envelope.value.build?.productBundleIdentifier
        )
    }
}

private nonisolated struct StatusEnvelope: Decodable {
    let value: Value

    struct Value: Decodable {
        let ready: Bool
        let message: String
        let device: String?
        let os: OperatingSystem?
        let build: Build?
    }

    struct OperatingSystem: Decodable {
        let name: String?
        let version: String?
    }

    struct Build: Decodable {
        let productBundleIdentifier: String?
    }
}
