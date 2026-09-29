import Foundation
import Testing
@testable import PumpStore

@Suite("Issue 5 workflow")
struct QuickLogWorkflowTests {
    @Test func strictInputAndChronology() throws {
        let store = try PumpStore.inMemory()
        let flow = QuickLogWorkflow(store: store)
        let vehicle = try flow.addVehicle("Wagon")
        #expect(throws: QuickLogError.invalidNumber("total price")) { try QuickLogInput.priceCents("12.345") }
        #expect(throws: QuickLogError.invalidNumber("total price")) { try QuickLogInput.priceCents("12.3x") }
        #expect(throws: QuickLogError.invalidNumber("total price")) { try QuickLogInput.priceCents("999999999999999999999999999999.00") }
        #expect(throws: QuickLogError.invalidNumber("US gallons")) { try QuickLogInput.decimal("5x", field: "US gallons") }
        // Empty fields (unfilled decimal-pad form) must fail closed, not index-crash.
        #expect(throws: QuickLogError.invalidNumber("US gallons")) { try QuickLogInput.decimal("", field: "US gallons") }
        #expect(throws: QuickLogError.invalidNumber("total price")) { try QuickLogInput.priceCents("") }
        #expect(throws: QuickLogError.invalidNumber("total price")) { try QuickLogInput.priceCents("0") }
        #expect(throws: QuickLogError.invalidNumber("total price")) { try QuickLogInput.priceCents("12.") }
        #expect(try QuickLogInput.priceCents("12.30") == 1230)
        let first = try flow.logFill(vehicleID: vehicle.id, odometer: "100", volume: "5", price: "15.00", classification: .full)
        #expect(throws: QuickLogError.nonIncreasingOdometer) {
            try flow.logFill(vehicleID: vehicle.id, odometer: "100", volume: "5", price: "15", classification: .full)
        }
        #expect(throws: QuickLogError.largeOdometerDelta) {
            try flow.logFill(vehicleID: vehicle.id, odometer: "10101", volume: "5", price: "15", classification: .full)
        }
        let second = try flow.logFill(vehicleID: vehicle.id, odometer: "200", volume: "5", price: "15", classification: .full)
        #expect(try flow.economy(vehicleID: vehicle.id).intervals.first?.evidence.startFillID == first.id)
        #expect(try flow.economy(vehicleID: vehicle.id).intervals.first?.evidence.endFillID == second.id)
        #expect(try flow.economy(vehicleID: vehicle.id).intervals.first?.mpgUS == 20)
    }

    @Test func correctionsServiceRetireAndPersistence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let flow = QuickLogWorkflow(store: try PumpStore.open(at: url))
        let vehicle = try flow.addVehicle("Car")
        let a = try flow.logFill(vehicleID: vehicle.id, odometer: "100", volume: "5", price: "15", classification: .full)
        let b = try flow.logFill(vehicleID: vehicle.id, odometer: "200", volume: "5", price: "15", classification: .full)
        let c = try flow.logFill(vehicleID: vehicle.id, odometer: "300", volume: "5", price: "15", classification: .full)
        #expect(throws: QuickLogError.nonIncreasingOdometer) { try flow.correctFill(id: b.id, odometer: "301", volume: "5", price: "15", classification: .full) }
        try flow.correctFill(id: b.id, odometer: "150", volume: "10", price: "20", classification: .full)
        #expect(try flow.economy(vehicleID: vehicle.id).intervals.first?.mpgUS == 5)
        #expect(try flow.store.fills.event(id: b.id)?.odometerDecimal == 200)
        #expect(try flow.store.corrections.corrections(fillEventID: b.id).count == 1)
        let service = try flow.logService(vehicleID: vehicle.id, category: "Oil", price: "45.50")
        try flow.correctServiceCategory(id: service.id, category: "Transmission")
        #expect(try flow.store.corrections.resolvedServiceEvent(id: service.id)?.category == "Transmission")
        try flow.retireVehicle(id: vehicle.id)
        #expect(throws: QuickLogError.vehicleRetired) { try flow.logFill(vehicleID: vehicle.id, odometer: "400", volume: "5", price: "15", classification: .full) }
        #expect(throws: QuickLogError.vehicleRetired) { try flow.logService(vehicleID: vehicle.id, category: "Oil", price: "10") }
        #expect(throws: PumpStoreError.vehicleRetired(id: vehicle.id)) {
            try flow.store.fills.append(FillEvent(vehicleID: vehicle.id, occurredAt: Date(), odometerDecimal: 400, volumeDecimal: 5, volumeUnit: .usGallon, costCents: 1500, pumpClassification: .full))
        }
        let reopened = QuickLogWorkflow(store: try PumpStore.open(at: url))
        #expect(try reopened.store.vehicles.vehicle(id: vehicle.id)?.retiredAt != nil)
        #expect(try reopened.store.fills.event(id: a.id) != nil)
        #expect(try reopened.store.fills.event(id: c.id) != nil)
        #expect(try reopened.store.corrections.resolvedServiceEvent(id: service.id)?.category == "Transmission")
    }
}
