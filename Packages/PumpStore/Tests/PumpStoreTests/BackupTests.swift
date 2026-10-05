import Foundation
import PumpStoreTestSupport
import Testing
@testable import PumpStore

@Suite("User-owned backup and deletion")
struct BackupTests {
    @Test("round trip retains originals, both ledgers, correction history and retirement")
    func roundTrip() throws {
        let source = try PumpStore.inMemory()
        let vehicle = Vehicle(nickname: "Wagon", createdAt: Date(timeIntervalSince1970: 1_700_000_000), retiredAt: nil)
        try source.vehicles.append(vehicle)
        let fill = FillEvent(vehicleID: vehicle.id, occurredAt: Date(timeIntervalSince1970: 1_700_000_100.25), odometerDecimal: Decimal(string: "123.25"), volumeDecimal: Decimal(string: "7.125")!, volumeUnit: .usGallon, costCents: 2015, pumpClassification: .full, note: "a,\"b\nnew line")
        try source.fills.append(fill)
        let service = ServiceEvent(vehicleID: vehicle.id, occurredAt: Date(timeIntervalSince1970: 1_700_000_200), odometerDecimal: nil, category: "Oil", costCents: 2500, intervalMileageDecimal: Decimal(3000), intervalDays: 90, intervalRuleText: "my rule", note: nil)
        try source.service.append(service)
        var corrected = fill
        corrected.volumeDecimal = Decimal(string: "8.250")!
        let first = try source.corrections.append(fillEventID: fill.id, corrected: corrected, correctedAt: Date(timeIntervalSince1970: 1_700_000_300))
        corrected.volumeDecimal = Decimal(string: "8.500")!
        _ = try source.corrections.append(fillEventID: fill.id, corrected: corrected, correctedAt: Date(timeIntervalSince1970: 1_700_000_400))
        var correctedService = service
        correctedService.category = "Tires"
        _ = try source.corrections.append(serviceEventID: service.id, corrected: correctedService, correctedAt: Date(timeIntervalSince1970: 1_700_000_500))
        let backup = try source.exportBackup()
        #expect(String(decoding: backup, as: UTF8.self).contains("pumplog-backup/1"))
        let preview = try source.previewBackup(backup)
        #expect(preview.vehicleCount == 1 && preview.fillCount == 1 && preview.serviceCount == 1 && preview.correctionCount == 3)
        #expect(preview.earliestDate == vehicle.createdAt && preview.latestDate == Date(timeIntervalSince1970: 1_700_000_500))
        let destination = try PumpStore.inMemory()
        try destination.vehicles.append(Vehicle(nickname: "replace me", createdAt: Date()))
        try destination.restoreBackup(backup)
        #expect(try destination.exportBackup() == backup)
        #expect(try destination.corrections.corrections(fillEventID: fill.id).first == first)
        #expect(try destination.corrections.resolvedFillEvent(id: fill.id) == corrected)
        #expect(try destination.corrections.resolvedServiceEvent(id: service.id) == correctedService)
    }

    @Test("rejects invalid schema or tampered correction without replacing current data")
    func invalidRestoreIsAtomic() throws {
        let store = try PumpStore.inMemory()
        try store.vehicles.append(Vehicle(nickname: "keep", createdAt: Date()))
        let original = try store.exportBackup()
        let incompatible = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "pumplog-backup/1", with: "pumplog-backup/2").utf8)
        #expect(throws: (any Error).self) { try store.restoreBackup(incompatible) }
        #expect(try store.exportBackup() == original)
    }

    @Test("tampered correction identity fails before replacement")
    func tamperedCorrection() throws {
        let store = try PumpStore.inMemory()
        let v = Vehicle(nickname: "keep", createdAt: Date(timeIntervalSince1970: 10))
        try store.vehicles.append(v)
        let fill = FillEvent(vehicleID: v.id, occurredAt: Date(timeIntervalSince1970: 20), odometerDecimal: Decimal(100), volumeDecimal: Decimal(2), volumeUnit: .usGallon, costCents: 400, pumpClassification: .full)
        try store.fills.append(fill)
        _ = try store.corrections.append(fillEventID: fill.id, corrected: fill, correctedAt: Date(timeIntervalSince1970: 30))
        let good = try store.exportBackup()
        var json = try #require(JSONSerialization.jsonObject(with: good) as? [String: Any])
        var corrections = try #require(json["corrections"] as? [[String: Any]])
        let payloadText = try #require(corrections[0]["correctedPayloadJSON"] as? String)
        var payload = try #require(JSONSerialization.jsonObject(with: Data(payloadText.utf8)) as? [String: Any])
        payload["vehicleID"] = UUID().uuidString
        corrections[0]["correctedPayloadJSON"] = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        json["corrections"] = corrections
        let bad = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: BackupError.self) { try store.restoreBackup(bad) }
        #expect(try store.exportBackup() == good)
    }

    @Test("CSV uses corrected values, RFC4180 quoting and stable ASCII decimals; deletion excludes data")
    func csvAndDeletion() throws {
        let store = try PumpStore.inMemory()
        let v = Vehicle(nickname: "A", createdAt: Date(timeIntervalSince1970: 0))
        try store.vehicles.append(v)
        let f = FillEvent(vehicleID: v.id, occurredAt: Date(timeIntervalSince1970: 10), odometerDecimal: Decimal(string: "12.5"), volumeDecimal: Decimal(string: "1.25")!, volumeUnit: .usGallon, costCents: 150, pumpClassification: .full, note: "hi,\"you\"\nnext")
        try store.fills.append(f)
        var corrected = f
        corrected.volumeDecimal = Decimal(string: "1.50")!
        _ = try store.corrections.append(fillEventID: f.id, corrected: corrected, correctedAt: Date(timeIntervalSince1970: 20))
        let service = ServiceEvent(vehicleID: v.id, occurredAt: Date(timeIntervalSince1970: 15), odometerDecimal: nil, category: "oil", costCents: 550, intervalMileageDecimal: nil, intervalDays: nil, intervalRuleText: nil)
        try store.service.append(service)
        let csv = try store.exportFillsCSV()
        #expect(csv.contains("1.5,us_gallon,150,full"))
        #expect(csv.contains("\"hi,\"\"you\"\"\nnext\""))
        #expect(try store.exportServiceCSV().contains("oil,550"))
        try store.deleteVehicle(id: v.id)
        #expect(try store.vehicles.allVehicles().isEmpty)
        #expect(try !store.exportFillsCSV().contains(f.id.uuidString))
        #expect(try !store.exportServiceCSV().contains(service.id.uuidString))
        #expect(try store.previewBackup(store.exportBackup()).correctionCount == 0)
        try store.vehicles.append(Vehicle(nickname: "B", createdAt: Date()))
        try store.wipeAll()
        #expect(try store.vehicles.allVehicles().isEmpty)
    }
}
