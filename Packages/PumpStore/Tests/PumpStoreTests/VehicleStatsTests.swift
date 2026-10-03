import Foundation
import PumpKit
import Testing
@testable import PumpStore

@Suite("Issue 6 vehicle stats")
struct VehicleStatsTests {
    @Test("economy + cost + coverage from honest ledgers")
    func statsFromLedgers() throws {
        let store = try PumpStore.inMemory()
        let flow = QuickLogWorkflow(store: store)
        let vehicle = try flow.addVehicle("Wagon")
        let vehicleID = vehicle.id
        // Explicit timestamps keep the half-open cost window and mileage
        // interval deterministic (flow.logFill stamps Date() internally).
        try store.fills.append(FillEvent(
            vehicleID: vehicleID,
            occurredAt: date("2026-01-02T08:00:00Z"),
            odometerDecimal: decimal("100"),
            volumeDecimal: decimal("5"),
            volumeUnit: .usGallon,
            costCents: 1_500,
            pumpClassification: .full
        ))
        try store.fills.append(FillEvent(
            vehicleID: vehicleID,
            occurredAt: date("2026-01-09T08:00:00Z"),
            odometerDecimal: decimal("200"),
            volumeDecimal: decimal("5"),
            volumeUnit: .usGallon,
            costCents: 1_500,
            pumpClassification: .full
        ))
        try store.service.append(ServiceEvent(
            vehicleID: vehicleID,
            occurredAt: date("2026-01-10T09:00:00Z"),
            odometerDecimal: nil,
            category: "Oil",
            costCents: 4_550,
            intervalMileageDecimal: nil,
            intervalDays: nil,
            intervalRuleText: nil
        ))

        let stats = try flow.vehicleStats(vehicleID: vehicleID)
        #expect(stats.economy.intervals.count == 1)
        let cost = try #require(stats.cost)
        #expect(cost.categoryTotalsCents[QuickLogWorkflow.fuelCategory] == 3_000)
        #expect(cost.categoryTotalsCents["Oil"] == 4_550)
        #expect(cost.totalCostCents == 7_550)
        #expect(cost.confirmedMiles == 100)
        if case let .known(centsPerMile) = cost.costPerMile {
            #expect(centsPerMile == 75.5)
        } else {
            Issue.record("expected known cost/mile with confirmed mileage evidence")
        }
        // Coverage stated explicitly: mileage evidence spans 168h of the
        // 217h half-open window (Jan 2 08:00 → Jan 11 09:00 = 77.42%).
        #expect(cost.coveragePercent > decimal("77") && cost.coveragePercent < decimal("78"))
        #expect(StatsPresentation.costPerMileLabel(cost) == "75.5 cents per confirmed mile · 77.42% coverage")
    }

    @Test("zero-mileage vehicle stays unknown with named reason")
    func unknownCostMile() throws {
        let store = try PumpStore.inMemory()
        let flow = QuickLogWorkflow(store: store)
        let vehicle = try flow.addVehicle("Truck")
        _ = try flow.logService(vehicleID: vehicle.id, category: "Tires", price: "200")

        let stats = try flow.vehicleStats(vehicleID: vehicle.id)
        let cost = try #require(stats.cost)
        #expect(cost.confirmedMiles == 0)
        #expect(cost.costPerMile == .unknown(reason: .noOdometerConfirmedMiles))
        #expect(StatsPresentation.costPerMileLabel(cost).contains("no-odometer-confirmed-miles"))
        #expect(StatsPresentation.costPerMileLabel(cost).contains("0% coverage"))
    }

    @Test("empty vehicle has no cost derivation and empty economy")
    func emptyVehicle() throws {
        let store = try PumpStore.inMemory()
        let flow = QuickLogWorkflow(store: store)
        let vehicle = try flow.addVehicle("Spare")
        let stats = try flow.vehicleStats(vehicleID: vehicle.id)
        #expect(stats.cost == nil)
        #expect(stats.economy.intervals.isEmpty)
        #expect(stats.economy.rolling3.sampleCount == 0)
        #expect(stats.serviceDue.isEmpty)
    }

    @Test("corrections feed stats without mutating originals")
    func correctionsFeedStats() throws {
        let store = try PumpStore.inMemory()
        let flow = QuickLogWorkflow(store: store)
        let vehicle = try flow.addVehicle("Wagon")
        let first = FillEvent(
            vehicleID: vehicle.id,
            occurredAt: date("2026-01-02T08:00:00Z"),
            odometerDecimal: decimal("100"),
            volumeDecimal: decimal("5"),
            volumeUnit: .usGallon,
            costCents: 1_500,
            pumpClassification: .full
        )
        let second = FillEvent(
            vehicleID: vehicle.id,
            occurredAt: date("2026-01-09T08:00:00Z"),
            odometerDecimal: decimal("200"),
            volumeDecimal: decimal("5"),
            volumeUnit: .usGallon,
            costCents: 1_500,
            pumpClassification: .full
        )
        try store.fills.append(first)
        try store.fills.append(second)
        try flow.correctFill(id: second.id, odometer: "150", volume: "5", price: "15", classification: .full)

        let stats = try flow.vehicleStats(vehicleID: vehicle.id)
        #expect(stats.economy.intervals.count == 1)
        #expect(stats.economy.intervals.first?.mpgUS == 10)
        let cost = try #require(stats.cost)
        #expect(cost.confirmedMiles == 50)
        // Original row untouched: raw store still shows odometer 200.
        let original = try #require(try store.fills.event(id: second.id))
        #expect(original.odometerDecimal == 200)
    }

    @Test("service due windows only surface user-owned rules")
    func serviceDueRules() throws {
        let store = try PumpStore.inMemory()
        let flow = QuickLogWorkflow(store: store)
        let vehicle = try flow.addVehicle("Wagon")

        // A plain service without interval data must NOT gain a due-window row.
        _ = try flow.logService(vehicleID: vehicle.id, category: "Wash", price: "10")
        var stats = try flow.vehicleStats(vehicleID: vehicle.id)
        #expect(stats.serviceDue.isEmpty)

        // A user-owned rule on the same category surfaces it — and only it.
        let ruled = ServiceEvent(
            vehicleID: vehicle.id,
            occurredAt: Date(timeIntervalSince1970: 1_767_225_600), // 2026-01-01
            odometerDecimal: decimal("10000"),
            category: "Oil",
            costCents: 4_550,
            intervalMileageDecimal: decimal("5000"),
            intervalDays: nil,
            intervalRuleText: "every 5000 miles (owner's notebook)"
        )
        try store.service.append(ruled)
        _ = try flow.logFill(vehicleID: vehicle.id, odometer: "11000", volume: "10", price: "30", classification: .full)

        stats = try flow.vehicleStats(vehicleID: vehicle.id)
        #expect(stats.serviceDue.count == 1)
        let due = try #require(stats.serviceDue.first)
        #expect(due.category == "Oil")
        // User rule text echoes verbatim — no invented schedule.
        #expect(due.ruleText == "every 5000 miles (owner's notebook)")
        #expect(due.state == .ok)
        #expect(due.remainingMiles == 4000)
        #expect(StatsPresentation.serviceDueLabel(due).contains("every 5000 miles (owner's notebook)"))

        // And the rule-less category still has no row.
        #expect(!stats.serviceDue.contains { $0.category == "Wash" })
    }

    @Test("rule text fallback restates only user-entered numbers")
    func ruleTextFallback() throws {
        let event = ServiceEvent(
            vehicleID: UUID(),
            occurredAt: Date(),
            odometerDecimal: nil,
            category: "Filter",
            costCents: 1_000,
            intervalMileageDecimal: decimal("3000"),
            intervalDays: 180,
            intervalRuleText: "  "
        )
        #expect(QuickLogWorkflow.serviceRuleText(for: event) == "every 3000 miles or every 180 days")
    }

    @Test("fill dates are indexed for point labels")
    func fillDateIndex() throws {
        let store = try PumpStore.inMemory()
        let flow = QuickLogWorkflow(store: store)
        let vehicle = try flow.addVehicle("Wagon")
        let first = try flow.logFill(vehicleID: vehicle.id, odometer: "100", volume: "5", price: "15", classification: .full)
        let stats = try flow.vehicleStats(vehicleID: vehicle.id)
        // Stats re-reads from the ledger, so compare against the persisted row
        // (SQLite round-trips dates at sub-second precision).
        let persisted = try #require(try store.fills.event(id: first.id))
        #expect(stats.fillDatesByID[first.id] == persisted.occurredAt)
    }
}

private func decimal(_ value: String) -> Decimal {
    guard let result = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
        fatalError("invalid decimal fixture: \(value)")
    }
    return result
}

private func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    guard let result = formatter.date(from: value) else {
        fatalError("invalid date fixture: \(value)")
    }
    return result
}
