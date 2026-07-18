import Foundation
import Testing
@testable import Lumina

struct AirPlayReceiverDiscoverabilityCheckerTests {
    @Test("The Mac's AirPlay screen service is reported as discoverable")
    func screenMirroringAdvertisement() async throws {
        let checker = makeChecker(results: [
            "_airplay._tcp": completed(
                "_airplay._tcp",
                services: [
                    service("Office Apple TV", type: "_airplay._tcp"),
                    service("Aeva’s MacBook Air", type: "_airplay._tcp")
                ]
            ),
            "_raop._tcp": completed(
                "_raop._tcp",
                services: [service("001122334455@Aevas-MacBook-Air", type: "_raop._tcp")]
            )
        ])

        let report = try await checker.check(timeout: .milliseconds(1))

        #expect(report.outcome == .screenMirroringAdvertised)
        #expect(report.isScreenMirroringAdvertised)
        #expect(report.macDisplayName == "Aeva’s MacBook Air")
        #expect(report.localHostName == "Aevas-MacBook-Air")
        #expect(report.matchingAirPlayServiceNames == ["Aeva’s MacBook Air"])
        #expect(report.matchingRAOPServiceNames == ["001122334455@Aevas-MacBook-Air"])
        #expect(report.airPlayServiceNames == ["Aeva’s MacBook Air", "Office Apple TV"])
        #expect(report.diagnostic.severity == .ready)
    }

    @Test("A matching RAOP service without AirPlay is diagnosed as audio only")
    func audioOnlyAdvertisement() async throws {
        let checker = makeChecker(results: [
            "_airplay._tcp": completed("_airplay._tcp"),
            "_raop._tcp": completed(
                "_raop._tcp",
                services: [service("AABBCCDDEEFF@Aevas-MacBook-Air", type: "_raop._tcp")]
            )
        ])

        let report = try await checker.check(timeout: .milliseconds(1))

        #expect(report.outcome == .audioOnly)
        #expect(!report.isScreenMirroringAdvertised)
        #expect(report.diagnostic.severity == .warning)
        #expect(report.diagnostic.title == "Only AirPlay audio is discoverable")
    }

    @Test("Unrelated receivers prove Bonjour works but do not match this Mac")
    func unrelatedReceivers() async throws {
        let checker = makeChecker(results: [
            "_airplay._tcp": completed(
                "_airplay._tcp",
                services: [service("Living Room Apple TV", type: "_airplay._tcp")]
            ),
            "_raop._tcp": completed("_raop._tcp")
        ])

        let report = try await checker.check(timeout: .milliseconds(1))

        #expect(report.outcome == .notAdvertised)
        #expect(report.airPlayServiceNames == ["Living Room Apple TV"])
        #expect(report.matchingAirPlayServiceNames.isEmpty)
        #expect(report.diagnostic.message.contains("Other screen-mirroring advertisements are visible"))
    }

    @Test("A failed screen-service browse returns an actionable unavailable report")
    func unavailableBrowse() async throws {
        let checker = makeChecker(results: [
            "_airplay._tcp": BonjourBrowseResult(
                serviceType: "_airplay._tcp",
                services: [],
                status: .unavailable(message: "The operation was not permitted")
            ),
            "_raop._tcp": completed("_raop._tcp")
        ])

        let report = try await checker.check(timeout: .milliseconds(1))

        #expect(report.outcome == .browsingUnavailable)
        #expect(report.diagnostic.severity == .error)
        #expect(report.diagnostic.message.contains("The operation was not permitted"))
        #expect(report.diagnostic.message.contains("Local Network permission"))
    }

    @Test("Service matching ignores punctuation, whitespace, and diacritics")
    func normalizedIdentityMatching() async throws {
        let checker = AirPlayReceiverDiscoverabilityChecker(
            browser: StubBonjourServiceBrowser(results: [
                "_airplay._tcp": completed(
                    "_airplay._tcp",
                    services: [service("Élodie’s MacBook-Pro", type: "_airplay._tcp")]
                ),
                "_raop._tcp": completed("_raop._tcp")
            ]),
            identityProvider: StubMacIdentityProvider(
                identity: MacAirPlayIdentity(
                    displayName: "Elodies MacBook Pro",
                    localHostName: "Elodies-MacBook-Pro"
                )
            )
        )

        let report = try await checker.check(timeout: .milliseconds(1))

        #expect(report.outcome == .screenMirroringAdvertised)
        #expect(report.matchingAirPlayServiceNames == ["Élodie’s MacBook-Pro"])
    }

    @Test("Bonjour conflict suffixes and trailing service-type dots still match this Mac")
    func bonjourConflictSuffixMatching() async throws {
        let checker = makeChecker(results: [
            "_airplay._tcp": completed(
                "_airplay._tcp",
                services: [service("Aeva’s MacBook Air (2)", type: "_airplay._tcp.")]
            ),
            "_raop._tcp": completed("_raop._tcp")
        ])

        let report = try await checker.check(timeout: .milliseconds(1))

        #expect(report.outcome == .screenMirroringAdvertised)
        #expect(report.matchingAirPlayServiceNames == ["Aeva’s MacBook Air (2)"])
    }

    private func makeChecker(
        results: [String: BonjourBrowseResult]
    ) -> AirPlayReceiverDiscoverabilityChecker {
        AirPlayReceiverDiscoverabilityChecker(
            browser: StubBonjourServiceBrowser(results: results),
            identityProvider: StubMacIdentityProvider(
                identity: MacAirPlayIdentity(
                    displayName: "Aeva’s MacBook Air",
                    localHostName: "Aevas-MacBook-Air"
                )
            )
        )
    }
}

private nonisolated struct StubMacIdentityProvider: MacAirPlayIdentityProviding {
    let identity: MacAirPlayIdentity

    func currentIdentity() -> MacAirPlayIdentity { identity }
}

private nonisolated struct StubBonjourServiceBrowser: BonjourServiceBrowsing {
    let results: [String: BonjourBrowseResult]

    func browse(serviceType: String, timeout: Duration) async throws -> BonjourBrowseResult {
        try Task.checkCancellation()
        guard let result = results[serviceType] else {
            return BonjourBrowseResult(
                serviceType: serviceType,
                services: [],
                status: .unavailable(message: "No stub result")
            )
        }
        return result
    }
}

private func completed(
    _ serviceType: String,
    services: [BonjourServiceRecord] = []
) -> BonjourBrowseResult {
    BonjourBrowseResult(serviceType: serviceType, services: services, status: .completed)
}

private func service(_ name: String, type: String) -> BonjourServiceRecord {
    BonjourServiceRecord(name: name, type: type, domain: "local.", interfaceName: "en0")
}
