enum AppRoute: String, CaseIterable, Identifiable {
    case welcome
    case setupAssistant

    var id: Self { self }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .setupAssistant: "Setup Assistant"
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: "sparkles.rectangle.stack"
        case .setupAssistant: "checklist"
        }
    }
}
