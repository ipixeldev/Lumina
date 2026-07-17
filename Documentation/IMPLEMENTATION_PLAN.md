# MirrorBridge implementation plan

## Repository inspection (2026-07-17)

- The repository is an Xcode macOS SwiftUI project with one application target, one unit-test target, and one UI-test target.
- The existing app is the untouched Xcode template and builds successfully with Xcode 26.1.1 when code signing is disabled.
- The original deployment target is macOS 26.1. Phase 1 lowers it to the required macOS 14.0 baseline.
- Automatic signing is configured with a development team in the project file. No certificate validity or private-key availability has been checked yet; that belongs to Phase 2.
- No WebDriverAgent source, Swift package dependency, port-forwarding helper, or third-party license is present.
- No physical-device discovery or device connection code exists.
- Hardened Runtime is enabled. Phase 3 confirmed that App Sandbox blocks Xcode/CoreDevice command-line services, so the app target disables App Sandbox with the rationale recorded in the Phase 3 report.
- The Xcode target and Swift module remain named `Lumina` in Phase 1 to avoid mixing a project-identity migration with the architectural foundation. The shipped product and UI are named `MirrorBridge`.

## Proposed final source structure

```text
Lumina/                         # Xcode synchronized application source root
├── Application/
├── Domain/
├── DeviceManagement/
├── DeveloperEnvironment/
├── RunnerManagement/
├── Automation/
├── Transport/
├── Mirroring/
├── Input/
├── Security/
├── Diagnostics/
├── UI/
│   ├── Welcome/
│   ├── DevicePicker/
│   ├── SetupAssistant/
│   ├── CertificateSetup/
│   ├── RunnerInstallation/
│   ├── MirrorWindow/
│   ├── DeviceToolbar/
│   ├── Settings/
│   ├── Diagnostics/
│   ├── Logs/
│   └── About/
├── Resources/
└── Assets.xcassets/
LuminaTests/
├── Domain/
├── DeveloperEnvironment/
├── DeviceManagement/
├── RunnerManagement/
├── Automation/
├── Transport/
├── Mirroring/
├── Input/
├── Security/
└── TestSupport/
LuminaUITests/
Vendor/
└── WebDriverAgent/            # Later pinned source/submodule or documented local checkout
Patches/
└── WebDriverAgent/            # Clearly identified MirrorBridge changes, if required
Licenses/
Documentation/
```

Directories are added only when their phase contains real code; empty architectural folders are not committed.

## Phase 1 — native macOS foundation

1. Replace the template UI with the MirrorBridge app entry point and native split-view navigation.
2. Add the complete explicit workflow state model, state metadata, guarded transitions, and typed transition errors.
3. Add a protocol-based dependency container and structured OSLog categories.
4. Add the welcome experience and a setup-assistant shell that clearly identifies future-phase functionality rather than simulating checks.
5. Add unit tests for valid transitions, invalid transitions, stopping, diagnostics metadata, and progress metadata.
6. Build and test against macOS 14 with Swift 6 language mode.

## Phase 2 — developer environment checker (complete)

1. Introduce command execution behind a typed `ProcessRunning` protocol using executable URLs and argument arrays, never shell-concatenated input.
2. Implement macOS, Xcode path/version, license readiness, Command Line Tools, iOS SDK, disk-space, and architecture checks.
3. Query Apple Development identities using Security.framework where practical, falling back to structured parsing of `security find-identity`; never expose private-key material.
4. Model individual check results and exact remediation instructions; feed them into guarded state transitions.
5. Add certificate selection, command construction, environment-result parsing, and failure tests using captured fixtures.

Exit criterion: real local results appear in the setup assistant; no iPhone access is attempted.

Implemented in `Documentation/PHASE_2_REPORT.md`. The production path uses real local system information, structured Xcode SDK output, and Security.framework identities. No iPhone access is attempted in this phase.

## Phase 3 — physical device discovery (complete)

1. Verify the current `xcrun devicectl` JSON schema on the installed Xcode and encapsulate it behind `DeviceDiscovering`.
2. Implement physical iPhone discovery and normalized device models, excluding simulator data from production results.
3. Add redacted identifiers, USB/network connection state, pairing/trust/lock fields only where the Apple tool actually reports them, and honest unknown states otherwise.
4. Add a bounded connection monitor with cancellation and non-tight polling/event observation.
5. Add fixture-driven parser tests and perform an explicitly recorded physical-device verification.

Exit criterion: a real connected iPhone can be shown with sourced, non-mocked properties.

Implemented in `Documentation/PHASE_3_REPORT.md`. A physical iPhone connected over USB was discovered in the signed application-level test with real model, iOS, pairing, Developer Mode, lock, and network-availability fields.

## Phase 4 — WebDriverAgent source and signing

1. Select a maintained upstream only after checking its current routes, release compatibility, and license; record repository URL, commit, notices, and modifications.
2. Keep upstream source pinned under `Vendor/` or use a user-selected checkout; never download or execute code silently.
3. Generate a stable per-install bundle suffix in local secure storage and resolve the selected team/signing identity without hard-coded values.
4. Build a typed `xcodebuild` invocation, streamed output capture, result-bundle handling, cancellation, signature verification, and readable error parser.
5. Add fixture-based build command/error tests; do not claim success before a physical-device signed build succeeds.

Exit criterion: the chosen WDA runner builds and its output signature is verified for the selected device/team.

## Phase 5 — install, launch, and local transport

1. Verify the supported `devicectl` install/launch/service workflow for the current Xcode/iOS combination; select and license any fallback helper explicitly.
2. Install and launch the signed XCTest runner with captured, redacted diagnostics.
3. Establish a loopback-only local endpoint and lifecycle-managed USB forwarding/tunnel; never bind a proxy to all interfaces.
4. Add runner health monitoring, cancellation, disconnect detection, and bounded exponential recovery.
5. Verify the WDA status response before enabling any session action.

Exit criterion: a physical iPhone runner responds through a local USB transport.

## Phase 6 — first automation proof

1. Inspect the pinned WDA route definitions and document every endpoint used with version compatibility notes.
2. Implement typed status/session/device/window/orientation/screenshot/tap/swipe/home/text operations with schema and HTTP validation.
3. Add the `AutomationSessionManager` actor and a diagnostic proof screen; commands remain disabled until a verified session exists.
4. Build a local mock WDA integration-test server covering success, malformed JSON, HTTP failures, expiration, delay, and transport loss.
5. Run the diagnostic proof on a physical iPhone and record each verified operation without claiming untested functionality.

Exit criterion: status, screenshot, center tap, upward swipe, Home, and test text are verified on a physical iPhone.

## Phase boundary

Phase 7 screenshot mirroring starts only after the Phase 6 physical-device proof. Visual streaming and control remain independent channels throughout the design.
