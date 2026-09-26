import Foundation
import GRDB

public struct PumpStore: Sendable {
    public let db: any DatabaseWriter
    public let vehicles: any VehicleRepository
    public let fills: any FillEventRepository
    public let service: any ServiceEventRepository
    public let corrections: any CorrectionRepository

    public init(db: any DatabaseWriter) {
        self.db = db
        self.vehicles = GRDBVehicleRepository(db: db)
        self.fills = GRDBFillEventRepository(db: db)
        self.service = GRDBServiceEventRepository(db: db)
        self.corrections = GRDBCorrectionRepository(db: db)
    }

    public static func open(at url: URL) throws -> PumpStore {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(path: url.path, configuration: configuration)
        try PumpStoreSchema.migrator.migrate(db)
        return PumpStore(db: db)
    }

    public static func inMemory() throws -> PumpStore {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: configuration)
        try PumpStoreSchema.migrator.migrate(db)
        return PumpStore(db: db)
    }
}
