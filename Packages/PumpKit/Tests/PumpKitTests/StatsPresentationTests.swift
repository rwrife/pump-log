import Foundation
import Testing
@testable import PumpKit

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

@Suite("Stats presentation — honesty doctrine")
struct StatsPresentationTests {
    @Test("decimal renders at most two fraction digits with a POSIX point")
    func decimalFormatting() {
        #expect(StatsPresentation.decimalString(decimal("20")) == "20")
        #expect(StatsPresentation.decimalString(decimal("20.5")) == "20.5")
        #expect(StatsPresentation.decimalString(decimal("20.25")) == "20.25")
        // Rounding is presentation-only; underlying Decimal is untouched.
        #expect(StatsPresentation.decimalString(decimal("20.333333")) == "20.33")
    }

    @Test("percent states coverage in text")
    func percentFormatting() {
        #expect(StatsPresentation.percentString(decimal("42.857")) == "42.86% coverage")
        #expect(StatsPresentation.percentString(decimal("0")) == "0% coverage")
        #expect(StatsPresentation.percentString(decimal("100")) == "100% coverage")
    }

    @Test("currency from cents")
    func currencyFormatting() {
        #expect(StatsPresentation.dollarsString(cents: 4875) == "$48.75")
        #expect(StatsPresentation.dollarsString(cents: 1500) == "$15.00")
    }

    @Test("every exclusion reason has a named label")
    func exclusionLabels() {
        for reason in EconomyExclusionReason.allCases {
            #expect(StatsPresentation.exclusionReasonLabel(reason).hasPrefix("excluded:"))
            #expect(StatsPresentation.exclusionReasonLabel(reason).count > "excluded:".count)
        }
    }

    @Test("point series label carries evidence")
    func pointLabel() {
        let interval = EconomyInterval(
            evidence: EconomyIntervalEvidence(
                startFillID: UUID(),
                endFillID: UUID(),
                gallonsUsed: decimal("12"),
                milesTravelled: decimal("300")
            ),
            mpgUS: decimal("25"),
            mpgImperial: decimal("30"),
            litresPer100km: decimal("9.43")
        )
        #expect(StatsPresentation.economyPointLabel(interval) == "25 MPG (US) · evidence: 300 miles ÷ 12 US gallons")
    }

    @Test("rolling windows state sample counts, unknowns stay unknown")
    func rollingWindowLabels() {
        let filled = RollingEconomyWindow(
            pairWindow: 3,
            sampleCount: 2,
            totalMiles: decimal("500"),
            totalGallonsUS: decimal("25"),
            measurement: .known(mpgUS: decimal("20"), mpgImperial: decimal("24"), litresPer100km: decimal("11.76"))
        )
        #expect(StatsPresentation.rollingWindowLabel(filled) == "Last 3 fills: 20 MPG (US) · 24 MPG (imp) · 11.76 L/100km · 2 samples")

        let empty = RollingEconomyWindow.empty(window: 5)
        #expect(StatsPresentation.rollingWindowLabel(empty) == "Last 5 fills: unknown (insufficient-valid-full-fill-evidence, 0 samples)")

        let zeroSampleUnknown = RollingEconomyWindow(
            pairWindow: 10,
            sampleCount: 4,
            totalMiles: decimal("400"),
            totalGallonsUS: .zero,
            measurement: .unknown
        )
        #expect(StatsPresentation.rollingWindowLabel(zeroSampleUnknown) == "Last 10 fills: unknown (insufficient-valid-full-fill-evidence, 4 samples)")
    }

    @Test("series with no intervals renders the honest unknown")
    func seriesUnknown() {
        let derivation = EconomyDerivation(
            intervals: [],
            exclusions: [],
            rolling3: .empty(window: 3),
            rolling5: .empty(window: 5),
            rolling10: .empty(window: 10)
        )
        #expect(StatsPresentation.economySeriesLabel(derivation).contains("insufficient-valid-full-fill-evidence"))
    }

    @Test("cost/mile states coverage in text for known and unknown")
    func costPerMileLabels() {
        let window = CostWindow(start: date("2026-01-01T00:00:00Z"), end: date("2026-02-01T00:00:00Z"))
        let known = CostDerivation(
            window: window,
            categoryTotalsCents: ["Fuel": 30_000, "Oil": 4_550],
            totalCostCents: 34_550,
            confirmedMiles: decimal("1000"),
            coveragePercent: decimal("50"),
            costPerMile: .known(centsPerMile: decimal("34.55"))
        )
        #expect(StatsPresentation.costPerMileLabel(known) == "34.55 cents per confirmed mile · 50% coverage")

        let unknown = CostDerivation(
            window: window,
            categoryTotalsCents: ["Fuel": 30_000],
            totalCostCents: 30_000,
            confirmedMiles: .zero,
            coveragePercent: .zero,
            costPerMile: .unknown(reason: .noOdometerConfirmedMiles)
        )
        #expect(StatsPresentation.costPerMileLabel(unknown) == "cost/mile unknown (no-odometer-confirmed-miles) · 0% coverage")

        let overlapping = CostDerivation(
            window: window,
            categoryTotalsCents: ["Fuel": 30_000],
            totalCostCents: 30_000,
            confirmedMiles: .zero,
            coveragePercent: .zero,
            costPerMile: .unknown(reason: .overlappingMileageIntervals)
        )
        #expect(StatsPresentation.costPerMileLabel(overlapping).contains("overlapping-mileage-intervals"))
    }

    @Test("category totals label")
    func categoryTotalLabel() {
        #expect(StatsPresentation.categoryTotalLabel(category: "Oil", cents: 4550) == "Oil: $45.50")
    }

    @Test("service due labels never fabricate unknown rules")
    func serviceDueLabels() {
        let unknown = ServiceDueDerivation(
            ruleText: "every 5000 miles",
            category: "Oil",
            state: .unknown,
            anchor: nil,
            dueMileage: nil,
            dueDate: nil,
            remainingMiles: nil,
            remainingDays: nil
        )
        #expect(StatsPresentation.serviceDueLabel(unknown).contains("unknown"))
        #expect(StatsPresentation.serviceDueLabel(unknown).contains("every 5000 miles"))

        let ok = ServiceDueDerivation(
            ruleText: "every 5000 miles",
            category: "Oil",
            state: .ok,
            anchor: ServiceIntervalAnchor(vehicleID: UUID(), occurredAt: date("2026-01-01T00:00:00Z"), odometer: decimal("10000")),
            dueMileage: decimal("15000"),
            dueDate: nil,
            remainingMiles: decimal("1500"),
            remainingDays: nil
        )
        let label = StatsPresentation.serviceDueLabel(ok)
        #expect(label.contains("not due"))
        #expect(label.contains("1500 miles remaining"))
        #expect(label.contains("2026-01-01"))
    }

    @Test("due-window-open renders unsigned magnitudes for due axes only")
    func serviceDueOpenLabels() {
        let overdue = ServiceDueDerivation(
            ruleText: "every 5000 miles or every 180 days",
            category: "Oil",
            state: .dueWindowOpen,
            anchor: nil,
            dueMileage: decimal("15000"),
            dueDate: nil,
            remainingMiles: decimal("-500"),
            remainingDays: 20 // day axis NOT due — must not read "past due"
        )
        let label = StatsPresentation.serviceDueLabel(overdue)
        #expect(label.contains("due window open"))
        #expect(label.contains("past due by 500 miles"))
        #expect(!label.contains("-500"))
        #expect(!label.contains("past due by 20 days"))
    }

    @Test("date formatting is UTC stable")
    func dateFormatting() {
        #expect(StatsPresentation.formattedDate(date("2026-01-05T09:30:00Z")) == "2026-01-05")
        let window = CostWindow(start: date("2026-01-01T00:00:00Z"), end: date("2026-02-01T00:00:00Z"))
        #expect(StatsPresentation.windowLabel(window) == "2026-01-01 → 2026-02-01")
    }
}
