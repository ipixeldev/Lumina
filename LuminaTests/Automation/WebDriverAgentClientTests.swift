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
            case "/session/SESSION-1/wda/lumina/status":
                json = Self.controlStatusJSON
            case "/session/SESSION-1/wda/lumina/health":
                json = Self.controlHealthJSON
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
        try await client.configureInteraction(session: session, screen: snapshot.screen.screenSize)
        try await client.checkSessionHealth(session: session)
        let screenshotRequestsBeforeMetadata = requests.count(for: "/session/SESSION-1/screenshot")
        let deviceState = try await client.deviceState(session: session)
        try await client.tap(at: AutomationPoint(x: 100, y: 200), session: session)
        try await client.drag(
            from: AutomationPoint(x: 100, y: 700),
            to: AutomationPoint(x: 100, y: 200),
            duration: 0.2,
            session: session
        )
        try await client.goHome()
        try await client.pressButton(.volumeUp, session: session)
        try await client.rotate(to: .landscapeLeft, session: session)
        try await client.configureVideoStream(session: session, profile: .highQuality)
        await client.deleteSession(session)

        #expect(session.id == "SESSION-1")
        #expect(snapshot.screen.screenSize.width == 430)
        #expect(snapshot.orientation == .portrait)
        #expect(snapshot.activeApplication.bundleId == "com.apple.springboard")
        #expect(snapshot.screenshot == Data("image".utf8))
        #expect(deviceState.screen.screenSize.height == 932)
        #expect(deviceState.orientation == .portrait)
        #expect(requests.count(for: "/session/SESSION-1/screenshot") == screenshotRequestsBeforeMetadata)
        #expect(requests.paths.contains("/session/SESSION-1/wda/lumina/tap"))
        #expect(requests.paths.contains("/session/SESSION-1/wda/lumina/drag"))
        #expect(requests.paths.contains("/wda/homescreen"))
        #expect(requests.paths.contains("/session/SESSION-1/wda/pressButton"))
        #expect(requests.paths.contains("/session/SESSION-1/wda/lumina/orientation"))
        #expect(requests.paths.contains("/session/SESSION-1/appium/settings"))

        let orientationRequest = requests.request(for: "/session/SESSION-1/wda/lumina/orientation", method: "POST")
        let orientationBody = try #require(orientationRequest?.httpBody)
        let orientationJSON = try #require(JSONSerialization.jsonObject(with: orientationBody) as? [String: Any])
        #expect(orientationJSON["orientation"] as? String == "LANDSCAPE")

        let settings = try requests.requests(for: "/session/SESSION-1/appium/settings").map { request in
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            return try #require(json["settings"] as? [String: Any])
        }
        #expect(settings.contains { $0["defaultActiveApplication"] as? String == "com.apple.springboard" })
        #expect(settings.contains {
            $0["defaultActiveApplication"] as? String == "com.apple.springboard" &&
                $0["activeAppDetectionPoint"] as? String == "215.0,466.0"
        })
        #expect(settings.contains {
            $0["mjpegServerFramerate"] as? Int == 30 &&
                $0["mjpegServerScreenshotQuality"] as? Int == 80 &&
                $0["mjpegScalingFactor"] as? Int == 100
        })

        #expect(requests.request(for: "/session")?.httpMethod == "POST")
        #expect(requests.request(for: "/session/SESSION-1/wda/lumina/status", method: "GET") != nil)
        #expect(requests.request(for: "/session/SESSION-1/wda/lumina/health", method: "GET") != nil)
        #expect(requests.request(for: "/session/SESSION-1/wda/screen") == nil)
        #expect(requests.request(for: "/session/SESSION-1/orientation") == nil)
        #expect(requests.request(for: "/session/SESSION-1/wda/activeAppInfo") == nil)
    }

    @Test("Uses overlay-safe global input routes")
    func overlaySafeInputRoutes() async throws {
        let requests = RequestRecorder()
        MockURLProtocol.handler = { request in
            requests.append(request)
            return Self.response(request, json: #"{"value":null}"#)
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = WebDriverAgentClient(
            endpoint: URL(string: "http://127.0.0.1:8100")!,
            urlSession: URLSession(configuration: configuration)
        )
        let session = AutomationSession(id: "OVERLAY-SESSION")

        try await client.tap(at: AutomationPoint(x: 48.5, y: 120.25), session: session)
        try await client.drag(
            from: AutomationPoint(x: 48.5, y: 700),
            to: AutomationPoint(x: 200, y: 120.25),
            duration: 0,
            session: session
        )
        try await client.rotate(to: .landscapeLeft, session: session)

        let tapRequest = try #require(
            requests.request(for: "/session/OVERLAY-SESSION/wda/lumina/tap", method: "POST")
        )
        let tapBody = try #require(tapRequest.httpBody)
        let tapJSON = try #require(JSONSerialization.jsonObject(with: tapBody) as? [String: Any])
        #expect(tapJSON["x"] as? Double == 48.5)
        #expect(tapJSON["y"] as? Double == 120.25)

        let dragRequest = try #require(
            requests.request(for: "/session/OVERLAY-SESSION/wda/lumina/drag", method: "POST")
        )
        let dragBody = try #require(dragRequest.httpBody)
        let dragJSON = try #require(JSONSerialization.jsonObject(with: dragBody) as? [String: Any])
        #expect(dragJSON["fromX"] as? Double == 48.5)
        #expect(dragJSON["fromY"] as? Double == 700)
        #expect(dragJSON["toX"] as? Double == 200)
        #expect(dragJSON["toY"] as? Double == 120.25)
        #expect(dragJSON["duration"] as? Double == 0.05)

        let orientationRequest = try #require(
            requests.request(for: "/session/OVERLAY-SESSION/wda/lumina/orientation", method: "POST")
        )
        let orientationBody = try #require(orientationRequest.httpBody)
        let orientationJSON = try #require(JSONSerialization.jsonObject(with: orientationBody) as? [String: Any])
        #expect(orientationJSON["orientation"] as? String == "LANDSCAPE")

        #expect(requests.request(for: "/session/OVERLAY-SESSION/wda/tap") == nil)
        #expect(requests.request(for: "/session/OVERLAY-SESSION/wda/dragfromtoforduration") == nil)
        #expect(requests.request(for: "/session/OVERLAY-SESSION/orientation", method: "POST") == nil)
    }

    @Test("Keeps required screen data when overlay metadata is unavailable")
    func overlayMetadataFallback() async throws {
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/session":
                return Self.response(request, json: #"{"value":{"sessionId":"SESSION-1","capabilities":{}}}"#)
            case "/session/SESSION-1/wda/lumina/status":
                return Self.response(request, json: Self.controlStatusJSON)
            default:
                return Self.response(request, json: #"{"value":null}"#)
            }
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = WebDriverAgentClient(
            endpoint: URL(string: "http://127.0.0.1:8100")!,
            urlSession: URLSession(configuration: configuration)
        )

        let session = try await client.createSession()
        let state = try await client.deviceState(session: session)

        #expect(state.screen.screenSize == DeviceScreenInfo.Size(width: 430, height: 932))
        #expect(state.orientation == .portrait)
        #expect(state.activeApplication.bundleId == "com.apple.springboard")
        #expect(state.activeApplication.name == "SpringBoard")
        #expect(state.screen.screenSize.height == 932)
    }

    @Test("Rejects an installed runner without the current Lumina control extension")
    func staleControlExtensionIsRejected() async throws {
        let requests = RequestRecorder()
        MockURLProtocol.handler = { request in
            requests.append(request)
            switch request.url?.path {
            case "/session":
                return Self.response(
                    request,
                    json: #"{"value":{"sessionId":"STALE-SESSION","capabilities":{}}}"#
                )
            case "/session/STALE-SESSION/wda/lumina/status":
                return Self.response(
                    request,
                    json: #"{"value":{"revision":"overlay-input-v1","capabilities":["globalTap"],"screen":{"screenSize":{"width":430,"height":932},"statusBarSize":{"width":0,"height":0},"scale":3},"orientation":"PORTRAIT"}}"#
                )
            default:
                return Self.response(request, json: #"{"value":null}"#)
            }
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = WebDriverAgentClient(
            endpoint: URL(string: "http://127.0.0.1:8100")!,
            urlSession: URLSession(configuration: configuration)
        )

        do {
            _ = try await client.createSession()
            Issue.record("A stale control extension should not become control-ready")
        } catch let issue as WebDriverAgentIssue {
            #expect(issue.code == "LUM-WDA-105")
        }
        #expect(
            requests.request(for: "/session/STALE-SESSION", method: "DELETE") != nil
        )
    }

    private static var controlStatusJSON: String {
        """
        {"value":{"revision":"\(LuminaWebDriverAgentPatch.revision)","capabilities":["globalTap","globalDrag","globalOrientation","overlayScreen","overlayOrientation"],"screen":{"screenSize":{"width":430,"height":932},"statusBarSize":{"width":0,"height":0},"scale":3},"orientation":"PORTRAIT"}}
        """
    }

    private static var controlHealthJSON: String {
        """
        {"value":{"revision":"\(LuminaWebDriverAgentPatch.revision)","capabilities":["globalTap","globalDrag","globalOrientation","overlayScreen","overlayOrientation"]}}
        """
    }

    private static func response(
        _ request: URLRequest,
        statusCode: Int = 200,
        json: String
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
            Data(json.utf8)
        )
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var paths: [String] {
        lock.withLock { requests.compactMap(\.url?.path) }
    }

    func append(_ request: URLRequest) {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            if !body.isEmpty { recorded.httpBody = body }
        }
        lock.withLock { requests.append(recorded) }
    }

    func request(for path: String, method: String? = nil) -> URLRequest? {
        lock.withLock {
            requests.first {
                $0.url?.path == path && (method == nil || $0.httpMethod == method)
            }
        }
    }

    func requests(for path: String, method: String? = nil) -> [URLRequest] {
        lock.withLock {
            requests.filter {
                $0.url?.path == path && (method == nil || $0.httpMethod == method)
            }
        }
    }

    func count(for path: String) -> Int {
        lock.withLock { requests.count { $0.url?.path == path } }
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
