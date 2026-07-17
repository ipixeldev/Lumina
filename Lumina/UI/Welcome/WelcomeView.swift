import SwiftUI

struct WelcomeView: View {
    let beginSetup: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "iphone.and.arrow.forward.inward")
                .font(.system(size: 68, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("MirrorBridge")
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                Text("View and control your own iPhone using local Apple developer automation.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 570)
            }

            Button("Set up an iPhone", action: beginSetup)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

            Label("Your screen and controls stay between this Mac and your iPhone.", systemImage: "lock.shield")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            Text("Developer Mode, initial USB pairing, and an Apple Development certificate are required. MirrorBridge cannot unlock an iPhone or bypass device confirmations.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 650)
                .padding(.bottom, 24)
        }
        .padding(40)
        .navigationTitle("Welcome")
    }
}

#Preview {
    WelcomeView(beginSetup: {})
        .frame(width: 820, height: 580)
}
