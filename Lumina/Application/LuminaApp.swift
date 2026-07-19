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
        Window("Lumina", id: "main") {
            AppRootView(dependencies: dependencies)
                .frame(minWidth: 840, minHeight: 580)
                .background(WindowRestorationController(identifier: .luminaMain))
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

private extension NSUserInterfaceItemIdentifier {
    static let luminaMain = Self("com.iPixeldev.Lumina.main-window")
    static let luminaDevice = Self("com.iPixeldev.Lumina.device-window")
}

private struct WindowRestorationController: NSViewRepresentable {
    let identifier: NSUserInterfaceItemIdentifier

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
            view.window?.identifier = identifier
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

        // The native receiver owns a full-screen Space, but the captured frame
        // belongs in Lumina's normal desktop window. Never let this window join
        // the receiver's Space; when ordered front, move it to the desktop Space
        // Lumina has just activated.
        var behavior = base
        behavior.subtract([
            .canJoinAllApplications,
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .fullScreenPrimary
        ])
        behavior.insert(.moveToActiveSpace)
        return behavior
    }
}

enum AirPlayDesktopHandoffPolicy {
    static func anchorIsReady(
        applicationIsActive: Bool,
        anchorIsVisible: Bool,
        anchorIsOnActiveSpace: Bool,
        anchorIsKeyWindow: Bool
    ) -> Bool {
        applicationIsActive && anchorIsVisible && anchorIsOnActiveSpace && anchorIsKeyWindow
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
        window.identifier = .luminaDevice

        let baseBehavior = coordinator.baseCollectionBehavior ?? window.collectionBehavior
        if visualSource == .airPlay {
            // Apple's receiver owns a separate full-screen Space. Lumina keeps
            // its interactive window on the desktop and captures the receiver
            // independently through ScreenCaptureKit.
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
            isReconnecting: dependencies.setupAssistantModel.isReconnecting,
            selectVisualSource: dependencies.setupAssistantModel.selectVisualSource,
            canSelectVisualSource: dependencies.setupAssistantModel.canSelectVisualSource
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
        .onChange(of: dependencies.automationWorkspace.airPlayPresentationFailureSequence) { _, _ in
            restoreSetupAfterAirPlayCaptureFailure()
        }
        .onChange(of: dependencies.automationWorkspace.isChoosingAirPlaySource) { _, isChoosing in
            if !isChoosing { restoreSetupAfterAirPlayCaptureFailure() }
        }
        .onChange(of: dependencies.automationWorkspace.issue) { _, issue in
            if issue != nil { restoreSetupAfterAirPlayCaptureFailure() }
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
            let presentationSource = dependencies.automationWorkspace.visualSource
            if presentationSource == .airPlay {
                guard await activateLuminaDesktop(excluding: deviceWindow) else {
                    guard !Task.isCancelled else { return }
                    restoreSetupPresentation()
                    return
                }
            }

            for _ in 0..<80 {
                guard !Task.isCancelled,
                      shouldPresentDeviceWindow,
                      dependencies.automationWorkspace.visualSource == presentationSource else { return }

                if presentationSource == .airPlay {
                    deviceWindow.makeKeyAndOrderFront(nil)
                } else {
                    NSRunningApplication.current.activate(options: [.activateAllWindows])
                    deviceWindow.makeKeyAndOrderFront(nil)
                }

                if deviceWindow.isVisible,
                   deviceWindow.isOnActiveSpace,
                   deviceWindow.isKeyWindow {
                    hideSetupWindow()
                    NSApplication.shared.setActivationPolicy(.accessory)
                    deviceWindow.orderFrontRegardless()
                    deviceWindow.makeKey()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }

            restoreSetupPresentation()
        }
    }

    private func activateLuminaDesktop(
        excluding deviceWindow: NSWindow?,
        requiresDevicePresentation: Bool = true
    ) async -> Bool {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)

        // The setup window already lives on Lumina's desktop Space. Bringing it
        // forward is the supported AppKit way to leave another application's
        // full-screen Space while ScreenCaptureKit keeps its independent stream.
        var requestedSetupWindow = false
        var consecutiveReadyObservations = 0
        for _ in 0..<80 {
            guard !Task.isCancelled,
                  dependencies.automationWorkspace.visualSource == .airPlay else { return false }
            if requiresDevicePresentation, !shouldPresentDeviceWindow { return false }

            if let setupWindow = application.windows.first(where: {
                $0 !== deviceWindow && $0.identifier == .luminaMain
            }) {
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                setupWindow.makeKeyAndOrderFront(nil)

                if AirPlayDesktopHandoffPolicy.anchorIsReady(
                    applicationIsActive: application.isActive,
                    anchorIsVisible: setupWindow.isVisible,
                    anchorIsOnActiveSpace: setupWindow.isOnActiveSpace,
                    anchorIsKeyWindow: setupWindow.isKeyWindow
                ) {
                    consecutiveReadyObservations += 1
                    if consecutiveReadyObservations >= 2 { return true }
                } else {
                    consecutiveReadyObservations = 0
                }
            } else if !requestedSetupWindow {
                requestedSetupWindow = true
                openWindow(id: "main")
            }

            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
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
            // so its collection behavior is configured in advance. Keep Setup
            // Assistant visible while a runtime Direct → AirPlay switch waits
            // for its first real frame.
            deviceWindow?.orderOut(nil)
            restoreSetupPresentation()
            return
        }

        restoreSetupPresentation()
        DispatchQueue.main.async {
            dismissWindow(id: "device-control")
        }
    }

    private func restoreSetupAfterAirPlayCaptureFailure() {
        let workspace = dependencies.automationWorkspace
        guard workspace.visualSource == .airPlay,
              !workspace.hasLiveVisualChannel else { return }
        presentationTask?.cancel()
        deviceWindow?.orderOut(nil)
        presentationTask = Task { @MainActor in
            guard await activateLuminaDesktop(
                excluding: deviceWindow,
                requiresDevicePresentation: false
            ) else {
                guard !Task.isCancelled else { return }
                restoreSetupPresentation()
                return
            }
        }
    }

    private func hideSetupWindow() {
        for window in NSApplication.shared.windows where window.identifier == .luminaMain {
            // Keep this window alive as a desktop-Space anchor. Closing the
            // SwiftUI scene would leave AirPlay reconnects with no normal Space
            // that Lumina can activate.
            window.orderOut(nil)
        }
    }

    private func restoreSetupPresentation() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        if let setupWindow = NSApplication.shared.windows.first(where: {
            $0.identifier == .luminaMain
        }) {
            setupWindow.makeKeyAndOrderFront(nil)
            return
        }

        openWindow(id: "main")
        DispatchQueue.main.async {
            NSApplication.shared.windows
                .first(where: { $0.identifier == .luminaMain })?
                .makeKeyAndOrderFront(nil)
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
