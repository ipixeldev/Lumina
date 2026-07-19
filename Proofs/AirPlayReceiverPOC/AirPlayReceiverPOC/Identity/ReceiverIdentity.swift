import CryptoKit
import Foundation

struct ReceiverIdentity: Codable, Equatable, Sendable {
    let deviceID: String
    let pairingIdentifier: String
    let privateKeyBase64: String

    var publicKeyHex: String {
        get throws {
            guard let privateKeyData = Data(base64Encoded: privateKeyBase64) else {
                throw ReceiverIdentityError.invalidPrivateKey
            }
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
            return privateKey.publicKey.rawRepresentation.hexadecimalString
        }
    }
}

enum ReceiverIdentityStore {
    private static let directoryName = "Lumina/AirPlayReceiverPOC"
    private static let fileName = "receiver-identity.json"

    static func loadOrCreate(fileManager: FileManager = .default) throws -> ReceiverIdentity {
        let url = try storageURL(fileManager: fileManager)

        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let identity = try JSONDecoder().decode(ReceiverIdentity.self, from: data)
            try validate(identity)
            return identity
        }

        let identity = ReceiverIdentity(
            deviceID: makeDeviceID(),
            pairingIdentifier: UUID().uuidString.lowercased(),
            privateKeyBase64: Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString()
        )
        try validate(identity)

        let data = try JSONEncoder().encode(identity)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
        return identity
    }

    private static func storageURL(fileManager: FileManager) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    private static func validate(_ identity: ReceiverIdentity) throws {
        let octets = identity.deviceID.split(separator: ":")
        guard
            octets.count == 6,
            octets.allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }),
            UUID(uuidString: identity.pairingIdentifier) != nil
        else {
            throw ReceiverIdentityError.invalidIdentity
        }
        _ = try identity.publicKeyHex
    }

    private static func makeDeviceID() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = (0..<6).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        bytes[0] = (bytes[0] | 0x02) & 0xFE
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

enum ReceiverIdentityError: LocalizedError {
    case invalidIdentity
    case invalidPrivateKey

    var errorDescription: String? {
        switch self {
        case .invalidIdentity:
            "The stored experimental receiver identity is malformed."
        case .invalidPrivateKey:
            "The stored experimental receiver key is malformed."
        }
    }
}

enum ReceiverName {
    // RAOP adds twelve device-ID bytes and "@" to the receiver name. Keeping
    // the base at 50 bytes guarantees both DNS-SD instance labels fit the
    // protocol's 63-byte limit.
    static let maximumReceiverNameUTF8Bytes = 50

    static func make(computerName: String? = Host.current().localizedName) -> String {
        let rawComputerName = computerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableComputerName = rawComputerName?.isEmpty == false
            ? rawComputerName!
            : ProcessInfo.processInfo.hostName
        return truncateBonjourName(
            "Lumina – \(usableComputerName)",
            maximumUTF8Bytes: maximumReceiverNameUTF8Bytes
        )
    }

    static func truncateBonjourName(_ name: String, maximumUTF8Bytes: Int = 63) -> String {
        var result = ""
        for character in name {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumUTF8Bytes else { break }
            result = candidate
        }
        return result
    }
}

private extension Data {
    var hexadecimalString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
