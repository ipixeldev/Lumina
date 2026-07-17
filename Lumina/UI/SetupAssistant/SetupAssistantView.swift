import SwiftUI

struct SetupAssistantView: View {
    @Bindable var stateMachine: ApplicationStateMachine

    private let steps = SetupStep.allCases

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Setup Assistant")
                        .font(.largeTitle.bold())
                    Text("The foundation is ready. Environment and device checks are introduced in Phases 2 and 3; this screen does not report simulated results.")
                        .foregroundStyle(.secondary)
                }

                stateCard

                VStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        SetupStepRow(step: step, number: index + 1, isLast: index == steps.count - 1)
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.separator.opacity(0.6), lineWidth: 1)
                }
            }
            .padding(32)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Setup Assistant")
    }

    private var stateCard: some View {
        let presentation = stateMachine.state.presentation
        return VStack(alignment: .leading, spacing: 8) {
            Label(presentation.title, systemImage: "info.circle")
                .font(.headline)
            Text(presentation.explanation)
                .foregroundStyle(.secondary)
            if let progress = presentation.progress {
                ProgressView(value: progress)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SetupStepRow: View {
    let step: SetupStep
    let number: Int
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                Text("\(number)")
                    .font(.caption.bold())
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
    SetupAssistantView(stateMachine: ApplicationStateMachine())
        .frame(width: 900, height: 700)
}
