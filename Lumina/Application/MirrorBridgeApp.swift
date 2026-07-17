import SwiftUI

@main
struct MirrorBridgeApp: App {
    @State private var dependencies = DependencyContainer.live

    var body: some Scene {
        WindowGroup("MirrorBridge") {
            AppRootView(dependencies: dependencies)
                .frame(minWidth: 840, minHeight: 580)
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MirrorBridge") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: "MirrorBridge",
                            .applicationVersion: "1.0"
                        ]
                    )
                }
            }
        }
    }
}
