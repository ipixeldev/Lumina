import Foundation

enum AirPlayServiceDescriptor {
    static let airPlayType = "_airplay._tcp"
    static let raopType = "_raop._tcp"
}

enum AirPlayTXTRecord {
    static func airPlay(identity: ReceiverIdentity) throws -> [String: Data] {
        try encode([
            "deviceid": identity.deviceID,
            "features": "0x5A7FFEE6,0x0",
            "pw": "false",
            "flags": "0x4",
            "model": "AppleTV3,2",
            "pk": identity.publicKeyHex,
            "pi": identity.pairingIdentifier,
            "srcvers": "220.68",
            "vv": "2",
        ])
    }

    static func raop(identity: ReceiverIdentity) throws -> [String: Data] {
        try encode([
            "ch": "2",
            "cn": "0,1,2,3",
            "da": "true",
            "et": "0,3,5",
            "vv": "2",
            "ft": "0x5A7FFEE6,0x0",
            "am": "AppleTV3,2",
            "md": "0,1,2",
            "rhd": "5.6.0.0",
            "pw": "false",
            "sf": "0x4",
            "sr": "44100",
            "ss": "16",
            "sv": "false",
            "tp": "UDP",
            "txtvers": "1",
            "vs": "220.68",
            "vn": "65537",
            "pk": identity.publicKeyHex,
        ])
    }

    static func raopInstanceName(receiverName: String, deviceID: String) -> String {
        let compactID = deviceID
            .replacingOccurrences(of: ":", with: "")
            .uppercased()
        return ReceiverName.truncateBonjourName("\(compactID)@\(receiverName)")
    }

    private static func encode(_ values: [String: String]) throws -> [String: Data] {
        try values.mapValues { value in
            guard let data = value.data(using: .utf8) else {
                throw TXTRecordError.invalidUTF8
            }
            return data
        }
    }
}

enum TXTRecordError: LocalizedError {
    case invalidUTF8

    var errorDescription: String? {
        "A receiver TXT value could not be encoded as UTF-8."
    }
}
