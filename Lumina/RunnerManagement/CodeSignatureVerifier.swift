import Foundation
import Security

nonisolated protocol CodeSignatureVerifying: Sendable {
    func verify(appURL: URL, expectedTeamIdentifier: String, expectedBundleIdentifier: String) throws -> RunnerCodeSignature
}

nonisolated struct SecurityCodeSignatureVerifier: CodeSignatureVerifying {
    func verify(appURL: URL, expectedTeamIdentifier: String, expectedBundleIdentifier: String) throws -> RunnerCodeSignature {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess else {
            throw RunnerBuildError.invalidSignature(Self.issue("The runner code signature is invalid"))
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [CFString: Any],
              let identifier = values[kSecCodeInfoIdentifier] as? String,
              let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String,
              let uniqueCode = values[kSecCodeInfoUnique] as? Data,
              !uniqueCode.isEmpty,
              teamIdentifier == expectedTeamIdentifier,
              identifier == expectedBundleIdentifier else {
            throw RunnerBuildError.invalidSignature(Self.issue("The runner signature does not match the selected team or bundle"))
        }
        let codeDirectoryHash = uniqueCode.map { String(format: "%02x", $0) }.joined()
        return RunnerCodeSignature(
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            codeDirectoryHash: codeDirectoryHash
        )
    }

    private static func issue(_ title: String) -> RunnerBuildIssue {
        RunnerBuildIssue(
            code: "LUM-BUILD-005",
            title: title,
            explanation: "Lumina refuses to install a runner whose local signature does not match its build configuration.",
            recovery: "Rebuild with a current Apple Development identity and inspect Xcode signing diagnostics.",
            retryIsSafe: true
        )
    }
}
