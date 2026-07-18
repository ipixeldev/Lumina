@preconcurrency import CoreImage
@preconcurrency import CoreMedia
@preconcurrency import ScreenCaptureKit

final class AirPlayCaptureService: NSObject, @unchecked Sendable {
    var onFrame: (@Sendable (CGImage) -> Void)?
    var onStarted: (@Sendable () -> Void)?
    var onStopped: (@Sendable (String?) -> Void)?

    private let sampleQueue = DispatchQueue(label: "com.iPixeldev.Lumina.airplay-capture", qos: .userInteractive)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var stream: SCStream?

    override init() {
        super.init()
        let picker = SCContentSharingPicker.shared
        var configuration = picker.defaultConfiguration
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
        configuration.allowsChangingSelectedContent = true
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        picker.add(self)
        picker.isActive = true
    }

    @MainActor
    func chooseMirroredContent() {
        SCContentSharingPicker.shared.present(using: .window)
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task {
            try? await stream.stopCapture()
        }
    }

    private func start(filter: SCContentFilter, existingStream: SCStream?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if let existingStream {
                    try await existingStream.updateContentFilter(filter)
                    stream = existingStream
                } else {
                    stop()
                    let configuration = SCStreamConfiguration()
                    let sourceWidth = max(filter.contentRect.width * CGFloat(filter.pointPixelScale), 1)
                    let sourceHeight = max(filter.contentRect.height * CGFloat(filter.pointPixelScale), 1)
                    let maximumDimension: CGFloat = 2560
                    let scale = min(1, maximumDimension / max(sourceWidth, sourceHeight))
                    configuration.width = Int(sourceWidth * scale)
                    configuration.height = Int(sourceHeight * scale)
                    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                    configuration.queueDepth = 5
                    configuration.pixelFormat = kCVPixelFormatType_32BGRA
                    configuration.showsCursor = false
                    configuration.capturesAudio = false
                    configuration.scalesToFit = true
                    configuration.preservesAspectRatio = true
                    configuration.captureResolution = .best

                    let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
                    try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
                    try await newStream.startCapture()
                    stream = newStream
                }
                onStarted?()
            } catch {
                onStopped?(error.localizedDescription)
            }
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
        if self.stream == nil { onStopped?(nil) }
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        onStopped?(error.localizedDescription)
    }
}

extension AirPlayCaptureService: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let frame = imageContext.createCGImage(image, from: image.extent) else { return }
        onFrame?(frame)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        if self.stream === stream { self.stream = nil }
        onStopped?(error.localizedDescription)
    }
}
