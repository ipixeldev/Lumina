import AppKit
import SwiftUI

struct DeviceControlView: View {
    @Bindable var model: AutomationWorkspaceModel
    let reconnect: () -> Void
    let isReconnecting: Bool

    @State private var privacyBlurred = false
    var body: some View {
        Group {
            if model.visualSource == .airPlay,
               let screen = model.screenInfo?.screenSize,
               let frame = model.airPlayFrame {
                deviceSurface(
                    image: Image(decorative: frame, scale: 1),
                    imageSize: CGSize(width: CGFloat(screen.width), height: CGFloat(screen.height)),
                    cropsToDeviceViewport: true
                )
                .overlay(alignment: .top) {
                    if !model.isConnected {
                        controlReconnectBanner
                    }
                }
            } else if model.visualSource == .direct,
                      model.isConnected,
                      let frame = model.directFrame {
                deviceSurface(
                    image: Image(decorative: frame, scale: 1),
                    imageSize: CGSize(width: frame.width, height: frame.height)
                )
            } else if model.visualSource == .airPlay, model.isConnected {
                airPlaySetup
            } else {
                unavailable
            }
        }
        .toolbar { deviceToolbar }
        .onAppear {
            if model.isConnected, model.visualSource == .direct { model.startStreaming() }
        }
    }

    private var controlReconnectBanner: some View {
        HStack(spacing: 10) {
            Label("iPhone control disconnected", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
            Spacer(minLength: 8)
            if isReconnecting {
                ProgressView().controlSize(.small)
            } else {
                Button("Reconnect", action: reconnect)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(12)
    }

    private func deviceSurface(
        image: Image,
        imageSize: CGSize,
        cropsToDeviceViewport: Bool = false
    ) -> some View {
        let displaySize = fittedDeviceSize(for: imageSize)

        return ZStack {
            Group {
                if cropsToDeviceViewport {
                    image
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: displaySize.width, height: displaySize.height)
                        .clipped()
                } else {
                    image
                        .resizable()
                        .interpolation(.high)
                        .frame(width: displaySize.width, height: displaySize.height)
                }
            }
            .blur(radius: privacyBlurred ? 32 : 0)

            if privacyBlurred {
                Label("Privacy Blur", systemImage: "eye.slash.fill")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(Rectangle())
        .gesture(deviceGesture(displaySize: displaySize))
    }

    @ToolbarContentBuilder
    private var deviceToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 4) {
                toolbarButton("Wake or Unlock", systemImage: "lock.open", action: model.wakeOrUnlock)
                toolbarButton("Home", systemImage: "house", action: model.goHome)
                toolbarButton("Rotate iPhone", systemImage: "rotate.right", action: model.rotate)
                toolbarButton("Volume Up", systemImage: "speaker.plus", action: model.volumeUp)
                Text(model.isStreaming ? "\(Int(model.framesPerSecond.rounded())) FPS" : "— FPS")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 39)
                controlsMenu
            }
            .fixedSize()
        }
    }

    private func toolbarButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 21, height: 21)
        }
        .buttonStyle(.plain)
        .help(title)
        .disabled(!model.isConnected)
    }

    private var controlsMenu: some View {
        Menu {
            if let issue = model.issue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                Divider()
            }

            Section("Connection") {
                Button(
                    isReconnecting ? "Reconnecting iPhone Control…" : "Reconnect iPhone Control",
                    systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                    action: reconnect
                )
                .disabled(isReconnecting)
            }

            Section("Controls") {
                Button("Volume Down", systemImage: "speaker.minus", action: model.volumeDown)
                Button("Lock Screen", systemImage: "lock", action: model.lockScreen)
                Button("Rotate iPhone", systemImage: "iphone.gen3.radiowaves.left.and.right", action: model.rotate)
            }

            Section("Display") {
                Toggle("Privacy Blur", systemImage: "eye.slash", isOn: $privacyBlurred)
                Button("Refresh", systemImage: "arrow.clockwise", action: model.refresh)
                if model.isStreaming {
                    Label("\(Int(model.framesPerSecond.rounded())) FPS", systemImage: "gauge.with.dots.needle.67percent")
                }
            }

            Section("Video") {
                Label(model.visualSource.title, systemImage: model.visualSource == .airPlay ? "airplayvideo" : "cable.connector")
                if model.visualSource == .airPlay {
                    Button("Choose Mirrored Window…", systemImage: "macwindow.on.rectangle", action: model.chooseAirPlaySource)
                }
            }

            if model.visualSource == .direct {
                Section("Direct Stream Quality") {
                    ForEach(StreamQualityProfile.allCases) { profile in
                        Button {
                            model.selectStreamProfile(profile)
                        } label: {
                            if model.streamProfile == profile {
                                Label(profile.title, systemImage: "checkmark")
                            } else {
                                Text(profile.title)
                            }
                        }
                        .help(profile.detail)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 21, height: 21)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More Controls")
    }

    private var airPlaySetup: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 16) {
                Image(systemName: "airplayvideo")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(.tint)
                Text("Connect with AirPlay")
                    .font(.title2.bold())
                Label("XCTest control connected · Direct video is off", systemImage: "checkmark.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 10) {
                    Label("Enable AirPlay Receiver on this Mac.", systemImage: "1.circle.fill")
                    Label("On iPhone, open Control Center → Screen Mirroring and choose this Mac.", systemImage: "2.circle.fill")
                    Label("Choose the mirrored iPhone window in Lumina.", systemImage: "3.circle.fill")
                }
                .font(.callout)
                .frame(maxWidth: 310, alignment: .leading)
                Text("Both devices must use the same network. Lumina uses the macOS AirPlay Receiver; it does not advertise a separate receiver name.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 310)
                Button("Open AirPlay Receiver Settings", systemImage: "gear") {
                    model.openAirPlayReceiverSettings()
                }
                Button(model.isChoosingAirPlaySource ? "Waiting for Selection…" : "Choose Mirrored Window…") {
                    model.chooseAirPlaySource()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isChoosingAirPlaySource)
                if let issue = model.issue {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 310)
                }
            }
            .padding(34)
            .frame(maxHeight: .infinity)
        }
        .frame(width: 390, height: 760)
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label(isReconnecting ? "Reconnecting…" : "No active iPhone session", systemImage: "iphone.slash")
        } description: {
            Text("Reconnect the existing runner without rebuilding or reinstalling it.")
        } actions: {
            if isReconnecting {
                ProgressView().controlSize(.small)
            } else {
                Button("Reconnect", action: reconnect)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(width: 390, height: 700)
    }

    private func deviceGesture(displaySize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onEnded { value in
                guard !privacyBlurred,
                      model.isConnected,
                      let screen = model.screenInfo?.screenSize,
                      displaySize.width > 0,
                      displaySize.height > 0 else { return }
                guard let start = DeviceViewportGeometry.map(value.startLocation, from: displaySize, to: screen),
                      let end = DeviceViewportGeometry.map(value.location, from: displaySize, to: screen) else { return }
                let distance = hypot(value.translation.width, value.translation.height)
                if distance < 8 {
                    model.tap(at: end)
                } else {
                    model.drag(from: start, to: end, duration: 0.15)
                }
            }
    }

    private func fittedDeviceSize(for imageSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGSize(width: 390, height: 700) }
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let maximum = CGSize(width: visible.width * 0.82, height: visible.height - 48)
        let device = DeviceScreenInfo.Size(
            width: Double(imageSize.width),
            height: Double(imageSize.height)
        )
        return DeviceViewportGeometry.fittedDisplaySize(device: device, available: maximum)
    }
}
