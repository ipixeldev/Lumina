import AppKit
import SwiftUI

struct DeviceControlView: View {
    private let toolbarHeight: CGFloat = 34

    @Bindable var model: AutomationWorkspaceModel
    let reconnect: () -> Void
    let isReconnecting: Bool

    @State private var privacyBlurred = false
    @State private var viewRotation = 0

    var body: some View {
        Group {
            if model.visualSource == .airPlay, let frame = model.airPlayFrame {
                deviceSurface(
                    image: Image(decorative: frame, scale: 1),
                    imageSize: CGSize(width: frame.width, height: frame.height)
                )
            } else if model.visualSource == .direct,
                      model.isConnected,
                      let data = model.screenshotData,
                      let image = NSImage(data: data) {
                deviceSurface(image: Image(nsImage: image), imageSize: image.size)
            } else if model.visualSource == .airPlay {
                airPlaySetup
            } else {
                unavailable
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            if model.isConnected, model.visualSource == .direct { model.startStreaming() }
        }
        .onDisappear { model.stopStreaming() }
    }

    private func deviceSurface(image: Image, imageSize: CGSize) -> some View {
        let baseSize = fittedDeviceSize(for: imageSize)
        let displaySize = rotatedSize(baseSize)

        return ZStack(alignment: .top) {
            image
                .resizable()
                .interpolation(.high)
                .frame(width: baseSize.width, height: baseSize.height)
                .blur(radius: privacyBlurred ? 32 : 0)
                .rotationEffect(.degrees(Double(viewRotation) * 90))
                .frame(width: displaySize.width, height: displaySize.height)

            if privacyBlurred {
                Label("Privacy Blur", systemImage: "eye.slash.fill")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxHeight: .infinity)
            }

            controls
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(Rectangle())
        .gesture(deviceGesture(displaySize: displaySize))
    }

    private var controls: some View {
        HStack(spacing: 2) {
            Spacer(minLength: 74)
            controlButton("Wake or Unlock", systemImage: "lock.open", action: model.wakeOrUnlock)
            controlButton("Home", systemImage: "house", action: model.goHome)
            controlButton("Rotate View", systemImage: "rotate.right") {
                withAnimation(.snappy) { viewRotation = (viewRotation + 1) % 4 }
            }
            controlButton("Volume Up", systemImage: "speaker.plus", action: model.volumeUp)
            if model.issue != nil || !model.isStreaming {
                controlButton("Reconnect", systemImage: "arrow.trianglehead.2.clockwise.rotate.90", action: reconnect)
                    .disabled(isReconnecting)
            }
            Text(model.isStreaming ? "\(Int(model.framesPerSecond.rounded())) FPS" : "— FPS")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(minWidth: 39)
            controlsMenu
        }
        .padding(.horizontal, 5)
        .frame(height: toolbarHeight)
        .background(Color(red: 0.025, green: 0.34, blue: 0.50))
    }

    private func controlButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
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
                Button("Reconnect", systemImage: "arrow.trianglehead.2.clockwise.rotate.90", action: reconnect)
                    .disabled(isReconnecting)
            }

            Section("Controls") {
                Button("Volume Down", systemImage: "speaker.minus", action: model.volumeDown)
                Button("Lock Screen", systemImage: "lock", action: model.lockScreen)
                Button("Request Device Rotation", systemImage: "iphone.gen3.radiowaves.left.and.right", action: model.rotate)
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
                .foregroundStyle(.white)
                .frame(width: 21, height: 21)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More Controls")
    }

    private var airPlaySetup: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(.black)
            VStack(spacing: 18) {
                Image(systemName: "airplayvideo")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(.tint)
                Text("AirPlay-assisted Video")
                    .font(.title2.bold())
                Text("Enable AirPlay Receiver on this Mac, then mirror the iPhone to this Mac from Control Center. Finally, select the mirrored window for Lumina to capture.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button(model.isChoosingAirPlaySource ? "Waiting for Selection…" : "Choose Mirrored Window…") {
                    model.chooseAirPlaySource()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isChoosingAirPlaySource)
            }
            .padding(34)
            .frame(maxHeight: .infinity)
            controls
        }
        .frame(width: 390, height: 760)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
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
                      value.startLocation.y > toolbarHeight,
                      let screen = model.screenInfo?.screenSize,
                      displaySize.width > 0,
                      displaySize.height > 0 else { return }
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
        let u = min(max(Double(point.x / display.width), 0), 1)
        let v = min(max(Double(point.y / display.height), 0), 1)
        let normalized: (x: Double, y: Double) = switch viewRotation {
        case 1: (v, 1 - u)
        case 2: (1 - u, 1 - v)
        case 3: (1 - v, u)
        default: (u, v)
        }
        return AutomationPoint(x: normalized.x * screen.width, y: normalized.y * screen.height)
    }

    private func rotatedSize(_ size: CGSize) -> CGSize {
        viewRotation.isMultiple(of: 2) ? size : CGSize(width: size.height, height: size.width)
    }

    private func fittedDeviceSize(for imageSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGSize(width: 390, height: 700) }
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let maximum = CGSize(width: visible.width * 0.82, height: visible.height - 48)
        let scale = min(1, maximum.width / imageSize.width, maximum.height / imageSize.height)
        return CGSize(width: floor(imageSize.width * scale), height: floor(imageSize.height * scale))
    }
}
