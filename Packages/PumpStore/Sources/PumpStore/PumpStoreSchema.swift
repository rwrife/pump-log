import Foundation
import GRDB

public enum PumpStoreSchema {
    public static let migrationIdentifiers: [String] = ["v1"]

    public static var currentVersion: Int {
        migrationIdentifiers.count
    }

    public static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "vehicles") { table in
                table.column("id", .text).notNull().primaryKey()
                table.column("nickname", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("retired_at", .datetime)
            }
            try db.create(
                index: "vehicles_created_at",
                on: "vehicles",
                columns: ["created_at"]
            )

            try db.create(table: "fill_events") { table in
                table.column("id", .text).notNull().primaryKey()
                table.column("vehicle_id", .text).notNull()
                    .references("vehicles", onDelete: .cascade)
                table.column("occurred_at", .datetime).notNull()
                table.column("odometer_decimal", .text)
                table.column("volume_decimal", .text).notNull()
                table.column("volume_unit", .text).notNull()
                table.column("cost_cents", .integer).notNull()
                table.column("pump_classification", .text).notNull()
                table.column("note", .text)
            }
            try db.create(
                index: "fill_events_vehicle_occurred",
                on: "fill_events",
                columns: ["vehicle_id", "occurred_at"]
            )

            try db.create(table: "service_events") { table in
                table.column("id", .text).notNull().primaryKey()
                table.column("vehicle_id", .text).notNull()
                    .references("vehicles", onDelete: .cascade)
                table.column("occurred_at", .datetime).notNull()
                table.column("odometer_decimal", .text)
                table.column("category", .text).notNull()
                table.column("cost_cents", .integer).notNull()
                table.column("interval_mileage_decimal", .text)
                table.column("interval_days", .integer)
                table.column("interval_rule_text", .text)
                table.column("note", .text)
            }
            try db.create(
                index: "service_events_vehicle_occurred",
                on: "service_events",
                columns: ["vehicle_id", "occurred_at"]
            )

            try db.create(table: "corrections") { table in
                table.column("id", .text).notNull().primaryKey()
                table.column("target_kind", .text).notNull()
                table.column("fill_event_id", .text)
                    .references("fill_events", onDelete: .cascade)
                table.column("service_event_id", .text)
                    .references("service_events", onDelete: .cascade)
                table.column("version", .integer).notNull()
                table.column("corrected_payload_json", .text).notNull()
                table.column("corrected_at", .datetime).notNull()
                table.check(sql: """
                    (target_kind = 'fill_event' AND fill_event_id IS NOT NULL AND service_event_id IS NULL) OR
                    (target_kind = 'service_event' AND service_event_id IS NOT NULL AND fill_event_id IS NULL)
                    """)
            }
            try db.create(
                index: "corrections_fill_version",
                on: "corrections",
                columns: ["fill_event_id", "version"],
                unique: true
            )
            try db.create(
                index: "corrections_service_version",
                on: "corrections",
                columns: ["service_event_id", "version"],
                unique: true
            )
        }
        return migrator
    }()
}

public func pumpStoreAppliedSchemaVersion(_ db: DatabaseReader) throws -> Int {
    try db.read { reader in
        try PumpStoreSchema.migrator.appliedMigrations(reader).count
    }
}
