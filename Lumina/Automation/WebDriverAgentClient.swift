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
    func configureInteraction(session: AutomationSession, screen: DeviceScreenInfo.Size) async throws
    func checkSessionHealth(session: AutomationSession) async throws
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

actor WebDriverAgentClient: WebDriverAgentControlling {
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
        let session = AutomationSession(id: response.value.sessionId)
        do {
            try await applyInteractionSettings(session: session)
            _ = try await controlExtensionStatus(session: session)
            return session
        } catch {
            await deleteSession(session)
            throw error
        }
    }

    func deleteSession(_ session: AutomationSession) async {
        do {
            let _: EmptyEnvelope = try await request("session/\(session.id)", method: "DELETE")
        } catch {
            // Runner shutdown still owns the transport lifecycle; session cleanup is best effort.
        }
    }

    func configureInteraction(session: AutomationSession, screen: DeviceScreenInfo.Size) async throws {
        let center = "\(screen.width / 2),\(screen.height / 2)"
        try await applyInteractionSettings(session: session, activeAppDetectionPoint: center)
    }

    func checkSessionHealth(session: AutomationSession) async throws {
        try await controlExtensionHealth(session: session)
    }

    func deviceState(session: AutomationSession) async throws -> AutomationDeviceState {
        // This single overlay-safe request is the complete control handshake.
        // Standard orientation and active-app endpoints resolve XCUIApplication
        // and can each stall while AirPlay exposes local.pid.0 as the foreground
        // process, even though global XCTest input remains healthy.
        let controlExtension = try await controlExtensionStatus(session: session)
        return AutomationDeviceState(
            screen: controlExtension.screen,
            orientation: controlExtension.orientation,
            activeApplication: Self.springBoardApplication
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
            "session/\(session.id)/wda/lumina/tap",
            method: "POST",
            body: ["x": point.x, "y": point.y]
        )
    }

    func drag(from start: AutomationPoint, to end: AutomationPoint, duration: Double, session: AutomationSession) async throws {
        let _: EmptyEnvelope = try await request(
            "session/\(session.id)/wda/lumina/drag",
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

    private func applyInteractionSettings(
        session: AutomationSession,
        activeAppDetectionPoint: String? = nil
    ) async throws {
        var settings: [String: Any] = [
            "defaultActiveApplication": "com.apple.springboard"
        ]
        if let activeAppDetectionPoint {
            settings["activeAppDetectionPoint"] = activeAppDetectionPoint
        }
        let _: EmptyEnvelope = try await request(
            "session/\(session.id)/appium/settings",
            method: "POST",
            body: ["settings": settings]
        )
    }

    private func controlExtensionStatus(
        session: AutomationSession
    ) async throws -> LuminaControlExtensionStatus {
        let response: ValueEnvelope<LuminaControlExtensionStatus>
        do {
            response = try await request("session/\(session.id)/wda/lumina/status")
        } catch let error as URLError {
            throw error
        } catch {
            throw Self.controlExtensionIssue
        }

        try validateControlExtension(
            revision: response.value.revision,
            capabilities: response.value.capabilities
        )
        guard response.value.screen.screenSize.width > 0,
              response.value.screen.screenSize.height > 0 else {
            throw Self.controlExtensionIssue
        }
        return response.value
    }

    private func controlExtensionHealth(session: AutomationSession) async throws {
        let response: ValueEnvelope<LuminaControlExtensionHealth>
        do {
            response = try await request("session/\(session.id)/wda/lumina/health")
        } catch let error as URLError {
            throw error
        } catch {
            throw Self.controlExtensionIssue
        }
        try validateControlExtension(
            revision: response.value.revision,
            capabilities: response.value.capabilities
        )
    }

    private func validateControlExtension(
        revision: String,
        capabilities: [String]
    ) throws {
        guard revision == LuminaWebDriverAgentPatch.revision,
              Self.requiredControlCapabilities.isSubset(of: Set(capabilities)) else {
            throw Self.controlExtensionIssue
        }
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
            "session/\(session.id)/wda/lumina/orientation",
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

    private static let springBoardApplication = ActiveApplicationInfo(
        bundleId: "com.apple.springboard",
        name: "SpringBoard",
        pid: nil
    )

    private static let requiredControlCapabilities: Set<String> = [
        "globalTap",
        "globalDrag",
        "globalOrientation",
        "overlayScreen",
        "overlayOrientation"
    ]

    private static let controlExtensionIssue = WebDriverAgentIssue(
        code: "LUM-WDA-105",
        message: "The installed iPhone runner does not contain Lumina's current control extension. Reinstall the verified runner once and reconnect."
    )
}

private nonisolated struct LuminaControlExtensionStatus: Decodable, Sendable {
    let revision: String
    let capabilities: [String]
    let screen: DeviceScreenInfo
    let orientation: DeviceOrientation
}

private nonisolated struct LuminaControlExtensionHealth: Decodable, Sendable {
    let revision: String
    let capabilities: [String]
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
