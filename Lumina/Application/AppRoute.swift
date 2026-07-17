enum AppRoute: String, CaseIterable, Identifiable {
    case welcome
    case setupAssistant
    case acknowledgements

    var id: Self { self }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .setupAssistant: "Setup Assistant"
        case .acknowledgements: "Acknowledgements"
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: "sparkles.rectangle.stack"
        case .setupAssistant: "checklist"
        case .acknowledgements: "doc.text"
        }
    }
}
