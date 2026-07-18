import AppKit
@preconcurrency import CoreImage
@preconcurrency import CoreMedia
@preconcurrency import ScreenCaptureKit

final class AirPlayCaptureService: NSObject, @unchecked Sendable {
    var onFrame: (@Sendable (CGImage, Int) async -> Void)?
    var onStarted: (@Sendable (Int) async -> Void)?
    var onStopped: (@Sendable (Int, String?) async -> Void)?

    private let sampleQueue = DispatchQueue(label: "com.iPixeldev.Lumina.airplay-capture", qos: .userInteractive)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let stateLock = NSLock()
    private let lifecycleQueue = AsyncSerialTaskQueue()
    private var stream: SCStream?
    private var captureGeneration = 0
    private var acceptsFrames = false
    private var frameDeliveryToken: UUID?

    func isCurrentGeneration(_ generation: Int) -> Bool {
        stateLock.withLock { captureGeneration == generation }
    }

    func isActiveCapture(_ generation: Int) -> Bool {
        stateLock.withLock {
            captureGeneration == generation && acceptsFrames && stream != nil
        }
    }

    override init() {
        super.init()
        configurePicker()
        let picker = SCContentSharingPicker.shared
        picker.maximumStreamCount = 1
        picker.add(self)
        picker.isActive = true
    }

    @MainActor
    func chooseMirroredContent() {
        configurePicker()
        // Present on the next run-loop pass. Menu actions can otherwise leave the
        // system picker attached to a disappearing menu window.
        DispatchQueue.main.async {
            SCContentSharingPicker.shared.present(using: .window)
        }
    }

    @MainActor
    private func configurePicker() {
        let picker = SCContentSharingPicker.shared
        var configuration = picker.defaultConfiguration
        configuration.allowedPickerModes = [.singleWindow]
        configuration.allowsChangingSelectedContent = true
        configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier].compactMap { $0 }
        configuration.excludedWindowIDs = NSApplication.shared.windows
            .map(\.windowNumber)
            .filter { $0 > 0 }
        picker.defaultConfiguration = configuration
    }

    func stop() {
        stateLock.withLock {
            captureGeneration += 1
            acceptsFrames = false
            frameDeliveryToken = nil
        }
        lifecycleQueue.enqueue { [weak self] in
            guard let self, let stream = takeActiveStream() else { return }
            try? await stream.stopCapture()
        }
    }

    private func beginCaptureRequest() -> Int {
        stateLock.withLock {
            captureGeneration += 1
            acceptsFrames = false
            frameDeliveryToken = nil
            return captureGeneration
        }
    }

    private func start(filter: SCContentFilter, existingStream: SCStream?) {
        let generation = beginCaptureRequest()
        lifecycleQueue.enqueue { [weak self] in
            guard let self else { return }
            await performStart(filter: filter, existingStream: existingStream, generation: generation)
        }
    }

    private func performStart(filter: SCContentFilter, existingStream: SCStream?, generation: Int) async {
        guard isCurrent(generation) else { return }
        var startingStream: SCStream?
        do {
            if let activeStream = currentStream(),
               let existingStream,
               existingStream === activeStream {
                try await activeStream.updateConfiguration(Self.configuration(for: filter))
                guard isCurrent(generation) else { return }
                try await activeStream.updateContentFilter(filter)
                guard activate(activeStream, generation: generation) else { return }
                await onStarted?(generation)
                return
            }

            if let previousStream = takeActiveStream() {
                try? await previousStream.stopCapture()
            }
            guard isCurrent(generation) else { return }

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
            await onStarted?(generation)
        } catch {
            if let startingStream { try? await startingStream.stopCapture() }
            guard isCurrent(generation) else { return }
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
        let maximumDimension: CGFloat = 2560
        let scale = min(1, maximumDimension / max(sourceWidth, sourceHeight))
        configuration.width = Int(sourceWidth * scale)
        configuration.height = Int(sourceHeight * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.captureResolution = .best
        return configuration
    }

    private func isCurrent(_ generation: Int) -> Bool {
        stateLock.withLock { captureGeneration == generation }
    }

    private func currentStream() -> SCStream? {
        stateLock.withLock { stream }
    }

    private func takeActiveStream() -> SCStream? {
        stateLock.withLock {
            let activeStream = stream
            stream = nil
            acceptsFrames = false
            frameDeliveryToken = nil
            return activeStream
        }
    }

    private func activate(_ candidate: SCStream, generation: Int) -> Bool {
        stateLock.withLock {
            guard captureGeneration == generation else { return false }
            stream = candidate
            acceptsFrames = true
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
            frameDeliveryToken = nil
            return captureGeneration
        }
    }
}

extension AirPlayCaptureService: SCContentSharingPickerObserver {
    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        start(filter: filter, existingStream: stream)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        if let generation = invalidateInactiveCapture() {
            Task { await onStopped?(generation, nil) }
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        if let generation = invalidateInactiveCapture() {
            let message = error.localizedDescription
            Task { await onStopped?(generation, message) }
        }
    }
}

extension AirPlayCaptureService: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let delivery = beginFrameDelivery(for: stream) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let frameRect = Self.contentRect(from: sampleBuffer, boundedBy: image.extent) else {
            finishFrameDelivery(token: delivery.token)
            return
        }
        guard let frame = imageContext.createCGImage(image, from: frameRect) else {
            finishFrameDelivery(token: delivery.token)
            return
        }
        Task { [weak self] in
            await self?.onFrame?(frame, delivery.generation)
            self?.finishFrameDelivery(token: delivery.token)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let notificationGeneration = stateLock.withLock { () -> Int? in
            guard self.stream === stream else { return nil }
            self.stream = nil
            frameDeliveryToken = nil
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

    private static func contentRect(from sampleBuffer: CMSampleBuffer, boundedBy extent: CGRect) -> CGRect? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let frameInfo = attachments.first else { return extent }
        if let statusValue = frameInfo[.status] as? Int,
           SCFrameStatus(rawValue: statusValue) != .complete { return nil }
        guard let contentRectValue = frameInfo[.contentRect],
              let contentRect = CGRect(
                dictionaryRepresentation: contentRectValue as! CFDictionary
              ),
              let scaleFactor = frameInfo[.scaleFactor] as? CGFloat else { return extent }
        let pixelRect = CGRect(
            x: contentRect.origin.x * scaleFactor,
            y: contentRect.origin.y * scaleFactor,
            width: contentRect.width * scaleFactor,
            height: contentRect.height * scaleFactor
        )
        let bounded = pixelRect.integral.intersection(extent)
        guard !bounded.isNull, bounded.width > 0, bounded.height > 0 else { return extent }
        return bounded
    }
}

private final class AsyncSerialTaskQueue: @unchecked Sendable {
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
