import Foundation

nonisolated struct AutomationSession: Equatable, Sendable {
    let id: String
}

nonisolated struct DeviceScreenInfo: Equatable, Sendable, Decodable {
    struct Size: Equatable, Sendable, Decodable {
        let width: Double
        let height: Double
    }

    let screenSize: Size
    let statusBarSize: Size
    let scale: Double
}

nonisolated struct ActiveApplicationInfo: Equatable, Sendable, Decodable {
    let bundleId: String?
    let name: String?
    let pid: Int?
}

nonisolated enum DeviceOrientation: String, Equatable, Sendable, Decodable {
    case portrait = "PORTRAIT"
    case portraitUpsideDown = "UIA_DEVICE_ORIENTATION_PORTRAIT_UPSIDEDOWN"
    case landscapeLeft = "LANDSCAPE"
    case landscapeRight = "UIA_DEVICE_ORIENTATION_LANDSCAPERIGHT"
    case unknown = "UNKNOWN"
}

nonisolated struct AutomationPoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

nonisolated struct AutomationSnapshot: Equatable, Sendable {
    let screen: DeviceScreenInfo
    let orientation: DeviceOrientation
    let activeApplication: ActiveApplicationInfo
    let screenshot: Data
}

nonisolated struct AutomationDeviceState: Equatable, Sendable {
    let screen: DeviceScreenInfo
    let orientation: DeviceOrientation
    let activeApplication: ActiveApplicationInfo
}

nonisolated enum StreamQualityProfile: String, CaseIterable, Identifiable, Sendable {
    case balanced
    case highQuality
    case smooth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: "Balanced"
        case .highQuality: "High Quality"
        case .smooth: "Smooth"
        }
    }

    var detail: String {
        switch self {
        case .balanced: "75% resolution · up to 30 FPS"
        case .highQuality: "Full resolution · up to 30 FPS"
        case .smooth: "50% resolution · up to 60 FPS"
        }
    }

    fileprivate var settings: [String: Any] {
        switch self {
        case .balanced:
            ["mjpegServerFramerate": 30, "mjpegServerScreenshotQuality": 65, "mjpegScalingFactor": 75]
        case .highQuality:
            ["mjpegServerFramerate": 30, "mjpegServerScreenshotQuality": 80, "mjpegScalingFactor": 100]
        case .smooth:
            ["mjpegServerFramerate": 60, "mjpegServerScreenshotQuality": 45, "mjpegScalingFactor": 50]
        }
    }
}

nonisolated struct WebDriverAgentIssue: Error, Equatable, Sendable, LocalizedError {
    let code: String
    let message: String

    var errorDescription: String? { message }
}

nonisolated protocol WebDriverAgentControlling: Sendable {
    func createSession() async throws -> AutomationSession
    func deleteSession(_ session: AutomationSession) async
    func deviceState(session: AutomationSession) async throws -> AutomationDeviceState
    func snapshot(session: AutomationSession) async throws -> AutomationSnapshot
    func screenshot(session: AutomationSession) async throws -> Data
    func tap(at point: AutomationPoint, session: AutomationSession) async throws
    func drag(from start: AutomationPoint, to end: AutomationPoint, duration: Double, session: AutomationSession) async throws
    func goHome() async throws
    func configureVideoStream(session: AutomationSession, profile: StreamQualityProfile) async throws
    func pressButton(_ button: DeviceButton, session: AutomationSession) async throws
    func lock() async throws
    func unlock() async throws
    func rotate(to orientation: DeviceOrientation, session: AutomationSession) async throws
}

nonisolated enum DeviceButton: String, Equatable, Sendable {
    case volumeUp = "volumeup"
    case volumeDown = "volumedown"
}

nonisolated actor WebDriverAgentClient: WebDriverAgentControlling {
    private let endpoint: URL
    private let urlSession: URLSession

    init(endpoint: URL, urlSession: URLSession = .shared) {
        self.endpoint = endpoint
        self.urlSession = urlSession
    }

    func createSession() async throws -> AutomationSession {
        let body: [String: Any] = [
            "capabilities": [
                "alwaysMatch": [
                    "platformName": "iOS",
                    "shouldWaitForQuiescence": false,
                    "disableAutomaticScreenshots": true
                ],
                "firstMatch": [[:]]
            ]
        ]
        let response: ValueEnvelope<SessionValue> = try await request("session", method: "POST", body: body)
        guard !response.value.sessionId.isEmpty else {
            throw WebDriverAgentIssue(code: "LUM-WDA-102", message: "WebDriverAgent returned an empty session identifier.")
        }
        return AutomationSession(id: response.value.sessionId)
    }

    func deleteSession(_ session: AutomationSession) async {
        do {
            let _: EmptyEnvelope = try await request("session/\(session.id)", method: "DELETE")
        } catch {
            // Runner shutdown still owns the transport lifecycle; session cleanup is best effort.
        }
    }

    func deviceState(session: AutomationSession) async throws -> AutomationDeviceState {
        async let screen: ValueEnvelope<DeviceScreenInfo> = request("session/\(session.id)/wda/screen")
        async let orientation: ValueEnvelope<DeviceOrientation> = request("session/\(session.id)/orientation")
        async let application: ValueEnvelope<ActiveApplicationInfo> = request("session/\(session.id)/wda/activeAppInfo")
        return try await AutomationDeviceState(
            screen: screen.value,
            orientation: orientation.value,
            activeApplication: application.value
        )
    }

    func snapshot(session: AutomationSession) async throws -> AutomationSnapshot {
        async let state = deviceState(session: session)
        async let image = screenshot(session: session)
        let stateValue = try await state
        return try await AutomationSnapshot(
            screen: stateValue.screen,
            orientation: stateValue.orientation,
            activeApplication: stateValue.activeApplication,
            screenshot: image
        )
    }

    func screenshot(session: AutomationSession) async throws -> Data {
        let response: ValueEnvelope<String> = try await request("session/\(session.id)/screenshot")
        guard let data = Data(base64Encoded: response.value), !data.isEmpty else {
            throw WebDriverAgentIssue(code: "LUM-WDA-103", message: "The iPhone returned an invalid screenshot.")
        }
        return data
    }

    func tap(at point: AutomationPoint, session: AutomationSession) async throws {
        let _: EmptyEnvelope = try await request(
            "session/\(session.id)/wda/tap",
            method: "POST",
            body: ["x": point.x, "y": point.y]
        )
    }

    func drag(from start: AutomationPoint, to end: AutomationPoint, duration: Double, session: AutomationSession) async throws {
        let _: EmptyEnvelope = try await request(
            "session/\(session.id)/wda/dragfromtoforduration",
            method: "POST",
            body: [
                "fromX": start.x, "fromY": start.y,
                "toX": end.x, "toY": end.y,
                "duration": max(0.05, duration)
            ]
        )
    }

    func goHome() async throws {
        let _: EmptyEnvelope = try await request("wda/homescreen", method: "POST")
    }

    func configureVideoStream(session: AutomationSession, profile: StreamQualityProfile) async throws {
        var settings = profile.settings
        settings["mjpegFixOrientation"] = true
        let _: EmptyEnvelope = try await request(
            "session/\(session.id)/appium/settings",
            method: "POST",
            body: [
                "settings": settings
            ]
        )
    }

    func pressButton(_ button: DeviceButton, session: AutomationSession) async throws {
        let _: EmptyEnvelope = try await request(
            "session/\(session.id)/wda/pressButton",
            method: "POST",
            body: ["name": button.rawValue]
        )
    }

    func lock() async throws {
        let _: EmptyEnvelope = try await request("wda/lock", method: "POST")
    }

    func unlock() async throws {
        let _: EmptyEnvelope = try await request("wda/unlock", method: "POST")
    }

    func rotate(to orientation: DeviceOrientation, session: AutomationSession) async throws {
        let _: EmptyEnvelope = try await request(
            "session/\(session.id)/orientation",
            method: "POST",
            body: ["orientation": orientation.rawValue]
        )
    }

    private func request<Response: Decodable & Sendable>(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil
    ) async throws -> Response {
        let url = path.split(separator: "/").reduce(endpoint) { url, component in
            url.appendingPathComponent(String(component))
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw Self.issue(from: data, fallbackCode: "LUM-WDA-100")
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw WebDriverAgentIssue(code: "LUM-WDA-101", message: "WebDriverAgent returned an unexpected response.")
        }
    }

    private static func issue(from data: Data, fallbackCode: String) -> WebDriverAgentIssue {
        if let response = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            return WebDriverAgentIssue(code: response.value.error ?? fallbackCode, message: response.value.message ?? "The automation command failed.")
        }
        return WebDriverAgentIssue(code: fallbackCode, message: "The automation command failed.")
    }
}

private nonisolated struct ValueEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value
}

private nonisolated struct SessionValue: Decodable, Sendable {
    let sessionId: String
}

private nonisolated struct EmptyEnvelope: Decodable, Sendable {
    let value: EmptyValue?
}

private nonisolated struct EmptyValue: Decodable, Sendable {}

private nonisolated struct ErrorEnvelope: Decodable, Sendable {
    struct Value: Decodable, Sendable {
        let error: String?
        let message: String?
    }
    let value: Value
}
