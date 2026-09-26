import Foundation
import GRDB

public protocol VehicleRepository: Sendable {
    func append(_ vehicle: Vehicle) throws
    func vehicle(id: UUID) throws -> Vehicle?
    func allVehicles() throws -> [Vehicle]
}

public protocol FillEventRepository: Sendable {
    func append(_ event: FillEvent) throws
    func event(id: UUID) throws -> FillEvent?
    func events(vehicleID: UUID) throws -> [FillEvent]
}

public protocol ServiceEventRepository: Sendable {
    func append(_ event: ServiceEvent) throws
    func event(id: UUID) throws -> ServiceEvent?
    func events(vehicleID: UUID) throws -> [ServiceEvent]
}

public protocol CorrectionRepository: Sendable {
    @discardableResult
    func append(fillEventID: UUID, corrected: FillEvent, correctedAt: Date) throws -> CorrectionRecord
    @discardableResult
    func append(serviceEventID: UUID, corrected: ServiceEvent, correctedAt: Date) throws -> CorrectionRecord
    func corrections(fillEventID: UUID) throws -> [CorrectionRecord]
    func corrections(serviceEventID: UUID) throws -> [CorrectionRecord]
    func resolvedFillEvent(id: UUID) throws -> FillEvent?
    func resolvedServiceEvent(id: UUID) throws -> ServiceEvent?
}

public struct GRDBVehicleRepository: VehicleRepository {
    let db: any DatabaseWriter
    public init(db: any DatabaseWriter) { self.db = db }

    public func append(_ vehicle: Vehicle) throws {
        try db.write { writer in
            try writer.execute(
                sql: "INSERT INTO vehicles (id, nickname, created_at, retired_at) VALUES (?, ?, ?, ?)",
                arguments: [vehicle.id.uuidString, vehicle.nickname, vehicle.createdAt, vehicle.retiredAt]
            )
        }
    }

    public func vehicle(id: UUID) throws -> Vehicle? {
        try db.read { reader in
            guard let row = try Row.fetchOne(reader, sql: "SELECT * FROM vehicles WHERE id = ?", arguments: [id.uuidString]) else {
                return nil
            }
            return decodeVehicle(row)
        }
    }

    public func allVehicles() throws -> [Vehicle] {
        try db.read { reader in
            try Row.fetchAll(reader, sql: "SELECT * FROM vehicles ORDER BY created_at, id").map(decodeVehicle)
        }
    }
}

public struct GRDBFillEventRepository: FillEventRepository {
    let db: any DatabaseWriter
    public init(db: any DatabaseWriter) { self.db = db }

    public func append(_ event: FillEvent) throws {
        try db.write { writer in
            try requireVehicle(event.vehicleID, in: writer)
            try writer.execute(
                sql: """
                INSERT INTO fill_events (
                    id, vehicle_id, occurred_at, odometer_decimal, volume_decimal,
                    volume_unit, cost_cents, pump_classification, note
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    event.id.uuidString,
                    event.vehicleID.uuidString,
                    event.occurredAt,
                    event.odometerDecimal.map(PumpStoreDecimalCodec.encode),
                    PumpStoreDecimalCodec.encode(event.volumeDecimal),
                    event.volumeUnit.rawValue,
                    event.costCents,
                    event.pumpClassification.rawValue,
                    event.note,
                ]
            )
        }
    }

    public func event(id: UUID) throws -> FillEvent? {
        try db.read { reader in
            guard let row = try Row.fetchOne(reader, sql: "SELECT * FROM fill_events WHERE id = ?", arguments: [id.uuidString]) else {
                return nil
            }
            return try decodeFillEvent(row)
        }
    }

    public func events(vehicleID: UUID) throws -> [FillEvent] {
        try db.read { reader in
            try Row.fetchAll(
                reader,
                sql: "SELECT * FROM fill_events WHERE vehicle_id = ? ORDER BY occurred_at, id",
                arguments: [vehicleID.uuidString]
            ).map(decodeFillEvent)
        }
    }
}

public struct GRDBServiceEventRepository: ServiceEventRepository {
    let db: any DatabaseWriter
    public init(db: any DatabaseWriter) { self.db = db }

    public func append(_ event: ServiceEvent) throws {
        try db.write { writer in
            try requireVehicle(event.vehicleID, in: writer)
            try writer.execute(
                sql: """
                INSERT INTO service_events (
                    id, vehicle_id, occurred_at, odometer_decimal, category, cost_cents,
                    interval_mileage_decimal, interval_days, interval_rule_text, note
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    event.id.uuidString,
                    event.vehicleID.uuidString,
                    event.occurredAt,
                    event.odometerDecimal.map(PumpStoreDecimalCodec.encode),
                    event.category,
                    event.costCents,
                    event.intervalMileageDecimal.map(PumpStoreDecimalCodec.encode),
                    event.intervalDays,
                    event.intervalRuleText,
                    event.note,
                ]
            )
        }
    }

    public func event(id: UUID) throws -> ServiceEvent? {
        try db.read { reader in
            guard let row = try Row.fetchOne(reader, sql: "SELECT * FROM service_events WHERE id = ?", arguments: [id.uuidString]) else {
                return nil
            }
            return try decodeServiceEvent(row)
        }
    }

    public func events(vehicleID: UUID) throws -> [ServiceEvent] {
        try db.read { reader in
            try Row.fetchAll(
                reader,
                sql: "SELECT * FROM service_events WHERE vehicle_id = ? ORDER BY occurred_at, id",
                arguments: [vehicleID.uuidString]
            ).map(decodeServiceEvent)
        }
    }
}

public struct GRDBCorrectionRepository: CorrectionRepository {
    let db: any DatabaseWriter
    public init(db: any DatabaseWriter) { self.db = db }

    public func append(fillEventID: UUID, corrected: FillEvent, correctedAt: Date) throws -> CorrectionRecord {
        guard fillEventID == corrected.id else {
            throw PumpStoreError.immutableIdentityMismatch(expectedID: fillEventID, observedID: corrected.id)
        }
        return try db.write { writer in
            guard try Int.fetchOne(writer, sql: "SELECT COUNT(*) FROM fill_events WHERE id = ?", arguments: [fillEventID.uuidString]) == 1 else {
                throw PumpStoreError.eventNotFound(table: "fill_events", id: fillEventID)
            }
            let version = try nextVersion(column: "fill_event_id", id: fillEventID, in: writer)
            let payload = String(decoding: try PumpStoreJSON.encoder().encode(FillEventPayload(event: corrected)), as: UTF8.self)
            let record = CorrectionRecord(
                targetKind: .fillEvent,
                fillEventID: fillEventID,
                serviceEventID: nil,
                version: version,
                correctedPayloadJSON: payload,
                correctedAt: correctedAt
            )
            try insert(record, in: writer)
            return record
        }
    }

    public func append(serviceEventID: UUID, corrected: ServiceEvent, correctedAt: Date) throws -> CorrectionRecord {
        guard serviceEventID == corrected.id else {
            throw PumpStoreError.immutableIdentityMismatch(expectedID: serviceEventID, observedID: corrected.id)
        }
        return try db.write { writer in
            guard try Int.fetchOne(writer, sql: "SELECT COUNT(*) FROM service_events WHERE id = ?", arguments: [serviceEventID.uuidString]) == 1 else {
                throw PumpStoreError.eventNotFound(table: "service_events", id: serviceEventID)
            }
            let version = try nextVersion(column: "service_event_id", id: serviceEventID, in: writer)
            let payload = String(decoding: try PumpStoreJSON.encoder().encode(ServiceEventPayload(event: corrected)), as: UTF8.self)
            let record = CorrectionRecord(
                targetKind: .serviceEvent,
                fillEventID: nil,
                serviceEventID: serviceEventID,
                version: version,
                correctedPayloadJSON: payload,
                correctedAt: correctedAt
            )
            try insert(record, in: writer)
            return record
        }
    }

    public func corrections(fillEventID: UUID) throws -> [CorrectionRecord] {
        try corrections(column: "fill_event_id", id: fillEventID)
    }

    public func corrections(serviceEventID: UUID) throws -> [CorrectionRecord] {
        try corrections(column: "service_event_id", id: serviceEventID)
    }

    public func resolvedFillEvent(id: UUID) throws -> FillEvent? {
        try db.read { reader in
            guard let originalRow = try Row.fetchOne(reader, sql: "SELECT * FROM fill_events WHERE id = ?", arguments: [id.uuidString]) else {
                return nil
            }
            let original = try decodeFillEvent(originalRow)
            guard let correction = try latestCorrection(column: "fill_event_id", id: id, in: reader) else {
                return original
            }
            do {
                return try PumpStoreJSON.decoder()
                    .decode(FillEventPayload.self, from: Data(correction.correctedPayloadJSON.utf8))
                    .toFillEvent()
            } catch {
                throw PumpStoreError.correctionPayloadCorrupt(table: "fill_events", id: id, underlying: String(describing: error))
            }
        }
    }

    public func resolvedServiceEvent(id: UUID) throws -> ServiceEvent? {
        try db.read { reader in
            guard let originalRow = try Row.fetchOne(reader, sql: "SELECT * FROM service_events WHERE id = ?", arguments: [id.uuidString]) else {
                return nil
            }
            let original = try decodeServiceEvent(originalRow)
            guard let correction = try latestCorrection(column: "service_event_id", id: id, in: reader) else {
                return original
            }
            do {
                return try PumpStoreJSON.decoder()
                    .decode(ServiceEventPayload.self, from: Data(correction.correctedPayloadJSON.utf8))
                    .toServiceEvent()
            } catch {
                throw PumpStoreError.correctionPayloadCorrupt(table: "service_events", id: id, underlying: String(describing: error))
            }
        }
    }

    private func nextVersion(column: String, id: UUID, in db: Database) throws -> Int {
        (try Int.fetchOne(
            db,
            sql: "SELECT MAX(version) FROM corrections WHERE \(column) = ?",
            arguments: [id.uuidString]
        ) ?? 0) + 1
    }

    private func insert(_ record: CorrectionRecord, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO corrections (
                id, target_kind, fill_event_id, service_event_id, version,
                corrected_payload_json, corrected_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                record.id.uuidString,
                record.targetKind.rawValue,
                record.fillEventID?.uuidString,
                record.serviceEventID?.uuidString,
                record.version,
                record.correctedPayloadJSON,
                record.correctedAt,
            ]
        )
    }

    private func corrections(column: String, id: UUID) throws -> [CorrectionRecord] {
        try db.read { reader in
            try Row.fetchAll(
                reader,
                sql: "SELECT * FROM corrections WHERE \(column) = ? ORDER BY version",
                arguments: [id.uuidString]
            ).map(decodeCorrection)
        }
    }

    private func latestCorrection(column: String, id: UUID, in db: Database) throws -> CorrectionRecord? {
        try Row.fetchOne(
            db,
            sql: "SELECT * FROM corrections WHERE \(column) = ? ORDER BY version DESC LIMIT 1",
            arguments: [id.uuidString]
        ).map(decodeCorrection)
    }
}

private func requireVehicle(_ id: UUID, in db: Database) throws {
    guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM vehicles WHERE id = ?", arguments: [id.uuidString]) == 1 else {
        throw PumpStoreError.parentNotFound(table: "vehicles", id: id)
    }
}

private func decodeVehicle(_ row: Row) -> Vehicle {
    Vehicle(
        id: UUID(uuidString: row["id"])!,
        nickname: row["nickname"],
        createdAt: row["created_at"],
        retiredAt: row["retired_at"]
    )
}

private func decodeFillEvent(_ row: Row) throws -> FillEvent {
    let volumeUnit = PumpVolumeUnit(rawValue: row["volume_unit"]) ?? .litre
    let classification = PumpClassification(rawValue: row["pump_classification"]) ?? .unknown
    let odometer: String? = row["odometer_decimal"]
    let volume: String = row["volume_decimal"]
    return FillEvent(
        id: UUID(uuidString: row["id"])!,
        vehicleID: UUID(uuidString: row["vehicle_id"])!,
        occurredAt: row["occurred_at"],
        odometerDecimal: try odometer.map { try PumpStoreDecimalCodec.decode($0, field: "odometer_decimal") },
        volumeDecimal: try PumpStoreDecimalCodec.decode(volume, field: "volume_decimal"),
        volumeUnit: volumeUnit,
        costCents: row["cost_cents"],
        pumpClassification: classification,
        note: row["note"]
    )
}

private func decodeServiceEvent(_ row: Row) throws -> ServiceEvent {
    let odometer: String? = row["odometer_decimal"]
    let intervalMileage: String? = row["interval_mileage_decimal"]
    return ServiceEvent(
        id: UUID(uuidString: row["id"])!,
        vehicleID: UUID(uuidString: row["vehicle_id"])!,
        occurredAt: row["occurred_at"],
        odometerDecimal: try odometer.map { try PumpStoreDecimalCodec.decode($0, field: "odometer_decimal") },
        category: row["category"],
        costCents: row["cost_cents"],
        intervalMileageDecimal: try intervalMileage.map { try PumpStoreDecimalCodec.decode($0, field: "interval_mileage_decimal") },
        intervalDays: row["interval_days"],
        intervalRuleText: row["interval_rule_text"],
        note: row["note"]
    )
}

private func decodeCorrection(_ row: Row) -> CorrectionRecord {
    CorrectionRecord(
        id: UUID(uuidString: row["id"])!,
        targetKind: CorrectionTargetKind(rawValue: row["target_kind"])!,
        fillEventID: (row["fill_event_id"] as String?).flatMap(UUID.init(uuidString:)),
        serviceEventID: (row["service_event_id"] as String?).flatMap(UUID.init(uuidString:)),
        version: row["version"],
        correctedPayloadJSON: row["corrected_payload_json"],
        correctedAt: row["corrected_at"]
    )
}
