# Phase 3 report — physical device discovery

Completed: 2026-07-17

## Outcome

MirrorBridge now discovers physical iPhones using current Apple developer tools, displays sourced device information, and continuously detects changes without mocked production data. Discovery starts automatically after the Mac tooling checks are ready and does not wait for runner-signing readiness.

The app displays:

- device name and marketing model
- iOS version
- active USB or Wi-Fi developer interface
- pairing state
- Developer Mode state
- current lock state when available
- partially redacted identifier
- local developer-network tunnel availability
- exact trust, unlock, and Developer Mode guidance

## Apple tooling verified

- `xcrun devicectl list devices --json-output <path>` is the supported structured source for CoreDevice properties. The installed schema reports JSON version 2 and tool version 477.39.
- `xcrun xcdevice list --timeout 1` supplies the active USB/Wi-Fi interface and availability signal that `devicectl` does not reliably expose as the physical cable path.
- `xcrun devicectl device info lockState --device <identifier> --json-output <path>` supplies the current `passcodeRequired` lock signal.
- Simulator, Apple Watch, iPad, and disconnected historical records are excluded from the physical-iPhone result.

No human-formatted device table is parsed.

## Implementation

- `DeviceDiscovering` hides Apple command execution behind dependency injection.
- Apple results are decoded into private typed schemas and normalized into the domain `Device` model.
- Full identifiers remain local and are never displayed or logged; UI identifiers are partially redacted.
- Temporary structured result files use unique names and are removed after decoding.
- Lock-state requests run concurrently for discovered devices.
- `DeviceConnectionMonitoring` exposes an `AsyncStream`, suppresses identical polls, uses a two-second steady interval, and applies bounded exponential backoff after failures.
- The Setup Assistant automatically reacts to connect, disconnect, trust, Developer Mode, and lock-state changes.
- Signing identity failure is still shown but does not block the earlier device-discovery step.

## Sandbox compatibility decision

The real signed application test demonstrated that App Sandbox prevents `xcrun` from reaching Xcode/CoreDevice developer services. MirrorBridge therefore disables App Sandbox for both application configurations while retaining Hardened Runtime.

This is required for the current local-development architecture, which must invoke `xcodebuild`, `devicectl`, and related Apple tools and will later access a user-selected WebDriverAgent checkout. A future separately signed helper could narrow the unsandboxed boundary, but adding such a helper prematurely would increase signing and IPC risk without removing the underlying device-service requirement. MirrorBridge does not request root privileges or introduce a privileged helper.

## Files created

- `Lumina/Domain/Device.swift`
- `Lumina/DeviceManagement/AppleDeviceParser.swift`
- `Lumina/DeviceManagement/DeviceDiscoveryService.swift`
- `Lumina/DeviceManagement/DeviceConnectionMonitor.swift`
- `LuminaTests/DeviceManagement/AppleDeviceParserTests.swift`
- `LuminaTests/DeviceManagement/DeviceConnectionMonitorTests.swift`
- `LuminaTests/DeviceManagement/Fixtures/devicectl-devices.json`
- `LuminaTests/DeviceManagement/Fixtures/devicectl-lock-state.json`
- `LuminaTests/DeviceManagement/Fixtures/xcdevice-devices.json`
- `Documentation/PHASE_3_REPORT.md`

## Files modified

- `Lumina.xcodeproj/project.pbxproj`
- `Lumina/Application/DependencyContainer.swift`
- `Lumina/DeveloperEnvironment/EnvironmentModels.swift`
- `Lumina/Domain/ApplicationStateMachine.swift`
- `Lumina/UI/SetupAssistant/SetupAssistantModel.swift`
- `Lumina/UI/SetupAssistant/SetupAssistantView.swift`
- `LuminaTests/DeveloperEnvironment/EnvironmentCheckerTests.swift`
- `LuminaTests/Domain/ApplicationStateMachineTests.swift`
- `LuminaUITests/LuminaUITests.swift`
- `Documentation/IMPLEMENTATION_PLAN.md`
- `README.md`

## Build and automated verification

```bash
xcodebuild -project Lumina.xcodeproj -scheme Lumina \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/MirrorBridgePhase3FinalBuild \
  CODE_SIGNING_ALLOWED=NO build
```

Result: `BUILD SUCCEEDED`.

```bash
xcodebuild -project Lumina.xcodeproj -scheme Lumina \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/MirrorBridgePhase3FinalUnit \
  CODE_SIGNING_ALLOWED=NO -only-testing:LuminaTests \
  -skip-testing:LuminaUITests test
```

Result: `TEST SUCCEEDED`; 21 unit tests passed. The suite covers environment checks, command safety/timeouts, state transitions, device filtering/normalization, identifier redaction, lock-state decoding, and connection-change deduplication.

## Real physical-device verification

The dedicated XCUITest launched the signed macOS application, navigated to Setup Assistant, ran the real environment workflow, waited for Apple device discovery, found the physical iPhone card, and verified that the active interface was USB.

```bash
xcodebuild -project Lumina.xcodeproj -scheme Lumina \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/MirrorBridgePhase3FinalDeviceUI \
  -only-testing:LuminaUITests/LuminaUITests/testConnectedPhysicalIPhoneIsDiscovered \
  test
```

Result: `TEST SUCCEEDED`; the physical-device test passed in 8.645 seconds.

Observed through Apple tooling during implementation:

- one available physical iPhone over USB
- paired state reported by CoreDevice
- Developer Mode enabled
- developer services available
- current lock state returned successfully
- a connected local developer-network tunnel also reported

The full device identifier, device name, and other unique values are intentionally omitted from this report.

Connection-change logic is fixture/unit tested. The cable was not physically unplugged during the automated UI test, so a real detach/reattach cycle remains a manual verification item.

## Remaining limitations

- No WebDriverAgent source, build, or signing configuration
- No runner installation or launch
- No automation endpoint or local port forwarding
- No mirroring or input control
- Untrusted-device behavior still requires manual testing with pairing reset
- Lock-state availability depends on CoreDevice access and is honestly shown as unknown when unavailable

## Exact next step

Phase 4 must select and license a maintained WebDriverAgent upstream, pin its exact revision, inspect the current route/source layout, generate a stable per-install bundle suffix, resolve the user’s team and certificate, construct a cancellable `xcodebuild` invocation, parse common failures, and verify the produced runner signature for the connected physical iPhone.
