import Foundation
import PumpStore

final class InMemoryStoreLock: @unchecked Sendable {
    private let lock = NSLock()
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public final class InMemoryVehicleRepository: VehicleRepository, @unchecked Sendable {
    private let lock = InMemoryStoreLock()
    private var vehicles: [UUID: Vehicle] = [:]

    public init() {}

    public func append(_ vehicle: Vehicle) throws {
        lock.withLock {
            vehicles[vehicle.id] = vehicle
        }
    }

    public func vehicle(id: UUID) throws -> Vehicle? {
        lock.withLock {
            vehicles[id]
        }
    }

    public func allVehicles() throws -> [Vehicle] {
        lock.withLock {
            vehicles.values.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        }
    }
}

public final class InMemoryFillEventRepository: FillEventRepository, @unchecked Sendable {
    private let lock = InMemoryStoreLock()
    private var eventsByID: [UUID: FillEvent] = [:]
    private var knownVehicleIDs: Set<UUID> = []

    public init(knownVehicleIDs: Set<UUID> = []) {
        self.knownVehicleIDs = knownVehicleIDs
    }

    public func registerVehicle(_ id: UUID) {
        lock.withLock {
            knownVehicleIDs.insert(id)
        }
    }

    public func append(_ event: FillEvent) throws {
        try lock.withLock {
            guard knownVehicleIDs.contains(event.vehicleID) else {
                throw PumpStoreError.parentNotFound(table: "vehicles", id: event.vehicleID)
            }
            eventsByID[event.id] = event
        }
    }

    public func event(id: UUID) throws -> FillEvent? {
        lock.withLock {
            eventsByID[id]
        }
    }

    public func events(vehicleID: UUID) throws -> [FillEvent] {
        lock.withLock {
            eventsByID.values
                .filter { $0.vehicleID == vehicleID }
                .sorted { ($0.occurredAt, $0.id.uuidString) < ($1.occurredAt, $1.id.uuidString) }
        }
    }
}

public final class InMemoryServiceEventRepository: ServiceEventRepository, @unchecked Sendable {
    private let lock = InMemoryStoreLock()
    private var eventsByID: [UUID: ServiceEvent] = [:]
    private var knownVehicleIDs: Set<UUID> = []

    public init(knownVehicleIDs: Set<UUID> = []) {
        self.knownVehicleIDs = knownVehicleIDs
    }

    public func registerVehicle(_ id: UUID) {
        lock.withLock {
            knownVehicleIDs.insert(id)
        }
    }

    public func append(_ event: ServiceEvent) throws {
        try lock.withLock {
            guard knownVehicleIDs.contains(event.vehicleID) else {
                throw PumpStoreError.parentNotFound(table: "vehicles", id: event.vehicleID)
            }
            eventsByID[event.id] = event
        }
    }

    public func event(id: UUID) throws -> ServiceEvent? {
        lock.withLock {
            eventsByID[id]
        }
    }

    public func events(vehicleID: UUID) throws -> [ServiceEvent] {
        lock.withLock {
            eventsByID.values
                .filter { $0.vehicleID == vehicleID }
                .sorted { ($0.occurredAt, $0.id.uuidString) < ($1.occurredAt, $1.id.uuidString) }
        }
    }
}

public final class InMemoryCorrectionRepository: CorrectionRepository, @unchecked Sendable {
    private let lock = InMemoryStoreLock()
    private var fillCorrections: [UUID: [CorrectionRecord]] = [:]
    private var serviceCorrections: [UUID: [CorrectionRecord]] = [:]
    private let fills: InMemoryFillEventRepository
    private let service: InMemoryServiceEventRepository

    public init(fills: InMemoryFillEventRepository, service: InMemoryServiceEventRepository) {
        self.fills = fills
        self.service = service
    }

    public func append(fillEventID: UUID, corrected: FillEvent, correctedAt: Date) throws -> CorrectionRecord {
        guard fillEventID == corrected.id else {
            throw PumpStoreError.immutableIdentityMismatch(expectedID: fillEventID, observedID: corrected.id)
        }
        return try lock.withLock {
            guard try fills.event(id: fillEventID) != nil else {
                throw PumpStoreError.eventNotFound(table: "fill_events", id: fillEventID)
            }
            var list = fillCorrections[fillEventID] ?? []
            let nextVersion = (list.map(\.version).max() ?? 0) + 1
            let payload = try PumpStoreCorrectionCodec.encode(corrected)
            let record = CorrectionRecord(
                targetKind: .fillEvent,
                fillEventID: fillEventID,
                serviceEventID: nil,
                version: nextVersion,
                correctedPayloadJSON: payload,
                correctedAt: correctedAt
            )
            list.append(record)
            fillCorrections[fillEventID] = list
            return record
        }
    }

    public func append(serviceEventID: UUID, corrected: ServiceEvent, correctedAt: Date) throws -> CorrectionRecord {
        guard serviceEventID == corrected.id else {
            throw PumpStoreError.immutableIdentityMismatch(expectedID: serviceEventID, observedID: corrected.id)
        }
        return try lock.withLock {
            guard try service.event(id: serviceEventID) != nil else {
                throw PumpStoreError.eventNotFound(table: "service_events", id: serviceEventID)
            }
            var list = serviceCorrections[serviceEventID] ?? []
            let nextVersion = (list.map(\.version).max() ?? 0) + 1
            let payload = try PumpStoreCorrectionCodec.encode(corrected)
            let record = CorrectionRecord(
                targetKind: .serviceEvent,
                fillEventID: nil,
                serviceEventID: serviceEventID,
                version: nextVersion,
                correctedPayloadJSON: payload,
                correctedAt: correctedAt
            )
            list.append(record)
            serviceCorrections[serviceEventID] = list
            return record
        }
    }

    public func corrections(fillEventID: UUID) throws -> [CorrectionRecord] {
        lock.withLock {
            fillCorrections[fillEventID] ?? []
        }
    }

    public func corrections(serviceEventID: UUID) throws -> [CorrectionRecord] {
        lock.withLock {
            serviceCorrections[serviceEventID] ?? []
        }
    }

    public func resolvedFillEvent(id: UUID) throws -> FillEvent? {
        try lock.withLock {
            guard let original = try fills.event(id: id) else { return nil }
            guard let latest = fillCorrections[id]?.last else { return original }
            return try PumpStoreCorrectionCodec.decodeFillEvent(latest.correctedPayloadJSON)
        }
    }

    public func resolvedServiceEvent(id: UUID) throws -> ServiceEvent? {
        try lock.withLock {
            guard let original = try service.event(id: id) else { return nil }
            guard let latest = serviceCorrections[id]?.last else { return original }
            return try PumpStoreCorrectionCodec.decodeServiceEvent(latest.correctedPayloadJSON)
        }
    }
}

public struct InMemoryRepositories: Sendable {
    public let vehicles: InMemoryVehicleRepository
    public let fills: InMemoryFillEventRepository
    public let service: InMemoryServiceEventRepository
    public let corrections: CorrectionRepository

    public init() {
        let vehicleRepo = InMemoryVehicleRepository()
        let fillRepo = InMemoryFillEventRepository()
        let serviceRepo = InMemoryServiceEventRepository()
        let correctionRepo = InMemoryCorrectionRepository(fills: fillRepo, service: serviceRepo)
        self.vehicles = vehicleRepo
        self.fills = fillRepo
        self.service = serviceRepo
        self.corrections = correctionRepo
    }
}
