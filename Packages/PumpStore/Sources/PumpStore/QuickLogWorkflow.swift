import Foundation
import PumpKit
import GRDB

public enum QuickLogError: Error, Equatable, LocalizedError, Sendable {
    case invalidNumber(String)
    case nonIncreasingOdometer
    case largeOdometerDelta
    case vehicleRetired
    case vehicleMissing
    case eventMissing
    case emptyName

    public var errorDescription: String? {
        switch self {
        case .invalidNumber(let field): "Enter a valid positive \(field)."
        case .nonIncreasingOdometer: "Odometer must increase from adjacent fills."
        case .largeOdometerDelta: "Odometer jump exceeds 10,000 miles. Confirm this entry to save."
        case .vehicleRetired: "Retired vehicles cannot receive new fills or services."
        case .vehicleMissing: "Vehicle was not found."
        case .eventMissing: "Ledger entry was not found."
        case .emptyName: "Enter a name or category."
        }
    }
}

public enum QuickLogInput {
    // The same ASCII grammar is used on device and in package tests. Decimal(string:)
    // alone accepts some prefixes and locale-specific forms.
    public static func decimal(_ text: String, field: String) throws -> Decimal {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !value.isEmpty, parts.count <= 2, !parts[0].isEmpty,
              parts.allSatisfy({ $0.unicodeScalars.allSatisfy { (48...57).contains($0.value) } }),
              parts.count == 1 || !parts[1].isEmpty,
              let parsed = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              parsed > 0, NSDecimalNumber(decimal: parsed) != .notANumber else {
            throw QuickLogError.invalidNumber(field)
        }
        return parsed
    }

    public static func priceCents(_ text: String) throws -> Int {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !value.isEmpty, parts.count <= 2, !parts[0].isEmpty,
              parts.allSatisfy({ $0.unicodeScalars.allSatisfy { (48...57).contains($0.value) } }),
              parts.count == 1 || (1...2).contains(parts[1].count) else {
            throw QuickLogError.invalidNumber("total price")
        }
        let whole = String(parts[0])
        let fractional = parts.count == 2 ? String(parts[1]).padding(toLength: 2, withPad: "0", startingAt: 0) : "00"
        guard let dollars = Int(whole), let cents = Int(fractional) else { throw QuickLogError.invalidNumber("total price") }
        let (scaled, overflow1) = dollars.multipliedReportingOverflow(by: 100)
        let (total, overflow2) = scaled.addingReportingOverflow(cents)
        guard !overflow1, !overflow2, total > 0 else { throw QuickLogError.invalidNumber("total price") }
        return total
    }
}

public struct QuickLogWorkflow: Sendable {
    public let store: PumpStore
    /// Entry sanity threshold only; this is not vehicle or maintenance advice.
    public static let confirmationDeltaMiles: Decimal = 10_000

    public init(store: PumpStore) { self.store = store }

    public func addVehicle(_ name: String) throws -> Vehicle {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuickLogError.emptyName }
        let vehicle = Vehicle(nickname: trimmed, createdAt: Date())
        try store.vehicles.append(vehicle)
        return vehicle
    }

    public func retireVehicle(id: UUID) throws {
        guard let vehicle = try store.vehicles.vehicle(id: id) else { throw QuickLogError.vehicleMissing }
        guard vehicle.retiredAt == nil else { return }
        try store.db.write { db in
            try db.execute(sql: "UPDATE vehicles SET retired_at = ? WHERE id = ? AND retired_at IS NULL", arguments: [Date(), id.uuidString])
        }
    }

    private func activeVehicle(_ id: UUID) throws {
        guard let vehicle = try store.vehicles.vehicle(id: id) else { throw QuickLogError.vehicleMissing }
        guard vehicle.retiredAt == nil else { throw QuickLogError.vehicleRetired }
    }

    public func resolvedFills(vehicleID: UUID) throws -> [FillEvent] {
        try store.fills.events(vehicleID: vehicleID).map { original in
            guard let resolved = try store.corrections.resolvedFillEvent(id: original.id) else { throw QuickLogError.eventMissing }
            return resolved
        }
    }

    public func resolvedServices(vehicleID: UUID) throws -> [ServiceEvent] {
        try store.service.events(vehicleID: vehicleID).map { original in
            guard let resolved = try store.corrections.resolvedServiceEvent(id: original.id) else { throw QuickLogError.eventMissing }
            return resolved
        }
    }

    private func validateOdometer(_ odometer: Decimal, at date: Date, id: UUID, vehicleID: UUID, confirmLargeDelta: Bool) throws {
        let others = try resolvedFills(vehicleID: vehicleID).filter { $0.id != id }
        let before = others.last { $0.occurredAt <= date && $0.odometerDecimal != nil }
        let after = others.first { $0.occurredAt > date && $0.odometerDecimal != nil }
        if let beforeOdometer = before?.odometerDecimal, odometer <= beforeOdometer { throw QuickLogError.nonIncreasingOdometer }
        if let afterOdometer = after?.odometerDecimal, odometer >= afterOdometer { throw QuickLogError.nonIncreasingOdometer }
        if !confirmLargeDelta, let beforeOdometer = before?.odometerDecimal, odometer - beforeOdometer > Self.confirmationDeltaMiles { throw QuickLogError.largeOdometerDelta }
        if !confirmLargeDelta, let afterOdometer = after?.odometerDecimal, afterOdometer - odometer > Self.confirmationDeltaMiles { throw QuickLogError.largeOdometerDelta }
    }

    public func logFill(vehicleID: UUID, odometer: String, volume: String, price: String, classification: PumpClassification, confirmLargeDelta: Bool = false) throws -> FillEvent {
        try activeVehicle(vehicleID)
        let miles = try QuickLogInput.decimal(odometer, field: "odometer miles")
        let gallons = try QuickLogInput.decimal(volume, field: "US gallons")
        let cents = try QuickLogInput.priceCents(price)
        let event = FillEvent(vehicleID: vehicleID, occurredAt: Date(), odometerDecimal: miles, volumeDecimal: gallons, volumeUnit: .usGallon, costCents: cents, pumpClassification: classification)
        try validateOdometer(miles, at: event.occurredAt, id: event.id, vehicleID: vehicleID, confirmLargeDelta: confirmLargeDelta)
        try store.fills.append(event)
        return event
    }

    public func correctFill(id: UUID, odometer: String, volume: String, price: String, classification: PumpClassification, confirmLargeDelta: Bool = false) throws {
        guard var event = try store.corrections.resolvedFillEvent(id: id) else { throw QuickLogError.eventMissing }
        let miles = try QuickLogInput.decimal(odometer, field: "odometer miles")
        event.odometerDecimal = miles
        event.volumeDecimal = try QuickLogInput.decimal(volume, field: "US gallons")
        event.costCents = try QuickLogInput.priceCents(price)
        event.pumpClassification = classification
        try validateOdometer(miles, at: event.occurredAt, id: id, vehicleID: event.vehicleID, confirmLargeDelta: confirmLargeDelta)
        try store.corrections.append(fillEventID: id, corrected: event, correctedAt: Date())
    }

    public func logService(vehicleID: UUID, category: String, price: String) throws -> ServiceEvent {
        try activeVehicle(vehicleID)
        let name = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw QuickLogError.emptyName }
        let event = ServiceEvent(vehicleID: vehicleID, occurredAt: Date(), odometerDecimal: nil, category: name, costCents: try QuickLogInput.priceCents(price), intervalMileageDecimal: nil, intervalDays: nil, intervalRuleText: nil)
        try store.service.append(event)
        return event
    }

    public func correctServiceCategory(id: UUID, category: String) throws {
        guard var event = try store.corrections.resolvedServiceEvent(id: id) else { throw QuickLogError.eventMissing }
        let name = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw QuickLogError.emptyName }
        event.category = name
        try store.corrections.append(serviceEventID: id, corrected: event, correctedAt: Date())
    }

    public func economy(vehicleID: UUID) throws -> EconomyDerivation {
        let events = try resolvedFills(vehicleID: vehicleID).map {
            FuelFillEvent(id: $0.id, vehicleID: $0.vehicleID, occurredAt: $0.occurredAt, odometer: $0.odometerDecimal, volume: $0.volumeDecimal, volumeUnit: .init(rawValue: $0.volumeUnit.rawValue)!, classification: .init(rawValue: $0.pumpClassification.rawValue)!)
        }
        return EconomyEngine.derive(from: events)
    }
}
