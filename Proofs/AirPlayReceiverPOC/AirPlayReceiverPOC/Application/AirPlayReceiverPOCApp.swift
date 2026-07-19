import SwiftUI

@main
struct AirPlayReceiverPOCApp: App {
    @StateObject private var model = ReceiverPOCModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 640, minHeight: 620)
                .task {
                    model.startIfNeeded()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Divider()
                Button(model.isActive ? "Stop Advertising" : "Start Advertising") {
                    model.toggleAdvertising()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
