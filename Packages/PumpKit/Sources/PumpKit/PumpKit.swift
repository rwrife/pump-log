/// PumpKit — pure-domain core for Pump Log.
///
/// Issue #1 ships only the skeleton namespace so CI has a real, testable
/// target. Issue #3 lands the full-to-full economy engine here (pairs,
/// named exclusion reasons, rolling windows, per-interval evidence) and
/// issue #4 the cost aggregation and service due-window derivation, all in
/// pure Swift with swift-testing coverage on Linux CI. The GRDB store is
/// issue #2 (PumpStore) and lives outside this package.
public enum PumpKit {
    /// Namespace marker for the domain layer.
    public static let domain = "PumpKit"

    /// Current build/CI milestone marker consumed by the app's debug surface.
    public static let milestone = "M0-skeleton"
}
