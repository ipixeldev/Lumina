import CryptoKit
import Foundation
import Security

nonisolated protocol InstallationIdentityProviding: Sendable {
    func stableBundleSuffix() throws -> String
}

nonisolated enum InstallationIdentityError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case invalidStoredValue
}

nonisolated struct KeychainInstallationIdentityProvider: InstallationIdentityProviding {
    private let service = "com.iPixeldev.Lumina.runner-identity"
    private let account = "installation"

    func stableBundleSuffix() throws -> String {
        let identity = try storedIdentity() ?? createIdentity()
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "u" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private func storedIdentity() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw InstallationIdentityError.keychain(status) }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              UUID(uuidString: value) != nil else {
            throw InstallationIdentityError.invalidStoredValue
        }
        return value
    }

    private func createIdentity() throws -> String {
        let value = UUID().uuidString
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem, let stored = try storedIdentity() { return stored }
        guard status == errSecSuccess else { throw InstallationIdentityError.keychain(status) }
        return value
    }
}

nonisolated struct SigningIdentityResolver {
    func resolve(from certificates: [DeveloperCertificateIdentity]) -> DeveloperCertificateIdentity? {
        certificates
            .filter { $0.canSign && $0.teamID != nil }
            .sorted {
                ($0.expirationDate ?? .distantPast) > ($1.expirationDate ?? .distantPast)
            }
            .first
    }
}
