import AppKit
import SwiftUI

@MainActor
final class LuminaApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let duplicateApplications = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentProcessIdentifier }

        // Xcode can launch a new Debug product while an older build from a
        // different DerivedData directory is still running. The newest launch
        // owns the local AirPlay capture and XCTest session.
        for application in duplicateApplications {
            application.terminate()
        }
    }
}

@main
struct LuminaApp: App {
    @NSApplicationDelegateAdaptor(LuminaApplicationDelegate.self) private var applicationDelegate
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

enum DeviceWindowPresentationPolicy {
    static func collectionBehavior(
        for visualSource: VisualSource,
        base: NSWindow.CollectionBehavior
    ) -> NSWindow.CollectionBehavior {
        guard visualSource == .airPlay else { return base }

        var behavior = base
        behavior.subtract([
            .primary,
            .auxiliary,
            .moveToActiveSpace,
            .managed,
            .stationary,
            .participatesInCycle,
            .fullScreenPrimary,
            .fullScreenNone
        ])
        behavior.formUnion([
            .canJoinAllApplications,
            .canJoinAllSpaces,
            .transient,
            .ignoresCycle,
            .fullScreenAuxiliary
        ])
        return behavior
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
        var baseCanHide: Bool?
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
                coordinator.baseCanHide = nil
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
            coordinator.baseCanHide = window.canHide
        }
        guard isNewWindow || coordinator.configuredSource != visualSource else { return }
        coordinator.configuredSource = visualSource

        let baseBehavior = coordinator.baseCollectionBehavior ?? window.collectionBehavior
        if visualSource == .airPlay {
            // Apple's receiver owns a separate full-screen Space. Lumina joins
            // that Space as a device-sized interactive overlay while continuing
            // to capture the receiver window through ScreenCaptureKit.
            window.collectionBehavior = DeviceWindowPresentationPolicy.collectionBehavior(
                for: visualSource,
                base: baseBehavior
            )
            window.level = .floating
            window.hidesOnDeactivate = false
            window.canHide = false
        } else {
            window.collectionBehavior = baseBehavior
            window.level = coordinator.baseLevel ?? .normal
            window.hidesOnDeactivate = coordinator.baseHidesOnDeactivate ?? false
            window.canHide = coordinator.baseCanHide ?? true
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
                updateDeviceWindowPresentation()
            }
        }
        .onAppear(perform: updateDeviceWindowPresentation)
        .onChange(of: dependencies.automationWorkspace.visualSource) { _, _ in
            updateDeviceWindowPresentation()
        }
        .onChange(of: dependencies.automationWorkspace.isConnected) { _, _ in
            updateDeviceWindowPresentation()
        }
        .onChange(of: dependencies.automationWorkspace.hasLiveVisualChannel) { _, _ in
            updateDeviceWindowPresentation()
        }
        .onChange(of: dependencies.automationWorkspace.hasPresentedAirPlayVideo) { _, _ in
            updateDeviceWindowPresentation()
        }
        .onChange(of: dependencies.stateMachine.state) { _, _ in
            updateDeviceWindowPresentation()
        }
        .onDisappear {
            presentationTask?.cancel()
        }
    }

    private func presentDeviceWindowIfReady() {
        presentationTask?.cancel()
        guard let deviceWindow,
              shouldPresentDeviceWindow else { return }

        presentationTask = Task { @MainActor in
            for _ in 0..<80 {
                guard !Task.isCancelled, shouldPresentDeviceWindow else { return }

                if dependencies.automationWorkspace.visualSource == .airPlay {
                    deviceWindow.orderFrontRegardless()
                    deviceWindow.makeKey()
                } else {
                    NSRunningApplication.current.activate(options: [.activateAllWindows])
                    deviceWindow.makeKeyAndOrderFront(nil)
                }

                if deviceWindow.isVisible, deviceWindow.isOnActiveSpace {
                    dismissWindow(id: "main")
                    NSApplication.shared.setActivationPolicy(.accessory)
                    deviceWindow.orderFrontRegardless()
                    deviceWindow.makeKey()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private var shouldPresentDeviceWindow: Bool {
        let workspace = dependencies.automationWorkspace
        if workspace.hasLiveVisualChannel {
            return workspace.visualSource == .airPlay || workspace.isControlReady
        }
        // Once AirPlay video has appeared, keep Lumina's window available if
        // the system receiver or XCTest channel drops. DeviceControlView then
        // presents recovery actions instead of leaving only a black Space.
        return workspace.visualSource == .airPlay && workspace.hasPresentedAirPlayVideo
    }

    private func updateDeviceWindowPresentation() {
        if shouldPresentDeviceWindow {
            presentDeviceWindowIfReady()
            return
        }

        presentationTask?.cancel()
        let workspace = dependencies.automationWorkspace
        if workspace.visualSource == .airPlay, workspace.isControlReady {
            // AppRootView creates this window before the user starts mirroring
            // so its full-screen collection behavior is configured in advance.
            deviceWindow?.orderOut(nil)
            return
        }

        restoreSetupPresentation()
        DispatchQueue.main.async {
            dismissWindow(id: "device-control")
        }
    }

    private func restoreSetupPresentation() {
        NSApplication.shared.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
}

private struct LuminaMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var dependencies: DependencyContainer

    var body: some View {
        Button("Open Lumina", systemImage: "macwindow") {
            NSApplication.shared.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        }

        if dependencies.automationWorkspace.isConnected ||
            dependencies.automationWorkspace.hasLiveVisualChannel ||
            dependencies.automationWorkspace.hasPresentedAirPlayVideo {
            Button("Show iPhone", systemImage: "iphone") {
                openWindow(id: "device-control")
                NSRunningApplication.current.activate(options: [.activateAllWindows])
            }
        }

        Divider()
        Button("Quit Lumina", systemImage: "power", role: .destructive) {
            NSApplication.shared.terminate(nil)
        }
    }
}
