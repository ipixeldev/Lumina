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
                    Text("Phase 2 performs real checks on this Mac. Physical iPhone discovery and connection arrive in Phase 3.")
                        .foregroundStyle(.secondary)
                }

                stateCard

                if let report = model.environmentReport {
                    EnvironmentReportView(report: report)
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
                Button(model.environmentReport == nil ? "Check this Mac" : "Run checks again") {
                    model.checkThisMac()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStartEnvironmentCheck)
                .accessibilityIdentifier("checkThisMacButton")
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
        default:
            return nil
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
