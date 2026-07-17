import AppKit
import SwiftUI

struct DeviceControlView: View {
    @Bindable var model: AutomationWorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if model.isConnected, let data = model.screenshotData, let image = NSImage(data: data) {
                let displaySize = fittedDeviceSize(for: image.size)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .contentShape(Rectangle())
                    .gesture(deviceGesture(displaySize: displaySize))
            } else {
                ContentUnavailableView(
                    "No active iPhone session",
                    systemImage: "iphone.slash",
                    description: Text("Complete Setup Assistant to connect Lumina to your iPhone.")
                )
                .frame(width: 390, height: 700)
            }
        }
        .background(.black)
        .onAppear {
            if model.isConnected { model.startStreaming() }
        }
        .onDisappear { model.stopStreaming() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if let app = model.activeApplication {
                Text(applicationName(app))
                    .lineLimit(1)
            }
            Spacer()
            if let issue = model.issue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(issue)
            }
            if model.isStreaming {
                Label("\(Int(model.framesPerSecond.rounded())) FPS", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if model.isConnected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Menu {
                Button { model.goHome() } label: { Label("Home", systemImage: "house") }
                Button { model.volumeUp() } label: { Label("Volume Up", systemImage: "speaker.plus") }
                Button { model.volumeDown() } label: { Label("Volume Down", systemImage: "speaker.minus") }
                Divider()
                Button { model.wakeOrUnlock() } label: { Label("Wake or Unlock", systemImage: "lock.open") }
                Button { model.lockScreen() } label: { Label("Lock Screen", systemImage: "lock") }
                Button { model.rotate() } label: { Label("Rotate", systemImage: "rotate.right") }
                Divider()
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!model.isConnected)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.bar)
    }

    private func deviceGesture(displaySize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onEnded { value in
                guard let screen = model.screenInfo?.screenSize,
                      displaySize.width > 0, displaySize.height > 0 else { return }
                let start = map(value.startLocation, from: displaySize, to: screen)
                let end = map(value.location, from: displaySize, to: screen)
                let distance = hypot(value.translation.width, value.translation.height)
                if distance < 8 {
                    model.tap(at: end)
                } else {
                    model.drag(from: start, to: end, duration: 0.15)
                }
            }
    }

    private func map(_ point: CGPoint, from display: CGSize, to screen: DeviceScreenInfo.Size) -> AutomationPoint {
        AutomationPoint(
            x: min(max(Double(point.x / display.width) * screen.width, 0), screen.width),
            y: min(max(Double(point.y / display.height) * screen.height, 0), screen.height)
        )
    }

    private func fittedDeviceSize(for imageSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGSize(width: 390, height: 700) }
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let maximum = CGSize(width: visible.width * 0.72, height: visible.height - 120)
        let scale = min(1, maximum.width / imageSize.width, maximum.height / imageSize.height)
        return CGSize(width: floor(imageSize.width * scale), height: floor(imageSize.height * scale))
    }

    private func applicationName(_ app: ActiveApplicationInfo) -> String {
        if let name = app.name, !name.isEmpty { return name }
        if let bundleIdentifier = app.bundleId, !bundleIdentifier.isEmpty { return bundleIdentifier }
        return "iPhone"
    }
}
