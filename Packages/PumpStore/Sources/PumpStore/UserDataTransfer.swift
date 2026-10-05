import Foundation
import GRDB

// Keep decimal fields as their stored ASCII strings rather than JSON numbers.
// Corrections carry their original payload JSON verbatim for evidence fidelity.

private struct UserBackup: Codable {
    let schema: String
    let vehicles: [Vehicle]
    let fills: [FillEventPayload]
    let services: [ServiceEventPayload]
    let corrections: [CorrectionRecord]
}

public struct BackupPreview: Sendable {
    public let vehicleCount: Int
    public let fillCount: Int
    public let serviceCount: Int
    public let correctionCount: Int
    public let earliestDate: Date?
    public let latestDate: Date?
}

public enum BackupError: Error, LocalizedError, Sendable {
    case unsupportedSchema
    case invalidEvidence
    case vehicleMissing

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "Unsupported Pump Log backup version. Your data was not changed."
        case .invalidEvidence: "Backup contains invalid or mismatched evidence. Your data was not changed."
        case .vehicleMissing: "Vehicle was not found. Your data was not changed."
        }
    }
}

private func encoder() -> JSONEncoder {
    let coder = JSONEncoder()
    coder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // SQLite/GRDB stores Date with sub-second resolution. ISO8601's default
    // whole seconds silently discard that evidence on an export/restore.
    coder.dateEncodingStrategy = .deferredToDate
    return coder
}

private func decodeBackup(_ data: Data) throws -> UserBackup {
    let value = try JSONDecoder().decode(UserBackup.self, from: data)
    guard value.schema == "pumplog-backup/1" else { throw BackupError.unsupportedSchema }
    let vehicleIDs = Set(value.vehicles.map(\.id))
    let fillIDs = Set(value.fills.map(\.id))
    let serviceIDs = Set(value.services.map(\.id))
    guard vehicleIDs.count == value.vehicles.count,
          fillIDs.count == value.fills.count,
          serviceIDs.count == value.services.count,
          Set(value.corrections.map(\.id)).count == value.corrections.count,
          value.fills.allSatisfy({ vehicleIDs.contains($0.vehicleID) }),
          value.services.allSatisfy({ vehicleIDs.contains($0.vehicleID) }) else { throw BackupError.invalidEvidence }
    let fills = Dictionary(uniqueKeysWithValues: value.fills.map { ($0.id, $0) })
    let services = Dictionary(uniqueKeysWithValues: value.services.map { ($0.id, $0) })
    var versions: [String: Int] = [:]
    for record in value.corrections {
        guard record.version > 0 else { throw BackupError.invalidEvidence }
        switch record.targetKind {
        case .fillEvent:
            guard let id = record.fillEventID, record.serviceEventID == nil, let original = fills[id],
                  let corrected = try? PumpStoreCorrectionCodec.decodeFillEvent(record.correctedPayloadJSON),
                  corrected.id == id, corrected.vehicleID == original.vehicleID,
                  floor(corrected.occurredAt.timeIntervalSince1970) == floor(original.occurredAt.timeIntervalSince1970) else { throw BackupError.invalidEvidence }
            let key = "f\(id)"
            guard record.version == (versions[key] ?? 0) + 1 else { throw BackupError.invalidEvidence }
            versions[key] = record.version
        case .serviceEvent:
            guard let id = record.serviceEventID, record.fillEventID == nil, let original = services[id],
                  let corrected = try? PumpStoreCorrectionCodec.decodeServiceEvent(record.correctedPayloadJSON),
                  corrected.id == id, corrected.vehicleID == original.vehicleID,
                  floor(corrected.occurredAt.timeIntervalSince1970) == floor(original.occurredAt.timeIntervalSince1970) else { throw BackupError.invalidEvidence }
            let key = "s\(id)"
            guard record.version == (versions[key] ?? 0) + 1 else { throw BackupError.invalidEvidence }
            versions[key] = record.version
        }
    }
    // Validate numeric fields before deleting anything.
    for row in value.fills { _ = try row.toFillEvent() }
    for row in value.services { _ = try row.toServiceEvent() }
    return value
}

private func csv(_ fields: [String]) -> String {
    fields.map { value in
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }.joined(separator: ",") + "\r\n"
}

extension PumpStore {
    public func exportBackup() throws -> Data {
        // One GRDB snapshot: no interleaved write can split a backup.
        try db.read { reader in
            let vehicleRows = try Row.fetchAll(reader, sql: "SELECT * FROM vehicles ORDER BY created_at, id")
            let vehicles = vehicleRows.map { row in
                Vehicle(id: UUID(uuidString: row["id"])!, nickname: row["nickname"], createdAt: row["created_at"], retiredAt: row["retired_at"])
            }
            let fills = try Row.fetchAll(reader, sql: "SELECT * FROM fill_events ORDER BY occurred_at, id").map { (row: Row) throws -> FillEventPayload in
                let odometer: String? = row["odometer_decimal"]
                let volume: String = row["volume_decimal"]
                return FillEventPayload(event: FillEvent(id: UUID(uuidString: row["id"])!, vehicleID: UUID(uuidString: row["vehicle_id"])!, occurredAt: row["occurred_at"], odometerDecimal: try odometer.map { try PumpStoreDecimalCodec.decode($0, field: "odometer_decimal") }, volumeDecimal: try PumpStoreDecimalCodec.decode(volume, field: "volume_decimal"), volumeUnit: PumpVolumeUnit(rawValue: row["volume_unit"])!, costCents: row["cost_cents"], pumpClassification: PumpClassification(rawValue: row["pump_classification"])!, note: row["note"]))
            }
            let services = try Row.fetchAll(reader, sql: "SELECT * FROM service_events ORDER BY occurred_at, id").map { (row: Row) throws -> ServiceEventPayload in
                let odometer: String? = row["odometer_decimal"]
                let mileage: String? = row["interval_mileage_decimal"]
                return ServiceEventPayload(event: ServiceEvent(id: UUID(uuidString: row["id"])!, vehicleID: UUID(uuidString: row["vehicle_id"])!, occurredAt: row["occurred_at"], odometerDecimal: try odometer.map { try PumpStoreDecimalCodec.decode($0, field: "odometer_decimal") }, category: row["category"], costCents: row["cost_cents"], intervalMileageDecimal: try mileage.map { try PumpStoreDecimalCodec.decode($0, field: "interval_mileage_decimal") }, intervalDays: row["interval_days"], intervalRuleText: row["interval_rule_text"], note: row["note"]))
            }
            let corrections = try Row.fetchAll(reader, sql: "SELECT * FROM corrections ORDER BY target_kind, COALESCE(fill_event_id, service_event_id), version").map { (row: Row) in
                CorrectionRecord(id: UUID(uuidString: row["id"])!, targetKind: CorrectionTargetKind(rawValue: row["target_kind"])!, fillEventID: (row["fill_event_id"] as String?).flatMap(UUID.init(uuidString:)), serviceEventID: (row["service_event_id"] as String?).flatMap(UUID.init(uuidString:)), version: row["version"], correctedPayloadJSON: row["corrected_payload_json"], correctedAt: row["corrected_at"])
            }
            return try encoder().encode(UserBackup(schema: "pumplog-backup/1", vehicles: vehicles, fills: fills, services: services, corrections: corrections))
        }
    }

    public func previewBackup(_ data: Data) throws -> BackupPreview {
        let backup = try decodeBackup(data)
        let dates = backup.vehicles.map(\.createdAt) + backup.vehicles.compactMap(\.retiredAt)
            + backup.fills.map(\.occurredAt) + backup.services.map(\.occurredAt)
            + backup.corrections.map(\.correctedAt)
        return BackupPreview(vehicleCount: backup.vehicles.count, fillCount: backup.fills.count,
                             serviceCount: backup.services.count, correctionCount: backup.corrections.count,
                             earliestDate: dates.min(), latestDate: dates.max())
    }

    public func restoreBackup(_ data: Data) throws {
        let backup = try decodeBackup(data)
        try db.write { writer in
            try writer.execute(sql: "DELETE FROM vehicles") // cascade both ledgers + corrections
            for row in backup.vehicles {
                try writer.execute(sql: "INSERT INTO vehicles (id, nickname, created_at, retired_at) VALUES (?, ?, ?, ?)", arguments: [row.id.uuidString, row.nickname, row.createdAt, row.retiredAt])
            }
            for row in backup.fills {
                try writer.execute(sql: "INSERT INTO fill_events (id, vehicle_id, occurred_at, odometer_decimal, volume_decimal, volume_unit, cost_cents, pump_classification, note) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [row.id.uuidString, row.vehicleID.uuidString, row.occurredAt, row.odometerDecimal, row.volumeDecimal, row.volumeUnit.rawValue, row.costCents, row.pumpClassification.rawValue, row.note])
            }
            for row in backup.services {
                try writer.execute(sql: "INSERT INTO service_events (id, vehicle_id, occurred_at, odometer_decimal, category, cost_cents, interval_mileage_decimal, interval_days, interval_rule_text, note) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [row.id.uuidString, row.vehicleID.uuidString, row.occurredAt, row.odometerDecimal, row.category, row.costCents, row.intervalMileageDecimal, row.intervalDays, row.intervalRuleText, row.note])
            }
            for row in backup.corrections {
                try writer.execute(sql: "INSERT INTO corrections (id, target_kind, fill_event_id, service_event_id, version, corrected_payload_json, corrected_at) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [row.id.uuidString, row.targetKind.rawValue, row.fillEventID?.uuidString, row.serviceEventID?.uuidString, row.version, row.correctedPayloadJSON, row.correctedAt])
            }
        }
    }

    public func deleteVehicle(id: UUID) throws {
        try db.write { writer in
            try writer.execute(sql: "DELETE FROM vehicles WHERE id = ?", arguments: [id.uuidString])
            guard writer.changesCount == 1 else { throw BackupError.vehicleMissing }
        }
    }

    public func wipeAll() throws {
        try db.write { writer in try writer.execute(sql: "DELETE FROM vehicles") }
    }

    public func exportFillsCSV() throws -> String {
        var result = csv(["id", "vehicle_id", "occurred_at_utc", "odometer_miles", "volume", "volume_unit", "cost_cents", "classification", "note"])
        for vehicle in try vehicles.allVehicles() {
            for original in try fills.events(vehicleID: vehicle.id) {
                guard let row = try corrections.resolvedFillEvent(id: original.id) else { throw BackupError.invalidEvidence }
                result += csv([row.id.uuidString, vehicle.id.uuidString, ISO8601DateFormatter().string(from: row.occurredAt), row.odometerDecimal.map(PumpStoreDecimalCodec.encode) ?? "", PumpStoreDecimalCodec.encode(row.volumeDecimal), row.volumeUnit.rawValue, String(row.costCents), row.pumpClassification.rawValue, row.note ?? ""])
            }
        }
        return result
    }

    public func exportServiceCSV() throws -> String {
        var result = csv(["id", "vehicle_id", "occurred_at_utc", "odometer_miles", "category", "cost_cents", "interval_miles", "interval_days", "interval_rule_text", "note"])
        for vehicle in try vehicles.allVehicles() {
            for original in try service.events(vehicleID: vehicle.id) {
                guard let row = try corrections.resolvedServiceEvent(id: original.id) else { throw BackupError.invalidEvidence }
                result += csv([row.id.uuidString, vehicle.id.uuidString, ISO8601DateFormatter().string(from: row.occurredAt), row.odometerDecimal.map(PumpStoreDecimalCodec.encode) ?? "", row.category, String(row.costCents), row.intervalMileageDecimal.map(PumpStoreDecimalCodec.encode) ?? "", row.intervalDays.map(String.init) ?? "", row.intervalRuleText ?? "", row.note ?? ""])
            }
        }
        return result
    }
}
