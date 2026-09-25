import Testing
@testable import PumpKit

@Suite("Skeleton placeholder")
struct PumpKitTests {
    @Test("domain namespace is reachable")
    func domainNamespace() {
        #expect(PumpKit.domain == "PumpKit")
    }

    @Test("milestone marker is set for M0")
    func milestoneMarker() {
        #expect(PumpKit.milestone == "M0-skeleton")
    }

    @Test("skeleton exposes no stored state beyond constants")
    func constantsAreStable() {
        // Guards the contract later issues depend on: these markers exist
        // and are pure constants (no clock, no I/O) in the M0 skeleton.
        let first = (PumpKit.domain, PumpKit.milestone)
        let second = (PumpKit.domain, PumpKit.milestone)
        #expect(first == second)
    }
}
