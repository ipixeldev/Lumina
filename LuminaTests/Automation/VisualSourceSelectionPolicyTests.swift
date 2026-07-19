import Testing
@testable import Lumina

struct VisualSourceSelectionPolicyTests {
    @Test("Video source remains selectable after connection and during recovery")
    func selectableRuntimeStates() {
        let states: [ApplicationState] = [
            .automationReady,
            .startingMirror,
            .connected,
            .temporarilyDisconnected,
            .reconnecting(attempt: 1),
            .deviceLocked,
            .runnerCrashed,
            .requiresUserAction(message: "Reconnect the iPhone")
        ]

        for state in states {
            #expect(VisualSourceSelectionPolicy.allowsSelection(
                in: state,
                isChecking: false,
                isBuildingRunner: false,
                isSettingUpRunner: false
            ))
        }
    }

    @Test("Video source is locked only while setup owns the connection lifecycle")
    func blockedSetupStates() {
        let states: [ApplicationState] = [
            .checkingEnvironment,
            .runnerBuilding(progress: nil),
            .runnerInstalling(progress: nil),
            .runnerLaunching,
            .connectingAutomation,
            .stopping
        ]

        for state in states {
            #expect(!VisualSourceSelectionPolicy.allowsSelection(
                in: state,
                isChecking: false,
                isBuildingRunner: false,
                isSettingUpRunner: false
            ))
        }
    }

    @Test("Active setup tasks prevent a competing source switch")
    func blockedSetupTasks() {
        #expect(!VisualSourceSelectionPolicy.allowsSelection(
            in: .connected,
            isChecking: true,
            isBuildingRunner: false,
            isSettingUpRunner: false
        ))
        #expect(!VisualSourceSelectionPolicy.allowsSelection(
            in: .connected,
            isChecking: false,
            isBuildingRunner: true,
            isSettingUpRunner: false
        ))
        #expect(!VisualSourceSelectionPolicy.allowsSelection(
            in: .connected,
            isChecking: false,
            isBuildingRunner: false,
            isSettingUpRunner: true
        ))
    }
}
