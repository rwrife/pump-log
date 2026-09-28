import Foundation
import Testing
@testable import PumpKit

private func costDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    guard let result = formatter.date(from: value) else {
        fatalError("invalid date fixture: \(value)")
    }
    return result
}

private func costDecimal(_ value: String) -> Decimal {
    guard let result = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
        fatalError("invalid decimal fixture: \(value)")
    }
    return result
}

@Suite("Cost ledger engine")
struct CostLedgerEngineTests {
    @Test("sums cents by category and divides by confirmed miles with explicit coverage")
    func categoryTotalsAndCoverage() throws {
        let vehicleID = UUID()
        let window = CostWindow(
            start: costDate("2026-01-01T00:00:00Z"),
            end: costDate("2026-01-11T00:00:00Z")
        )
        let costs = [
            CostLedgerEntry(vehicleID: vehicleID, occurredAt: costDate("2026-01-01T00:00:00Z"), category: "fuel", costCents: 3_000),
            CostLedgerEntry(vehicleID: vehicleID, occurredAt: costDate("2026-01-04T00:00:00Z"), category: "service", costCents: 2_000),
            CostLedgerEntry(vehicleID: vehicleID, occurredAt: costDate("2026-01-12T00:00:00Z"), category: "outside", costCents: 99_999),
        ]
        let mileage = [
            ConfirmedMileageInterval(
                vehicleID: vehicleID,
                start: costDate("2026-01-02T00:00:00Z"),
                end: costDate("2026-01-07T00:00:00Z"),
                miles: costDecimal("100")
            ),
        ]

        let result = try CostLedgerEngine.derive(
            vehicleID: vehicleID,
            window: window,
            costs: costs,
            mileage: mileage
        )

        #expect(result.categoryTotalsCents == ["fuel": 3_000, "service": 2_000])
        #expect(result.totalCostCents == 5_000)
        #expect(result.confirmedMiles == costDecimal("100"))
        #expect(result.coveragePercent == costDecimal("50"))
        let centsPerMile = try #require(result.costPerMile.centsPerMile)
        #expect(centsPerMile == costDecimal("50"))
    }

    @Test(
        "zero or unknown mileage denominator stays unknown",
        arguments: [
            ([ConfirmedMileageInterval](), costDecimal("0")),
            ([ConfirmedMileageInterval(
                vehicleID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                start: costDate("2026-01-02T00:00:00Z"),
                end: costDate("2026-01-03T00:00:00Z"),
                miles: .zero
            )], costDecimal("0")),
        ]
    )
    func unknownDenominator(mileage: [ConfirmedMileageInterval], expectedCoveragePercent: Decimal) throws {
        let vehicleID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let result = try CostLedgerEngine.derive(
            vehicleID: vehicleID,
            window: CostWindow(
                start: costDate("2026-01-01T00:00:00Z"),
                end: costDate("2026-01-11T00:00:00Z")
            ),
            costs: [
                CostLedgerEntry(vehicleID: vehicleID, occurredAt: costDate("2026-01-05T00:00:00Z"), category: "fuel", costCents: 4_000),
            ],
            mileage: mileage
        )

        #expect(result.costPerMile == .unknown(reason: .noOdometerConfirmedMiles))
        // Zero-mile intervals are not odometer-confirmed mileage and do not
        // contribute to coverage or denominator.
        #expect(result.coveragePercent == expectedCoveragePercent)
    }

    @Test("never prorates mileage intervals that cross the requested window")
    func crossingMileageIsExcluded() throws {
        let vehicleID = UUID()
        let result = try CostLedgerEngine.derive(
            vehicleID: vehicleID,
            window: CostWindow(
                start: costDate("2026-01-05T00:00:00Z"),
                end: costDate("2026-01-10T00:00:00Z")
            ),
            costs: [],
            mileage: [
                ConfirmedMileageInterval(
                    vehicleID: vehicleID,
                    start: costDate("2026-01-01T00:00:00Z"),
                    end: costDate("2026-01-07T00:00:00Z"),
                    miles: costDecimal("200")
                ),
            ]
        )

        #expect(result.confirmedMiles == .zero)
        #expect(result.costPerMile == .unknown(reason: .noOdometerConfirmedMiles))
    }

    @Test("overlapping mileage intervals fail closed instead of double-counting")
    func overlappingMileageFailsClosed() throws {
        let vehicleID = UUID()
        let result = try CostLedgerEngine.derive(
            vehicleID: vehicleID,
            window: CostWindow(
                start: costDate("2026-01-01T00:00:00Z"),
                end: costDate("2026-01-11T00:00:00Z")
            ),
            costs: [
                CostLedgerEntry(vehicleID: vehicleID, occurredAt: costDate("2026-01-02T00:00:00Z"), category: "fuel", costCents: 1_000),
            ],
            mileage: [
                ConfirmedMileageInterval(vehicleID: vehicleID, start: costDate("2026-01-01T00:00:00Z"), end: costDate("2026-01-06T00:00:00Z"), miles: costDecimal("100")),
                ConfirmedMileageInterval(vehicleID: vehicleID, start: costDate("2026-01-04T00:00:00Z"), end: costDate("2026-01-09T00:00:00Z"), miles: costDecimal("120")),
            ]
        )

        #expect(result.confirmedMiles == .zero)
        #expect(result.coveragePercent == .zero)
        #expect(result.costPerMile == .unknown(reason: .overlappingMileageIntervals))
    }

    @Test("integer-cent overflow returns an explicit error instead of trapping")
    func centsOverflowThrows() {
        let vehicleID = UUID()
        #expect(throws: CostLedgerDerivationError.centsOverflow) {
            try CostLedgerEngine.derive(
                vehicleID: vehicleID,
                window: CostWindow(
                    start: costDate("2026-01-01T00:00:00Z"),
                    end: costDate("2026-01-11T00:00:00Z")
                ),
                costs: [
                    CostLedgerEntry(vehicleID: vehicleID, occurredAt: costDate("2026-01-02T00:00:00Z"), category: "fuel", costCents: Int.max),
                    CostLedgerEntry(vehicleID: vehicleID, occurredAt: costDate("2026-01-03T00:00:00Z"), category: "fuel", costCents: 1),
                ],
                mileage: []
            )
        }
    }

    @Test("cost windows are half-open so adjacent windows do not double-count boundary events")
    func halfOpenWindowBoundary() throws {
        let vehicleID = UUID()
        let boundary = costDate("2026-01-11T00:00:00Z")
        let entry = CostLedgerEntry(vehicleID: vehicleID, occurredAt: boundary, category: "fuel", costCents: 1_000)
        let first = try CostLedgerEngine.derive(
            vehicleID: vehicleID,
            window: CostWindow(start: costDate("2026-01-01T00:00:00Z"), end: boundary),
            costs: [entry],
            mileage: []
        )
        let second = try CostLedgerEngine.derive(
            vehicleID: vehicleID,
            window: CostWindow(start: boundary, end: costDate("2026-01-21T00:00:00Z")),
            costs: [entry],
            mileage: []
        )
        #expect(first.totalCostCents == 0)
        #expect(second.totalCostCents == 1_000)
    }
}

private let serviceSuiteVehicleID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

@Suite("Service due-window engine")
struct ServiceDueWindowEngineTests {
    struct Case: CustomTestStringConvertible {
        let name: String
        let rule: ServiceIntervalRule
        let anchor: ServiceIntervalAnchor
        let currentOdometer: Decimal?
        let now: Date
        let expected: ServiceDueState

        var testDescription: String { name }
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    @Test(
        "table-driven due boundaries",
        arguments: [
            Case(
                name: "exactly due by mileage",
                rule: ServiceIntervalRule(
                    category: "user category",
                    ruleText: "My own 5,000 mile rule",
                    mileageInterval: costDecimal("5000"),
                    dayInterval: nil,
                    approachingMileage: nil,
                    approachingDays: nil
                ),
                anchor: ServiceIntervalAnchor(
                    vehicleID: serviceSuiteVehicleID,
                    occurredAt: costDate("2026-01-01T08:00:00Z"),
                    odometer: costDecimal("10000")
                ),
                currentOdometer: costDecimal("15000"),
                now: costDate("2026-01-02T08:00:00Z"),
                expected: .dueWindowOpen
            ),
            Case(
                name: "missing odometer anchor",
                rule: ServiceIntervalRule(
                    category: "user category",
                    ruleText: "Mileage only",
                    mileageInterval: costDecimal("3000"),
                    dayInterval: nil,
                    approachingMileage: nil,
                    approachingDays: nil
                ),
                anchor: ServiceIntervalAnchor(
                    vehicleID: serviceSuiteVehicleID,
                    occurredAt: costDate("2026-01-01T08:00:00Z"),
                    odometer: nil
                ),
                currentOdometer: costDecimal("12000"),
                now: costDate("2026-01-02T08:00:00Z"),
                expected: .unknown
            ),
            Case(
                name: "day-only rule before due date",
                rule: ServiceIntervalRule(
                    category: "user category",
                    ruleText: "Every 30 calendar days",
                    mileageInterval: nil,
                    dayInterval: 30,
                    approachingMileage: nil,
                    approachingDays: nil
                ),
                anchor: ServiceIntervalAnchor(
                    vehicleID: serviceSuiteVehicleID,
                    occurredAt: costDate("2026-01-01T08:00:00Z"),
                    odometer: nil
                ),
                currentOdometer: nil,
                now: costDate("2026-01-30T08:00:00Z"),
                expected: .ok
            ),
            Case(
                name: "mileage-only rule in user-defined approaching range",
                rule: ServiceIntervalRule(
                    category: "user category",
                    ruleText: "Tell me 500 miles early",
                    mileageInterval: costDecimal("5000"),
                    dayInterval: nil,
                    approachingMileage: costDecimal("500"),
                    approachingDays: nil
                ),
                anchor: ServiceIntervalAnchor(
                    vehicleID: serviceSuiteVehicleID,
                    occurredAt: costDate("2026-01-01T08:00:00Z"),
                    odometer: costDecimal("10000")
                ),
                currentOdometer: costDecimal("14600"),
                now: costDate("2026-01-02T08:00:00Z"),
                expected: .approaching
            ),
        ]
    )
    func boundaries(testCase: Case) {
        let result = ServiceDueWindowEngine.derive(
            rule: testCase.rule,
            vehicleID: serviceSuiteVehicleID,
            anchor: testCase.anchor,
            currentOdometer: testCase.currentOdometer,
            now: testCase.now,
            calendar: Self.utc
        )

        #expect(result.state == testCase.expected)
        #expect(result.ruleText == testCase.rule.ruleText)
    }

    @Test("day interval uses calendar-day addition across daylight-saving transition")
    func dstSafeDayMath() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let anchorDate = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 7,
            hour: 12
        )))
        let expectedDueDate = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 8,
            hour: 12
        )))
        let rule = ServiceIntervalRule(
            category: "user category",
            ruleText: "One calendar day",
            mileageInterval: nil,
            dayInterval: 1,
            approachingMileage: nil,
            approachingDays: nil
        )

        let result = ServiceDueWindowEngine.derive(
            rule: rule,
            vehicleID: serviceSuiteVehicleID,
            anchor: ServiceIntervalAnchor(vehicleID: serviceSuiteVehicleID, occurredAt: anchorDate, odometer: nil),
            currentOdometer: nil,
            now: expectedDueDate,
            calendar: calendar
        )

        #expect(result.dueDate == expectedDueDate)
        #expect(result.state == .dueWindowOpen)
        #expect(expectedDueDate.timeIntervalSince(anchorDate) == 23 * 60 * 60)
    }

    @Test("latest matching event becomes the anchor while other categories and vehicles are ignored")
    func latestMatchingAnchor() throws {
        let vehicleID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let otherVehicleID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let rule = ServiceIntervalRule(
            category: "My custom category",
            ruleText: "Echo EXACTLY: every 1000",
            mileageInterval: costDecimal("1000"),
            dayInterval: nil,
            approachingMileage: nil,
            approachingDays: nil
        )
        let events = [
            UserServiceEvent(vehicleID: vehicleID, category: "My custom category", occurredAt: costDate("2026-01-01T00:00:00Z"), odometer: costDecimal("10000")),
            UserServiceEvent(vehicleID: otherVehicleID, category: "My custom category", occurredAt: costDate("2026-04-01T00:00:00Z"), odometer: costDecimal("99000")),
            UserServiceEvent(vehicleID: vehicleID, category: "Different category", occurredAt: costDate("2026-02-01T00:00:00Z"), odometer: costDecimal("50000")),
            UserServiceEvent(vehicleID: vehicleID, category: "My custom category", occurredAt: costDate("2026-03-01T00:00:00Z"), odometer: costDecimal("12000")),
        ]

        let result = ServiceDueWindowEngine.derive(
            rule: rule,
            vehicleID: vehicleID,
            serviceEvents: events,
            currentOdometer: costDecimal("13000"),
            now: costDate("2026-03-02T00:00:00Z"),
            calendar: Self.utc
        )

        #expect(result.state == .dueWindowOpen)
        #expect(result.anchor?.odometer == costDecimal("12000"))
        #expect(result.ruleText == "Echo EXACTLY: every 1000")
    }

    @Test("non-positive intervals and odometer rollback render unknown")
    func invalidServiceInputsStayUnknown() {
        let nonPositiveRule = ServiceIntervalRule(
            category: "oil",
            ruleText: "Bad rule",
            mileageInterval: costDecimal("-100"),
            dayInterval: 0
        )
        let anchor = ServiceIntervalAnchor(
            vehicleID: serviceSuiteVehicleID,
            occurredAt: costDate("2026-01-01T00:00:00Z"),
            odometer: costDecimal("10000")
        )
        let nonPositiveResult = ServiceDueWindowEngine.derive(
            rule: nonPositiveRule,
            vehicleID: serviceSuiteVehicleID,
            anchor: anchor,
            currentOdometer: costDecimal("10500"),
            now: costDate("2026-01-02T00:00:00Z"),
            calendar: Self.utc
        )
        #expect(nonPositiveResult.state == .unknown)

        let validRule = ServiceIntervalRule(
            category: "oil",
            ruleText: "Valid rule",
            mileageInterval: costDecimal("5000"),
            dayInterval: nil
        )
        let rollbackResult = ServiceDueWindowEngine.derive(
            rule: validRule,
            vehicleID: serviceSuiteVehicleID,
            anchor: anchor,
            currentOdometer: costDecimal("9000"), // rolled back relative to anchor 10000
            now: costDate("2026-01-02T00:00:00Z"),
            calendar: Self.utc
        )
        #expect(rollbackResult.state == .unknown)
    }

    @Test("an invalid mileage component cannot be masked by a due day component")
    func invalidMileageFailsClosedEvenWhenDayIsDue() {
        let rule = ServiceIntervalRule(
            category: "oil",
            ruleText: "Invalid mileage, overdue days",
            mileageInterval: costDecimal("-100"),
            dayInterval: 1
        )
        let anchor = ServiceIntervalAnchor(
            vehicleID: serviceSuiteVehicleID,
            occurredAt: costDate("2026-01-01T00:00:00Z"),
            odometer: costDecimal("10000")
        )
        let result = ServiceDueWindowEngine.derive(
            rule: rule,
            vehicleID: serviceSuiteVehicleID,
            anchor: anchor,
            currentOdometer: costDecimal("10500"),
            now: costDate("2026-01-05T00:00:00Z"), // day window is long overdue
            calendar: Self.utc
        )
        #expect(result.state == .unknown)
    }

    @Test("an anchor from a different vehicle renders unknown")
    func foreignAnchorFailsClosed() {
        let rule = ServiceIntervalRule(
            category: "oil",
            ruleText: "Valid rule",
            mileageInterval: costDecimal("5000"),
            dayInterval: nil
        )
        let foreignAnchor = ServiceIntervalAnchor(
            vehicleID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            occurredAt: costDate("2026-01-01T00:00:00Z"),
            odometer: costDecimal("10000")
        )
        let result = ServiceDueWindowEngine.derive(
            rule: rule,
            vehicleID: serviceSuiteVehicleID,
            anchor: foreignAnchor,
            currentOdometer: costDecimal("20000"),
            now: costDate("2026-01-02T00:00:00Z"),
            calendar: Self.utc
        )
        #expect(result.state == .unknown)
        #expect(result.anchor == nil)
    }

    @Test("a zero-duration interval with positive miles is not confirmed mileage")
    func zeroDurationMileageExcluded() throws {
        let vehicleID = UUID()
        let result = try CostLedgerEngine.derive(
            vehicleID: vehicleID,
            window: CostWindow(
                start: costDate("2026-01-01T00:00:00Z"),
                end: costDate("2026-01-11T00:00:00Z")
            ),
            costs: [
                CostLedgerEntry(vehicleID: vehicleID, occurredAt: costDate("2026-01-02T00:00:00Z"), category: "fuel", costCents: 1_000),
            ],
            mileage: [
                ConfirmedMileageInterval(
                    vehicleID: vehicleID,
                    start: costDate("2026-01-05T00:00:00Z"),
                    end: costDate("2026-01-05T00:00:00Z"),
                    miles: costDecimal("50")
                ),
            ]
        )
        #expect(result.confirmedMiles == .zero)
        #expect(result.coveragePercent == .zero)
        #expect(result.costPerMile == .unknown(reason: .noOdometerConfirmedMiles))
    }
}

private extension CostPerMileMeasurement {
    var centsPerMile: Decimal? {
        guard case let .known(value) = self else { return nil }
        return value
    }
}
