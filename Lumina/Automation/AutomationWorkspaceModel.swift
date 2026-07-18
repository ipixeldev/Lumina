import AppKit
import Foundation
import Observation

nonisolated enum VisualSource: String, CaseIterable, Identifiable, Sendable {
    case direct
    case airPlay

    var id: String { rawValue }
    var title: String { self == .direct ? "Direct" : "AirPlay-assisted" }
}

@MainActor
@Observable
final class AutomationWorkspaceModel {
    private static let visualSourceKey = "preferredVisualSource"

    private(set) var isConnected = false
    private(set) var isStreaming = false
    private(set) var screenshotData: Data?
    private(set) var airPlayFrame: CGImage?
    private(set) var screenInfo: DeviceScreenInfo?
    private(set) var orientation: DeviceOrientation?
    private(set) var activeApplication: ActiveApplicationInfo?
    private(set) var framesPerSecond = 0.0
    private(set) var issue: String?
    private(set) var streamProfile: StreamQualityProfile = .balanced
    private(set) var visualSource: VisualSource
    private(set) var hasSelectedVisualSource: Bool
    private(set) var isChoosingAirPlaySource = false

    private let logger: StructuredLogging
    private var client: (any WebDriverAgentControlling)?
    private var session: AutomationSession?
    private var streamTask: Task<Void, Never>?
    private var streamID: UUID?
    private var streamClient: MJPEGStreamClient?
    private var endpoint: URL?
    private var frameTimes: [ContinuousClock.Instant] = []
    @ObservationIgnored private let airPlayCapture: AirPlayCaptureService

    init(logger: StructuredLogging) {
        self.logger = logger
        if let storedValue = UserDefaults.standard.string(forKey: Self.visualSourceKey),
           let storedSource = VisualSource(rawValue: storedValue) {
            visualSource = storedSource
            hasSelectedVisualSource = true
        } else {
            visualSource = .direct
            hasSelectedVisualSource = false
        }
        airPlayCapture = AirPlayCaptureService()
        airPlayCapture.onFrame = { [weak self] frame in
            Task { @MainActor in
                guard self?.visualSource == .airPlay else { return }
                self?.acceptAirPlay(frame: frame, at: .now)
            }
        }
        airPlayCapture.onStarted = { [weak self] in
            Task { @MainActor in
                guard self?.visualSource == .airPlay else { return }
                self?.isChoosingAirPlaySource = false
                self?.isStreaming = true
                self?.issue = nil
            }
        }
        airPlayCapture.onStopped = { [weak self] message in
            Task { @MainActor in
                guard self?.visualSource == .airPlay else { return }
                self?.isChoosingAirPlaySource = false
                self?.isStreaming = false
                if let message { self?.issue = "AirPlay capture stopped: \(message)" }
            }
        }
    }

    func connect(to endpoint: URL) async throws {
        await disconnect()
        let client = WebDriverAgentClient(endpoint: endpoint)
        let session = try await client.createSession()
        do {
            let snapshot = try await client.snapshot(session: session)
            self.client = client
            self.session = session
            self.endpoint = endpoint
            screenInfo = snapshot.screen
            orientation = snapshot.orientation
            activeApplication = snapshot.activeApplication
            screenshotData = snapshot.screenshot
            isConnected = true
            issue = nil
            logger.info("Local iPhone automation session connected", category: .automation)
        } catch {
            await client.deleteSession(session)
            throw error
        }
    }

    func startStreaming() {
        guard visualSource == .direct else { return }
        guard streamTask == nil, let client, let session, let endpoint else { return }
        let profile = streamProfile
        isStreaming = true
        issue = nil
        frameTimes.removeAll(keepingCapacity: true)
        let streamID = UUID()
        self.streamID = streamID
        streamTask = Task { [weak self] in
            do {
                try await client.configureVideoStream(session: session, profile: profile)
                let streamClient = MJPEGStreamClient()
                self?.streamClient = streamClient
                let streamEndpoint = Self.videoEndpoint(from: endpoint)
                let frames = streamClient.frames(from: streamEndpoint) { frame in
                    Task { @MainActor in self?.accept(frame: frame, at: .now) }
                }
                for try await _ in frames {
                    guard !Task.isCancelled else { break }
                }
            } catch is CancellationError {
                // Normal shutdown.
            } catch {
                self?.logger.error("High-frame-rate stream unavailable; using screenshot fallback", category: .mirroring)
                await self?.runScreenshotFallback(client: client, session: session)
            }
            if self?.streamID == streamID {
                self?.isStreaming = false
                self?.streamTask = nil
                self?.streamID = nil
            }
        }
        logger.info("Live screen refresh started", category: .mirroring)
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamClient?.stop()
        streamClient = nil
        streamTask = nil
        streamID = nil
        isStreaming = false
        airPlayCapture.stop()
    }

    func selectStreamProfile(_ profile: StreamQualityProfile) {
        guard streamProfile != profile else { return }
        streamProfile = profile
        guard isConnected else { return }
        stopStreaming()
        startStreaming()
    }

    func selectVisualSource(_ source: VisualSource) {
        hasSelectedVisualSource = true
        UserDefaults.standard.set(source.rawValue, forKey: Self.visualSourceKey)
        guard visualSource != source else { return }
        stopStreaming()
        visualSource = source
        airPlayFrame = nil
        framesPerSecond = 0
        issue = nil
        if source == .direct { startStreaming() }
    }

    func chooseAirPlaySource() {
        guard visualSource == .airPlay else { return }
        isChoosingAirPlaySource = true
        issue = nil
        airPlayCapture.chooseMirroredContent()
    }

    func tap(at point: AutomationPoint) {
        performInput { client, session in
            try await client.tap(at: point, session: session)
        }
    }

    func drag(from start: AutomationPoint, to end: AutomationPoint, duration: Double) {
        performInput { client, session in
            try await client.drag(from: start, to: end, duration: duration, session: session)
        }
    }

    func goHome() {
        performInput { client, _ in try await client.goHome() }
    }

    func volumeUp() {
        performInput { client, session in try await client.pressButton(.volumeUp, session: session) }
    }

    func volumeDown() {
        performInput { client, session in try await client.pressButton(.volumeDown, session: session) }
    }

    func lockScreen() {
        performInput { client, _ in try await client.lock() }
    }

    func wakeOrUnlock() {
        performInput { client, _ in try await client.unlock() }
    }

    func rotate() {
        let target: DeviceOrientation = switch orientation {
        case .landscapeLeft, .landscapeRight: .portrait
        default: .landscapeLeft
        }
        performInput { client, session in try await client.rotate(to: target, session: session) }
        orientation = target
    }

    func refresh() {
        guard let client, let session else { return }
        Task { [weak self] in
            do {
                let snapshot = try await client.snapshot(session: session)
                self?.screenInfo = snapshot.screen
                self?.orientation = snapshot.orientation
                self?.activeApplication = snapshot.activeApplication
                self?.screenshotData = snapshot.screenshot
                self?.issue = nil
            } catch {
                self?.issue = error.localizedDescription
            }
        }
    }

    func disconnect() async {
        streamTask?.cancel()
        streamClient?.stop()
        airPlayCapture.stop()
        streamClient = nil
        streamTask = nil
        streamID = nil
        if let client, let session {
            await client.deleteSession(session)
        }
        client = nil
        session = nil
        endpoint = nil
        isConnected = false
        isStreaming = false
        screenshotData = nil
        airPlayFrame = nil
        framesPerSecond = 0
    }

    private func performInput(
        _ operation: @escaping @Sendable (any WebDriverAgentControlling, AutomationSession) async throws -> Void
    ) {
        guard let client, let session else { return }
        Task { [weak self] in
            do {
                try await operation(client, session)
                self?.issue = nil
                self?.logger.debug("iPhone input command completed", category: .input)
            } catch {
                self?.issue = error.localizedDescription
                self?.logger.error("iPhone input command failed", category: .input)
            }
        }
    }

    private func accept(frame: Data, at now: ContinuousClock.Instant) {
        screenshotData = frame
        issue = nil
        recordFrame(at: now)
    }

    private func acceptAirPlay(frame: CGImage, at now: ContinuousClock.Instant) {
        airPlayFrame = frame
        issue = nil
        recordFrame(at: now)
    }

    private func recordFrame(at now: ContinuousClock.Instant) {
        frameTimes.append(now)
        let cutoff = now.advanced(by: .seconds(-1))
        frameTimes.removeAll { $0 < cutoff }
        framesPerSecond = Double(frameTimes.count)
    }

    private func runScreenshotFallback(
        client: any WebDriverAgentControlling,
        session: AutomationSession
    ) async {
        while !Task.isCancelled {
            let started = ContinuousClock.now
            do {
                let frame = try await client.screenshot(session: session)
                accept(frame: frame, at: .now)
                let elapsed = started.duration(to: .now)
                let target = Duration.milliseconds(200)
                if elapsed < target { try await Task.sleep(for: target - elapsed) }
            } catch is CancellationError {
                break
            } catch {
                issue = error.localizedDescription
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func videoEndpoint(from endpoint: URL) -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint
        }
        components.port = 9100
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url ?? endpoint
    }
}
