import SwiftUI

struct AppRootView: View {
    @Bindable var dependencies: DependencyContainer
    @State private var selection: AppRoute? = .welcome

    var body: some View {
        NavigationSplitView {
            List(AppRoute.allCases, selection: $selection) { route in
                Label(route.title, systemImage: route.systemImage)
                    .tag(route)
            }
            .navigationTitle("MirrorBridge")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            switch selection ?? .welcome {
            case .welcome:
                WelcomeView {
                    dependencies.logger.info("Setup assistant opened", category: .app)
                    selection = .setupAssistant
                }
            case .setupAssistant:
                SetupAssistantView(model: dependencies.setupAssistantModel)
            case .acknowledgements:
                AcknowledgementsView()
            }
        }
    }
}

#Preview {
    AppRootView(dependencies: .live)
}
