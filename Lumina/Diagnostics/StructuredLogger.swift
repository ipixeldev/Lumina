import OSLog

nonisolated enum LogCategory: String, CaseIterable, Sendable {
    case app
    case environment
    case device
    case signing
    case build
    case installation
    case runner
    case transport
    case automation
    case mirroring
    case input
    case security
    case performance
}

nonisolated protocol StructuredLogging: Sendable {
    func debug(_ message: String, category: LogCategory)
    func info(_ message: String, category: LogCategory)
    func error(_ message: String, category: LogCategory)
}

nonisolated struct StructuredLogger: StructuredLogging {
    private let subsystem: String

    init(subsystem: String = Bundle.main.bundleIdentifier ?? "com.iPixeldev.MirrorBridge") {
        self.subsystem = subsystem
    }

    func debug(_ message: String, category: LogCategory) {
        logger(for: category).debug("\(message, privacy: .public)")
    }

    func info(_ message: String, category: LogCategory) {
        logger(for: category).info("\(message, privacy: .public)")
    }

    func error(_ message: String, category: LogCategory) {
        logger(for: category).error("\(message, privacy: .public)")
    }

    private func logger(for category: LogCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }
}
