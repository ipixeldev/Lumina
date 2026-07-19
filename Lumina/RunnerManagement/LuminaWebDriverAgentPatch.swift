import CryptoKit
import Foundation

nonisolated enum LuminaWebDriverAgentPatch {
    static let revision = "overlay-input-v6"

    static var cacheIdentity: String {
        cacheIdentity(for: url())
    }

    static func cacheIdentity(for patchURL: URL) -> String {
        let patchDigest = (try? Data(contentsOf: patchURL)).map { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } ?? "missing-patch"
        return "\(WebDriverAgentPin.commit):\(revision):\(patchDigest)"
    }

    static func url() -> URL {
        if let bundledPatch = Bundle.main.url(
            forResource: "WebDriverAgent-Lumina",
            withExtension: "patch"
        ) {
            return bundledPatch
        }

#if DEBUG
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let repositoryURL = sourceFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repositoryURL.appendingPathComponent(
            "Lumina/Resources/WebDriverAgent-Lumina.patch",
            isDirectory: false
        )
#else
        // Return the expected bundle location so a packaging error fails the
        // runner build explicitly instead of silently using unpatched WDA.
        return Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent("WebDriverAgent-Lumina.patch", isDirectory: false)
#endif
    }
}
