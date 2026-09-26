import Foundation
import GRDB
import Testing
@testable import PumpStore

private func fixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/v1.sqlite")
}

private func migratedFixture() throws -> (store: PumpStore, fileURL: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PumpStoreFixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let dbFile = directory.appendingPathComponent("pumplog.sqlite")
    try FileManager.default.copyItem(at: fixtureURL(), to: dbFile)
    return (try PumpStore.open(at: dbFile), dbFile)
}

private func schemaSignature(_ db: any DatabaseReader) throws -> [String: [String]] {
    try db.read { reader in
        let tables = ["vehicles", "fill_events", "service_events", "corrections"]
        return try tables.reduce(into: [String: [String]]()) { result, table in
            result[table] = try reader.columns(in: table).map(\.name)
        }
    }
}

@Suite("PumpStore migration + fixture")
struct MigrationTests {
    @Test("fixture upgrades to current migration version")
    func fixtureUpgrades() throws {
        let (store, fileURL) = try migratedFixture()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        #expect(try pumpStoreAppliedSchemaVersion(store.db) == PumpStoreSchema.currentVersion)
        #expect(PumpStoreSchema.currentVersion == 1)
    }

    @Test("fixture seeded rows are preserved and correction resolves")
    func fixtureRowsPreserved() throws {
        let (store, fileURL) = try migratedFixture()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let vehicles = try store.vehicles.allVehicles()
        #expect(vehicles.count == 1)
        let vehicle = try #require(vehicles.first)
        #expect(vehicle.nickname == "Fixture Wagon")

        let fills = try store.fills.events(vehicleID: vehicle.id)
        #expect(fills.count == 1)
        let fill = try #require(fills.first)
        #expect(fill.volumeDecimal == decimal("10.375"))
        #expect(fill.odometerDecimal == decimal("12345.67"))

        let service = try store.service.events(vehicleID: vehicle.id)
        #expect(service.count == 1)
        #expect(service.first?.category == "oil")

        let correctionHistory = try store.corrections.corrections(fillEventID: fill.id)
        #expect(correctionHistory.map(\.version) == [1])

        let resolved = try #require(try store.corrections.resolvedFillEvent(id: fill.id))
        #expect(resolved.odometerDecimal == decimal("12346.00"))
        #expect(resolved.note == "fixture corrected")
    }

    @Test("empty in-memory migration reaches same schema version as fixture")
    func inMemoryMatchesFixtureVersion() throws {
        let fresh = try PumpStore.inMemory()
        let (fixture, fileURL) = try migratedFixture()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let freshVersion = try pumpStoreAppliedSchemaVersion(fresh.db)
        let fixtureVersion = try pumpStoreAppliedSchemaVersion(fixture.db)
        #expect(freshVersion == fixtureVersion)
    }

    @Test("round-trip contract: empty database migrated to v1 matches fixture schema")
    func roundTripSchemaEquality() throws {
        let fresh = try PumpStore.inMemory()
        let (fixture, fileURL) = try migratedFixture()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let freshSignature = try schemaSignature(fresh.db)
        let fixtureSignature = try schemaSignature(fixture.db)
        #expect(freshSignature == fixtureSignature)
    }
}

private func decimal(_ value: String) -> Decimal {
    guard let result = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
        fatalError("invalid decimal fixture: \(value)")
    }
    return result
}
