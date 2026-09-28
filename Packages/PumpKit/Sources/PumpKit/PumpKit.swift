import Foundation

/// PumpKit — pure-domain core for Pump Log.
///
/// Issue #4 implements deterministic cost ledger aggregation and user-owned
/// service due-window derivations:
/// - cents-only category sums over a window
/// - cost/mile = cents ÷ odometer-confirmed miles, rendered with explicit coverage %
/// - unknown state for zero/missing mileage denominator, never extrapolated
/// - user-owned interval rule echoed verbatim; no hardcoded vehicle schedules
/// - DST-safe calendar math for day-interval rules
public enum PumpKit {
    /// Namespace marker for the domain layer.
    public static let domain = "PumpKit"

    /// Current milestone marker consumed by the app bootstrap surface.
    public static let milestone = "M4-cost-ledger-engine"
}

public enum PumpVolumeUnit: String, Codable, CaseIterable, Sendable {
    case usGallon = "us_gallon"
    case imperialGallon = "imperial_gallon"
    case litre = "litre"
}

public enum PumpClassification: String, Codable, CaseIterable, Sendable {
    case full
    case partial
    case topoff
    case unknown
}

public struct FuelFillEvent: Equatable, Sendable {
    public var id: UUID
    public var vehicleID: UUID
    public var occurredAt: Date
    public var odometer: Decimal?
    public var volume: Decimal
    public var volumeUnit: PumpVolumeUnit
    public var classification: PumpClassification

    public init(
        id: UUID = UUID(),
        vehicleID: UUID,
        occurredAt: Date,
        odometer: Decimal?,
        volume: Decimal,
        volumeUnit: PumpVolumeUnit,
        classification: PumpClassification
    ) {
        self.id = id
        self.vehicleID = vehicleID
        self.occurredAt = occurredAt
        self.odometer = odometer
        self.volume = volume
        self.volumeUnit = volumeUnit
        self.classification = classification
    }
}

public enum EconomyExclusionReason: String, Codable, CaseIterable, Sendable {
    case topoff
    case partial
    case odometerMissing = "odometer-missing"
    case odometerNonincreasing = "odometer-nonincreasing"
    case vehicleBoundary = "vehicle-boundary"
}

public struct EconomyExclusion: Equatable, Sendable {
    public var fillID: UUID
    public var vehicleID: UUID
    public var reason: EconomyExclusionReason

    public init(fillID: UUID, vehicleID: UUID, reason: EconomyExclusionReason) {
        self.fillID = fillID
        self.vehicleID = vehicleID
        self.reason = reason
    }
}

public struct EconomyIntervalEvidence: Equatable, Sendable {
    public var startFillID: UUID
    public var endFillID: UUID
    public var gallonsUsed: Decimal
    public var milesTravelled: Decimal

    public init(startFillID: UUID, endFillID: UUID, gallonsUsed: Decimal, milesTravelled: Decimal) {
        self.startFillID = startFillID
        self.endFillID = endFillID
        self.gallonsUsed = gallonsUsed
        self.milesTravelled = milesTravelled
    }
}

public struct EconomyInterval: Equatable, Sendable {
    public var evidence: EconomyIntervalEvidence
    public var mpgUS: Decimal
    public var mpgImperial: Decimal
    public var litresPer100km: Decimal

    public init(
        evidence: EconomyIntervalEvidence,
        mpgUS: Decimal,
        mpgImperial: Decimal,
        litresPer100km: Decimal
    ) {
        self.evidence = evidence
        self.mpgUS = mpgUS
        self.mpgImperial = mpgImperial
        self.litresPer100km = litresPer100km
    }
}

public enum EconomyMeasurement: Equatable, Sendable {
    case known(mpgUS: Decimal, mpgImperial: Decimal, litresPer100km: Decimal)
    case unknown
}

public struct RollingEconomyWindow: Equatable, Sendable {
    public var pairWindow: Int
    public var sampleCount: Int
    public var totalMiles: Decimal
    public var totalGallonsUS: Decimal
    public var measurement: EconomyMeasurement

    public init(
        pairWindow: Int,
        sampleCount: Int,
        totalMiles: Decimal,
        totalGallonsUS: Decimal,
        measurement: EconomyMeasurement
    ) {
        self.pairWindow = pairWindow
        self.sampleCount = sampleCount
        self.totalMiles = totalMiles
        self.totalGallonsUS = totalGallonsUS
        self.measurement = measurement
    }
}

public struct EconomyDerivation: Equatable, Sendable {
    public var intervals: [EconomyInterval]
    public var exclusions: [EconomyExclusion]
    public var rolling3: RollingEconomyWindow
    public var rolling5: RollingEconomyWindow
    public var rolling10: RollingEconomyWindow

    public init(
        intervals: [EconomyInterval],
        exclusions: [EconomyExclusion],
        rolling3: RollingEconomyWindow,
        rolling5: RollingEconomyWindow,
        rolling10: RollingEconomyWindow
    ) {
        self.intervals = intervals
        self.exclusions = exclusions
        self.rolling3 = rolling3
        self.rolling5 = rolling5
        self.rolling10 = rolling10
    }
}

public enum EconomyEngine {
    public static func derive(from fills: [FuelFillEvent]) -> EconomyDerivation {
        let sorted = fills.sorted {
            if $0.occurredAt == $1.occurredAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.occurredAt < $1.occurredAt
        }

        var intervals: [EconomyInterval] = []
        var exclusions: [EconomyExclusion] = []

        var anchor: FuelFillEvent?
        var gapContainsSkippedFill = false
        var activeVehicleID: UUID?

        for fill in sorted {
            if let vehicle = activeVehicleID, vehicle != fill.vehicleID {
                exclusions.append(
                    EconomyExclusion(fillID: fill.id, vehicleID: fill.vehicleID, reason: .vehicleBoundary)
                )
                anchor = nil
                gapContainsSkippedFill = false

                if fill.classification == .full, fill.odometer != nil {
                    anchor = fill
                }
                activeVehicleID = fill.vehicleID
                continue
            }

            activeVehicleID = fill.vehicleID

            switch fill.classification {
            case .topoff:
                exclusions.append(
                    EconomyExclusion(fillID: fill.id, vehicleID: fill.vehicleID, reason: .topoff)
                )
                if anchor != nil {
                    gapContainsSkippedFill = true
                }

            case .partial, .unknown:
                exclusions.append(
                    EconomyExclusion(fillID: fill.id, vehicleID: fill.vehicleID, reason: .partial)
                )
                if anchor != nil {
                    gapContainsSkippedFill = true
                }

            case .full:
                guard let odometer = fill.odometer else {
                    exclusions.append(
                        EconomyExclusion(fillID: fill.id, vehicleID: fill.vehicleID, reason: .odometerMissing)
                    )
                    anchor = nil
                    gapContainsSkippedFill = false
                    continue
                }

                guard let start = anchor, let startOdometer = start.odometer else {
                    anchor = fill
                    gapContainsSkippedFill = false
                    continue
                }

                if gapContainsSkippedFill {
                    anchor = fill
                    gapContainsSkippedFill = false
                    continue
                }

                if odometer <= startOdometer {
                    exclusions.append(
                        EconomyExclusion(fillID: fill.id, vehicleID: fill.vehicleID, reason: .odometerNonincreasing)
                    )
                    anchor = nil
                    gapContainsSkippedFill = false
                    continue
                }

                let miles = odometer - startOdometer
                let gallonsUS = VolumeConverter.usGallons(from: fill.volume, unit: fill.volumeUnit)
                let measurement = measurementFrom(miles: miles, volume: fill.volume, unit: fill.volumeUnit)

                if case let .known(mpgUS, mpgImperial, litresPer100km) = measurement {
                    intervals.append(
                        EconomyInterval(
                            evidence: EconomyIntervalEvidence(
                                startFillID: start.id,
                                endFillID: fill.id,
                                gallonsUsed: gallonsUS,
                                milesTravelled: miles
                            ),
                            mpgUS: mpgUS,
                            mpgImperial: mpgImperial,
                            litresPer100km: litresPer100km
                        )
                    )
                }

                anchor = fill
                gapContainsSkippedFill = false
            }
        }

        return EconomyDerivation(
            intervals: intervals,
            exclusions: exclusions,
            rolling3: rollingWindow(from: intervals, pairWindow: 3),
            rolling5: rollingWindow(from: intervals, pairWindow: 5),
            rolling10: rollingWindow(from: intervals, pairWindow: 10)
        )
    }

    private static func rollingWindow(from intervals: [EconomyInterval], pairWindow: Int) -> RollingEconomyWindow {
        let sample = Array(intervals.suffix(pairWindow))
        let sampleCount = sample.count

        guard sampleCount > 0 else {
            return RollingEconomyWindow(
                pairWindow: pairWindow,
                sampleCount: 0,
                totalMiles: .zero,
                totalGallonsUS: .zero,
                measurement: .unknown
            )
        }

        let totalMiles = sample.reduce(Decimal.zero) { $0 + $1.evidence.milesTravelled }
        let totalGallonsUS = sample.reduce(Decimal.zero) { $0 + $1.evidence.gallonsUsed }

        return RollingEconomyWindow(
            pairWindow: pairWindow,
            sampleCount: sampleCount,
            totalMiles: totalMiles,
            totalGallonsUS: totalGallonsUS,
            measurement: measurementFromAggregate(miles: totalMiles, gallonsUS: totalGallonsUS)
        )
    }

    /// Exact per-interval measurement: each target unit converts the native
    /// volume directly, never via a chained conversion (avoids Decimal drift).
    private static func measurementFrom(miles: Decimal, volume: Decimal, unit: PumpVolumeUnit) -> EconomyMeasurement {
        guard miles > .zero else {
            return .unknown
        }
        let gallonsUS = VolumeConverter.usGallons(from: volume, unit: unit)
        let gallonsImperial = VolumeConverter.imperialGallons(from: volume, unit: unit)
        let litres = VolumeConverter.litres(from: volume, unit: unit)
        guard gallonsUS > .zero, gallonsImperial > .zero, litres > .zero else {
            return .unknown
        }

        let mpgUS = miles / gallonsUS
        let mpgImperial = miles / gallonsImperial
        let kilometres = miles * VolumeConverter.kmPerMile
        guard kilometres > .zero else {
            return .unknown
        }
        let litresPer100km = (litres * decimal("100")) / kilometres

        return .known(mpgUS: mpgUS, mpgImperial: mpgImperial, litresPer100km: litresPer100km)
    }

    /// Aggregate measurement over rolling windows; totals are US-gallon based,
    /// so the imperial/litre figures convert from that total.
    private static func measurementFromAggregate(miles: Decimal, gallonsUS: Decimal) -> EconomyMeasurement {
        guard miles > .zero, gallonsUS > .zero else {
            return .unknown
        }

        let mpgUS = miles / gallonsUS
        let gallonsImperial = VolumeConverter.imperialGallons(fromUSGallons: gallonsUS)
        guard gallonsImperial > .zero else {
            return .unknown
        }
        let mpgImperial = miles / gallonsImperial

        let litres = VolumeConverter.litres(fromUSGallons: gallonsUS)
        let kilometres = miles * VolumeConverter.kmPerMile
        guard kilometres > .zero else {
            return .unknown
        }
        let litresPer100km = (litres * decimal("100")) / kilometres

        return .known(mpgUS: mpgUS, mpgImperial: mpgImperial, litresPer100km: litresPer100km)
    }
}

// MARK: - Cost Ledger Engine

public struct CostWindow: Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        precondition(start < end, "CostWindow start must be strictly before end")
        self.start = start
        self.end = end
    }

    /// Half-open [start, end).
    public func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    public var durationSeconds: TimeInterval {
        end.timeIntervalSince(start)
    }
}

public struct CostLedgerEntry: Equatable, Sendable {
    public var id: UUID
    public var vehicleID: UUID
    public var occurredAt: Date
    public var category: String
    public var costCents: Int

    public init(
        id: UUID = UUID(),
        vehicleID: UUID,
        occurredAt: Date,
        category: String,
        costCents: Int
    ) {
        self.id = id
        self.vehicleID = vehicleID
        self.occurredAt = occurredAt
        self.category = category
        self.costCents = costCents
    }
}

public struct ConfirmedMileageInterval: Equatable, Sendable {
    public var id: UUID
    public var vehicleID: UUID
    public var start: Date
    public var end: Date
    public var miles: Decimal

    public init(
        id: UUID = UUID(),
        vehicleID: UUID,
        start: Date,
        end: Date,
        miles: Decimal
    ) {
        precondition(start <= end, "ConfirmedMileageInterval start must be <= end")
        self.id = id
        self.vehicleID = vehicleID
        self.start = start
        self.end = end
        self.miles = miles
    }
}

public enum CostPerMileUnknownReason: String, Codable, CaseIterable, Sendable {
    case noOdometerConfirmedMiles = "no-odometer-confirmed-miles"
    case overlappingMileageIntervals = "overlapping-mileage-intervals"
}

public enum CostLedgerDerivationError: Error, Equatable, Sendable {
    case centsOverflow
}

public enum CostPerMileMeasurement: Equatable, Sendable {
    /// Cents per confirmed mile.
    case known(centsPerMile: Decimal)
    case unknown(reason: CostPerMileUnknownReason)
}

public struct CostDerivation: Equatable, Sendable {
    public var window: CostWindow
    public var categoryTotalsCents: [String: Int]
    public var totalCostCents: Int
    public var confirmedMiles: Decimal
    public var coveragePercent: Decimal
    public var costPerMile: CostPerMileMeasurement

    public init(
        window: CostWindow,
        categoryTotalsCents: [String: Int],
        totalCostCents: Int,
        confirmedMiles: Decimal,
        coveragePercent: Decimal,
        costPerMile: CostPerMileMeasurement
    ) {
        self.window = window
        self.categoryTotalsCents = categoryTotalsCents
        self.totalCostCents = totalCostCents
        self.confirmedMiles = confirmedMiles
        self.coveragePercent = coveragePercent
        self.costPerMile = costPerMile
    }
}

public enum CostLedgerEngine {
    public static func derive(
        vehicleID: UUID,
        window: CostWindow,
        costs: [CostLedgerEntry],
        mileage: [ConfirmedMileageInterval]
    ) throws -> CostDerivation {
        var categoryTotals: [String: Int] = [:]
        var totalCents: Int = 0

        for entry in costs where entry.vehicleID == vehicleID && window.contains(entry.occurredAt) {
            let (categoryTotal, categoryOverflow) = categoryTotals[entry.category, default: 0]
                .addingReportingOverflow(entry.costCents)
            let (newTotal, totalOverflow) = totalCents.addingReportingOverflow(entry.costCents)
            guard !categoryOverflow, !totalOverflow else {
                throw CostLedgerDerivationError.centsOverflow
            }
            categoryTotals[entry.category] = categoryTotal
            totalCents = newTotal
        }

        let matchingMileage = mileage
            .filter { interval in
                interval.vehicleID == vehicleID &&
                    interval.start >= window.start &&
                    interval.end <= window.end &&
                    interval.end > interval.start &&
                    interval.miles > .zero
            }
            .sorted {
                if $0.start == $1.start {
                    return $0.end < $1.end
                }
                return $0.start < $1.start
            }

        var previousEnd: Date?
        for interval in matchingMileage {
            if let end = previousEnd, interval.start < end {
                return CostDerivation(
                    window: window,
                    categoryTotalsCents: categoryTotals,
                    totalCostCents: totalCents,
                    confirmedMiles: .zero,
                    coveragePercent: .zero,
                    costPerMile: .unknown(reason: .overlappingMileageIntervals)
                )
            }
            previousEnd = interval.end
        }

        let confirmedMiles = matchingMileage.reduce(Decimal.zero) { $0 + $1.miles }

        let coveragePercent: Decimal
        let windowSeconds = Decimal(max(0, window.durationSeconds))
        if windowSeconds > .zero {
            let coveredSeconds = matchingMileage.reduce(Decimal.zero) { sum, interval in
                sum + Decimal(max(0, interval.end.timeIntervalSince(interval.start)))
            }
            coveragePercent = (coveredSeconds * decimal("100")) / windowSeconds
        } else {
            coveragePercent = .zero
        }

        let measurement: CostPerMileMeasurement
        if confirmedMiles > .zero {
            let cents = Decimal(totalCents)
            measurement = .known(centsPerMile: cents / confirmedMiles)
        } else {
            measurement = .unknown(reason: .noOdometerConfirmedMiles)
        }

        return CostDerivation(
            window: window,
            categoryTotalsCents: categoryTotals,
            totalCostCents: totalCents,
            confirmedMiles: confirmedMiles,
            coveragePercent: coveragePercent,
            costPerMile: measurement
        )
    }
}

// MARK: - Service Due Window Engine

public enum ServiceDueState: String, Codable, CaseIterable, Sendable {
    case ok
    case approaching
    case dueWindowOpen = "due-window-open"
    case unknown
}

public struct ServiceIntervalRule: Equatable, Sendable {
    public var category: String
    public var ruleText: String
    public var mileageInterval: Decimal?
    public var dayInterval: Int?
    public var approachingMileage: Decimal?
    public var approachingDays: Int?

    public init(
        category: String,
        ruleText: String,
        mileageInterval: Decimal?,
        dayInterval: Int?,
        approachingMileage: Decimal? = nil,
        approachingDays: Int? = nil
    ) {
        self.category = category
        self.ruleText = ruleText
        self.mileageInterval = mileageInterval
        self.dayInterval = dayInterval
        self.approachingMileage = approachingMileage
        self.approachingDays = approachingDays
    }
}

public struct ServiceIntervalAnchor: Equatable, Sendable {
    public var vehicleID: UUID
    public var occurredAt: Date
    public var odometer: Decimal?

    public init(vehicleID: UUID, occurredAt: Date, odometer: Decimal?) {
        self.vehicleID = vehicleID
        self.occurredAt = occurredAt
        self.odometer = odometer
    }
}

public struct UserServiceEvent: Equatable, Sendable {
    public var id: UUID
    public var vehicleID: UUID
    public var category: String
    public var occurredAt: Date
    public var odometer: Decimal?

    public init(
        id: UUID = UUID(),
        vehicleID: UUID,
        category: String,
        occurredAt: Date,
        odometer: Decimal?
    ) {
        self.id = id
        self.vehicleID = vehicleID
        self.category = category
        self.occurredAt = occurredAt
        self.odometer = odometer
    }
}

public struct ServiceDueDerivation: Equatable, Sendable {
    public var ruleText: String
    public var category: String
    public var state: ServiceDueState
    public var anchor: ServiceIntervalAnchor?
    public var dueMileage: Decimal?
    public var dueDate: Date?
    public var remainingMiles: Decimal?
    public var remainingDays: Int?

    public init(
        ruleText: String,
        category: String,
        state: ServiceDueState,
        anchor: ServiceIntervalAnchor?,
        dueMileage: Decimal?,
        dueDate: Date?,
        remainingMiles: Decimal?,
        remainingDays: Int?
    ) {
        self.ruleText = ruleText
        self.category = category
        self.state = state
        self.anchor = anchor
        self.dueMileage = dueMileage
        self.dueDate = dueDate
        self.remainingMiles = remainingMiles
        self.remainingDays = remainingDays
    }
}

public enum ServiceDueWindowEngine {
    public static func derive(
        rule: ServiceIntervalRule,
        vehicleID: UUID,
        anchor: ServiceIntervalAnchor?,
        currentOdometer: Decimal?,
        now: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> ServiceDueDerivation {
        guard let anchor = anchor, anchor.vehicleID == vehicleID else {
            return ServiceDueDerivation(
                ruleText: rule.ruleText,
                category: rule.category,
                state: .unknown,
                anchor: nil,
                dueMileage: nil,
                dueDate: nil,
                remainingMiles: nil,
                remainingDays: nil
            )
        }

        var mileageState: ServiceDueState?
        var mileageInvalid = false
        var dueMileage: Decimal?
        var remainingMiles: Decimal?

        if let intervalMiles = rule.mileageInterval {
            if intervalMiles <= .zero {
                // Non-positive user interval is not usable evidence.
                mileageState = .unknown
                mileageInvalid = true
            } else if let anchorOdo = anchor.odometer, let currentOdo = currentOdometer {
                if currentOdo < anchorOdo {
                    // Odometer rolled back relative to the anchor: unknown, never clamped.
                    mileageState = .unknown
                    mileageInvalid = true
                } else {
                    let target = anchorOdo + intervalMiles
                    dueMileage = target
                    let remaining = target - currentOdo
                    remainingMiles = remaining

                    if currentOdo >= target {
                        mileageState = .dueWindowOpen
                    } else if let approaching = rule.approachingMileage, remaining <= approaching {
                        mileageState = .approaching
                    } else {
                        mileageState = .ok
                    }
                }
            } else {
                mileageState = .unknown
            }
        }

        var dayState: ServiceDueState?
        var dayInvalid = false
        var dueDate: Date?
        var remainingDays: Int?

        if let intervalDays = rule.dayInterval {
            if intervalDays <= 0 {
                dayState = .unknown
                dayInvalid = true
            } else if let calculatedDueDate = calendar.date(byAdding: .day, value: intervalDays, to: anchor.occurredAt) {
                dueDate = calculatedDueDate
                let diffComponents = calendar.dateComponents([.day], from: now, to: calculatedDueDate)
                let diffDays = diffComponents.day ?? 0
                remainingDays = diffDays

                if now >= calculatedDueDate {
                    dayState = .dueWindowOpen
                } else if let approachingDays = rule.approachingDays, diffDays <= approachingDays {
                    dayState = .approaching
                } else {
                    dayState = .ok
                }
            } else {
                dayState = .unknown
            }
        }

        let combinedState: ServiceDueState
        if mileageInvalid || dayInvalid {
            combinedState = .unknown
        } else {
            switch (mileageState, dayState) {
            case (nil, nil):
                combinedState = .unknown
            case let (m?, nil):
                combinedState = m
            case let (nil, d?):
                combinedState = d
            case let (m?, d?):
                if m == .dueWindowOpen || d == .dueWindowOpen {
                    combinedState = .dueWindowOpen
                } else if m == .approaching || d == .approaching {
                    combinedState = .approaching
                } else if m == .unknown || d == .unknown {
                    combinedState = .unknown
                } else {
                    combinedState = .ok
                }
            }
        }

        return ServiceDueDerivation(
            ruleText: rule.ruleText,
            category: rule.category,
            state: combinedState,
            anchor: anchor,
            dueMileage: dueMileage,
            dueDate: dueDate,
            remainingMiles: remainingMiles,
            remainingDays: remainingDays
        )
    }

    public static func derive(
        rule: ServiceIntervalRule,
        vehicleID: UUID,
        serviceEvents: [UserServiceEvent],
        currentOdometer: Decimal?,
        now: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> ServiceDueDerivation {
        let matching = serviceEvents
            .filter { $0.vehicleID == vehicleID && $0.category == rule.category }
            .sorted {
                if $0.occurredAt == $1.occurredAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.occurredAt < $1.occurredAt
            }

        let latestAnchor = matching.last.map {
            ServiceIntervalAnchor(vehicleID: $0.vehicleID, occurredAt: $0.occurredAt, odometer: $0.odometer)
        }

        return derive(
            rule: rule,
            vehicleID: vehicleID,
            anchor: latestAnchor,
            currentOdometer: currentOdometer,
            now: now,
            calendar: calendar
        )
    }
}

private enum VolumeConverter {
    static let litresPerUSGallon = decimal("3.785411784")
    static let litresPerImperialGallon = decimal("4.54609")
    static let kmPerMile = decimal("1.609344")

    static func litres(from volume: Decimal, unit: PumpVolumeUnit) -> Decimal {
        switch unit {
        case .litre:
            return volume
        case .usGallon:
            return volume * litresPerUSGallon
        case .imperialGallon:
            return volume * litresPerImperialGallon
        }
    }

    static func usGallons(from volume: Decimal, unit: PumpVolumeUnit) -> Decimal {
        switch unit {
        case .usGallon:
            return volume
        case .litre, .imperialGallon:
            return litres(from: volume, unit: unit) / litresPerUSGallon
        }
    }

    static func imperialGallons(from volume: Decimal, unit: PumpVolumeUnit) -> Decimal {
        switch unit {
        case .imperialGallon:
            return volume
        case .litre, .usGallon:
            return litres(from: volume, unit: unit) / litresPerImperialGallon
        }
    }

    static func litres(fromUSGallons gallonsUS: Decimal) -> Decimal {
        gallonsUS * litresPerUSGallon
    }

    static func imperialGallons(fromUSGallons gallonsUS: Decimal) -> Decimal {
        litres(fromUSGallons: gallonsUS) / litresPerImperialGallon
    }
}

private func decimal(_ value: String) -> Decimal {
    guard let result = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
        preconditionFailure("invalid decimal literal: \(value)")
    }
    return result
}
