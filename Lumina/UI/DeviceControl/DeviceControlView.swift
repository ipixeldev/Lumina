import AppKit
import SwiftUI

struct DeviceControlView: View {
    @Bindable var model: AutomationWorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.isConnected, let data = model.screenshotData, let image = NSImage(data: data) {
                GeometryReader { proxy in
                    let frame = aspectFit(imageSize: image.size, in: proxy.size)
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: frame.width, height: frame.height)
                        .contentShape(Rectangle())
                        .gesture(deviceGesture(displaySize: frame))
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                }
                .padding(28)
                .background(Color(nsColor: .windowBackgroundColor))
            } else {
                ContentUnavailableView(
                    "No active iPhone session",
                    systemImage: "iphone.slash",
                    description: Text("Complete Setup Assistant to connect Lumina to your iPhone.")
                )
            }
        }
        .navigationTitle("Device Control")
        .onAppear {
            if model.isConnected { model.startStreaming() }
        }
        .onDisappear { model.stopStreaming() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { model.goHome() } label: {
                Label("Home", systemImage: "house")
            }
            .disabled(!model.isConnected)
            Button { model.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(!model.isConnected)

            Divider().frame(height: 20)
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
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
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

    private func aspectFit(imageSize: CGSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func applicationName(_ app: ActiveApplicationInfo) -> String {
        if let name = app.name, !name.isEmpty { return name }
        if let bundleIdentifier = app.bundleId, !bundleIdentifier.isEmpty { return bundleIdentifier }
        return "iPhone"
    }
}
