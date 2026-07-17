import Foundation

nonisolated enum RunnerSetupLogParser {
    static func installationIssue(for output: String) -> RunnerSetupIssue {
        let normalized = output.lowercased()
        if normalized.contains("device is locked") ||
            (normalized.contains("passcode") && normalized.contains("locked")) {
            return issue("LUM-INSTALL-002", "The iPhone is locked", "Unlock the iPhone physically and retry installation.")
        }
        if normalized.contains("developer mode") && normalized.contains("disabled") {
            return issue("LUM-INSTALL-003", "Developer Mode is disabled", "Enable Developer Mode, restart the iPhone, and confirm the on-device prompt.")
        }
        if normalized.contains("signature") || normalized.contains("provision") || normalized.contains("applicationverificationfailed") {
            return issue("LUM-INSTALL-004", "iOS rejected the runner signature", "Rebuild the runner with a current Apple Development identity and provisioning profile.")
        }
        if normalized.contains("not connected") || normalized.contains("unavailable") || normalized.contains("could not find") {
            return issue("LUM-INSTALL-005", "The target iPhone is unavailable", "Reconnect the trusted iPhone by USB, unlock it, and retry.")
        }
        return issue("LUM-INSTALL-006", "The runner could not be installed", "Open the local diagnostics, correct the reported Apple device error, and retry.")
    }

    static func launchIssue(for output: String) -> RunnerSetupIssue {
        let normalized = output.lowercased()
        if normalized.contains("device is locked") || normalized.contains("passcode") && normalized.contains("locked") {
            return issue("LUM-LAUNCH-002", "The iPhone is locked", "Unlock the iPhone physically and launch the runner again.")
        }
        if normalized.contains("not trusted") || normalized.contains("pairing") {
            return issue("LUM-LAUNCH-003", "The developer connection is not trusted", "Reconnect by USB and complete any Trust This Computer confirmation on the iPhone.")
        }
        if (normalized.contains("test runner") && normalized.contains("failed")) ||
            normalized.contains("early unexpected exit") {
            return issue("LUM-LAUNCH-004", "The XCTest runner stopped during launch", "Keep the iPhone unlocked, rebuild the runner, and retry.")
        }
        return issue("LUM-LAUNCH-005", "The XCTest runner did not launch", "Inspect Xcode diagnostics, then rebuild and retry the signed runner.")
    }

    static let connectionIssue = issue(
        "LUM-CONNECT-001",
        "The automation endpoint did not respond",
        "Keep the iPhone unlocked and connected. If using Wi-Fi, confirm the trusted developer tunnel is connected, then retry."
    )

    private static func issue(_ code: String, _ title: String, _ recovery: String) -> RunnerSetupIssue {
        RunnerSetupIssue(
            code: code,
            title: title,
            explanation: "Lumina could not establish a verified local WebDriverAgent connection.",
            recovery: recovery,
            retryIsSafe: true
        )
    }
}
