import Foundation
import Testing
@testable import Lumina

struct MJPEGStreamClientTests {
    @Test func parsesChunkedMultipartFrames() {
        let first = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        let second = Data([0xFF, 0xD8, 0x02, 0x03, 0xFF, 0xD9])
        let payload = part(first) + part(second)
        var parser = MJPEGFrameParser()
        var frames: [Data] = []

        for chunk in payload.chunks(ofCount: 7) {
            frames.append(contentsOf: parser.append(chunk))
        }

        #expect(frames == [first, second])
    }

    private func part(_ frame: Data) -> Data {
        Data("--BoundaryString\r\nContent-type: image/jpeg\r\nContent-Length: \(frame.count)\r\n\r\n".utf8)
            + frame
            + Data("\r\n\r\n".utf8)
    }
}

private extension Data {
    func chunks(ofCount count: Int) -> [Data] {
        stride(from: startIndex, to: endIndex, by: count).map {
            Data(self[$0..<Swift.min($0 + count, endIndex)])
        }
    }
}
