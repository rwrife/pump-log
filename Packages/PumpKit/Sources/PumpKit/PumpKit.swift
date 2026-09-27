import Foundation

/// PumpKit — pure-domain core for Pump Log.
///
/// Issue #3 implements deterministic, unknown-safe fuel economy derivation:
/// - intervals only between consecutive valid full fills
/// - named exclusion reasons for skipped fills
/// - rolling windows with explicit sample counts and unknown state
/// - per-interval evidence for UI surfaces
public enum PumpKit {
    /// Namespace marker for the domain layer.
    public static let domain = "PumpKit"

    /// Current milestone marker consumed by the app bootstrap surface.
    public static let milestone = "M3-economy-engine"
}

public enum PumpVolumeUnit: String, Codable, CaseIterable {
    case usGallon = "us_gallon"
    case imperialGallon = "imperial_gallon"
    case litre = "litre"
}

public enum PumpClassification: String, Codable, CaseIterable {
    case full
    case partial
    case topoff
    case unknown
}

public struct FuelFillEvent: Equatable {
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

public enum EconomyExclusionReason: String, Codable, CaseIterable {
    case topoff
    case partial
    case odometerMissing = "odometer-missing"
    case odometerNonincreasing = "odometer-nonincreasing"
    case vehicleBoundary = "vehicle-boundary"
}

public struct EconomyExclusion: Equatable {
    public var fillID: UUID
    public var vehicleID: UUID
    public var reason: EconomyExclusionReason

    public init(fillID: UUID, vehicleID: UUID, reason: EconomyExclusionReason) {
        self.fillID = fillID
        self.vehicleID = vehicleID
        self.reason = reason
    }
}

public struct EconomyIntervalEvidence: Equatable {
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

public struct EconomyInterval: Equatable {
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

public enum EconomyMeasurement: Equatable {
    case known(mpgUS: Decimal, mpgImperial: Decimal, litresPer100km: Decimal)
    case unknown
}

public struct RollingEconomyWindow: Equatable {
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

public struct EconomyDerivation: Equatable {
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
