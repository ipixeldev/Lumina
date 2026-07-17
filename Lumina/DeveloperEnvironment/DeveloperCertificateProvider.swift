import CryptoKit
import Foundation
import Security

nonisolated enum DeveloperCertificateProviderError: Error, Equatable, Sendable {
    case keychainQueryFailed(status: OSStatus)
}

nonisolated protocol DeveloperCertificateProviding: Sendable {
    func developmentCertificates() async throws -> [DeveloperCertificateIdentity]
}

nonisolated struct KeychainDeveloperCertificateProvider: DeveloperCertificateProviding {
    func developmentCertificates() async throws -> [DeveloperCertificateIdentity] {
        try await Task.detached(priority: .utility) {
            try Self.queryIdentities()
        }.value
    }

    private static func queryIdentities() throws -> [DeveloperCertificateIdentity] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw DeveloperCertificateProviderError.keychainQueryFailed(status: status)
        }

        guard let identities = result as? [SecIdentity] else {
            return []
        }

        return identities.compactMap(makeIdentity).sorted {
            if $0.canSign != $1.canSign { return $0.canSign }
            return ($0.expirationDate ?? .distantPast) > ($1.expirationDate ?? .distantPast)
        }
    }

    private static func makeIdentity(_ identity: SecIdentity) -> DeveloperCertificateIdentity? {
        var certificateReference: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificateReference) == errSecSuccess,
              let certificate = certificateReference else {
            return nil
        }

        var commonNameReference: CFString?
        guard SecCertificateCopyCommonName(certificate, &commonNameReference) == errSecSuccess,
              let displayName = commonNameReference as String?,
              displayName.hasPrefix("Apple Development:") else {
            return nil
        }

        var privateKeyReference: SecKey?
        let hasPrivateKey = SecIdentityCopyPrivateKey(identity, &privateKeyReference) == errSecSuccess
        let expirationDate = certificateDate(certificate, oid: kSecOIDX509V1ValidityNotAfter)
        let notBeforeDate = certificateDate(certificate, oid: kSecOIDX509V1ValidityNotBefore)
        let now = Date()
        let isCurrentlyValid = (notBeforeDate.map { $0 <= now } ?? true)
            && (expirationDate.map { $0 > now } ?? false)
        let teamID = certificateString(certificate, oid: kSecOIDOrganizationalUnitName)
            ?? trailingTeamIdentifier(in: displayName)

        let certificateData = SecCertificateCopyData(certificate) as Data
        let certificateID = SHA256.hash(data: certificateData)
            .map { String(format: "%02x", $0) }
            .joined()

        return DeveloperCertificateIdentity(
            id: certificateID,
            displayName: displayName,
            teamID: teamID,
            expirationDate: expirationDate,
            hasPrivateKey: hasPrivateKey,
            isCurrentlyValid: isCurrentlyValid
        )
    }

    private static func certificateDate(_ certificate: SecCertificate, oid: CFString) -> Date? {
        let value = propertyValue(certificate, oid: oid)
        if let date = value as? Date {
            return date
        }
        if let absoluteTime = value as? NSNumber {
            return Date(timeIntervalSinceReferenceDate: absoluteTime.doubleValue)
        }
        return nil
    }

    private static func certificateString(_ certificate: SecCertificate, oid: CFString) -> String? {
        if let direct = propertyValue(certificate, oid: oid).flatMap(firstCertificateString) {
            return direct
        }
        guard let subject = propertyValue(certificate, oid: kSecOIDX509V1SubjectName) else {
            return nil
        }
        return certificateString(in: subject, matchingLabel: oid as String)
    }

    static func certificateString(in value: Any, matchingLabel expectedLabel: String) -> String? {
        if let dictionary = value as? NSDictionary {
            if let label = dictionary.object(forKey: kSecPropertyKeyLabel) as? String,
               label == expectedLabel,
               let nested = dictionary.object(forKey: kSecPropertyKeyValue) {
                return firstCertificateString(in: nested)
            }
            for nested in dictionary.allValues {
                if let string = certificateString(in: nested, matchingLabel: expectedLabel) {
                    return string
                }
            }
        }
        if let values = value as? NSArray {
            for nested in values {
                if let string = certificateString(in: nested, matchingLabel: expectedLabel) {
                    return string
                }
            }
        }
        return nil
    }

    static func firstCertificateString(in value: Any) -> String? {
        if let string = value as? String {
            return string
        }
        if let dictionary = value as? NSDictionary {
            if let nested = dictionary.object(forKey: kSecPropertyKeyValue),
               let string = firstCertificateString(in: nested) {
                return string
            }
            for nested in dictionary.allValues {
                if let string = firstCertificateString(in: nested) {
                    return string
                }
            }
        }
        if let values = value as? NSArray {
            for nested in values {
                if let string = firstCertificateString(in: nested) {
                    return string
                }
            }
        }
        return nil
    }

    private static func propertyValue(_ certificate: SecCertificate, oid: CFString) -> Any? {
        guard let properties = SecCertificateCopyValues(certificate, [oid] as CFArray, nil)
                as? [CFString: [CFString: Any]],
              let property = properties[oid] else {
            return nil
        }
        return property[kSecPropertyKeyValue]
    }

    private static func trailingTeamIdentifier(in displayName: String) -> String? {
        guard let open = displayName.lastIndex(of: "("), displayName.hasSuffix(")") else {
            return nil
        }
        let start = displayName.index(after: open)
        let end = displayName.index(before: displayName.endIndex)
        let candidate = String(displayName[start..<end])
        guard candidate.count == 10,
              candidate.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            return nil
        }
        return candidate
    }
}
