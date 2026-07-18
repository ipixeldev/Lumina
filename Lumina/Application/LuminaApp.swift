import SwiftUI

@main
struct LuminaApp: App {
    @State private var dependencies = DependencyContainer.live

    var body: some Scene {
        WindowGroup("Lumina") {
            AppRootView(dependencies: dependencies)
                .frame(minWidth: 840, minHeight: 580)
        }

        Window("iPhone", id: "device-control") {
            DeviceControlView(
                model: dependencies.automationWorkspace,
                reconnect: dependencies.setupAssistantModel.reconnectRunner,
                isReconnecting: dependencies.setupAssistantModel.isReconnecting
            )
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
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
