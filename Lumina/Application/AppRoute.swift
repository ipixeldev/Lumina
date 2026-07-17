enum AppRoute: String, CaseIterable, Identifiable {
    case welcome
    case setupAssistant
    case deviceControl
    case acknowledgements

    var id: Self { self }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .setupAssistant: "Setup Assistant"
        case .deviceControl: "Device Control"
        case .acknowledgements: "Acknowledgements"
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: "sparkles.rectangle.stack"
        case .setupAssistant: "checklist"
        case .deviceControl: "iphone.gen3.radiowaves.left.and.right"
        case .acknowledgements: "doc.text"
        }
    }
}
