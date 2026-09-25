# Pump Log

**Local-first iPhone fuel log: honest MPG from full-tank fills, odometer-gap math with unknown-safe gaps, service and expense ledgers, and cost-per-mile trends — no accounts, no cloud.**

## Overview

Pump Log is a native Swift iPhone app for people who fill up their own car and want the
two numbers every driver secretly wants — *how efficient is this car, really?* and *what is
each mile actually costing me?* — without installing an ad-laden fuel-social-network, an
account, or a cloud sync subscription.

Every figure Pump Log shows is derived deterministically from fills and events **you**
entered, and every derivation states its evidence: a MPG number is only computed from
proper full-tank-to-full-tank pairs, a gap with a missing or top-off fill is `unknown`,
never guessed. Costs are stored as integer cents. The app performs zero network requests.

**One-sentence pitch:** Pump Log gives car owners honest fuel-economy and cost-per-mile
numbers from their own fill-ups and service receipts, entirely on-device — no accounts,
no cloud, no ads, no subscriptions.

## Motivation

The popular fuel-log apps on the App Store (Fuelio-style, Drivvo-style, subscription
mileage trackers) are chart-toppers for a reason: drivers genuinely want MPG and
cost-per-mile tracking. But they typically ship with accounts, cloud sync, ads, premium
paywalls, GPS trip auto-tracking (a permission-heavy background location posture), and
MPG math that silently averages over partial and top-off fills — producing numbers that
look precise but are wrong. Pump Log takes the offline-privacy-first derivative angle:
the same core value, stripped to one job done honestly — full-tank math with
unknown-safe gaps, everything local.

## Target users

- Daily drivers who want to know real MPG and cost per mile for their car.
- Used-car buyers/sellers who want a private fuel + service history record.
- Commuters comparing car-vs-commute economics on their own data.
- Households with two or more vehicles tracking each separately.

## Concrete use cases

1. **Pump-side quick log.** At the pump, one thumb: odometer, gallons, price, pump
   locked-or-unlocked flag. After two proper full-tank fills, the card shows a
   provisional MPG; after four, a rolling average with a sample count.
2. **Honest economy check.** A winter drop or a new set of tires shows as an honest
   trend line over per-fill MPG points — computed only from valid full-to-full pairs,
   with each interval showing its evidence (start/end fill ids, gallons, distance).
3. **True cost per mile.** Fuel + service + user-tagged fees (registration, tolls as
   ledger events) divided by odometer-confirmed distance, rendered with explicit
   coverage ("costs cover 84% of mileage window by date").
4. **Service ledger with user-owned intervals.** "Oil changed at 92,140 mi" plus a
   *user-entered* interval (not a maintenance database) surfaces a gentle "due
   window" reminder — clearly framed as the user's own rule, not vehicle advice.
5. **Vehicle sale packet.** Export a per-vehicle chronological fuel + service history
   as CSV/JSON to hand a buyer.

## How to use (intended end-to-end workflow)

1. Add a vehicle (nickname, plate-optional note, unit prefs: US gal / L, °F/°C).
2. At each fill: tap **Log fill** → odometer, gallons, total price, pump full-auto
   stop or not. Partial fills and top-offs are still logged and honestly excluded
   from economy math.
3. Optionally log service events and fees with integer-cent costs and odometer.
4. Browse per-vehicle screens: economy (per-fill MPG series + rolling window),
   cost ledger (per-category totals, cost/mile with coverage), service list with
   user-owned due windows.
5. Back up any time via Files-app JSON export (versioned, previewed restore) and CSV
   export of fills/service for spreadsheets.

## MVP feature list

- Vehicle registry (multiple vehicles, per-vehicle unit preferences).
- Append-only fill ledger: odometer, volume, integer-cent cost, pump full-stop flag,
  partial/top-off classification, notes, photo-free.
- Append-only service/fee ledger: category, user-owned interval rule, integer-cent
  cost, odometer, date.
- Deterministic economy engine: full-to-full MPG pairs only; unknown-safe gaps with
  named exclusion reasons (top-off, missing odometer, replaced vehicle, odometer
  rollback); rolling 3/5/10-fill windows with sample counts.
- Cost engine: cents-only arithmetic, cost-per-mile with explicit mileage-coverage
  percentage, never extrapolated.
- Local notifications for user-defined service due windows (opt-in permission).
- Versioned JSON backup/restore via Files app (previewed replace) + CSV export.
- Accessibility: Dynamic Type, VoiceOver labels on all ledger rows and stats cards,
  full keyboard/switch entry for numeric fields.

## Non-goals (explicit)

- No cross-platform or hybrid frameworks: no Flutter, React Native, Expo,
  Kotlin Multiplatform, .NET MAUI, Unity, or equivalents. Native Swift (SwiftUI/UIKit) only.
- No Android and no native iPad support (iPhone-only, `TARGETED_DEVICE_FAMILY = 1`;
  iPad requires explicit user opt-in).
- No accounts, cloud sync, server backend, analytics, ads, trackers, or subscriptions.
  Zero network requests by construction, CI-gated.
- No GPS/background-location trip auto-detection; odometer is user-entered.
- No receipt OCR, plate scanning, or label photos.
- No maintenance-database or repair-advice content; intervals are the user's own
  rules echoed back verbatim. No safety-inspection or roadworthiness claims.
- No tax-authority (IRS/HMRC) reimbursement exports or legal-rate claims.
- No fuel-price crowdsourcing maps or station ratings.
- No driving-behavior scoring, insurance telematics, or health claims.

## Privacy, permissions, and data storage

- **Storage:** app-private SQLite (GRDB) store; all data stays on device.
- **Network:** none. A CI gate asserts no networking API usage.
- **Permissions:** notifications only (opt-in, for user-defined service windows).
  No location, camera, contacts, or HealthKit.
- **Export/backup:** user-initiated JSON (versioned schema, previewed restore) and CSV
  via the Files app; nothing leaves the device without an explicit export action.
- **Deletion:** per-vehicle and per-ledger delete with confirmation; full-wipe in app
  settings.

## iPhone Duo dual-screen design target

The dual-screen experience is a **documented design target with a migration path**, not
a current dependency — no foldable SDK APIs are used or assumed today.

- **Value story:** at the pump, one screen holds the one-thumb quick-log entry surface
  while the other shows the live economy card (last valid MPG, rolling window, this
  fill's odometer delta) — confirmation without context switching. In the driveway,
  the unfolded layout spans the ledger editor beside the trend charts.
- **Build shape today:** standard SwiftUI iPhone app, iPad support disabled by
  default. All layout passes through a single `FuelWorkspaceLayout` seam that today
  renders single-pane; when native dual-screen APIs mature, only that seam changes.
- **Migration path:** documented in the backlog (issue #5) — selection/scroll
  continuity contract, quick-log surface as the persistent companion pane.

## Current status & milestones

**Status: native skeleton landed.** `PumpLog.xcodeproj`, the pure-Swift
`Packages/PumpKit` package, pinned Linux + macOS CI, and the launch XCUITest
smoke exist. No product features, archive, or TestFlight binary yet.

1. ✅ Repo scaffold (docs, toolchain pin, backlog).
2. ✅ Swift package domain core (PumpKit) + skeleton app + pinned CI (issue #1).
3. GRDB store + migrations + fixtures (issue #2).
4. Fill/service ledgers + economy/cost engines with unknown-safe semantics (issues #3–4).
5. Accessible UI + workspace layout seam (issues #5–6).
6. Backup/export + TestFlight release with real evidence (issue #7).

## Development / build quickstart

- **Platform:** native Swift (SwiftUI) iPhone-only iOS app; iOS 26 SDK or newer
  (pinned Xcode 26.0.1 / 17A400 / iOS SDK 26.0 / Swift 6 mode — see `toolchain.json`).
  An exact-pin Apple runner is a hard gate; missing pin is an environment blocker.
- **Bundle ID:** `com.infinityball.pumplog` (registered in App Store Connect), used as
  `PRODUCT_BUNDLE_IDENTIFIER` in every app-target configuration.
- **Device family:** `TARGETED_DEVICE_FAMILY = 1` in all configurations; built app
  `UIDeviceFamily` must verify `[1]` on an Apple runner.
- **Module plan:** pure-Swift `PumpKit` (economy/cost engines, backup codec) + `PumpStore`
  (GRDB) + thin SwiftUI app target; `swift test` runs the domain core on Linux CI.
- Release: TestFlight via App Store Connect API using repository Actions secrets
  `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID` (names only — values are
  never stored in this repository).

## License

MIT — see [LICENSE](LICENSE).
