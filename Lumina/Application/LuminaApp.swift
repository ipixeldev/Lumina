import SwiftUI

@main
struct LuminaApp: App {
    @State private var dependencies = DependencyContainer.live

    var body: some Scene {
        WindowGroup("Lumina", id: "main") {
            AppRootView(dependencies: dependencies)
                .frame(minWidth: 840, minHeight: 580)
                .background(WindowRestorationController())
        }

        MenuBarExtra("Lumina", systemImage: "iphone.gen3.radiowaves.left.and.right") {
            LuminaMenuBarView(dependencies: dependencies)
        }

        Window("iPhone", id: "device-control") {
            DeviceControlSceneView(dependencies: dependencies)
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
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

private struct WindowRestorationController: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindow(for: nsView)
    }

    private func configureWindow(for view: NSView) {
        DispatchQueue.main.async {
            view.window?.isRestorable = false
        }
    }
}

private struct DeviceWindowController: NSViewRepresentable {
    let visualSource: VisualSource
    let onWindowChanged: @MainActor (NSWindow?) -> Void

    final class Coordinator {
        weak var configuredWindow: NSWindow?
        var configuredSource: VisualSource?
        var baseCollectionBehavior: NSWindow.CollectionBehavior?
        var baseLevel: NSWindow.Level?
        var baseHidesOnDeactivate: Bool?
    }

    final class WindowAttachmentView: NSView {
        var windowDidChange: (@MainActor (NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowDidChange?(window)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = WindowAttachmentView(frame: .zero)
        installAttachmentHandler(on: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowAttachmentView else { return }
        installAttachmentHandler(on: view, coordinator: context.coordinator)
        if let window = view.window {
            configure(window, coordinator: context.coordinator)
        }
    }

    private func installAttachmentHandler(on view: WindowAttachmentView, coordinator: Coordinator) {
        view.windowDidChange = { window in
            guard let window else {
                coordinator.configuredWindow = nil
                coordinator.configuredSource = nil
                coordinator.baseCollectionBehavior = nil
                coordinator.baseLevel = nil
                coordinator.baseHidesOnDeactivate = nil
                onWindowChanged(nil)
                return
            }
            configure(window, coordinator: coordinator)
        }
    }

    private func configure(_ window: NSWindow, coordinator: Coordinator) {
        let isNewWindow = coordinator.configuredWindow !== window
        if isNewWindow {
            coordinator.configuredWindow = window
            coordinator.baseCollectionBehavior = window.collectionBehavior
            coordinator.baseLevel = window.level
            coordinator.baseHidesOnDeactivate = window.hidesOnDeactivate
        }
        guard isNewWindow || coordinator.configuredSource != visualSource else { return }
        coordinator.configuredSource = visualSource

        let baseBehavior = coordinator.baseCollectionBehavior ?? window.collectionBehavior
        if visualSource == .airPlay {
            // Keep Lumina on its normal desktop Space. Activating this regular
            // window moves the user away from AirPlayUIAgent's black full-screen
            // Space while ScreenCaptureKit continues capturing that window.
            window.collectionBehavior = baseBehavior
            window.level = .floating
            window.hidesOnDeactivate = false
        } else {
            window.collectionBehavior = baseBehavior
            window.level = coordinator.baseLevel ?? .normal
            window.hidesOnDeactivate = coordinator.baseHidesOnDeactivate ?? false
        }
        window.isRestorable = false
        onWindowChanged(window)
    }
}

private struct DeviceControlSceneView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Bindable var dependencies: DependencyContainer
    @State private var deviceWindow: NSWindow?
    @State private var presentationTask: Task<Void, Never>?

    var body: some View {
        DeviceControlView(
            model: dependencies.automationWorkspace,
            reconnect: dependencies.setupAssistantModel.reconnectRunner,
            isReconnecting: dependencies.setupAssistantModel.isReconnecting
        )
        .background {
            DeviceWindowController(visualSource: dependencies.automationWorkspace.visualSource) { window in
                deviceWindow = window
                presentDeviceWindowIfReady()
            }
        }
        .onAppear(perform: validateSession)
        .onChange(of: dependencies.automationWorkspace.isConnected) { _, isConnected in
            if isConnected {
                presentDeviceWindowIfReady()
            } else {
                validateSession()
            }
        }
        .onChange(of: dependencies.automationWorkspace.hasLiveVisualChannel) { _, _ in
            presentDeviceWindowIfReady()
        }
        .onChange(of: dependencies.stateMachine.state) { _, _ in
            presentDeviceWindowIfReady()
        }
        .onDisappear {
            presentationTask?.cancel()
        }
    }

    private func presentDeviceWindowIfReady() {
        presentationTask?.cancel()
        guard let deviceWindow,
              dependencies.stateMachine.state == .connected,
              dependencies.automationWorkspace.isConnected,
              dependencies.automationWorkspace.hasLiveVisualChannel else { return }

        presentationTask = Task { @MainActor in
            // Start as a regular app so macOS switches from AirPlayUIAgent's
            // full-screen Space back to Lumina's device-sized window.
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)

            for _ in 0..<20 {
                guard !Task.isCancelled,
                      dependencies.stateMachine.state == .connected,
                      dependencies.automationWorkspace.isConnected,
                      dependencies.automationWorkspace.hasLiveVisualChannel else {
                    restoreSetupPresentation()
                    return
                }

                deviceWindow.makeKeyAndOrderFront(nil)
                if deviceWindow.isVisible, deviceWindow.isKeyWindow {
                    dismissWindow(id: "main")
                    NSApplication.shared.setActivationPolicy(.accessory)
                    deviceWindow.makeKeyAndOrderFront(nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }

            restoreSetupPresentation()
        }
    }

    private func restoreSetupPresentation() {
        NSApplication.shared.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func validateSession() {
        presentationTask?.cancel()
        guard !dependencies.automationWorkspace.isConnected else { return }
        restoreSetupPresentation()
        DispatchQueue.main.async {
            dismissWindow(id: "device-control")
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
