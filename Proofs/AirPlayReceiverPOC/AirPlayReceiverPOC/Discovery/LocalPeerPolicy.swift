import Darwin
import Foundation
import Network

struct LocalInterfaceNetwork: Equatable, Sendable {
    let interfaceName: String
    let address: [UInt8]
    let netmask: [UInt8]

    init?(interfaceName: String, address: [UInt8], netmask: [UInt8]) {
        guard
            !interfaceName.isEmpty,
            (address.count == 4 || address.count == 16),
            address.count == netmask.count,
            netmask.contains(where: { $0 != 0 })
        else {
            return nil
        }
        self.interfaceName = interfaceName
        self.address = address
        self.netmask = netmask
    }

    func contains(_ candidate: [UInt8]) -> Bool {
        guard candidate.count == address.count else { return false }
        return address.indices.allSatisfy { index in
            address[index] & netmask[index] == candidate[index] & netmask[index]
        }
    }
}

enum LocalPeerPolicy {
    static func permits(
        remoteEndpoint: NWEndpoint,
        localEndpoint: NWEndpoint?,
        networks: [LocalInterfaceNetwork] = currentInterfaceNetworks()
    ) -> Bool {
        guard
            let remoteAddress = endpointAddress(from: remoteEndpoint),
            let localEndpoint,
            let localAddress = endpointAddress(from: localEndpoint)
        else {
            return false
        }

        return networks.contains { network in
            guard network.address == localAddress.bytes else { return false }
            if let localInterfaceName = localAddress.interfaceName,
               network.interfaceName != localInterfaceName {
                return false
            }
            if let remoteInterfaceName = remoteAddress.interfaceName,
               network.interfaceName != remoteInterfaceName {
                return false
            }
            return network.contains(remoteAddress.bytes)
        }
    }

    static func currentInterfaceNetworks() -> [LocalInterfaceNetwork] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
        defer { freeifaddrs(firstAddress) }

        var result: [LocalInterfaceNetwork] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = cursor {
            let entry = current.pointee
            cursor = entry.ifa_next

            guard
                entry.ifa_flags & UInt32(IFF_UP) != 0,
                entry.ifa_flags & UInt32(IFF_POINTOPOINT) == 0,
                let namePointer = entry.ifa_name,
                let addressPointer = entry.ifa_addr,
                let netmaskPointer = entry.ifa_netmask,
                let address = addressBytes(from: UnsafePointer(addressPointer)),
                let netmask = addressBytes(from: UnsafePointer(netmaskPointer)),
                let network = LocalInterfaceNetwork(
                    interfaceName: String(cString: namePointer),
                    address: address,
                    netmask: netmask
                )
            else {
                continue
            }
            result.append(network)
        }
        return result
    }

    private static func endpointAddress(from endpoint: NWEndpoint) -> EndpointAddress? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case let .ipv4(address):
            return EndpointAddress(bytes: Array(address.rawValue), interfaceName: nil)
        case let .ipv6(address):
            return EndpointAddress(
                bytes: normalizedIPv6(Array(address.rawValue)),
                interfaceName: address.interface?.name
            )
        case let .name(name, _):
            if let address = IPv4Address(name) {
                return EndpointAddress(bytes: Array(address.rawValue), interfaceName: nil)
            }
            if let address = IPv6Address(name) {
                return EndpointAddress(
                    bytes: normalizedIPv6(Array(address.rawValue)),
                    interfaceName: address.interface?.name
                )
            }
            return nil
        @unknown default:
            return nil
        }
    }

    private static func addressBytes(from pointer: UnsafePointer<sockaddr>) -> [UInt8]? {
        switch Int32(pointer.pointee.sa_family) {
        case AF_INET:
            var address = UnsafeRawPointer(pointer)
                .assumingMemoryBound(to: sockaddr_in.self)
                .pointee
                .sin_addr
            return withUnsafeBytes(of: &address) { Array($0) }

        case AF_INET6:
            var address = UnsafeRawPointer(pointer)
                .assumingMemoryBound(to: sockaddr_in6.self)
                .pointee
                .sin6_addr
            return withUnsafeBytes(of: &address) { normalizedIPv6(Array($0)) }

        default:
            return nil
        }
    }

    private static func normalizedIPv6(_ bytes: [UInt8]) -> [UInt8] {
        let isIPv4Mapped = bytes.count == 16
            && bytes.prefix(10).allSatisfy { $0 == 0 }
            && bytes[10] == 0xFF
            && bytes[11] == 0xFF
        return isIPv4Mapped ? Array(bytes.suffix(4)) : bytes
    }

    private struct EndpointAddress {
        let bytes: [UInt8]
        let interfaceName: String?
    }
}
