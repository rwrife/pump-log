import Foundation
import PumpKit

/// Aggregated stats evidence for one vehicle, computed from the honest
/// ledgers (issue #6). The app's stats screens render this structure
/// verbatim — no number is invented here or in the views.
public struct VehicleStats: Equatable, Sendable {
    public var economy: EconomyDerivation
    /// nil when the vehicle has no fills or services at all.
    public var cost: CostDerivation?
    /// User-owned service rules only; categories without interval data never
    /// appear (no maintenance-advice inference).
    public var serviceDue: [ServiceDueDerivation]
    /// Occurrence dates keyed by fill id, for point-series labels.
    public var fillDatesByID: [UUID: Date]

    public init(economy: EconomyDerivation, cost: CostDerivation?, serviceDue: [ServiceDueDerivation], fillDatesByID: [UUID: Date] = [:]) {
        self.economy = economy
        self.cost = cost
        self.serviceDue = serviceDue
        self.fillDatesByID = fillDatesByID
    }
}

extension QuickLogWorkflow {
    /// Cost-ledger category label used for every fill (services keep their own
    /// user-entered category).
    public static let fuelCategory = "Fuel"

    /// Cost window end padding: the window is [earliest event, latest event + 1 day)
    /// so a single-event vehicle still yields a valid half-open window.
    static let costWindowPaddingSeconds: TimeInterval = 86_400

    public func vehicleStats(vehicleID: UUID) throws -> VehicleStats {
        let fills = try resolvedFills(vehicleID: vehicleID)
        let services = try resolvedServices(vehicleID: vehicleID)
        let economy = try economy(vehicleID: vehicleID)

        var entries: [CostLedgerEntry] = []
        entries.reserveCapacity(fills.count + services.count)
        for fill in fills {
            entries.append(CostLedgerEntry(
                id: fill.id,
                vehicleID: vehicleID,
                occurredAt: fill.occurredAt,
                category: Self.fuelCategory,
                costCents: fill.costCents
            ))
        }
        for service in services {
            entries.append(CostLedgerEntry(
                id: service.id,
                vehicleID: vehicleID,
                occurredAt: service.occurredAt,
                category: service.category,
                costCents: service.costCents
            ))
        }

        // Denominator: only odometer-confirmed full-to-full pair evidence.
        let occurredByFillID = Dictionary(uniqueKeysWithValues: fills.map { ($0.id, $0.occurredAt) })
        var mileage: [ConfirmedMileageInterval] = []
        for interval in economy.intervals {
            guard let start = occurredByFillID[interval.evidence.startFillID],
                  let end = occurredByFillID[interval.evidence.endFillID] else { continue }
            mileage.append(ConfirmedMileageInterval(
                id: interval.evidence.endFillID,
                vehicleID: vehicleID,
                start: start,
                end: end,
                miles: interval.evidence.milesTravelled
            ))
        }

        let cost: CostDerivation?
        if entries.isEmpty {
            cost = nil
        } else {
            let earliest = entries.map(\.occurredAt).min()!
            let latest = entries.map(\.occurredAt).max()!
            let window = CostWindow(start: earliest, end: latest.addingTimeInterval(Self.costWindowPaddingSeconds))
            cost = try CostLedgerEngine.derive(vehicleID: vehicleID, window: window, costs: entries, mileage: mileage)
        }

        var serviceDue: [ServiceDueDerivation] = []
        let ruleCategories = Set(services
            .filter { $0.intervalMileageDecimal != nil || $0.intervalDays != nil }
            .map(\.category))
        let currentOdometer = fills
            .filter { $0.odometerDecimal != nil }
            .max { $0.occurredAt < $1.occurredAt }?
            .odometerDecimal
        for category in ruleCategories.sorted() {
            guard let ruleSource = services
                .filter({ $0.category == category && ($0.intervalMileageDecimal != nil || $0.intervalDays != nil) })
                .max(by: { $0.occurredAt < $1.occurredAt }) else { continue }
            let rule = ServiceIntervalRule(
                category: category,
                ruleText: Self.serviceRuleText(for: ruleSource),
                mileageInterval: ruleSource.intervalMileageDecimal,
                dayInterval: ruleSource.intervalDays
            )
            let userEvents = services.filter { $0.category == category }.map {
                UserServiceEvent(
                    id: $0.id,
                    vehicleID: $0.vehicleID,
                    category: $0.category,
                    occurredAt: $0.occurredAt,
                    odometer: $0.odometerDecimal
                )
            }
            serviceDue.append(ServiceDueWindowEngine.derive(
                rule: rule,
                vehicleID: vehicleID,
                serviceEvents: userEvents,
                currentOdometer: currentOdometer,
                now: Date()
            ))
        }

        return VehicleStats(
            economy: economy,
            cost: cost,
            serviceDue: serviceDue,
            fillDatesByID: Dictionary(uniqueKeysWithValues: fills.map { ($0.id, $0.occurredAt) })
        )
    }

    /// Echoes the user's own rule text verbatim when present; otherwise
    /// restates only the numbers the user entered. Never invents schedules.
    static func serviceRuleText(for event: ServiceEvent) -> String {
        if let text = event.intervalRuleText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        var parts: [String] = []
        if let miles = event.intervalMileageDecimal {
            parts.append("every \(StatsPresentation.decimalString(miles)) miles")
        }
        if let days = event.intervalDays {
            parts.append("every \(days) days")
        }
        return parts.isEmpty ? "no rule recorded" : parts.joined(separator: " or ")
    }
}
