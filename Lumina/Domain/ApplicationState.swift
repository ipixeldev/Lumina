import Foundation

nonisolated enum ApplicationState: Equatable, Sendable {
    case appStarting
    case checkingEnvironment
    case xcodeMissing
    case sdkMissing
    case certificateMissing
    case noDevice
    case deviceConnectedUSB
    case deviceNeedsTrust
    case developerModeDisabled
    case devicePreparing
    case runnerNotInstalled
    case runnerBuilding(progress: Double?)
    case runnerBuildFailed(message: String)
    case runnerBuilt
    case runnerInstalling(progress: Double?)
    case runnerInstallFailed(message: String)
    case runnerLaunching
    case connectingAutomation
    case automationReady
    case startingMirror
    case connected
    case temporarilyDisconnected
    case reconnecting(attempt: Int)
    case deviceLocked
    case runnerCrashed
    case requiresUserAction(message: String)
    case stopping
    case stopped

    var presentation: StatePresentation {
        switch self {
        case .appStarting:
            StatePresentation(title: "Ready to begin", explanation: "MirrorBridge has not checked this Mac yet.", actions: [.beginSetup], canRecoverAutomatically: false)
        case .checkingEnvironment:
            StatePresentation(title: "Checking this Mac", explanation: "Inspecting the local developer environment.", actions: [.cancel], canRecoverAutomatically: true, progress: nil)
        case .xcodeMissing:
            StatePresentation(title: "Xcode is required", explanation: "Install and open Xcode before continuing.", actions: [.openInstructions, .retry], canRecoverAutomatically: false, diagnostics: ["MB-ENV-001"])
        case .sdkMissing:
            StatePresentation(title: "iOS SDK is missing", explanation: "Install an iOS platform in Xcode Settings.", actions: [.openInstructions, .retry], canRecoverAutomatically: false, diagnostics: ["MB-ENV-002"])
        case .certificateMissing:
            StatePresentation(title: "Development certificate required", explanation: "Create an Apple Development certificate in Xcode.", actions: [.openInstructions, .retry], canRecoverAutomatically: false, diagnostics: ["MB-SIGN-003"])
        case .noDevice:
            StatePresentation(title: "Connect an iPhone", explanation: "Connect an unlocked iPhone by USB to continue initial setup.", actions: [.retry], canRecoverAutomatically: true)
        case .deviceConnectedUSB:
            StatePresentation(title: "iPhone connected by USB", explanation: "The device is visible to this Mac.", actions: [.continueSetup], canRecoverAutomatically: true)
        case .deviceNeedsTrust:
            StatePresentation(title: "Trust this Mac", explanation: "Unlock the iPhone and approve Trust This Computer on the device.", actions: [.retry], canRecoverAutomatically: false, diagnostics: ["MB-DEV-001"])
        case .developerModeDisabled:
            StatePresentation(title: "Developer Mode is disabled", explanation: "Enable Developer Mode in iPhone Settings and complete the required restart.", actions: [.openInstructions, .retry], canRecoverAutomatically: false, diagnostics: ["MB-DEV-003"])
        case .devicePreparing:
            StatePresentation(title: "Preparing iPhone", explanation: "Xcode is preparing developer services for this device.", actions: [.cancel], canRecoverAutomatically: true)
        case .runnerNotInstalled:
            StatePresentation(title: "Automation runner not installed", explanation: "The signed XCTest runner must be built and installed.", actions: [.buildRunner], canRecoverAutomatically: false)
        case let .runnerBuilding(progress):
            StatePresentation(title: "Building automation runner", explanation: "Xcode is compiling and signing the local XCTest runner.", actions: [.cancel], canRecoverAutomatically: false, progress: progress)
        case let .runnerBuildFailed(message):
            StatePresentation(title: "Runner build failed", explanation: message, actions: [.retry, .openDiagnostics], canRecoverAutomatically: false, diagnostics: ["MB-BUILD-004"])
        case .runnerBuilt:
            StatePresentation(title: "Runner ready to install", explanation: "The signed WebDriverAgent runner was built and its signature was verified locally.", actions: [.continueSetup], canRecoverAutomatically: false)
        case let .runnerInstalling(progress):
            StatePresentation(title: "Installing automation runner", explanation: "Installing the signed runner on the connected iPhone.", actions: [.cancel], canRecoverAutomatically: false, progress: progress)
        case let .runnerInstallFailed(message):
            StatePresentation(title: "Runner installation failed", explanation: message, actions: [.retry, .openDiagnostics], canRecoverAutomatically: false, diagnostics: ["MB-INSTALL-005"])
        case .runnerLaunching:
            StatePresentation(title: "Launching automation runner", explanation: "Starting the signed XCTest runner on the iPhone.", actions: [.cancel], canRecoverAutomatically: true)
        case .connectingAutomation:
            StatePresentation(title: "Connecting automation", explanation: "Waiting for the local WebDriverAgent endpoint.", actions: [.cancel], canRecoverAutomatically: true)
        case .automationReady:
            StatePresentation(title: "Automation ready", explanation: "The control channel has responded successfully.", actions: [.startMirroring, .stop], canRecoverAutomatically: true)
        case .startingMirror:
            StatePresentation(title: "Starting screen stream", explanation: "Starting the independent visual channel.", actions: [.cancel], canRecoverAutomatically: true)
        case .connected:
            StatePresentation(title: "Connected", explanation: "Visual and control channels are active locally.", actions: [.stop, .openDiagnostics], canRecoverAutomatically: true)
        case .temporarilyDisconnected:
            StatePresentation(title: "Connection interrupted", explanation: "MirrorBridge paused input while the device is unavailable.", actions: [.reconnect, .stop], canRecoverAutomatically: true)
        case let .reconnecting(attempt):
            StatePresentation(title: "Reconnecting", explanation: "Recovery attempt \(attempt) is in progress.", actions: [.cancel, .stop], canRecoverAutomatically: true)
        case .deviceLocked:
            StatePresentation(title: "iPhone is locked", explanation: "Unlock the iPhone physically to resume automation.", actions: [.retry, .stop], canRecoverAutomatically: false, diagnostics: ["MB-DEV-002"])
        case .runnerCrashed:
            StatePresentation(title: "Automation runner stopped", explanation: "The signed XCTest runner is no longer responding.", actions: [.reconnect, .stop], canRecoverAutomatically: true, diagnostics: ["MB-WDA-006"])
        case let .requiresUserAction(message):
            StatePresentation(title: "Action required on iPhone", explanation: message, actions: [.retry, .stop], canRecoverAutomatically: false)
        case .stopping:
            StatePresentation(title: "Stopping", explanation: "Closing local sessions and transports.", actions: [], canRecoverAutomatically: true)
        case .stopped:
            StatePresentation(title: "Stopped", explanation: "No device session is active.", actions: [.beginSetup], canRecoverAutomatically: false)
        }
    }
}

nonisolated struct StatePresentation: Equatable, Sendable {
    let title: String
    let explanation: String
    let actions: [StateAction]
    let canRecoverAutomatically: Bool
    var diagnostics: [String] = []
    var progress: Double?
}

nonisolated enum StateAction: String, Equatable, Sendable {
    case beginSetup
    case continueSetup
    case retry
    case cancel
    case openInstructions
    case openDiagnostics
    case buildRunner
    case startMirroring
    case reconnect
    case stop
}
