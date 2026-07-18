import SwiftUI

@main
struct LuminaApp: App {
    @State private var dependencies = DependencyContainer.live

    var body: some Scene {
        WindowGroup("Lumina", id: "main") {
            AppRootView(dependencies: dependencies)
                .frame(minWidth: 840, minHeight: 580)
        }

        MenuBarExtra("Lumina", systemImage: "iphone.gen3.radiowaves.left.and.right") {
            LuminaMenuBarView(dependencies: dependencies)
        }

        Window("iPhone", id: "device-control") {
            DeviceControlView(
                model: dependencies.automationWorkspace,
                reconnect: dependencies.setupAssistantModel.reconnectRunner,
                isReconnecting: dependencies.setupAssistantModel.isReconnecting
            )
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultPosition(.trailing)
        .commandsRemoved()
        .defaultSize(width: 390, height: 844)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Lumina") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: "Lumina",
                            .applicationVersion: "1.0"
                        ]
                    )
                }
            }
        }
    }
}

private struct LuminaMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var dependencies: DependencyContainer

    var body: some View {
        Button("Open Lumina", systemImage: "macwindow") {
            NSApplication.shared.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        if dependencies.automationWorkspace.isConnected {
            Button("Show iPhone", systemImage: "iphone") {
                openWindow(id: "device-control")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }

        Divider()
        Button("Quit Lumina", systemImage: "power", role: .destructive) {
            NSApplication.shared.terminate(nil)
        }
    }
}
