import SwiftUI

@main
struct LuminaApp: App {
    @State private var dependencies = DependencyContainer.live

    var body: some Scene {
        WindowGroup("Lumina") {
            AppRootView(dependencies: dependencies)
                .frame(minWidth: 840, minHeight: 580)
        }
        .defaultSize(width: 1040, height: 700)
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
