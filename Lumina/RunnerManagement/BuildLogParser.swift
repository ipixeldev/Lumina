import Foundation

nonisolated enum BuildLogParser {
    static func issue(for output: String) -> RunnerBuildIssue {
        let normalized = output.lowercased()
        if normalized.contains("requires a development team") ||
            (normalized.contains("development_team") && normalized.contains("empty")) {
            return issue("LUM-BUILD-002", "Development team is not configured", "Select a usable Apple Development identity in Xcode.")
        }
        if normalized.contains("no accounts: add a new account") {
            return issue(
                "LUM-BUILD-011",
                "Xcode is not signed in",
                "Open Xcode Settings → Accounts, add your Apple ID, select your development team, and retry."
            )
        }
        if normalized.contains("no profiles for") || normalized.contains("provisioning profile") {
            return issue("LUM-BUILD-004", "Provisioning failed", "Keep the iPhone connected and allow Xcode to create or refresh its development profile.")
        }
        if normalized.contains("developer mode is disabled") {
            return issue("LUM-DEV-003", "Developer Mode is disabled", "Enable Developer Mode on the iPhone, restart it, and confirm the on-device prompt.")
        }
        if normalized.contains("device is locked") ||
            (normalized.contains("passcode") && normalized.contains("locked")) {
            return issue("LUM-DEV-002", "The iPhone is locked", "Unlock the iPhone physically and retry the build.")
        }
        if normalized.contains("certificate") && normalized.contains("expired") {
            return issue("LUM-BUILD-003", "Development certificate expired", "Create a current Apple Development certificate in Xcode Settings → Accounts.")
        }
        if normalized.contains("failed to verify code signature") || normalized.contains("code signature invalid") {
            return issue("LUM-BUILD-005", "Runner signature was rejected", "Refresh signing assets in Xcode and rebuild the runner.")
        }
        if normalized.contains("ineligible destinations") || normalized.contains("device is not connected") {
            return issue("LUM-DEV-004", "The target iPhone is unavailable", "Reconnect the trusted iPhone by USB, unlock it, and retry.")
        }
        return issue("LUM-BUILD-006", "WebDriverAgent did not build", "Open build diagnostics, correct the reported Xcode error, and retry.")
    }

    private static func issue(_ code: String, _ title: String, _ recovery: String) -> RunnerBuildIssue {
        RunnerBuildIssue(
            code: code,
            title: title,
            explanation: "Xcode could not produce a signed WebDriverAgent runner for this iPhone.",
            recovery: recovery,
            retryIsSafe: true
        )
    }
}
