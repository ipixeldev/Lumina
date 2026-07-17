import SwiftUI

struct AcknowledgementsView: View {
    private let licenseText: String = {
        let direct = Bundle.main.url(forResource: "WebDriverAgent-LICENSE", withExtension: "txt")
        let nested = Bundle.main.url(
            forResource: "WebDriverAgent-LICENSE",
            withExtension: "txt",
            subdirectory: "Licenses"
        )
        guard let url = direct ?? nested else {
            return "The bundled WebDriverAgent license resource is unavailable."
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            return "The bundled WebDriverAgent license could not be read: \(error.localizedDescription)"
        }
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Acknowledgements")
                    .font(.largeTitle.bold())
                Text("MirrorBridge is independent open-source software and is not affiliated with Apple or Appium.")
                    .foregroundStyle(.secondary)

                GroupBox("Appium WebDriverAgent") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Version \(WebDriverAgentPin.version)")
                        Text(WebDriverAgentPin.commit)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        if let sourceURL = URL(string: "https://github.com/appium/WebDriverAgent") {
                            Link("Upstream source", destination: sourceURL)
                        }
                        Divider()
                        Text(licenseText)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
            }
            .padding(32)
            .frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Acknowledgements")
    }
}
