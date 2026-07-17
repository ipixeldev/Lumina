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
                    Text("Phases 2 and 3 perform real Mac checks and continuously discover physical iPhones using Apple developer tools.")
                        .foregroundStyle(.secondary)
                }

                stateCard

                if let report = model.environmentReport {
                    EnvironmentReportView(report: report)
                }

                if let snapshot = model.deviceSnapshot {
                    DeviceDiscoveryView(snapshot: snapshot, error: model.deviceDiscoveryError)
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
        switch model.stateMachine.state {
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
        default:
            return nil
        }
    }

    private func deviceStatus(_ status: (Device) -> EnvironmentCheckStatus) -> EnvironmentCheckStatus? {
        guard let device = model.deviceSnapshot?.devices.first else { return nil }
        return status(device)
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
            Label("Unlock the iPhone and approve Trust This Computer. MirrorBridge cannot bypass this confirmation.", systemImage: "hand.raised.fill")
                .foregroundStyle(.orange)
        } else if device.developerModeState == .disabled {
            Label("Enable Developer Mode in Settings → Privacy & Security, restart, and confirm it on the iPhone.", systemImage: "hammer.fill")
                .foregroundStyle(.orange)
        } else if device.lockState == .locked {
            Label("Unlock the iPhone physically to continue setup.", systemImage: "lock.fill")
                .foregroundStyle(.orange)
        } else {
            Label("This iPhone is ready for runner setup in Phase 4.", systemImage: "checkmark.circle.fill")
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

            Text(step.phaseLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
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
        case .buildRunner: "Build runner"
        case .installRunner: "Install runner"
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
        case .buildRunner: "Build and sign the selected WebDriverAgent XCTest runner."
        case .installRunner: "Install and launch the signed runner on the paired iPhone."
        case .testConnection: "Verify status, session, device information, and a screenshot."
        case .startMirroring: "Begin the independent screenshot visual channel."
        }
    }

    var phaseLabel: String {
        switch self {
        case .macRequirements, .signing: "Phase 2"
        case .connectIPhone, .trust, .developerMode: "Phase 3"
        case .buildRunner: "Phase 4"
        case .installRunner: "Phase 5"
        case .testConnection: "Phase 6"
        case .startMirroring: "Phase 7"
        }
    }
}

#Preview {
    SetupAssistantView(model: DependencyContainer.live.setupAssistantModel)
        .frame(width: 960, height: 760)
}
