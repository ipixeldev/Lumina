import Foundation
import Network
import SystemConfiguration

/// Checks whether this Mac's public Bonjour advertisements are visible on the
/// local network. This does not read or change private AirPlay preferences.
nonisolated protocol AirPlayReceiverDiscoverabilityChecking: Sendable {
    func check(timeout: Duration) async throws -> AirPlayReceiverDiscoverabilityReport
}

nonisolated struct AirPlayReceiverDiscoverabilityChecker: AirPlayReceiverDiscoverabilityChecking {
    private let browser: any BonjourServiceBrowsing
    private let identityProvider: any MacAirPlayIdentityProviding

    init(
        browser: any BonjourServiceBrowsing = NetworkBonjourServiceBrowser(),
        identityProvider: any MacAirPlayIdentityProviding = SystemMacAirPlayIdentityProvider()
    ) {
        self.browser = browser
        self.identityProvider = identityProvider
    }

    func check(
        timeout: Duration = .seconds(2.5)
    ) async throws -> AirPlayReceiverDiscoverabilityReport {
        let identity = identityProvider.currentIdentity()

        async let airPlayResult = browser.browse(serviceType: "_airplay._tcp", timeout: timeout)
        async let raopResult = browser.browse(serviceType: "_raop._tcp", timeout: timeout)
        let results = try await (airPlayResult, raopResult)

        return Self.makeReport(
            identity: identity,
            airPlayResult: results.0,
            raopResult: results.1
        )
    }

    static func makeReport(
        identity: MacAirPlayIdentity,
        airPlayResult: BonjourBrowseResult,
        raopResult: BonjourBrowseResult
    ) -> AirPlayReceiverDiscoverabilityReport {
        let airPlayNames = uniqueNames(in: airPlayResult.services)
        let raopNames = uniqueNames(in: raopResult.services)
        let matchingAirPlayNames = matchingNames(
            in: airPlayResult.services,
            serviceType: "_airplay._tcp",
            identity: identity
        )
        let matchingRAOPNames = matchingNames(
            in: raopResult.services,
            serviceType: "_raop._tcp",
            identity: identity
        )

        let outcome: AirPlayReceiverDiscoverabilityOutcome
        let diagnostic: AirPlayReceiverDiagnostic

        if !matchingAirPlayNames.isEmpty {
            outcome = .screenMirroringAdvertised
            diagnostic = AirPlayReceiverDiagnostic(
                severity: .ready,
                title: "AirPlay Receiver is discoverable",
                message: "\(identity.displayName) is advertising screen mirroring on the local network."
            )
        } else if !matchingRAOPNames.isEmpty {
            outcome = .audioOnly
            diagnostic = AirPlayReceiverDiagnostic(
                severity: .warning,
                title: "Only AirPlay audio is discoverable",
                message: "\(identity.displayName) is advertising AirPlay audio, but its screen-mirroring service is missing. Turn AirPlay Receiver off and on in System Settings, then recheck."
            )
        } else if case let .unavailable(message) = airPlayResult.status {
            outcome = .browsingUnavailable
            diagnostic = AirPlayReceiverDiagnostic(
                severity: .error,
                title: "AirPlay discovery is unavailable",
                message: "Lumina could not browse screen-mirroring services (\(message)). Check the network connection, Lumina's Local Network permission, firewall, or VPN, then retry."
            )
        } else {
            outcome = .notAdvertised
            let networkContext = airPlayNames.isEmpty
                ? "No screen-mirroring advertisements were found on the local network."
                : "Other screen-mirroring advertisements are visible, but none match this Mac."
            diagnostic = AirPlayReceiverDiagnostic(
                severity: .warning,
                title: "AirPlay Receiver is not advertised",
                message: "\(networkContext) Confirm that AirPlay Receiver is enabled for \(identity.displayName), then toggle it off and on and recheck."
            )
        }

        return AirPlayReceiverDiscoverabilityReport(
            macDisplayName: identity.displayName,
            localHostName: identity.localHostName,
            airPlayServiceNames: airPlayNames,
            raopServiceNames: raopNames,
            matchingAirPlayServiceNames: matchingAirPlayNames,
            matchingRAOPServiceNames: matchingRAOPNames,
            outcome: outcome,
            diagnostic: diagnostic
        )
    }

    private static func uniqueNames(in services: [BonjourServiceRecord]) -> [String] {
        Array(Set(services.map(\.name))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private static func matchingNames(
        in services: [BonjourServiceRecord],
        serviceType: String,
        identity: MacAirPlayIdentity
    ) -> [String] {
        let aliases = Set(
            [identity.displayName, identity.localHostName]
                .map(canonicalName)
                .filter { !$0.isEmpty }
        )

        return Array(Set(services.compactMap { service in
            guard canonicalServiceType(service.type) == canonicalServiceType(serviceType) else { return nil }
            let candidate: String
            if canonicalServiceType(serviceType) == canonicalServiceType("_raop._tcp"),
               let separator = service.name.firstIndex(of: "@") {
                candidate = String(service.name[service.name.index(after: separator)...])
            } else {
                candidate = service.name
            }
            let canonicalCandidate = canonicalName(candidate)
            let canonicalCandidateWithoutConflictSuffix = canonicalName(
                removingBonjourConflictSuffix(from: candidate)
            )
            return aliases.contains(canonicalCandidate)
                || aliases.contains(canonicalCandidateWithoutConflictSuffix)
                ? service.name
                : nil
        })).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private static func canonicalServiceType(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private static func removingBonjourConflictSuffix(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.last == ")",
              let openingParenthesis = trimmed.range(of: " (", options: .backwards)?.lowerBound else {
            return trimmed
        }

        let digitsStart = trimmed.index(openingParenthesis, offsetBy: 2)
        let digitsEnd = trimmed.index(before: trimmed.endIndex)
        let suffix = trimmed[digitsStart..<digitsEnd]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return trimmed }
        return String(trimmed[..<openingParenthesis])
    }

    private static func canonicalName(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }
}

nonisolated enum AirPlayReceiverDiscoverabilityOutcome: String, Equatable, Sendable {
    case screenMirroringAdvertised
    case audioOnly
    case notAdvertised
    case browsingUnavailable
}

nonisolated struct AirPlayReceiverDiagnostic: Equatable, Sendable {
    enum Severity: String, Equatable, Sendable {
        case ready
        case warning
        case error
    }

    let severity: Severity
    let title: String
    let message: String
}

nonisolated struct AirPlayReceiverDiscoverabilityReport: Equatable, Sendable {
    let macDisplayName: String
    let localHostName: String
    let airPlayServiceNames: [String]
    let raopServiceNames: [String]
    let matchingAirPlayServiceNames: [String]
    let matchingRAOPServiceNames: [String]
    let outcome: AirPlayReceiverDiscoverabilityOutcome
    let diagnostic: AirPlayReceiverDiagnostic

    var isScreenMirroringAdvertised: Bool {
        outcome == .screenMirroringAdvertised
    }
}

nonisolated struct MacAirPlayIdentity: Equatable, Sendable {
    let displayName: String
    let localHostName: String
}

nonisolated protocol MacAirPlayIdentityProviding: Sendable {
    func currentIdentity() -> MacAirPlayIdentity
}

nonisolated struct SystemMacAirPlayIdentityProvider: MacAirPlayIdentityProviding {
    func currentIdentity() -> MacAirPlayIdentity {
        let configuredLocalName = SCDynamicStoreCopyLocalHostName(nil) as String?
        let processHostName = ProcessInfo.processInfo.hostName
        let localHostName = nonempty(configuredLocalName)
            ?? nonempty(processHostName.components(separatedBy: ".").first)
            ?? "This-Mac"
        let configuredDisplayName = SCDynamicStoreCopyComputerName(nil, nil) as String?
        let displayName = nonempty(configuredDisplayName) ?? localHostName

        return MacAirPlayIdentity(displayName: displayName, localHostName: localHostName)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

nonisolated protocol BonjourServiceBrowsing: Sendable {
    func browse(serviceType: String, timeout: Duration) async throws -> BonjourBrowseResult
}

nonisolated struct BonjourServiceRecord: Hashable, Sendable {
    let name: String
    let type: String
    let domain: String
    let interfaceName: String?
}

nonisolated enum BonjourBrowseStatus: Equatable, Sendable {
    case completed
    case unavailable(message: String)
}

nonisolated struct BonjourBrowseResult: Equatable, Sendable {
    let serviceType: String
    let services: [BonjourServiceRecord]
    let status: BonjourBrowseStatus
}

nonisolated struct NetworkBonjourServiceBrowser: BonjourServiceBrowsing {
    func browse(serviceType: String, timeout: Duration) async throws -> BonjourBrowseResult {
        try Task.checkCancellation()
        let session = NetworkBonjourBrowseSession(serviceType: serviceType, timeout: timeout)

        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.start(continuation: continuation)
            }
        } onCancel: {
            session.cancel()
        }
        try Task.checkCancellation()
        return result
    }
}

private nonisolated final class NetworkBonjourBrowseSession: @unchecked Sendable {
    private let serviceType: String
    private let timeout: Duration
    private let queue: DispatchQueue
    private let browser: NWBrowser

    // Every property below is confined to `queue`.
    private var continuation: CheckedContinuation<BonjourBrowseResult, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var services: Set<BonjourServiceRecord> = []
    private var isReady = false
    private var lastErrorMessage: String?
    private var hasStarted = false
    private var isFinished = false

    init(serviceType: String, timeout: Duration) {
        self.serviceType = serviceType
        self.timeout = max(timeout, .zero)
        self.queue = DispatchQueue(
            label: "com.iPixeldev.Lumina.bonjour.\(serviceType)",
            qos: .utility
        )
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        self.browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: "local."),
            using: parameters
        )
    }

    func start(continuation: CheckedContinuation<BonjourBrowseResult, any Error>) {
        queue.async { [self] in
            guard !isFinished else {
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            configureBrowserCallbacks()
            hasStarted = true
            browser.start(queue: queue)
            timeoutTask = Task { [weak self, timeout] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self?.completeAtDeadline()
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            guard !isFinished else { return }
            isFinished = true
            timeoutTask?.cancel()
            timeoutTask = nil
            if hasStarted { browser.cancel() }
            let continuation = self.continuation
            self.continuation = nil
            continuation?.resume(throwing: CancellationError())
        }
    }

    private func configureBrowserCallbacks() {
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                isReady = true
                lastErrorMessage = nil
            case let .waiting(error):
                isReady = false
                lastErrorMessage = Self.message(for: error)
            case let .failed(error):
                finishUnavailable(message: Self.message(for: error))
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            services = Set(results.compactMap(Self.serviceRecord(from:)))
        }
    }

    private func completeAtDeadline() {
        queue.async { [self] in
            guard !isFinished else { return }
            if isReady {
                finish(status: .completed)
            } else {
                finish(status: .unavailable(
                    message: lastErrorMessage ?? "Bonjour browsing did not become ready before the check ended"
                ))
            }
        }
    }

    private func finishUnavailable(message: String) {
        finish(status: .unavailable(message: message))
    }

    private func finish(status: BonjourBrowseStatus) {
        guard !isFinished else { return }
        isFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        browser.cancel()
        let result = BonjourBrowseResult(
            serviceType: serviceType,
            services: services.sorted {
                if $0.name != $1.name {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.interfaceName ?? "" < $1.interfaceName ?? ""
            },
            status: status
        )
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }

    private static func serviceRecord(from result: NWBrowser.Result) -> BonjourServiceRecord? {
        guard case let .service(name, type, domain, interface) = result.endpoint else {
            return nil
        }
        return BonjourServiceRecord(
            name: name,
            type: type,
            domain: domain,
            interfaceName: interface?.name
        )
    }

    private static func message(for error: NWError) -> String {
        (error as NSError).localizedDescription
    }
}
