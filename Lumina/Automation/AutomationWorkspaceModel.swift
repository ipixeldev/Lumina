import Foundation
import Observation

@MainActor
@Observable
final class AutomationWorkspaceModel {
    private(set) var isConnected = false
    private(set) var isStreaming = false
    private(set) var screenshotData: Data?
    private(set) var screenInfo: DeviceScreenInfo?
    private(set) var orientation: DeviceOrientation?
    private(set) var activeApplication: ActiveApplicationInfo?
    private(set) var framesPerSecond = 0.0
    private(set) var issue: String?

    private let logger: StructuredLogging
    private var client: (any WebDriverAgentControlling)?
    private var session: AutomationSession?
    private var streamTask: Task<Void, Never>?
    private var streamID: UUID?
    private var frameTimes: [ContinuousClock.Instant] = []

    init(logger: StructuredLogging) {
        self.logger = logger
    }

    func connect(to endpoint: URL) async throws {
        await disconnect()
        let client = WebDriverAgentClient(endpoint: endpoint)
        let session = try await client.createSession()
        do {
            let snapshot = try await client.snapshot(session: session)
            self.client = client
            self.session = session
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
        guard streamTask == nil, let client, let session else { return }
        isStreaming = true
        issue = nil
        frameTimes.removeAll(keepingCapacity: true)
        let streamID = UUID()
        self.streamID = streamID
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                let started = ContinuousClock.now
                do {
                    let frame = try await client.screenshot(session: session)
                    guard !Task.isCancelled else { break }
                    self?.accept(frame: frame, at: .now)
                    let elapsed = started.duration(to: .now)
                    let target = Duration.milliseconds(200)
                    if elapsed < target {
                        try await Task.sleep(for: target - elapsed)
                    }
                } catch is CancellationError {
                    break
                } catch {
                    self?.issue = error.localizedDescription
                    self?.logger.error("Live screen refresh failed", category: .mirroring)
                    try? await Task.sleep(for: .seconds(1))
                }
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
        streamTask = nil
        streamID = nil
        isStreaming = false
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
        streamTask = nil
        streamID = nil
        if let client, let session {
            await client.deleteSession(session)
        }
        client = nil
        session = nil
        isConnected = false
        isStreaming = false
        screenshotData = nil
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
        frameTimes.append(now)
        let cutoff = now.advanced(by: .seconds(-1))
        frameTimes.removeAll { $0 < cutoff }
        framesPerSecond = Double(frameTimes.count)
    }
}
