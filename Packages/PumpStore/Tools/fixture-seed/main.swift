import Foundation
import PumpStore

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: fixture-seed <output.sqlite>\n".utf8))
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])
try? FileManager.default.removeItem(at: outputURL)
let store = try PumpStore.open(at: outputURL)

func uuid(_ string: String) -> UUID {
    guard let result = UUID(uuidString: string) else { fatalError("bad UUID fixture") }
    return result
}

func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    guard let result = formatter.date(from: string) else { fatalError("bad date fixture") }
    return result
}

func decimal(_ string: String) -> Decimal {
    guard let result = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) else {
        fatalError("bad decimal fixture")
    }
    return result
}

let vehicleID = uuid("11111111-1111-1111-1111-111111111111")
let fillID = uuid("22222222-2222-2222-2222-222222222222")
let serviceID = uuid("33333333-3333-3333-3333-333333333333")

try store.vehicles.append(
    Vehicle(id: vehicleID, nickname: "Fixture Wagon", createdAt: date("2026-01-01T00:00:00Z"))
)
try store.fills.append(
    FillEvent(
        id: fillID,
        vehicleID: vehicleID,
        occurredAt: date("2026-01-02T08:00:00Z"),
        odometerDecimal: decimal("12345.67"),
        volumeDecimal: decimal("10.375"),
        volumeUnit: .usGallon,
        costCents: 4875,
        pumpClassification: .full,
        note: "fixture original"
    )
)
try store.service.append(
    ServiceEvent(
        id: serviceID,
        vehicleID: vehicleID,
        occurredAt: date("2026-01-03T09:00:00Z"),
        odometerDecimal: decimal("12400.12"),
        category: "oil",
        costCents: 6599,
        intervalMileageDecimal: decimal("5000"),
        intervalDays: 180,
        intervalRuleText: "every 5000 miles or 180 days",
        note: "fixture service"
    )
)
let correctedFill = FillEvent(
    id: fillID,
    vehicleID: vehicleID,
    occurredAt: date("2026-01-02T08:00:00Z"),
    odometerDecimal: decimal("12346.00"),
    volumeDecimal: decimal("10.375"),
    volumeUnit: .usGallon,
    costCents: 4875,
    pumpClassification: .full,
    note: "fixture corrected"
)
let correctionPayload = try PumpStoreCorrectionCodec.encode(correctedFill)
try store.db.write { db in
    try db.execute(
        sql: """
        INSERT INTO corrections (
            id, target_kind, fill_event_id, service_event_id, version,
            corrected_payload_json, corrected_at
        ) VALUES (?, 'fill_event', ?, NULL, 1, ?, ?)
        """,
        arguments: [
            uuid("44444444-4444-4444-4444-444444444444").uuidString,
            fillID.uuidString,
            correctionPayload,
            date("2026-01-04T00:00:00Z"),
        ]
    )
}

let applied = try pumpStoreAppliedSchemaVersion(store.db)
guard applied == 1 else {
    fatalError("fixture schema mismatch: \(applied)")
}
guard try store.vehicles.allVehicles().count == 1 else { fatalError("vehicle seed failed") }
guard try store.fills.events(vehicleID: vehicleID).count == 1 else { fatalError("fill seed failed") }
guard try store.service.events(vehicleID: vehicleID).count == 1 else { fatalError("service seed failed") }
guard try store.corrections.corrections(fillEventID: fillID).count == 1 else { fatalError("correction seed failed") }

print("Seeded PumpStore v1 fixture at \(outputURL.path)")
