import AppKit
import SwiftUI

struct AppRootView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Bindable var dependencies: DependencyContainer
    @State private var selection: AppRoute? = .welcome

    var body: some View {
        NavigationSplitView {
            List(AppRoute.allCases, selection: $selection) { route in
                Label(route.title, systemImage: route.systemImage)
                    .tag(route)
            }
            .navigationTitle("Lumina")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            switch selection ?? .welcome {
            case .welcome:
                WelcomeView {
                    dependencies.logger.info("Setup assistant opened", category: .app)
                    selection = .setupAssistant
                }
            case .setupAssistant:
                SetupAssistantView(model: dependencies.setupAssistantModel)
            case .deviceControl:
                DeviceControlLauncherView(model: dependencies.automationWorkspace) {
                    openWindow(id: "device-control")
                }
            case .acknowledgements:
                AcknowledgementsView()
            }
        }
        .onChange(of: dependencies.stateMachine.state) { _, state in
            let shouldOpenAirPlaySetup = state == .startingMirror &&
                dependencies.automationWorkspace.visualSource == .airPlay
            if state == .connected || shouldOpenAirPlaySetup {
                selection = .deviceControl
                openWindow(id: "device-control")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    dismissWindow(id: "main")
                    NSApplication.shared.setActivationPolicy(.accessory)
                }
            }
        }
    }
}

private struct DeviceControlLauncherView: View {
    @Bindable var model: AutomationWorkspaceModel
    let openDeviceWindow: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(model.isConnected ? "iPhone Connected" : "No Active iPhone", systemImage: model.isConnected ? "iphone.gen3.radiowaves.left.and.right" : "iphone.slash")
        } description: {
            Text(model.isConnected ? "The iPhone screen opens in its own Simulator-style window." : "Complete Setup Assistant to connect Lumina to your iPhone.")
        } actions: {
            Button("Open iPhone Window", action: openDeviceWindow)
                .buttonStyle(.borderedProminent)
                .disabled(!model.isConnected)
        }
    }
}

#Preview {
    AppRootView(dependencies: .live)
}
