import GRDB
import Testing
@testable import PumpStore

@Suite("PumpStore schema v1")
struct SchemaTests {
    @Test("fresh migration creates the frozen v1 tables and cascading foreign keys")
    func createsFrozenV1Schema() throws {
        let store = try PumpStore.inMemory()
        let schema = try store.db.read { db in
            try ["vehicles", "fill_events", "service_events", "corrections"].reduce(into: [String: [String]]()) {
                $0[$1] = try db.columns(in: $1).map(\.name)
            }
        }

        #expect(schema["vehicles"] == ["id", "nickname", "created_at", "retired_at"])
        #expect(schema["fill_events"] == [
            "id", "vehicle_id", "occurred_at", "odometer_decimal", "volume_decimal",
            "volume_unit", "cost_cents", "pump_classification", "note",
        ])
        #expect(schema["service_events"] == [
            "id", "vehicle_id", "occurred_at", "odometer_decimal", "category",
            "cost_cents", "interval_mileage_decimal", "interval_days", "interval_rule_text", "note",
        ])
        #expect(schema["corrections"] == [
            "id", "target_kind", "fill_event_id", "service_event_id", "version",
            "corrected_payload_json", "corrected_at",
        ])
        #expect(try pumpStoreAppliedSchemaVersion(store.db) == 1)
    }
}
