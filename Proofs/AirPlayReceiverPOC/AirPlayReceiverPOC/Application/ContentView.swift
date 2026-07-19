import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ReceiverPOCModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                receiverCard
                serviceCard
                instructionsCard
                eventCard
            }
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lumina AirPlay Receiver Proof")
                .font(.largeTitle.bold())
            Text("Advertisement milestone")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("This standalone app publishes an experimental receiver identity. It does not authenticate, decrypt, capture, or render an AirPlay stream.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var receiverCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: model.isRunning ? "airplayvideo.circle.fill" : "airplayvideo.circle")
                        .font(.system(size: 38))
                        .foregroundStyle(model.isRunning ? .green : .secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.receiverName)
                            .font(.title2.bold())
                            .textSelection(.enabled)
                        Text(model.statusText)
                            .foregroundStyle(model.hasFailure ? .red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Button(model.isActive ? "Stop" : "Start") {
                        model.toggleAdvertising()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.isActive ? .red : .green)
                }

                Divider()

                LabeledContent("Receiver ID", value: model.deviceID)
                    .textSelection(.enabled)
                LabeledContent("Pairing ID", value: model.pairingIdentifier)
                    .textSelection(.enabled)
                LabeledContent("TCP port", value: model.portText)
                    .textSelection(.enabled)
            }
            .padding(8)
        } label: {
            Label("Receiver identity", systemImage: "person.text.rectangle")
        }
    }

    private var serviceCard: some View {
        GroupBox {
            VStack(spacing: 12) {
                serviceRow(
                    name: "_airplay._tcp",
                    detail: model.receiverName,
                    published: model.airPlayPublished
                )
                Divider()
                serviceRow(
                    name: "_raop._tcp",
                    detail: model.raopInstanceName,
                    published: model.raopPublished
                )
            }
            .padding(8)
        } label: {
            Label("Bonjour services", systemImage: "network")
        }
    }

    private func serviceRow(name: String, detail: String, published: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: published ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(published ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.body.monospaced().weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Text(published ? "Published" : "Waiting")
                .font(.caption.weight(.semibold))
                .foregroundStyle(published ? .green : .secondary)
        }
    }

    private var instructionsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 11) {
                instruction(number: 1, text: "Keep this Mac and the test iPhone on the same Wi-Fi network.")
                instruction(number: 2, text: "On iPhone, open Control Center → Screen Mirroring.")
                instruction(number: 3, text: "Confirm that \(model.receiverName) appears as a separate receiver.")
                instruction(number: 4, text: "Select it once. The proof logs the first bounded request and returns Not Implemented by design.")

                Label(
                    "The Mac's built-in AirPlay Receiver and Screen Recording permission are not used by this proof.",
                    systemImage: "lock.shield"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
                .padding(.top, 4)
            }
            .padding(8)
        } label: {
            Label("Physical-device check", systemImage: "iphone.gen3.radiowaves.left.and.right")
        }
    }

    private func instruction(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 21, height: 21)
                .background(.blue, in: Circle())
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var eventCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if model.events.isEmpty {
                    Text("No events yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.events.enumerated()), id: \.offset) { _, event in
                        Text(event)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Label("Bounded event log", systemImage: "list.bullet.rectangle")
        }
    }
}
