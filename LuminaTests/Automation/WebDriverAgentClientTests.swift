import Foundation
import Testing
@testable import Lumina

@Suite("WebDriverAgent client", .serialized)
struct WebDriverAgentClientTests {
    @Test("Creates a session and performs typed device commands")
    func commands() async throws {
        let requests = RequestRecorder()
        MockURLProtocol.handler = { request in
            requests.append(request)
            let path = request.url?.path ?? ""
            let json: String
            switch path {
            case "/session":
                json = #"{"value":{"sessionId":"SESSION-1","capabilities":{}}}"#
            case "/session/SESSION-1/wda/screen":
                json = #"{"value":{"screenSize":{"width":430,"height":932},"statusBarSize":{"width":430,"height":59},"scale":3}}"#
            case "/session/SESSION-1/orientation":
                json = #"{"value":"PORTRAIT"}"#
            case "/session/SESSION-1/wda/activeAppInfo":
                json = #"{"value":{"pid":42,"bundleId":"com.apple.springboard","name":"SpringBoard","processArguments":{"args":[],"env":{}}}}"#
            case "/session/SESSION-1/screenshot":
                json = #"{"value":"aW1hZ2U="}"#
            default:
                json = #"{"value":null}"#
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = WebDriverAgentClient(
            endpoint: URL(string: "http://127.0.0.1:8100")!,
            urlSession: URLSession(configuration: configuration)
        )

        let session = try await client.createSession()
        let snapshot = try await client.snapshot(session: session)
        try await client.tap(at: AutomationPoint(x: 100, y: 200), session: session)
        try await client.drag(
            from: AutomationPoint(x: 100, y: 700),
            to: AutomationPoint(x: 100, y: 200),
            duration: 0.2,
            session: session
        )
        try await client.goHome()
        try await client.configureVideoStream(session: session, profile: .highQuality)
        await client.deleteSession(session)

        #expect(session.id == "SESSION-1")
        #expect(snapshot.screen.screenSize.width == 430)
        #expect(snapshot.orientation == .portrait)
        #expect(snapshot.activeApplication.bundleId == "com.apple.springboard")
        #expect(snapshot.screenshot == Data("image".utf8))
        #expect(requests.paths.contains("/session/SESSION-1/wda/tap"))
        #expect(requests.paths.contains("/session/SESSION-1/wda/dragfromtoforduration"))
        #expect(requests.paths.contains("/wda/homescreen"))
        #expect(requests.paths.contains("/session/SESSION-1/appium/settings"))

        let settingsRequest = requests.request(for: "/session/SESSION-1/appium/settings")
        let settingsBody = try #require(settingsRequest?.httpBody)
        let settingsJSON = try #require(JSONSerialization.jsonObject(with: settingsBody) as? [String: Any])
        let settings = try #require(settingsJSON["settings"] as? [String: Any])
        #expect(settings["mjpegServerFramerate"] as? Int == 20)
        #expect(settings["mjpegServerScreenshotQuality"] as? Int == 85)
        #expect(settings["mjpegScalingFactor"] as? Int == 100)

        #expect(requests.request(for: "/session")?.httpMethod == "POST")
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var paths: [String] {
        lock.withLock { requests.compactMap(\.url?.path) }
    }

    func append(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }

    func request(for path: String) -> URLRequest? {
        lock.withLock { requests.first { $0.url?.path == path } }
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
