import Testing
@testable import PumpKit
import Foundation

private func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    guard let result = formatter.date(from: value) else {
        fatalError("invalid date fixture: \(value)")
    }
    return result
}

private func decimal(_ value: String) -> Decimal {
    guard let result = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
        fatalError("invalid decimal fixture: \(value)")
    }
    return result
}

private func fill(
    vehicleID: UUID,
    at time: String,
    odometer: String?,
    volume: String,
    unit: PumpVolumeUnit = .usGallon,
    classification: PumpClassification
) -> FuelFillEvent {
    FuelFillEvent(
        vehicleID: vehicleID,
        occurredAt: date(time),
        odometer: odometer.map(decimal),
        volume: decimal(volume),
        volumeUnit: unit,
        classification: classification
    )
}

@Suite("PumpKit namespace")
struct PumpKitTests {
    @Test("domain namespace is reachable")
    func domainNamespace() {
        #expect(PumpKit.domain == "PumpKit")
    }

    @Test("milestone marker reflects the stats screens milestone")
    func milestoneMarker() {
        #expect(PumpKit.milestone == "M5-stats-screens")
    }
}

@Suite("Economy engine — full-to-full pairs")
struct EconomyEnginePairTests {
    @Test("two consecutive full fills with increasing odometer form one interval")
    func simplePair() {
        let vehicleID = UUID()
        let first = fill(vehicleID: vehicleID, at: "2026-01-01T08:00:00Z", odometer: "10000", volume: "10", classification: .full)
        let second = fill(vehicleID: vehicleID, at: "2026-01-08T08:00:00Z", odometer: "10300", volume: "12", classification: .full)

        let derivation = EconomyEngine.derive(from: [first, second])

        #expect(derivation.intervals.count == 1)
        let interval = try! #require(derivation.intervals.first)
        #expect(interval.evidence.startFillID == first.id)
        #expect(interval.evidence.endFillID == second.id)
        #expect(interval.evidence.milesTravelled == decimal("300"))
        #expect(interval.evidence.gallonsUsed == decimal("12"))
        #expect(interval.mpgUS == decimal("25"))
        #expect(derivation.exclusions.isEmpty)
    }

    @Test("three full fills produce two chained intervals")
    func chainedPairs() {
        let vehicleID = UUID()
        let a = fill(vehicleID: vehicleID, at: "2026-01-01T08:00:00Z", odometer: "1000", volume: "10", classification: .full)
        let b = fill(vehicleID: vehicleID, at: "2026-01-08T08:00:00Z", odometer: "1300", volume: "10", classification: .full)
        let c = fill(vehicleID: vehicleID, at: "2026-01-15T08:00:00Z", odometer: "1620", volume: "12", classification: .full)

        let derivation = EconomyEngine.derive(from: [a, b, c])

        #expect(derivation.intervals.count == 2)
        #expect(derivation.intervals[0].evidence.startFillID == a.id)
        #expect(derivation.intervals[0].evidence.endFillID == b.id)
        #expect(derivation.intervals[1].evidence.startFillID == b.id)
        #expect(derivation.intervals[1].evidence.endFillID == c.id)
    }
}

@Suite("Economy engine — named exclusion reasons")
struct EconomyEngineExclusionTests {
    @Test("a topoff fill produces a topoff exclusion and breaks the pairing chain")
    func topoffExclusion() {
        let vehicleID = UUID()
        let a = fill(vehicleID: vehicleID, at: "2026-01-01T08:00:00Z", odometer: "1000", volume: "10", classification: .full)
        let topoff = fill(vehicleID: vehicleID, at: "2026-01-03T08:00:00Z", odometer: "1100", volume: "2", classification: .topoff)
        let b = fill(vehicleID: vehicleID, at: "2026-01-08T08:00:00Z", odometer: "1300", volume: "10", classification: .full)

        let derivation = EconomyEngine.derive(from: [a, topoff, b])

        #expect(derivation.exclusions == [
            EconomyExclusion(fillID: topoff.id, vehicleID: vehicleID, reason: .topoff),
        ])
        // The topoff fill breaks the a→b chain: no interval spans across it.
        #expect(derivation.intervals.isEmpty)
    }

    @Test("a partial fill produces a partial exclusion and breaks the pairing chain")
    func partialExclusion() {
        let vehicleID = UUID()
        let a = fill(vehicleID: vehicleID, at: "2026-01-01T08:00:00Z", odometer: "1000", volume: "10", classification: .full)
        let partial = fill(vehicleID: vehicleID, at: "2026-01-03T08:00:00Z", odometer: "1100", volume: "3", classification: .partial)
        let b = fill(vehicleID: vehicleID, at: "2026-01-08T08:00:00Z", odometer: "1300", volume: "10", classification: .full)

        let derivation = EconomyEngine.derive(from: [a, partial, b])

        #expect(derivation.exclusions == [
            EconomyExclusion(fillID: partial.id, vehicleID: vehicleID, reason: .partial),
        ])
        #expect(derivation.intervals.isEmpty)
    }

    @Test("an unknown-classification fill is excluded with the partial reason and breaks pairing")
    func unknownClassificationExclusion() {
        let vehicleID = UUID()
        let a = fill(vehicleID: vehicleID, at: "2026-01-01T08:00:00Z", odometer: "1000", volume: "10", classification: .full)
        let unknownFill = fill(vehicleID: vehicleID, at: "2026-01-03T08:00:00Z", odometer: "1100", volume: "3", classification: .unknown)
        let b = fill(vehicleID: vehicleID, at: "2026-01-08T08:00:00Z", odometer: "1300", volume: "10", classification: .full)

        let derivation = EconomyEngine.derive(from: [a, unknownFill, b])

        #expect(derivation.exclusions == [
            EconomyExclusion(fillID: unknownFill.id, vehicleID: vehicleID, reason: .partial),
        ])
        #expect(derivation.intervals.isEmpty)
    }

    @Test("a full fill with a missing odometer produces an odometer-missing exclusion")
    func odometerMissingExclusion() {
        let vehicleID = UUID()
        let a = fill(vehicleID: vehicleID, at: "2026-01-01T08:00:00Z", odometer: "1000", volume: "10", classification: .full)
        let missing = fill(vehicleID: vehicleID, at: "2026-01-08T08:00:00Z", odometer: nil, volume: "10", classification: .full)
        let c = fill(vehicleID: vehicleID, at: "2026-01-15T08:00:00Z", odometer: "1600", volume: "10", classification: .full)

        let derivation = EconomyEngine.derive(from: [a, missing, c])

        #expect(derivation.exclusions == [
            EconomyExclusion(fillID: missing.id, vehicleID: vehicleID, reason: .odometerMissing),
        ])
        // The chain restarts fresh at c; a→c is not paired because the anchor was dropped.
        #expect(derivation.intervals.isEmpty)
    }

    @Test("a non-increasing odometer produces an odometer-nonincreasing exclusion")
    func odometerNonincreasingExclusion() {
        let vehicleID = UUID()
        let a = fill(vehicleID: vehicleID, at: "2026-01-01T08:00:00Z", odometer: "1000", volume: "10", classification: .full)
        let rollback = fill(vehicleID: vehicleID, at: "2026-01-08T08:00:00Z", odometer: "999", volume: "10", classification: .full)

        let derivation = EconomyEngine.derive(from: [a, rollback])

        #expect(derivation.exclusions == [
            EconomyExclusion(fillID: rollback.id, vehicleID: vehicleID, reason: .odometerNonincreasing),
        ])
        #expect(derivation.intervals.isEmpty)
    }

    @Test("an equal (non-increasing) odometer also produces the odometer-nonincreasing exclusion")
    func odometerEqualIsNonincreasing() {
        let vehicleID = UUID()
        let a = fill(vehicleID: vehicleID, at: "2026-01-01T08:00:00Z", odometer: "1000", volume: "10", classification: .full)
        let same = fill(vehicleID: vehicleID, at: "2026-01-08T08:00:00Z", odometer: "1000", volume: "10", classification: .full)

        let derivation = EconomyEngine.derive(from: [a, same])

        #expect(derivation.exclusions == [
            EconomyExclusion(fillID: same.id, vehicleID: vehicleID, reason: .odometerNonincreasing),
        ])
    }

    @Test("a fill for a different vehicle produces a vehicle-boundary exclusion")
    func vehicleBoundaryExclusion() {
        let vehicleA = UUID()
        let vehicleB = UUID()
        let a1 = fill(vehicleID: vehicleA, at: "2026-01-01T08:00:00Z", odometer: "1000", volume: "10", classification: .full)
        let b1 = fill(vehicleID: vehicleB, at: "2026-01-02T08:00:00Z", odometer: "500", volume: "8", classification: .full)
        let b2 = fill(vehicleID: vehicleB, at: "2026-01-09T08:00:00Z", odometer: "800", volume: "9", classification: .full)

        let derivation = EconomyEngine.derive(from: [a1, b1, b2])

        #expect(derivation.exclusions == [
            EconomyExclusion(fillID: b1.id, vehicleID: vehicleB, reason: .vehicleBoundary),
        ])
        // b1 becomes the new anchor for vehicle B; b1→b2 is a valid interval.
        #expect(derivation.intervals.count == 1)
        #expect(derivation.intervals[0].evidence.startFillID == b1.id)
        #expect(derivation.intervals[0].evidence.endFillID == b2.id)
    }
}

@Suite("Economy engine — rolling windows")
struct EconomyEngineRollingWindowTests {
    private func chain(vehicleID: UUID, odometers: [String], startDate: String = "2026-01-01T08:00:00Z") -> [FuelFillEvent] {
        var results: [FuelFillEvent] = []
        let base = date(startDate)
        for (index, odometer) in odometers.enumerated() {
            let occurred = base.addingTimeInterval(TimeInterval(index * 7 * 24 * 3600))
            let formatter = ISO8601DateFormatter()
            results.append(
                fill(
                    vehicleID: vehicleID,
                    at: formatter.string(from: occurred),
                    odometer: odometer,
                    volume: "10",
                    classification: .full
                )
            )
        }
        return results
    }

    @Test("zero valid pairs renders unknown for every rolling window — the derivation-unknown canary")
    func zeroPairsIsUnknown() {
        let vehicleID = UUID()
        let onlyFill = fill(vehicleID: vehicleID, at: "2026-01-01T08:00:00Z", odometer: "1000", volume: "10", classification: .full)

        let derivation = EconomyEngine.derive(from: [onlyFill])

        #expect(derivation.rolling3.sampleCount == 0)
        #expect(derivation.rolling3.measurement == .unknown)
        #expect(derivation.rolling5.measurement == .unknown)
        #expect(derivation.rolling10.measurement == .unknown)
    }

    @Test("a ledger with a hole (missing odometer) still renders unknown — no number leaks through")
    func ledgerWithHoleStaysUnknown() {
        let vehicleID = UUID()
        let a = fill(vehicleID: vehicleID, at: "2026-01-01T08:00:00Z", odometer: "1000", volume: "10", classification: .full)
        let hole = fill(vehicleID: vehicleID, at: "2026-01-08T08:00:00Z", odometer: nil, volume: "10", classification: .full)

        let derivation = EconomyEngine.derive(from: [a, hole])

        #expect(derivation.intervals.isEmpty)
        #expect(derivation.rolling3.measurement == .unknown)
        #expect(derivation.rolling5.measurement == .unknown)
        #expect(derivation.rolling10.measurement == .unknown)
    }

    @Test("rolling window of 3 reports sample count and aggregate measurement from the most recent pairs")
    func rollingWindowReportsSampleCount() {
        let vehicleID = UUID()
        // 5 fills => 4 valid pairs.
        let odometers = ["0", "300", "620", "960", "1320"]
        let events = chain(vehicleID: vehicleID, odometers: odometers)

        let derivation = EconomyEngine.derive(from: events)

        #expect(derivation.intervals.count == 4)
        #expect(derivation.rolling3.sampleCount == 3)
        #expect(derivation.rolling5.sampleCount == 4)
        #expect(derivation.rolling10.sampleCount == 4)

        if case .unknown = derivation.rolling3.measurement {
            Issue.record("expected a known rolling-3 measurement with 4 available pairs")
        }
    }
}

@Suite("Economy engine — unit conversion")
struct EconomyEngineUnitConversionTests {
    @Test("litre-denominated fills convert exactly to US-gallon MPG")
    func litreConversion() {
        let vehicleID = UUID()
        let a = fill(vehicleID: vehicleID, at: "2026-01-01T08:00:00Z", odometer: "0", volume: "40", unit: .litre, classification: .full)
        let b = fill(vehicleID: vehicleID, at: "2026-01-08T08:00:00Z", odometer: "300", volume: "37.85411784", unit: .litre, classification: .full)

        let derivation = EconomyEngine.derive(from: [a, b])

        let interval = try! #require(derivation.intervals.first)
        // 37.85411784 L == exactly 10 US gallons.
        #expect(interval.evidence.gallonsUsed == decimal("10"))
        #expect(interval.mpgUS == decimal("30"))
    }

    @Test("imperial-gallon fills convert to a smaller US-gallon-equivalent volume")
    func imperialGallonConversion() {
        let vehicleID = UUID()
        let a = fill(vehicleID: vehicleID, at: "2026-01-01T08:00:00Z", odometer: "0", volume: "10", unit: .imperialGallon, classification: .full)
        let b = fill(vehicleID: vehicleID, at: "2026-01-08T08:00:00Z", odometer: "300", volume: "10", unit: .imperialGallon, classification: .full)

        let derivation = EconomyEngine.derive(from: [a, b])

        let interval = try! #require(derivation.intervals.first)
        // 10 imperial gallons > 10 US gallons, so US-gallon-equivalent volume is larger than 10.
        #expect(interval.evidence.gallonsUsed > decimal("10"))
        // mpgImperial (miles per imperial gallon) should be exactly 30 (300 miles / 10 imp gal).
        #expect(interval.mpgImperial == decimal("30"))
    }
}
