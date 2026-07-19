import SwiftUI

struct SetupAssistantView: View {
    @Bindable var model: SetupAssistantModel

    private let steps = SetupStep.allCases

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Setup Assistant")
                        .font(.largeTitle.bold())
                    Text("Lumina checks this Mac and continuously discovers physical iPhones using local Apple developer tools.")
                        .foregroundStyle(.secondary)
                }

                videoMethodPicker

                stateCard

                if model.hasSelectedVisualSource, model.visualSource == .airPlay {
                    AirPlayPreparationView(model: model)
                }

                if let report = model.environmentReport {
                    EnvironmentReportView(report: report)
                }

                if let snapshot = model.deviceSnapshot {
                    DeviceDiscoveryView(snapshot: snapshot, error: model.deviceDiscoveryError)
                    if model.hasReadyDevice {
                        RunnerBuildView(model: model)
                    }
                } else if model.isMonitoringDevices {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Looking for a physical iPhone…")
                                .foregroundStyle(.secondary)
                        }
                        if let error = model.deviceDiscoveryError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                    .accessibilityIdentifier("deviceDiscoveryProgress")
                }

                VStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        SetupStepRow(
                            step: step,
                            number: index + 1,
                            isLast: index == steps.count - 1,
                            status: status(for: step)
                        )
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.separator.opacity(0.6), lineWidth: 1)
                }
            }
            .padding(32)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Setup Assistant")
    }

    private var videoMethodPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose video method")
                        .font(.title2.bold())
                    Text("Choose now or switch later. Both video methods keep the same signed XCTest control session.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 14) {
                VideoMethodCard(
                    title: "Direct",
                    subtitle: "USB or paired Wi-Fi",
                    detail: "Fast setup with interactive device control and adjustable stream quality.",
                    systemImage: "cable.connector",
                    isSelected: model.hasSelectedVisualSource && model.visualSource == .direct
                ) {
                    model.selectVisualSource(.direct)
                }
                .disabled(!model.canSelectVisualSource)
                .accessibilityIdentifier("directVideoMethodCard")
                VideoMethodCard(
                    title: "AirPlay",
                    subtitle: "macOS system receiver",
                    detail: "AirPlay supplies video; the signed XCTest runner supplies controls only.",
                    systemImage: "airplayvideo",
                    isSelected: model.hasSelectedVisualSource && model.visualSource == .airPlay
                ) {
                    model.selectVisualSource(.airPlay)
                }
                .disabled(!model.canSelectVisualSource)
                .accessibilityIdentifier("airPlayVideoMethodCard")
            }

            if !model.hasSelectedVisualSource {
                Label("Choose a method to continue.", systemImage: "arrow.up")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityIdentifier("videoMethodPicker")
    }

    private var stateCard: some View {
        let presentation = model.stateMachine.state.presentation
        return VStack(alignment: .leading, spacing: 12) {
            Label(presentation.title, systemImage: model.isChecking ? "gearshape.2" : "info.circle")
                .font(.headline)
                .accessibilityIdentifier("applicationStateTitle")
            Text(presentation.explanation)
                .foregroundStyle(.secondary)

            if model.isChecking {
                ProgressView()
                    .controlSize(.small)
                Button("Cancel", role: .cancel) {
                    model.cancelCheck()
                }
            } else {
                HStack {
                    Button(model.environmentReport == nil ? "Check this Mac" : "Run Mac checks again") {
                        model.checkThisMac()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStartEnvironmentCheck)
                    .accessibilityIdentifier("checkThisMacButton")

                    if model.environmentReport != nil, !model.isMonitoringDevices {
                        Button("Find connected iPhones") {
                            model.startDeviceMonitoring()
                        }
                        .accessibilityIdentifier("findIPhonesButton")
                    }
                }
            }

            if let error = model.lastUnexpectedError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var canStartEnvironmentCheck: Bool {
        guard model.isSelectedVisualSourceReadyToConnect else { return false }
        return switch model.stateMachine.state {
        case .appStarting, .stopped, .xcodeMissing, .sdkMissing, .certificateMissing, .noDevice, .requiresUserAction:
            true
        default:
            false
        }
    }

    private func status(for step: SetupStep) -> EnvironmentCheckStatus? {
        guard let report = model.environmentReport else { return nil }
        switch step {
        case .macRequirements:
            let requirements: [EnvironmentRequirement] = [
                .macOS, .architecture, .diskSpace, .xcode, .developerDirectory,
                .xcodeFirstLaunch, .commandLineTools, .iOSSDK, .helper
            ]
            let statuses = requirements.compactMap { report.result(for: $0)?.status }
            if statuses.contains(.failed) { return .failed }
            if statuses.contains(.warning) { return .warning }
            return statuses.isEmpty ? nil : .passed
        case .signing:
            return report.result(for: .developmentCertificate)?.status
        case .connectIPhone:
            return deviceStatus { _ in .passed }
        case .trust:
            return deviceStatus { $0.pairingState == .paired ? .passed : .failed }
        case .developerMode:
            return deviceStatus {
                switch $0.developerModeState {
                case .enabled: .passed
                case .disabled: .failed
                case .unknown: .warning
                }
            }
        case .buildRunner:
            if model.runnerBuildResult != nil { return .passed }
            if model.runnerBuildIssue != nil { return .failed }
            return nil
        case .installRunner:
            if model.runnerConnection != nil { return .passed }
            if model.runnerSetupIssue != nil { return .failed }
            return nil
        default:
            return nil
        }
    }

    private func deviceStatus(_ status: (Device) -> EnvironmentCheckStatus) -> EnvironmentCheckStatus? {
        guard let device = model.deviceSnapshot?.devices.first else { return nil }
        return status(device)
    }
}

private struct AirPlayPreparationView: View {
    @Bindable var model: SetupAssistantModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "airplayvideo")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 46, height: 46)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("AirPlay video")
                        .font(.title2.bold())
                    Text(airPlayStatusDetail)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(
                    airPlayStatusTitle,
                    systemImage: model.isAirPlayVideoActive ? "checkmark.circle.fill" : "hourglass"
                )
                .font(.callout.bold())
                .foregroundStyle(model.isAirPlayVideoActive ? .green : .orange)
            }

            VStack(alignment: .leading, spacing: 10) {
                if model.isAirPlayControlReady {
                    Label("On iPhone, open Control Center → Screen Mirroring.", systemImage: "1.circle.fill")
                    Label("Choose \(model.airPlayReceiverName).", systemImage: "2.circle.fill")
                    Label("Lumina will capture the receiver, return to the desktop, and open its device-sized control window automatically.", systemImage: "3.circle.fill")
                } else {
                    Label("Let Lumina finish connecting the XCTest control channel first.", systemImage: "1.circle.fill")
                    Label("Keep the iPhone paired by USB or developer Wi-Fi.", systemImage: "2.circle.fill")
                    Label("Start iPhone Screen Mirroring only after control is ready.", systemImage: "3.circle.fill")
                }
            }
            .font(.callout)

            if model.screenCapturePermissionNeedsRelaunch {
                Label("Permission changed. Quit and reopen Lumina once before starting AirPlay.", systemImage: "arrow.clockwise.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            } else if !model.hasScreenCapturePermission {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Screen Recording is required only to copy the native AirPlay video into Lumina's window.", systemImage: "rectangle.inset.filled.and.person.filled")
                        .font(.callout.weight(.semibold))
                    if model.screenCapturePermissionRequestWasDenied {
                        Button("Open Screen Recording Settings", systemImage: "gear") {
                            model.openScreenCaptureSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        Text("Enable Lumina in System Settings, then quit and reopen it once.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Allow Screen Recording…", systemImage: "lock.open") {
                            model.requestScreenCapturePermission()
                        }
                        .buttonStyle(.borderedProminent)
                        Text("After enabling Lumina in System Settings, quit and run it again once. A development-signed build keeps this permission across future rebuilds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack {
                Button("Open AirPlay Receiver Settings", systemImage: "gear") {
                    model.openAirPlayReceiverSettings()
                }
                Button(model.isCheckingAirPlayReceiver ? "Checking Receiver…" : "Recheck Receiver", systemImage: "arrow.clockwise") {
                    model.checkAirPlayReceiver()
                }
                .disabled(model.isCheckingAirPlayReceiver)
                if model.isCheckingAirPlayReceiver {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let report = model.airPlayReceiverReport {
                Label(report.diagnostic.title, systemImage: report.isScreenMirroringAdvertised ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(report.isScreenMirroringAdvertised ? .green : .orange)
                Text(report.diagnostic.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let error = model.airPlayDiscoveryError {
                Label(error, systemImage: "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(model.isChoosingAirPlaySource ? "Watching for iPhone Window…" : "Watch for iPhone AirPlay Window", systemImage: "macwindow.on.rectangle") {
                    model.waitForAirPlaySource()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !model.isAirPlayControlReady ||
                    !model.hasScreenCapturePermission ||
                    model.screenCapturePermissionNeedsRelaunch ||
                    model.isChoosingAirPlaySource ||
                    model.isAirPlayVideoActive
                )
                .accessibilityIdentifier("chooseAirPlayWindowButton")

                if model.isAirPlayControlReady,
                   !model.isAirPlayVideoActive,
                   model.airPlayIssue != nil {
                    Button("Choose Window Manually…", systemImage: "cursorarrow.click") {
                        model.chooseAirPlaySource()
                    }
                    .disabled(
                        !model.hasScreenCapturePermission ||
                        model.screenCapturePermissionNeedsRelaunch ||
                        model.isChoosingAirPlaySource
                    )
                }
            }

            if let issue = model.airPlayIssue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Text("Apple's AirPlay receiver supplies smooth video only. Lumina captures that video into its device-sized desktop window and routes every click and gesture through the separate XCTest control channel.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.separator.opacity(0.6), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("airPlayPreparation")
    }

    private var airPlayStatusTitle: String {
        if model.isAirPlayVideoActive { return "Video ready" }
        if model.isChoosingAirPlaySource { return "Watching for iPhone" }
        if model.isAirPlayControlReady { return "Control ready" }
        return "Preparing control"
    }

    private var airPlayStatusDetail: String {
        if model.isAirPlayVideoActive {
            return "The AirPlay video and XCTest control channels are both active."
        }
        if model.isAirPlayControlReady {
            return "XCTest control is ready. Lumina is waiting for the macOS AirPlay receiver window."
        }
        return "Lumina connects XCTest control before asking you to start the view-only AirPlay stream."
    }
}

private struct VideoMethodCard: View {
    let title: String
    let subtitle: String
    let detail: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(isSelected ? Color.accentColor : Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title).font(.headline)
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(subtitle)
                        .font(.callout.bold())
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct RunnerBuildView: View {
    @Bindable var model: SetupAssistantModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("WebDriverAgent runner")
                        .font(.title2.bold())
                    Text("Appium WebDriverAgent v\(WebDriverAgentPin.version) · pinned source")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("BSD licensed", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
            }

            if let bundleIdentifier = model.runnerBundleIdentifier {
                DeviceProperty(label: "Unique runner identifier", value: bundleIdentifier + ".xctrunner")
                    .textSelection(.enabled)
            }

            if model.isBuildingRunner {
                ProgressView(model.isCheckingRunnerCache ? "Checking the reusable signed runner…" : "Building and signing with Xcode…")
                Button("Cancel build", role: .cancel) {
                    model.cancelRunnerBuild()
                }
            } else if let result = model.runnerBuildResult {
                Label("Signed runner verified for team \(result.signature.teamIdentifier)", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Product: \(result.productURL.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.isSettingUpRunner {
                    ProgressView(setupProgressTitle)
                    Button("Cancel runner setup", role: .cancel) {
                        model.cancelRunnerSetup()
                    }
                } else if let connection = model.runnerConnection {
                    Label("Lumina is connected to this iPhone", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    DeviceProperty(label: "Local endpoint", value: connection.endpoint.absoluteString)
                        .textSelection(.enabled)
                    DeviceProperty(label: "Status", value: connection.status.message)
                    if let osName = connection.status.operatingSystemName,
                       let osVersion = connection.status.operatingSystemVersion {
                        DeviceProperty(label: "Device software", value: "\(osName) \(osVersion)")
                    }
                    Text("Open Device Control in the sidebar to view and control the live screen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Stop runner", role: .destructive) {
                        model.stopRunner()
                    }
                } else {
                    Button(model.runnerIsInstalled == true ? "Start installed runner" : "Install and start runner") {
                        model.installAndLaunchRunner()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canInstallRunner)
                    .accessibilityIdentifier("installRunnerButton")
                    Text("Lumina reuses the installed app when its identity matches, starts a fresh XCTest session, and checks its status over the trusted developer connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Build signed runner") {
                    model.buildRunner()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canBuildRunner)
                .accessibilityIdentifier("buildRunnerButton")
                Text("This user-triggered build may contact Apple through Xcode to create or refresh development provisioning. No source or binary is downloaded by this action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let issue = model.runnerBuildIssue {
                VStack(alignment: .leading, spacing: 5) {
                    Label(issue.title, systemImage: "xmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text(issue.explanation)
                    Text(issue.recovery)
                        .foregroundStyle(.secondary)
                    Text(issue.code)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }

            if let issue = model.runnerSetupIssue {
                VStack(alignment: .leading, spacing: 5) {
                    Label(issue.title, systemImage: "xmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text(issue.explanation)
                    Text(issue.recovery)
                        .foregroundStyle(.secondary)
                    Text(issue.code)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runnerBuildSection")
    }

    private var setupProgressTitle: String {
        if model.runnerIsInstalled == nil { return "Checking for the installed runner…" }
        return switch model.stateMachine.state {
        case .runnerInstalling:
            "Installing the signed runner…"
        case .runnerLaunching:
            "Starting the XCTest runner…"
        case .connectingAutomation:
            "Checking the local automation endpoint…"
        default:
            model.runnerIsInstalled == true ? "Starting the installed runner…" : "Preparing the automation runner…"
        }
    }
}

private struct DeviceDiscoveryView: View {
    let snapshot: DeviceDiscoverySnapshot
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Physical iPhones")
                    .font(.title2.bold())
                Spacer()
                Text("Monitoring connection changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if snapshot.devices.isEmpty {
                ContentUnavailableView(
                    "No connected iPhone",
                    systemImage: "cable.connector",
                    description: Text("Connect an unlocked iPhone by USB, then approve Trust This Computer if prompted.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ForEach(snapshot.devices) { device in
                    DeviceCard(device: device)
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deviceDiscoveryReport")
    }
}

private struct DeviceCard: View {
    let device: Device

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: "iphone")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name).font(.headline)
                    Text("\(device.model) · iOS \(device.operatingSystemVersion)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(device.connectionTransport.displayName, systemImage: device.connectionTransport == .usb ? "cable.connector" : "wifi")
                    .font(.callout.bold())
            }

            HStack(spacing: 18) {
                DeviceProperty(label: "Pairing", value: device.pairingState.rawValue.capitalized)
                DeviceProperty(label: "Developer Mode", value: device.developerModeState.rawValue.capitalized)
                DeviceProperty(label: "Lock", value: device.lockState.rawValue.capitalized)
                DeviceProperty(label: "Identifier", value: device.redactedIdentifier)
            }

            if device.isAvailableOverNetwork {
                Label("Also available through the local developer network tunnel", systemImage: "wifi")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            guidance
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("physicalIPhoneCard")
    }

    @ViewBuilder
    private var guidance: some View {
        if device.pairingState != .paired {
            Label("Unlock the iPhone and approve Trust This Computer. Lumina cannot bypass this confirmation.", systemImage: "hand.raised.fill")
                .foregroundStyle(.orange)
        } else if device.developerModeState == .disabled {
            Label("Enable Developer Mode in Settings → Privacy & Security, restart, and confirm it on the iPhone.", systemImage: "hammer.fill")
                .foregroundStyle(.orange)
        } else if device.lockState == .locked {
            Label("Unlock the iPhone physically to continue setup.", systemImage: "lock.fill")
                .foregroundStyle(.orange)
        } else if !device.developerServicesAvailable {
            Label("The developer connection is unavailable. Reconnect USB once and enable Connect via network for this iPhone in Xcode.", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.orange)
        } else if device.connectionTransport == .wifi && (!device.isAvailableOverNetwork || device.developerConnectionHosts.isEmpty) {
            Label("This paired iPhone is visible, but its Wi-Fi developer tunnel is not ready yet.", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.orange)
        } else {
            Label("This iPhone is ready for runner setup.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}

private struct DeviceProperty: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
    }
}

private struct EnvironmentReportView: View {
    let report: EnvironmentReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Mac environment")
                    .font(.title2.bold())
                Spacer()
                Text(report.completedAt, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(report.checks.enumerated()), id: \.element.id) { index, result in
                    EnvironmentCheckRow(result: result)
                    if index < report.checks.count - 1 {
                        Divider().padding(.leading, 44)
                    }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))

            if !report.certificates.isEmpty {
                Text("Development identities")
                    .font(.headline)
                ForEach(report.certificates) { certificate in
                    CertificateRow(certificate: certificate)
                }
            }
        }
        .accessibilityIdentifier("environmentReport")
    }
}

private struct EnvironmentCheckRow: View {
    let result: EnvironmentCheckResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: result.status.systemImage)
                .foregroundStyle(result.status.color)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(result.requirement.title)
                    .font(.headline)
                Text(result.summary)
                    .font(.callout)
                if let details = result.details {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let remediation = result.remediation {
                    Label(remediation, systemImage: "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(result.status == .failed ? .orange : .secondary)
                }
                if let errorCode = result.errorCode {
                    Text(errorCode)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(14)
        .accessibilityIdentifier("environmentCheck.\(result.requirement.rawValue)")
    }
}

private struct CertificateRow: View {
    let certificate: DeveloperCertificateIdentity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(
                    certificate.canSign ? "Ready for signing" : "Not usable",
                    systemImage: certificate.canSign ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(certificate.canSign ? .green : .orange)
                Spacer()
                if let expirationDate = certificate.expirationDate {
                    Text("Expires \(expirationDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(certificate.displayName)
                .textSelection(.enabled)
            HStack(spacing: 14) {
                if let teamID = certificate.teamID {
                    Text("Team \(teamID)")
                }
                Text(certificate.hasPrivateKey ? "Private key available" : "Private key missing")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SetupStepRow: View {
    let step: SetupStep
    let number: Int
    let isLast: Bool
    let status: EnvironmentCheckStatus?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                Group {
                    if let status {
                        Image(systemName: status.systemImage)
                            .foregroundStyle(status.color)
                    } else {
                        Text("\(number)")
                            .font(.caption.bold())
                    }
                }
                .frame(width: 26, height: 26)
                .background(.quaternary, in: Circle())
                if !isLast {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1)
                        .frame(minHeight: 26)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.headline)
                Text(step.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, isLast ? 0 : 18)

            Spacer()

        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, isLast ? 18 : 0)
    }
}

private extension EnvironmentCheckStatus {
    var systemImage: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        }
    }
}

private enum SetupStep: String, CaseIterable, Identifiable {
    case macRequirements
    case connectIPhone
    case trust
    case developerMode
    case signing
    case buildRunner
    case installRunner
    case testConnection
    case startMirroring

    var id: Self { self }

    var title: String {
        switch self {
        case .macRequirements: "Mac requirements"
        case .connectIPhone: "Connect iPhone"
        case .trust: "Trust"
        case .developerMode: "Developer Mode"
        case .signing: "Apple Development signing"
        case .buildRunner: "Prepare runner"
        case .installRunner: "Start runner"
        case .testConnection: "Test connection"
        case .startMirroring: "Start mirroring"
        }
    }

    var detail: String {
        switch self {
        case .macRequirements: "Verify macOS, Xcode, Command Line Tools, and the iOS SDK."
        case .connectIPhone: "Discover a physical iPhone over USB using structured Apple tooling."
        case .trust: "Guide the required on-device Trust This Computer confirmation."
        case .developerMode: "Confirm Developer Mode without bypassing device security."
        case .signing: "Resolve a usable local Apple Development identity and team."
        case .buildRunner: "Reuse a verified cached build, or build and sign it when needed."
        case .installRunner: "Reuse the installed app when possible and start a fresh XCTest session."
        case .testConnection: "Verify status, session, device information, and a screenshot."
        case .startMirroring: "Begin the independent screenshot visual channel."
        }
    }

}

#Preview {
    SetupAssistantView(model: DependencyContainer.live.setupAssistantModel)
        .frame(width: 960, height: 760)
}
