import Foundation

/// Issue #6 presentation helpers for stats screens.
///
/// Honesty doctrine: derivations render `unknown` with a named exclusion
/// reason rather than guessed numbers. These helpers are pure string
/// functions (Decimal/Date in, String out) so the honest formatting is
/// unit-tested on Linux CI, not only visually on the simulator.
///
/// Formatting rules:
/// - `unknown` never becomes an em dash or a made-up average.
/// - Fractions render via `NumberFormatter` percent style.
/// - Decimals render with a maximum of two fractional digits using the
///   POSIX locale so output is locale-stable for tests and VoiceOver.
public enum StatsPresentation {
    private static func maximumFractionDigits(_ value: Decimal) -> Int {
        var source = value
        var truncated = Decimal()
        NSDecimalRound(&truncated, &source, 0, .down)
        return truncated == value ? 0 : 2
    }

    /// Plain decimal string, up to two fractional digits, POSIX decimal point.
    public static func decimalString(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits(value)
        return formatter.string(from: NSDecimalNumber(decimal: value))
            ?? NSDecimalNumber(decimal: value).stringValue
    }

    /// Percent string for a 0–100 Decimal coverage value (e.g. 42.86 → "42.86%").
    public static func percentString(_ percent: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .percent
        formatter.usesGroupingSeparator = false
        formatter.multiplier = 1
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits(percent)
        return formatter.string(from: NSDecimalNumber(decimal: percent)).map { "\($0) coverage" }
            ?? "coverage-unknown"
    }

    public static func dollarsString(cents: Int) -> String {
        let dollars = Decimal(cents) / Decimal(100)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        // Manual $ prefix: ICU currency style injects a no-break space that
        // makes assertions (and VoiceOver text) locale-noisy.
        return "$" + (formatter.string(from: NSDecimalNumber(decimal: dollars)) ?? "?")
    }

    // MARK: - Economy

    public static func exclusionReasonLabel(_ reason: EconomyExclusionReason) -> String {
        switch reason {
        case .topoff: "excluded: top-off fill"
        case .partial: "excluded: partial or unknown fill"
        case .odometerMissing: "excluded: odometer missing"
        case .odometerNonincreasing: "excluded: odometer did not increase"
        case .vehicleBoundary: "excluded: vehicle boundary"
        }
    }

    public static func economyPointLabel(_ interval: EconomyInterval) -> String {
        "\(decimalString(interval.mpgUS)) MPG (US) · evidence: \(decimalString(interval.evidence.milesTravelled)) miles ÷ \(decimalString(interval.evidence.gallonsUsed)) US gallons"
    }

    public static func rollingWindowLabel(_ window: RollingEconomyWindow) -> String {
        guard window.sampleCount > 0 else {
            return "Last \(window.pairWindow) fills: unknown (insufficient-valid-full-fill-evidence, 0 samples)"
        }
        guard case let .known(mpgUS, mpgImperial, litresPer100km) = window.measurement else {
            return "Last \(window.pairWindow) fills: unknown (insufficient-valid-full-fill-evidence, \(window.sampleCount) samples)"
        }
        return "Last \(window.pairWindow) fills: \(decimalString(mpgUS)) MPG (US) · \(decimalString(mpgImperial)) MPG (imp) · \(decimalString(litresPer100km)) L/100km · \(window.sampleCount) samples"
    }

    public static func economySeriesLabel(_ derivation: EconomyDerivation) -> String {
        guard !derivation.intervals.isEmpty else {
            return "MPG unknown (insufficient-valid-full-fill-evidence): two qualifying full fills with increasing odometer miles are needed."
        }
        return "MPG: \(economyPointLabel(derivation.intervals[derivation.intervals.count - 1]))"
    }

    // MARK: - Cost per mile

    public static func costPerMileUnknownLabel(_ reason: CostPerMileUnknownReason) -> String {
        switch reason {
        case .noOdometerConfirmedMiles:
            "cost/mile unknown (no-odometer-confirmed-miles)"
        case .overlappingMileageIntervals:
            "cost/mile unknown (overlapping-mileage-intervals)"
        }
    }

    /// Cost/mile with coverage % stated in text, per the honesty doctrine.
    public static func costPerMileLabel(_ derivation: CostDerivation) -> String {
        let coverage = percentString(derivation.coveragePercent)
        switch derivation.costPerMile {
        case let .known(centsPerMile):
            return "\(decimalString(centsPerMile)) cents per confirmed mile · \(coverage)"
        case let .unknown(reason):
            return "\(costPerMileUnknownLabel(reason)) · \(coverage)"
        }
    }

    public static func categoryTotalLabel(category: String, cents: Int) -> String {
        "\(category): \(dollarsString(cents: cents))"
    }

    // MARK: - Service due windows

    public static func serviceDueLabel(_ derivation: ServiceDueDerivation) -> String {
        switch derivation.state {
        case .ok:
            var parts: [String] = ["\(derivation.category): not due"]
            if let miles = derivation.remainingMiles { parts.append("\(decimalString(miles)) miles remaining") }
            if let days = derivation.remainingDays { parts.append("\(days) days remaining") }
            if let anchor = derivation.anchor {
                let odometer = anchor.odometer.map { " at \(decimalString($0)) miles" } ?? ""
                parts.append("rule: \(derivation.ruleText) · anchored \(formattedDate(anchor.occurredAt))\(odometer)")
            }
            return parts.joined(separator: " · ")
        case .approaching:
            var parts: [String] = ["\(derivation.category): approaching due window"]
            if let miles = derivation.remainingMiles { parts.append("\(decimalString(miles)) miles remaining") }
            if let days = derivation.remainingDays { parts.append("\(days) days remaining") }
            if let anchor = derivation.anchor {
                let odometer = anchor.odometer.map { " at \(decimalString($0)) miles" } ?? ""
                parts.append("rule: \(derivation.ruleText) · anchored \(formattedDate(anchor.occurredAt))\(odometer)")
            }
            return parts.joined(separator: " · ")
        case .dueWindowOpen:
            var parts: [String] = ["\(derivation.category): due window open"]
            // Only axes that are actually due get a "past due" clause, and the
            // magnitude is rendered unsigned (remaining values are signed).
            if let miles = derivation.remainingMiles, miles <= .zero {
                parts.append("past due by \(StatsPresentation.decimalString(-miles)) miles")
            }
            if let days = derivation.remainingDays, days <= 0 {
                parts.append("past due by \(-days) days")
            }
            parts.append("rule: \(derivation.ruleText)")
            return parts.joined(separator: " · ")
        case .unknown:
            return "\(derivation.category): unknown (insufficient user-owned anchor or current odometer) · rule: \(derivation.ruleText)"
        }
    }

    // MARK: - Dates

    public static func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func windowLabel(_ window: CostWindow) -> String {
        "\(formattedDate(window.start)) → \(formattedDate(window.end))"
    }
}
