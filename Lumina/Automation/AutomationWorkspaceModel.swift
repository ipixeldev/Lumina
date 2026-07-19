import AppKit
import Foundation
import ImageIO
import Observation

nonisolated enum VisualSource: String, CaseIterable, Identifiable, Sendable {
    case direct
    case airPlay

    var id: String { rawValue }
    var title: String { self == .direct ? "Direct" : "AirPlay" }
}

@MainActor
@Observable
final class AutomationWorkspaceModel {
    private static let visualSourceKey = "preferredVisualSource"

    private(set) var isConnected = false
    private(set) var isStreaming = false
    private(set) var directFrame: CGImage?
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
    private(set) var hasPresentedAirPlayVideo = false
    @ObservationIgnored var onVisualChannelStarted: (@MainActor @Sendable (VisualSource) -> Void)?
    @ObservationIgnored var onVisualChannelStopped: (@MainActor @Sendable (VisualSource) -> Void)?
    @ObservationIgnored var onControlChannelStopped: (@MainActor @Sendable () -> Void)?

    private let logger: StructuredLogging
    private var client: (any WebDriverAgentControlling)?
    private var session: AutomationSession?
    private var connectionToken: UUID?
    private var streamTask: Task<Void, Never>?
    private var streamID: UUID?
    private var streamClient: MJPEGStreamClient?
    private var endpoint: URL?
    private var frameTimes: [ContinuousClock.Instant] = []
    private var airPlaySelectionTask: Task<Void, Never>?
    private var airPlayRecoveryTask: Task<Void, Never>?
    private var consecutiveControlTimeouts = 0
    private var controlHealthProbeTask: Task<Void, Never>?
    private var controlHealthProbeID: UUID?
    private var controlHealthMonitorTask: Task<Void, Never>?
    @ObservationIgnored private let frameDecoder = DirectFrameDecoder()
    @ObservationIgnored private let airPlayCapture: AirPlayCaptureService

    var hasLiveVisualChannel: Bool {
        guard isStreaming else { return false }
        return switch visualSource {
        case .direct: directFrame != nil
        case .airPlay: airPlayFrame != nil
        }
    }

    var isControlReady: Bool {
        isConnected && screenInfo != nil && client != nil && session != nil
    }

    init(logger: StructuredLogging) {
        self.logger = logger
        if let storedValue = UserDefaults.standard.string(forKey: Self.visualSourceKey),
           let storedSource = VisualSource(rawValue: storedValue) {
            visualSource = storedSource
            hasSelectedVisualSource = false
        } else {
            visualSource = .direct
            hasSelectedVisualSource = false
        }
        airPlayCapture = AirPlayCaptureService()
        airPlayCapture.onFrame = { [weak self] frame, generation in
            await MainActor.run {
                guard let self,
                      self.visualSource == .airPlay,
                      self.airPlayCapture.isActiveCapture(generation) else { return }
                self.acceptAirPlay(frame: frame, at: .now)
            }
        }
        airPlayCapture.onStarted = { [weak self] generation in
            await MainActor.run {
                guard let self,
                      self.visualSource == .airPlay,
                      self.airPlayCapture.isActiveCapture(generation) else { return }
                self.airPlaySelectionTask?.cancel()
                self.airPlayRecoveryTask?.cancel()
                self.airPlayRecoveryTask = nil
                self.isChoosingAirPlaySource = false
                self.isStreaming = true
                self.issue = nil
                self.onVisualChannelStarted?(.airPlay)
            }
        }
        airPlayCapture.onStopped = { [weak self] generation, message, allowsAutomaticRecovery in
            await MainActor.run {
                guard let self,
                      self.visualSource == .airPlay,
                      self.airPlayCapture.isCurrentGeneration(generation) else { return }
                self.airPlaySelectionTask?.cancel()
                self.isChoosingAirPlaySource = false
                self.isStreaming = false
                self.airPlayFrame = nil
                self.framesPerSecond = 0
                if let message { self.issue = "AirPlay capture stopped: \(message)" }
                self.onVisualChannelStopped?(.airPlay)
                if allowsAutomaticRecovery { self.scheduleAirPlayRecovery() }
            }
        }
    }

    func connect(to endpoint: URL) async throws {
        await disconnect(preservingAirPlayCapture: visualSource == .airPlay)
        let connectionToken = UUID()
        self.connectionToken = connectionToken
        let client = WebDriverAgentClient(endpoint: endpoint)
        var createdSession: AutomationSession?
        do {
            let session = try await client.createSession()
            createdSession = session
            let state: AutomationDeviceState
            let initialFrame: CGImage?
            switch visualSource {
            case .direct:
                let snapshot = try await client.snapshot(session: session)
                state = AutomationDeviceState(
                    screen: snapshot.screen,
                    orientation: snapshot.orientation,
                    activeApplication: snapshot.activeApplication
                )
                initialFrame = await frameDecoder.decode(snapshot.screenshot)
            case .airPlay:
                state = try await client.deviceState(session: session)
                initialFrame = nil
            }
            try Task.checkCancellation()
            guard self.connectionToken == connectionToken else { throw CancellationError() }
            self.client = client
            self.session = session
            self.endpoint = endpoint
            apply(state: state)
            directFrame = initialFrame
            resetControlHealthTracking()
            isConnected = true
            startControlHealthMonitor(
                connectionToken: connectionToken,
                client: client,
                session: session
            )
            issue = nil
            logger.info("Local iPhone control session connected at \(endpoint.absoluteString)", category: .automation)
        } catch {
            if let createdSession { await client.deleteSession(createdSession) }
            if self.connectionToken == connectionToken { self.connectionToken = nil }
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
                let frames = streamClient.frames(from: streamEndpoint)
                for try await frame in frames {
                    guard !Task.isCancelled else { break }
                    guard let decoded = await self?.frameDecoder.decode(frame) else { continue }
                    self?.accept(decoded: decoded, at: .now)
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

    func startSelectedVisualSource() {
        switch visualSource {
        case .direct:
            startStreaming()
        case .airPlay:
            streamTask?.cancel()
            streamClient?.stop()
            streamClient = nil
            streamTask = nil
            streamID = nil
            directFrame = nil
            isStreaming = airPlayFrame != nil
            if isStreaming {
                onVisualChannelStarted?(.airPlay)
            } else {
                waitForAirPlaySource()
            }
            logger.info("AirPlay video is waiting for the macOS mirrored window", category: .mirroring)
        }
    }

    func stopStreaming() {
        let stoppedSource = visualSource
        let hadLiveVisualChannel = hasLiveVisualChannel
        streamTask?.cancel()
        streamClient?.stop()
        streamClient = nil
        streamTask = nil
        streamID = nil
        isStreaming = false
        airPlaySelectionTask?.cancel()
        airPlaySelectionTask = nil
        airPlayRecoveryTask?.cancel()
        airPlayRecoveryTask = nil
        airPlayCapture.stop()
        airPlayFrame = nil
        hasPresentedAirPlayVideo = false
        framesPerSecond = 0
        if stoppedSource == .airPlay, hadLiveVisualChannel {
            onVisualChannelStopped?(stoppedSource)
        }
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
        airPlayRecoveryTask?.cancel()
        airPlayRecoveryTask = nil
        isChoosingAirPlaySource = true
        issue = nil
        airPlayCapture.chooseMirroredContent()
        airPlaySelectionTask?.cancel()
        airPlaySelectionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.isChoosingAirPlaySource else { return }
            self.isChoosingAirPlaySource = false
            self.issue = "No mirrored window was selected. Enable AirPlay Receiver on this Mac, mirror the iPhone from Control Center, then try again."
        }
    }

    func waitForAirPlaySource() {
        guard visualSource == .airPlay, isControlReady else { return }
        airPlayRecoveryTask?.cancel()
        airPlayRecoveryTask = nil
        isChoosingAirPlaySource = true
        issue = nil
        airPlayCapture.waitForMirroredContent(timeout: .seconds(300))
        airPlaySelectionTask?.cancel()
        airPlaySelectionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(302))
            guard !Task.isCancelled, let self, self.isChoosingAirPlaySource else { return }
            self.isChoosingAirPlaySource = false
            self.issue = "No full-screen AirPlay window appeared. Start Screen Mirroring on the iPhone, choose this Mac, then retry or choose the window manually."
        }
    }

    func openAirPlayReceiverSettings() {
        let settingsURL = URL(string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension")
        if let settingsURL, NSWorkspace.shared.open(settingsURL) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
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
        guard let client, let session, let connectionToken else { return }
        let target: DeviceOrientation = switch orientation {
        case .landscapeLeft, .landscapeRight: .portrait
        default: .landscapeLeft
        }
        Task { [weak self] in
            do {
                try await client.rotate(to: target, session: session)
                try await Task.sleep(for: .milliseconds(250))
                let state = try await client.deviceState(session: session)
                guard self?.connectionToken == connectionToken else { return }
                self?.apply(state: state)
                self?.clearControlIssueAfterSuccess()
                self?.logger.debug("iPhone orientation command completed", category: .input)
            } catch {
                self?.handleControlFailure(
                    error,
                    connectionToken: connectionToken,
                    logMessage: "iPhone orientation command failed"
                )
            }
        }
    }

    func refresh() {
        guard let client, let session, let connectionToken else { return }
        Task { [weak self] in
            do {
                if self?.visualSource == .direct {
                    let snapshot = try await client.snapshot(session: session)
                    guard self?.connectionToken == connectionToken else { return }
                    self?.apply(state: AutomationDeviceState(
                        screen: snapshot.screen,
                        orientation: snapshot.orientation,
                        activeApplication: snapshot.activeApplication
                    ))
                    let frame = await self?.frameDecoder.decode(snapshot.screenshot)
                    guard self?.connectionToken == connectionToken else { return }
                    self?.directFrame = frame
                } else {
                    let state = try await client.deviceState(session: session)
                    guard self?.connectionToken == connectionToken else { return }
                    self?.apply(state: state)
                }
                self?.clearControlIssueAfterSuccess()
            } catch {
                self?.handleControlFailure(
                    error,
                    connectionToken: connectionToken,
                    logMessage: "iPhone state refresh failed"
                )
            }
        }
    }

    func disconnect() async {
        await disconnect(preservingAirPlayCapture: false)
    }

    private func disconnect(preservingAirPlayCapture: Bool) async {
        streamTask?.cancel()
        streamClient?.stop()
        if !preservingAirPlayCapture { airPlayCapture.stop() }
        streamClient = nil
        streamTask = nil
        streamID = nil
        if !preservingAirPlayCapture {
            airPlaySelectionTask?.cancel()
            airPlaySelectionTask = nil
            airPlayRecoveryTask?.cancel()
            airPlayRecoveryTask = nil
        }
        let connectedClient = client
        let connectedSession = session
        client = nil
        session = nil
        connectionToken = nil
        endpoint = nil
        isConnected = false
        stopControlHealthMonitor()
        resetControlHealthTracking()
        airPlayCapture.setDeviceViewport(nil)
        if !preservingAirPlayCapture { isStreaming = false }
        if let connectedClient, let connectedSession {
            await connectedClient.deleteSession(connectedSession)
        }
        directFrame = nil
        if !preservingAirPlayCapture {
            airPlayFrame = nil
            hasPresentedAirPlayVideo = false
            framesPerSecond = 0
        }
    }

    private func performInput(
        _ operation: @escaping @Sendable (any WebDriverAgentControlling, AutomationSession) async throws -> Void
    ) {
        guard let client, let session, let connectionToken else {
            issue = "iPhone control is not connected. Reconnect the XCTest control channel and try again."
            return
        }
        Task { [weak self] in
            do {
                try await operation(client, session)
                guard self?.connectionToken == connectionToken else { return }
                self?.clearControlIssueAfterSuccess()
                self?.logger.debug("iPhone input command completed", category: .input)
            } catch {
                self?.handleControlFailure(
                    error,
                    connectionToken: connectionToken,
                    logMessage: "iPhone input command failed"
                )
            }
        }
    }

    private func clearControlIssueAfterSuccess() {
        resetControlHealthTracking()
        // Keep a useful AirPlay capture/permission message visible while the
        // independent XCTest channel continues to accept commands.
        if visualSource != .airPlay || isStreaming {
            issue = nil
        }
    }

    private func handleControlFailure(
        _ error: Error,
        connectionToken: UUID,
        logMessage: String
    ) {
        guard self.connectionToken == connectionToken else { return }
        issue = error.localizedDescription
        logger.error(logMessage, category: .input)
        if Self.isConfirmedControlLoss(error) {
            invalidateControlChannel()
            return
        }

        if let urlError = error as? URLError, urlError.code == .timedOut {
            consecutiveControlTimeouts += 1
            if consecutiveControlTimeouts >= 2 {
                invalidateControlChannel()
            } else {
                scheduleControlHealthProbe(connectionToken: connectionToken)
            }
        } else {
            consecutiveControlTimeouts = 0
        }
    }

    private func scheduleControlHealthProbe(connectionToken: UUID) {
        guard controlHealthProbeTask == nil,
              let client,
              let session else { return }
        let probeID = UUID()
        controlHealthProbeID = probeID
        controlHealthProbeTask = Task { [weak self] in
            do {
                let state = try await client.deviceState(session: session)
                guard let self,
                      self.connectionToken == connectionToken,
                      self.controlHealthProbeID == probeID else { return }
                self.controlHealthProbeTask = nil
                self.controlHealthProbeID = nil
                self.consecutiveControlTimeouts = 0
                self.apply(state: state)
                if self.visualSource != .airPlay || self.isStreaming {
                    self.issue = nil
                }
                self.logger.info("iPhone control health check recovered", category: .automation)
            } catch is CancellationError {
                // A successful command, disconnect, or replacement session
                // cancelled this probe.
            } catch {
                guard let self,
                      self.connectionToken == connectionToken,
                      self.controlHealthProbeID == probeID else { return }
                self.controlHealthProbeTask = nil
                self.controlHealthProbeID = nil
                self.handleControlFailure(
                    error,
                    connectionToken: connectionToken,
                    logMessage: "iPhone control health check failed"
                )
            }
        }
    }

    private func resetControlHealthTracking() {
        controlHealthProbeTask?.cancel()
        controlHealthProbeTask = nil
        controlHealthProbeID = nil
        consecutiveControlTimeouts = 0
    }

    private func startControlHealthMonitor(
        connectionToken: UUID,
        client: any WebDriverAgentControlling,
        session: AutomationSession
    ) {
        controlHealthMonitorTask?.cancel()
        controlHealthMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                    let state = try await client.deviceState(session: session)
                    guard let self, self.connectionToken == connectionToken else { return }
                    self.apply(state: state)
                    self.clearControlIssueAfterSuccess()
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, self.connectionToken == connectionToken else { return }
                    self.handleControlFailure(
                        error,
                        connectionToken: connectionToken,
                        logMessage: "iPhone control health monitor failed"
                    )
                    if self.connectionToken != connectionToken { return }
                }
            }
        }
    }

    private func stopControlHealthMonitor() {
        controlHealthMonitorTask?.cancel()
        controlHealthMonitorTask = nil
    }

    private func invalidateControlChannel() {
        stopControlHealthMonitor()
        resetControlHealthTracking()
        client = nil
        session = nil
        connectionToken = nil
        endpoint = nil
        isConnected = false
        airPlayCapture.setDeviceViewport(nil)
        onControlChannelStopped?()
    }

    private func scheduleAirPlayRecovery() {
        guard visualSource == .airPlay, isControlReady else { return }
        airPlayRecoveryTask?.cancel()
        airPlayRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled,
                  let self,
                  self.visualSource == .airPlay,
                  self.isControlReady,
                  !self.isStreaming else { return }
            self.airPlayRecoveryTask = nil
            self.isChoosingAirPlaySource = true
            self.airPlayCapture.waitForMirroredContent(timeout: .seconds(300))
            self.logger.info("Waiting for the AirPlay receiver window to return", category: .mirroring)
        }
    }

    private static func isConfirmedControlLoss(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return switch urlError.code {
            case .cannotConnectToHost,
                 .cannotFindHost,
                 .dnsLookupFailed,
                 .networkConnectionLost,
                 .notConnectedToInternet:
                true
            default:
                false
            }
        }

        guard let issue = error as? WebDriverAgentIssue else { return false }
        let diagnostic = "\(issue.code) \(issue.message)".lowercased()
        return diagnostic.contains("invalid session") ||
            diagnostic.contains("no such session") ||
            diagnostic.contains("session does not exist")
    }

    private func accept(decoded: CGImage, at now: ContinuousClock.Instant) {
        directFrame = decoded
        issue = nil
        recordFrame(at: now)
    }

    private func acceptAirPlay(frame: CGImage, at now: ContinuousClock.Instant) {
        airPlayFrame = frame
        hasPresentedAirPlayVideo = true
        issue = nil
        recordFrame(at: now)
    }

    private func apply(state: AutomationDeviceState) {
        screenInfo = state.screen
        airPlayCapture.setDeviceViewport(state.screen.screenSize)
        orientation = state.orientation
        activeApplication = state.activeApplication
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
                if let decoded = await frameDecoder.decode(frame) {
                    accept(decoded: decoded, at: .now)
                }
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

private actor DirectFrameDecoder {
    func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: true
        ] as CFDictionary)
    }
}
