import CryptoKit
import Network
import XCTest
@testable import AirPlayReceiverPOC

final class AirPlayTXTRecordTests: XCTestCase {
    func testAirPlayRecordUsesStableIdentityAndConservativeMirrorProfile() throws {
        let identity = try fixtureIdentity()
        let record = try AirPlayTXTRecord.airPlay(identity: identity)

        XCTAssertEqual(value("deviceid", in: record), "02:12:34:56:78:9A")
        XCTAssertEqual(value("features", in: record), "0x5A7FFEE6,0x0")
        XCTAssertEqual(value("model", in: record), "AppleTV3,2")
        XCTAssertEqual(value("pi", in: record), "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(value("pk", in: record), try identity.publicKeyHex)
        XCTAssertEqual(value("pw", in: record), "false")
        XCTAssertEqual(value("srcvers", in: record), "220.68")
    }

    func testRAOPRecordAndInstanceName() throws {
        let identity = try fixtureIdentity()
        let record = try AirPlayTXTRecord.raop(identity: identity)

        XCTAssertEqual(
            AirPlayTXTRecord.raopInstanceName(receiverName: "Lumina – Test Mac", deviceID: identity.deviceID),
            "02123456789A@Lumina – Test Mac"
        )
        XCTAssertEqual(value("ft", in: record), "0x5A7FFEE6,0x0")
        XCTAssertEqual(value("et", in: record), "0,3,5")
        XCTAssertEqual(value("tp", in: record), "UDP")
        XCTAssertEqual(value("pk", in: record), try identity.publicKeyHex)
    }

    func testReceiverNameIsBrandedAndFitsBonjourLimit() {
        let name = ReceiverName.make(computerName: String(repeating: "Very Long Mac Name ", count: 8))
        let raopName = AirPlayTXTRecord.raopInstanceName(
            receiverName: name,
            deviceID: "02:12:34:56:78:9A"
        )

        XCTAssertTrue(name.hasPrefix("Lumina – "))
        XCTAssertLessThanOrEqual(name.utf8.count, ReceiverName.maximumReceiverNameUTF8Bytes)
        XCTAssertLessThanOrEqual(raopName.utf8.count, 63)
    }

    func testLocalPeerPolicyUsesInterfaceSubnetsForIPv4AndGlobalIPv6() throws {
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: 7_000))
        let ipv4Network = try XCTUnwrap(LocalInterfaceNetwork(
            interfaceName: "en0",
            address: [192, 168, 40, 12],
            netmask: [255, 255, 255, 0]
        ))
        let ipv6Network = try XCTUnwrap(LocalInterfaceNetwork(
            interfaceName: "en0",
            address: Array(try XCTUnwrap(IPv6Address("2001:db8:abcd:12::7")).rawValue),
            netmask: Array(try XCTUnwrap(IPv6Address("ffff:ffff:ffff:ffff::")).rawValue)
        ))
        let networks = [ipv4Network, ipv6Network]

        XCTAssertTrue(LocalPeerPolicy.permits(
            remoteEndpoint: .hostPort(host: .ipv4(try XCTUnwrap(IPv4Address("192.168.40.24"))), port: port),
            localEndpoint: .hostPort(host: .ipv4(try XCTUnwrap(IPv4Address("192.168.40.12"))), port: port),
            networks: networks
        ))
        XCTAssertTrue(LocalPeerPolicy.permits(
            remoteEndpoint: .hostPort(host: .ipv6(try XCTUnwrap(IPv6Address("2001:db8:abcd:12::24"))), port: port),
            localEndpoint: .hostPort(host: .ipv6(try XCTUnwrap(IPv6Address("2001:db8:abcd:12::7"))), port: port),
            networks: networks
        ))

        XCTAssertFalse(LocalPeerPolicy.permits(
            remoteEndpoint: .hostPort(host: .ipv4(try XCTUnwrap(IPv4Address("192.168.41.24"))), port: port),
            localEndpoint: .hostPort(host: .ipv4(try XCTUnwrap(IPv4Address("192.168.40.12"))), port: port),
            networks: networks
        ))
        XCTAssertFalse(LocalPeerPolicy.permits(
            remoteEndpoint: .hostPort(host: .ipv6(try XCTUnwrap(IPv6Address("2001:db8:abcd:13::24"))), port: port),
            localEndpoint: .hostPort(host: .ipv6(try XCTUnwrap(IPv6Address("2001:db8:abcd:12::7"))), port: port),
            networks: networks
        ))
        XCTAssertFalse(LocalPeerPolicy.permits(
            remoteEndpoint: .hostPort(host: .name("example.com", nil), port: port),
            localEndpoint: .hostPort(host: .ipv4(try XCTUnwrap(IPv4Address("192.168.40.12"))), port: port),
            networks: networks
        ))
        XCTAssertFalse(LocalPeerPolicy.permits(
            remoteEndpoint: .hostPort(host: .ipv4(try XCTUnwrap(IPv4Address("192.168.40.24"))), port: port),
            localEndpoint: nil,
            networks: networks
        ))
    }

    private func fixtureIdentity() throws -> ReceiverIdentity {
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x2A, count: 32)
        )
        return ReceiverIdentity(
            deviceID: "02:12:34:56:78:9A",
            pairingIdentifier: "11111111-2222-3333-4444-555555555555",
            privateKeyBase64: privateKey.rawRepresentation.base64EncodedString()
        )
    }

    private func value(_ key: String, in record: [String: Data]) -> String? {
        record[key].flatMap { String(data: $0, encoding: .utf8) }
    }
}
