import Foundation
import GRDB
import PumpStoreTestSupport
import Testing
@testable import PumpStore

@Suite("PumpStore repositories")
struct RepositoryTests {
    @Test("stores decimal fields losslessly and keeps cents exact")
    func storesDecimalsAndCents() throws {
        let store = try PumpStore.inMemory()
        let vehicleID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        try store.vehicles.append(Vehicle(id: vehicleID, nickname: "Wagon", createdAt: date("2026-01-01T00:00:00Z")))

        let fillID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let fill = FillEvent(
            id: fillID,
            vehicleID: vehicleID,
            occurredAt: date("2026-01-02T08:00:00Z"),
            odometerDecimal: decimal("12345.67"),
            volumeDecimal: decimal("10.375"),
            volumeUnit: .usGallon,
            costCents: 4875,
            pumpClassification: .full,
            note: "pump 4"
        )
        try store.fills.append(fill)
        let loadedFill = try #require(try store.fills.event(id: fillID))
        #expect(loadedFill == fill)

        let serviceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let service = ServiceEvent(
            id: serviceID,
            vehicleID: vehicleID,
            occurredAt: date("2026-01-05T09:30:00Z"),
            odometerDecimal: decimal("12400.12"),
            category: "oil",
            costCents: 6599,
            intervalMileageDecimal: decimal("5000"),
            intervalDays: 180,
            intervalRuleText: "every 5000 miles or 180 days",
            note: "synthetic"
        )
        try store.service.append(service)
        let loadedService = try #require(try store.service.event(id: serviceID))
        #expect(loadedService == service)
    }

    @Test("append rejects child rows when vehicle parent is missing")
    func parentMissingIsRejected() throws {
        let store = try PumpStore.inMemory()
        let ghost = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

        #expect(throws: PumpStoreError.parentNotFound(table: "vehicles", id: ghost)) {
            try store.fills.append(
                FillEvent(
                    id: UUID(),
                    vehicleID: ghost,
                    occurredAt: date("2026-01-02T08:00:00Z"),
                    odometerDecimal: decimal("100"),
                    volumeDecimal: decimal("10"),
                    volumeUnit: .litre,
                    costCents: 1000,
                    pumpClassification: .partial
                )
            )
        }

        #expect(throws: PumpStoreError.parentNotFound(table: "vehicles", id: ghost)) {
            try store.service.append(
                ServiceEvent(
                    id: UUID(),
                    vehicleID: ghost,
                    occurredAt: date("2026-01-02T08:00:00Z"),
                    odometerDecimal: nil,
                    category: "tires",
                    costCents: 4200,
                    intervalMileageDecimal: nil,
                    intervalDays: nil,
                    intervalRuleText: nil
                )
            )
        }
    }

    @Test("vehicle delete cascades fill/service/correction rows")
    func cascadeDeleteRemovesChildren() throws {
        let store = try PumpStore.inMemory()
        let vehicleID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        try store.vehicles.append(Vehicle(id: vehicleID, nickname: "Sedan", createdAt: date("2026-01-01T00:00:00Z")))

        let fill = FillEvent(
            id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
            vehicleID: vehicleID,
            occurredAt: date("2026-01-03T08:00:00Z"),
            odometerDecimal: decimal("20000"),
            volumeDecimal: decimal("8.25"),
            volumeUnit: .usGallon,
            costCents: 3500,
            pumpClassification: .full
        )
        try store.fills.append(fill)
        _ = try store.corrections.append(
            fillEventID: fill.id,
            corrected: FillEvent(
                id: fill.id,
                vehicleID: fill.vehicleID,
                occurredAt: fill.occurredAt,
                odometerDecimal: fill.odometerDecimal,
                volumeDecimal: decimal("8.5"),
                volumeUnit: fill.volumeUnit,
                costCents: fill.costCents,
                pumpClassification: fill.pumpClassification
            ),
            correctedAt: date("2026-01-04T00:00:00Z")
        )

        let service = ServiceEvent(
            id: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            vehicleID: vehicleID,
            occurredAt: date("2026-01-06T08:00:00Z"),
            odometerDecimal: decimal("20100"),
            category: "wash",
            costCents: 1299,
            intervalMileageDecimal: nil,
            intervalDays: nil,
            intervalRuleText: nil
        )
        try store.service.append(service)

        try store.db.write { db in
            try db.execute(sql: "DELETE FROM vehicles WHERE id = ?", arguments: [vehicleID.uuidString])
        }

        #expect(try store.fills.events(vehicleID: vehicleID).isEmpty)
        #expect(try store.service.events(vehicleID: vehicleID).isEmpty)
        #expect(try store.corrections.corrections(fillEventID: fill.id).isEmpty)
        #expect(try store.corrections.resolvedFillEvent(id: fill.id) == nil)
    }

    @Test("corrections are versioned and latest payload resolves")
    func correctionVersioningAndResolution() throws {
        let store = try PumpStore.inMemory()
        let vehicleID = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        try store.vehicles.append(Vehicle(id: vehicleID, nickname: "Truck", createdAt: date("2026-01-01T00:00:00Z")))

        let fill = FillEvent(
            id: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
            vehicleID: vehicleID,
            occurredAt: date("2026-01-02T08:00:00Z"),
            odometerDecimal: decimal("11000"),
            volumeDecimal: decimal("12.000"),
            volumeUnit: .usGallon,
            costCents: 5200,
            pumpClassification: .full,
            note: "initial"
        )
        try store.fills.append(fill)

        let v1 = try store.corrections.append(
            fillEventID: fill.id,
            corrected: FillEvent(
                id: fill.id,
                vehicleID: vehicleID,
                occurredAt: fill.occurredAt,
                odometerDecimal: decimal("11001.0"),
                volumeDecimal: fill.volumeDecimal,
                volumeUnit: fill.volumeUnit,
                costCents: fill.costCents,
                pumpClassification: fill.pumpClassification,
                note: "odometer fix"
            ),
            correctedAt: date("2026-01-03T00:00:00Z")
        )
        let v2 = try store.corrections.append(
            fillEventID: fill.id,
            corrected: FillEvent(
                id: fill.id,
                vehicleID: vehicleID,
                occurredAt: fill.occurredAt,
                odometerDecimal: decimal("11001.0"),
                volumeDecimal: decimal("12.125"),
                volumeUnit: fill.volumeUnit,
                costCents: fill.costCents,
                pumpClassification: fill.pumpClassification,
                note: "volume fix"
            ),
            correctedAt: date("2026-01-04T00:00:00Z")
        )

        #expect(v1.version == 1)
        #expect(v2.version == 2)
        let history = try store.corrections.corrections(fillEventID: fill.id)
        #expect(history.map(\.version) == [1, 2])

        let resolved = try #require(try store.corrections.resolvedFillEvent(id: fill.id))
        #expect(resolved.volumeDecimal == decimal("12.125"))
        #expect(resolved.note == "volume fix")
    }

    @Test("resolved event fails closed on corrupt correction payload")
    func corruptCorrectionPayloadFailsClosed() throws {
        let store = try PumpStore.inMemory()
        let vehicleID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        try store.vehicles.append(Vehicle(id: vehicleID, nickname: "Hatch", createdAt: date("2026-01-01T00:00:00Z")))
        let fillID = UUID(uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa")!
        try store.fills.append(
            FillEvent(
                id: fillID,
                vehicleID: vehicleID,
                occurredAt: date("2026-01-02T08:00:00Z"),
                odometerDecimal: decimal("7000"),
                volumeDecimal: decimal("7.5"),
                volumeUnit: .litre,
                costCents: 2999,
                pumpClassification: .partial
            )
        )

        try store.db.write { db in
            try db.execute(
                sql: """
                INSERT INTO corrections (
                    id, target_kind, fill_event_id, service_event_id, version,
                    corrected_payload_json, corrected_at
                ) VALUES (?, 'fill_event', ?, NULL, 1, '{broken', ?)
                """,
                arguments: [UUID().uuidString, fillID.uuidString, date("2026-01-03T00:00:00Z")]
            )
        }

        var caught: PumpStoreError?
        do {
            _ = try store.corrections.resolvedFillEvent(id: fillID)
        } catch let error as PumpStoreError {
            caught = error
        }
        switch caught {
        case .correctionPayloadCorrupt(let table, let id, _):
            #expect(table == "fill_events")
            #expect(id == fillID)
        case .none:
            Issue.record("expected correctionPayloadCorrupt, got no error")
        case let .some(other):
            Issue.record("expected correctionPayloadCorrupt, got \(other)")
        }
    }

    @Test("in-memory fakes match GRDB correction semantics")
    func inMemoryFakesMatchGRDB() throws {
        let vehicleID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        let fillID = UUID(uuidString: "34343434-3434-3434-3434-343434343434")!
        let original = FillEvent(
            id: fillID,
            vehicleID: vehicleID,
            occurredAt: date("2026-02-01T10:00:00Z"),
            odometerDecimal: decimal("9000"),
            volumeDecimal: decimal("9.5"),
            volumeUnit: .usGallon,
            costCents: 4500,
            pumpClassification: .full,
            note: "orig"
        )
        let corrected = FillEvent(
            id: fillID,
            vehicleID: vehicleID,
            occurredAt: original.occurredAt,
            odometerDecimal: decimal("9001"),
            volumeDecimal: decimal("9.75"),
            volumeUnit: original.volumeUnit,
            costCents: original.costCents,
            pumpClassification: original.pumpClassification,
            note: "corrected"
        )

        let store = try PumpStore.inMemory()
        try store.vehicles.append(Vehicle(id: vehicleID, nickname: "A", createdAt: date("2026-01-01T00:00:00Z")))
        try store.fills.append(original)
        let grdbV1 = try store.corrections.append(fillEventID: fillID, corrected: corrected, correctedAt: date("2026-02-02T00:00:00Z"))
        let grdbResolved = try #require(try store.corrections.resolvedFillEvent(id: fillID))

        let memory = InMemoryRepositories()
        try memory.vehicles.append(Vehicle(id: vehicleID, nickname: "A", createdAt: date("2026-01-01T00:00:00Z")))
        memory.fills.registerVehicle(vehicleID)
        try memory.fills.append(original)
        let memV1 = try memory.corrections.append(fillEventID: fillID, corrected: corrected, correctedAt: date("2026-02-02T00:00:00Z"))
        let memResolved = try #require(try memory.corrections.resolvedFillEvent(id: fillID))

        #expect(grdbV1.version == memV1.version)
        #expect(grdbResolved == memResolved)
        #expect(memResolved.note == "corrected")
    }
}

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
