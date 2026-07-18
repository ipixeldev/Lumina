import AppKit
@preconcurrency import CoreImage
@preconcurrency import CoreMedia
@preconcurrency import ScreenCaptureKit

nonisolated final class AirPlayCaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct WindowCandidate: Identifiable, Hashable, Sendable {
        let id: CGWindowID
        let applicationName: String
        let bundleIdentifier: String?
        let windowTitle: String?
        let width: Int
        let height: Int
        let isLikelyAirPlay: Bool

        var displayName: String {
            let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = if let title, !title.isEmpty, title.caseInsensitiveCompare(applicationName) != .orderedSame {
                "\(title) — \(applicationName)"
            } else {
                applicationName
            }
            let recommendation = isLikelyAirPlay ? "Recommended — " : ""
            return "\(recommendation)\(subject) · \(width)×\(height)"
        }
    }

    var onFrame: (@Sendable (CGImage, Int) async -> Void)?
    var onStarted: (@Sendable (Int) async -> Void)?
    var onStopped: (@Sendable (Int, String?) async -> Void)?

    private let sampleQueue = DispatchQueue(label: "com.iPixeldev.Lumina.airplay-capture", qos: .userInteractive)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let stateLock = NSLock()
    private let lifecycleQueue = AsyncSerialTaskQueue()
    private var stream: SCStream?
    private var captureGeneration = 0
    private var selectionGeneration = 0
    private var acceptsFrames = false
    private var deliveredFirstFrame = false
    private var frameDeliveryToken: UUID?

    func isCurrentGeneration(_ generation: Int) -> Bool {
        stateLock.withLock { captureGeneration == generation }
    }

    func isActiveCapture(_ generation: Int) -> Bool {
        stateLock.withLock {
            captureGeneration == generation && acceptsFrames && stream != nil
        }
    }

    /// Returns a ranked, local-only snapshot of capturable on-screen windows.
    /// AirPlayUIAgent, Control Center, and iPhone-like windows are placed first.
    @MainActor
    func availableMirroredWindows() async throws -> [WindowCandidate] {
        try Self.ensureScreenCapturePermission()
        return try await loadWindowSnapshots().map(\.candidate)
    }

    /// Presents Lumina's own chooser instead of activating a process-global
    /// system picker that can interfere with Control Center and AirPlay.
    @MainActor
    func chooseMirroredContent() {
        let request = beginSelectionRequest()
        Task { @MainActor [weak self] in
            await self?.performWindowSelection(request: request)
        }
    }

    /// Starts capture for a candidate previously returned by
    /// `availableMirroredWindows()`. The window is resolved again so stale
    /// ScreenCaptureKit objects never cross a selection boundary.
    @MainActor
    func capture(_ candidate: WindowCandidate) {
        let request = beginSelectionRequest()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Self.ensureScreenCapturePermission()
                let snapshots = try await loadWindowSnapshots()
                guard isCurrentSelection(request) else { return }
                guard let snapshot = snapshots.first(where: { $0.candidate.id == candidate.id }) else {
                    throw CaptureIssue.windowUnavailable
                }
                start(window: snapshot.window)
            } catch {
                await finishSelection(request: request, error: error)
            }
        }
    }

    func stop() {
        stateLock.withLock {
            captureGeneration += 1
            selectionGeneration += 1
            acceptsFrames = false
            deliveredFirstFrame = false
            frameDeliveryToken = nil
        }
        lifecycleQueue.enqueue { [weak self] in
            guard let self, let stream = takeActiveStream() else { return }
            try? await stream.stopCapture()
        }
    }

    @MainActor
    private func performWindowSelection(request: Int) async {
        do {
            try Self.ensureScreenCapturePermission()
            let snapshots = try await loadWindowSnapshots()
            guard isCurrentSelection(request) else { return }
            guard !snapshots.isEmpty else { throw CaptureIssue.noWindows }
            guard let candidate = await presentWindowChooser(snapshots.map(\.candidate)) else {
                await finishSelection(request: request, error: nil)
                return
            }
            guard isCurrentSelection(request) else { return }
            guard let snapshot = snapshots.first(where: { $0.candidate.id == candidate.id }) else {
                throw CaptureIssue.windowUnavailable
            }
            start(window: snapshot.window)
        } catch {
            await finishSelection(request: request, error: error)
        }
    }

    @MainActor
    private func loadWindowSnapshots() async throws -> [WindowSnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        return content.windows.compactMap { window -> WindowSnapshot? in
            let application = window.owningApplication
            let bundleIdentifier = application?.bundleIdentifier
            guard bundleIdentifier != ownBundleIdentifier else { return nil }

            let frame = window.frame.standardized
            guard !frame.isNull,
                  frame.width >= 180,
                  frame.height >= 180 else { return nil }

            let applicationName = Self.nonempty(application?.applicationName) ?? "Unknown Application"
            let title = Self.nonempty(window.title)
            let rank = Self.candidateRank(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                title: title,
                frame: frame
            )
            let isLikelyAirPlay = Self.isLikelyAirPlayWindow(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                title: title
            )
            return WindowSnapshot(
                window: window,
                candidate: WindowCandidate(
                    id: window.windowID,
                    applicationName: applicationName,
                    bundleIdentifier: bundleIdentifier,
                    windowTitle: title,
                    width: Int(frame.width.rounded()),
                    height: Int(frame.height.rounded()),
                    isLikelyAirPlay: isLikelyAirPlay
                ),
                rank: rank
            )
        }
        .sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
            if lhs.candidate.applicationName != rhs.candidate.applicationName {
                return lhs.candidate.applicationName.localizedStandardCompare(rhs.candidate.applicationName) == .orderedAscending
            }
            return (lhs.candidate.windowTitle ?? "").localizedStandardCompare(rhs.candidate.windowTitle ?? "") == .orderedAscending
        }
    }

    @MainActor
    private func presentWindowChooser(_ candidates: [WindowCandidate]) async -> WindowCandidate? {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Choose Mirrored iPhone Window"
        alert.informativeText = "Start Screen Mirroring on the iPhone first. Lumina lists on-screen windows locally and places likely AirPlay windows first."
        alert.icon = NSImage(systemSymbolName: "airplayvideo", accessibilityDescription: "AirPlay")
        alert.addButton(withTitle: "Capture")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 480, height: 28), pullsDown: false)
        for candidate in candidates {
            popup.addItem(withTitle: candidate.displayName)
            popup.lastItem?.representedObject = NSNumber(value: candidate.id)
            popup.lastItem?.toolTip = candidate.bundleIdentifier
        }
        popup.selectItem(at: 0)
        alert.accessoryView = popup

        let response: NSApplication.ModalResponse
        if let parentWindow = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: parentWindow) { result in
                    continuation.resume(returning: result)
                }
            }
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn,
              let selectedID = popup.selectedItem?.representedObject as? NSNumber else { return nil }
        let windowID = CGWindowID(selectedID.uint32Value)
        return candidates.first(where: { $0.id == windowID })
    }

    @MainActor
    private static func ensureScreenCapturePermission() throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureIssue.screenRecordingPermission
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func candidateRank(
        applicationName: String,
        bundleIdentifier: String?,
        title: String?,
        frame: CGRect
    ) -> Int {
        let searchable = [applicationName, bundleIdentifier ?? "", title ?? ""]
            .joined(separator: " ")
            .lowercased()
        var rank = 0
        if searchable.contains("airplayuiagent") || searchable.contains("airplay") { rank += 1_000 }
        if searchable.contains("controlcenter") || searchable.contains("control center") { rank += 750 }
        if searchable.contains("screen mirroring") || searchable.contains("screenmirroring") { rank += 650 }
        if searchable.contains("iphone") || searchable.contains("ipad") || searchable.contains("ios") { rank += 600 }

        let aspectRatio = frame.width / max(frame.height, 1)
        if (0.35...0.82).contains(aspectRatio) { rank += 180 }
        if (1.20...2.40).contains(aspectRatio) { rank += 90 }
        if frame.height >= 600 || frame.width >= 900 { rank += 30 }
        return rank
    }

    private static func isLikelyAirPlayWindow(
        applicationName: String,
        bundleIdentifier: String?,
        title: String?
    ) -> Bool {
        let normalizedBundleIdentifier = bundleIdentifier?.lowercased()
        if normalizedBundleIdentifier == "com.apple.airplayuiagent" { return true }

        guard normalizedBundleIdentifier == "com.apple.controlcenter" else { return false }
        let searchable = [applicationName, title ?? ""]
            .joined(separator: " ")
            .lowercased()
        return searchable.contains("airplay") ||
            searchable.contains("screen mirroring") ||
            searchable.contains("iphone")
    }

    private func beginSelectionRequest() -> Int {
        stateLock.withLock {
            selectionGeneration += 1
            return selectionGeneration
        }
    }

    private func isCurrentSelection(_ generation: Int) -> Bool {
        stateLock.withLock { selectionGeneration == generation }
    }

    private func finishSelection(request: Int, error: Error?) async {
        guard isCurrentSelection(request) else { return }
        if let activeGeneration = activeCaptureGeneration() {
            // The user may cancel while replacing a healthy capture. Reaffirming
            // that capture clears the model's selection progress without tearing
            // down video that is still valid.
            await onStarted?(activeGeneration)
            return
        }
        guard let generation = invalidateInactiveCapture() else { return }
        await onStopped?(generation, error?.localizedDescription)
    }

    private func activeCaptureGeneration() -> Int? {
        stateLock.withLock {
            guard stream != nil, acceptsFrames, deliveredFirstFrame else { return nil }
            return captureGeneration
        }
    }

    private func start(window: SCWindow) {
        let generation = beginCaptureRequest()
        let filter = SCContentFilter(desktopIndependentWindow: window)
        lifecycleQueue.enqueue { [weak self] in
            guard let self else { return }
            await performStart(filter: filter, generation: generation)
        }
    }

    private func beginCaptureRequest() -> Int {
        stateLock.withLock {
            captureGeneration += 1
            acceptsFrames = false
            deliveredFirstFrame = false
            frameDeliveryToken = nil
            return captureGeneration
        }
    }

    private func performStart(filter: SCContentFilter, generation: Int) async {
        guard isCurrentGeneration(generation) else { return }
        var startingStream: SCStream?
        do {
            if let previousStream = takeActiveStream() {
                try? await previousStream.stopCapture()
            }
            guard isCurrentGeneration(generation) else { return }

            let configuration = Self.configuration(for: filter)
            let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
            startingStream = newStream
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await newStream.startCapture()
            guard activate(newStream, generation: generation) else {
                try? await newStream.stopCapture()
                return
            }
            startingStream = nil
        } catch {
            if let startingStream { try? await startingStream.stopCapture() }
            guard isCurrentGeneration(generation) else { return }
            if let activeStream = takeActiveStream() {
                try? await activeStream.stopCapture()
            }
            await onStopped?(generation, error.localizedDescription)
        }
    }

    private static func configuration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let sourceWidth = max(filter.contentRect.width * CGFloat(filter.pointPixelScale), 1)
        let sourceHeight = max(filter.contentRect.height * CGFloat(filter.pointPixelScale), 1)
        let maximumDimension: CGFloat = 4_096
        let scale = min(1, maximumDimension / max(sourceWidth, sourceHeight))
        configuration.width = max(2, Int((sourceWidth * scale).rounded(.up)))
        configuration.height = max(2, Int((sourceHeight * scale).rounded(.up)))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.captureResolution = .best
        return configuration
    }

    private func takeActiveStream() -> SCStream? {
        stateLock.withLock {
            let activeStream = stream
            stream = nil
            acceptsFrames = false
            deliveredFirstFrame = false
            frameDeliveryToken = nil
            return activeStream
        }
    }

    private func activate(_ candidate: SCStream, generation: Int) -> Bool {
        stateLock.withLock {
            guard captureGeneration == generation else { return false }
            stream = candidate
            acceptsFrames = true
            deliveredFirstFrame = false
            return true
        }
    }

    private func beginFrameDelivery(for candidate: SCStream) -> (token: UUID, generation: Int)? {
        stateLock.withLock {
            guard acceptsFrames, stream === candidate, frameDeliveryToken == nil else { return nil }
            let token = UUID()
            frameDeliveryToken = token
            return (token, captureGeneration)
        }
    }

    private func registerValidFrame(token: UUID, generation: Int, stream candidate: SCStream) -> Bool? {
        stateLock.withLock {
            guard frameDeliveryToken == token,
                  captureGeneration == generation,
                  acceptsFrames,
                  stream === candidate else { return nil }
            let isFirstFrame = !deliveredFirstFrame
            deliveredFirstFrame = true
            return isFirstFrame
        }
    }

    private func finishFrameDelivery(token: UUID) {
        stateLock.withLock {
            if frameDeliveryToken == token { frameDeliveryToken = nil }
        }
    }

    private func invalidateInactiveCapture() -> Int? {
        stateLock.withLock {
            guard stream == nil else { return nil }
            captureGeneration += 1
            acceptsFrames = false
            deliveredFirstFrame = false
            frameDeliveryToken = nil
            return captureGeneration
        }
    }
}

extension AirPlayCaptureService {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let delivery = beginFrameDelivery(for: stream) else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let frameRect = Self.contentRect(from: sampleBuffer, boundedBy: image.extent),
              let frame = imageContext.createCGImage(image, from: frameRect),
              let isFirstFrame = registerValidFrame(
                token: delivery.token,
                generation: delivery.generation,
                stream: stream
              ) else {
            finishFrameDelivery(token: delivery.token)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            defer { finishFrameDelivery(token: delivery.token) }
            guard isActiveCapture(delivery.generation) else { return }
            await onFrame?(frame, delivery.generation)
            guard isActiveCapture(delivery.generation), isFirstFrame else { return }
            await onStarted?(delivery.generation)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let notificationGeneration = stateLock.withLock { () -> Int? in
            guard self.stream === stream else { return nil }
            self.stream = nil
            frameDeliveryToken = nil
            deliveredFirstFrame = false
            let wasActive = acceptsFrames
            acceptsFrames = false
            if wasActive { captureGeneration += 1 }
            return wasActive ? captureGeneration : nil
        }
        if let notificationGeneration {
            let message = error.localizedDescription
            Task { await onStopped?(notificationGeneration, message) }
        }
    }

    nonisolated private static func contentRect(
        from sampleBuffer: CMSampleBuffer,
        boundedBy extent: CGRect
    ) -> CGRect? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let frameInfo = attachments.first else { return extent }

        if let status = Self.number(frameInfo[.status]).flatMap({ SCFrameStatus(rawValue: $0.intValue) }),
           status != .complete { return nil }
        guard let rawRect = Self.rect(frameInfo[.contentRect]) else { return extent }

        let scaleFactor = max(Self.number(frameInfo[.scaleFactor])?.doubleValue ?? 1, 0.01)
        let scaledRect = CGRect(
            x: rawRect.origin.x * scaleFactor,
            y: rawRect.origin.y * scaleFactor,
            width: rawRect.width * scaleFactor,
            height: rawRect.height * scaleFactor
        )

        // ScreenCaptureKit has represented contentRect in both point and pixel
        // coordinates across OS releases. Prefer the largest interpretation that
        // remains inside the delivered pixel buffer, then convert its top-left Y
        // coordinate into Core Image's bottom-left coordinate space.
        let candidates = [scaledRect, rawRect].flatMap { rect -> [CGRect] in
            let flipped = CGRect(
                x: rect.origin.x,
                y: extent.maxY - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            return [flipped, rect]
        }
        let boundedCandidates = candidates.compactMap { candidate -> CGRect? in
            let bounded = candidate.integral.intersection(extent)
            guard !bounded.isNull,
                  bounded.width > 0,
                  bounded.height > 0,
                  bounded.width >= candidate.width * 0.98,
                  bounded.height >= candidate.height * 0.98 else { return nil }
            return bounded
        }
        return boundedCandidates.max { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        } ?? extent
    }

    nonisolated private static func rect(_ value: Any?) -> CGRect? {
        if let value = value as? NSValue { return value.rectValue }
        if let dictionary = value as? NSDictionary {
            return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        }
        return nil
    }

    nonisolated private static func number(_ value: Any?) -> NSNumber? {
        value as? NSNumber
    }
}

private extension AirPlayCaptureService {
    struct WindowSnapshot {
        let window: SCWindow
        let candidate: WindowCandidate
        let rank: Int
    }

    enum CaptureIssue: LocalizedError {
        case screenRecordingPermission
        case noWindows
        case windowUnavailable

        var errorDescription: String? {
            switch self {
            case .screenRecordingPermission:
                "Allow Lumina in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Lumina."
            case .noWindows:
                "No capturable windows are on screen. Start iPhone Screen Mirroring, then try again."
            case .windowUnavailable:
                "That mirrored window is no longer available. Start iPhone Screen Mirroring and choose it again."
            }
        }
    }
}

nonisolated private final class AsyncSerialTaskQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        lock.withLock {
            let previous = tail
            tail = Task { @MainActor in
                if let previous { await previous.value }
                await operation()
            }
        }
    }
}
