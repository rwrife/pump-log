# Pump Log — PLAN

## Scope

Pump Log is an iPhone-only, native Swift, zero-network fuel-economy and vehicle-cost
ledger. Core objects:

- **Vehicle** — nickname, units (US gal / imperial / litre; °F/°C), odometer unit,
  created/retired dates.
- **FillEvent** (append-only) — vehicle, timestamp, odometer (optional but required
  for economy math), volume (decimal + unit), integer-cent total cost, pump
  full-auto-stop flag (`full` / `partial` / `topoff` / `unknown`), station note
  (free text, no lookup).
- **ServiceEvent** (append-only) — vehicle, category (user-editable list), optional
  user-owned interval rule (every N miles and/or M days, both optional), integer-cent
  cost, odometer, date, note.
- Derived, never stored as truth: per-fill economy pairs, rolling windows,
  cost-per-mile with coverage, due windows.

Out of scope: everything in README "Non-goals" (accounts, network, GPS, OCR, tax
exports, maintenance-database content, repair advice, Android, iPad, and all
cross-platform/hybrid frameworks — no Flutter, React Native, Expo, Kotlin
Multiplatform, .NET MAUI, Unity).

## Architecture

```
PumpLogApp (SwiftUI, thin) 
  ├── PumpKit        — pure Swift package, no UIKit: models, economy engine,
  │                   cost engine, due-window derivation, backup codec (v1)
  ├── PumpStore      — SwiftPM package: GRDB, schema migrations, fixture DB
  └── PumpKitTests / PumpStoreTests (swift-testing, run on Linux CI)
```

- **Single source of truth:** SQLite via GRDB; ledgers are append-only — edits are
  versioned correction events referencing the original, so derivation history is
  replayable and backups are lossless.
- **Economy engine (PumpKit):** an economy interval exists only between two
  consecutive `full` fills with valid increasing odometer deltas; gallons used = the
  second fill's volume. Every non-pair yields a named exclusion (`topoff`,
  `partial`, `odometer-missing`, `odometer-nonincreasing`, `vehicle-boundary`).
  Rolling windows (3/5/10 valid pairs) report sample count and never pad with
  guesses. Unit conversion is exact rationals at the boundary; internal math in
  decimal + integer cents.
- **Cost engine:** cost/mile = Σ(integer-cent costs in window) ÷ odometer-confirmed
  miles in window; render with explicit coverage % and "unknown" when denominator is
  zero/unknown. No proration, no interpolation.
- **Due windows:** from the user's own interval rule anchored at the last matching
  service event; state ∈ {ok, approaching, due-window-open, unknown}; echo the rule
  text verbatim — the app never supplies maintenance knowledge.
- **`FuelWorkspaceLayout`** seam: single SwiftUI layout strategy protocol; today only
  a compact single-pane implementation ships. The dual-screen (iPhone Duo) adapter —
  persistent quick-log companion pane + spanned ledger/trends — lands only when
  native fold APIs are available; the seam keeps selection/scroll continuity the
  contract. No fold SDK dependency exists or is stubbed.

## Technology choices (rationale)

| Choice | Rationale |
|---|---|
| SwiftUI + UIKit escape hatches | User directive: native Swift only; SwiftUI first-class for accessible dynamic lists. |
| iOS 26 SDK, Xcode 26.0.1 (17A400), Swift 6 | Tool-lab platform floor + strict-concurrency safety for the pure core. |
| GRDB (SQLite) | Proven local-first store used across the fleet; versioned migrations + fixture DBs. |
| swift-testing in pure packages | Runs on Linux CI without Xcode; keeps domain honest off-Apple. |
| Zero-network by construction | Privacy default + CI grep gate on URLSession/Network/bonjour symbols. |
| `com.infinityball.pumplog` | Account bundle-prefix convention; already registered in App Store Connect. |
| `TARGETED_DEVICE_FAMILY = 1` | iPhone-only directive; CI greps pbxproj and verifies built `UIDeviceFamily == [1]`. |

## Milestones & dependency order

1. **M1 Skeleton + CI** (issue #1): Xcode project, PumpKit empty core, pinned macOS
   runner asserting exact Xcode build, Linux `swift test`, iPhone-only grep guard,
   zero-network gate.
2. **M2 Store** (issue #2): GRDB schema v1 (vehicles, fills, service_events,
   corrections), migrator, committed fixture DB, repository protocols + fakes.
3. **M3 Domain engines** (issue #3): economy pairing, exclusion taxonomy, rolling
   windows, cost/coverage, due windows — table-driven tests incl. DST/timezone and
   unit-conversion cases.
4. **M4 Primary workflow UI** (issue #4): quick-log fill entry (one-thumb), ledger
   list with correction flow, vehicle management.
5. **M5 Accessible UI + layout seam** (issues #5–6): VoiceOver/Dynamic Type pass,
   stats cards, `FuelWorkspaceLayout` compact impl + documented dual-screen
   migration contract.
6. **M6 Backup/export + release** (issue #7): versioned JSON backup (previewed
   restore), CSV exports, TestFlight upload via ASC secrets with real processed-build
   evidence.

## Testing strategy

- **Domain:** property-style table tests in PumpKit on Linux CI — every exclusion
  reason reachable; unknown-safe derivation canary tests (a ledger with a hole must
  produce `unknown`, never a number).
- **Store:** migration up/down fixtures; byte-stable fixture DB regeneration script.
- **UI:** XCUITest journeys on pinned macOS runner for the fill-log → ledger →
  stats path; identifier-stable controls (learned fleet pitfalls: no Section-level
  identifiers, toggle-row taps target nested `switches`).
- **Contract gates:** iPhone-only pbxproj grep + built-plist `UIDeviceFamily [1]`;
  zero-network symbol gate; toolchain.json exact-pin assertion.
- No claim of device/archive/TestFlight success without raw evidence.

## Packaging / distribution

- Ad-hoc internal TestFlight only for MVP: `xcodebuild archive` + `-exportArchive`
  with `app-store-connect` upload method, signing via ASC API key secrets
  (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID` — names only),
  `CURRENT_PROJECT_VERSION=$GITHUB_RUN_NUMBER`, poll builds until
  `processingState=COMPLETE` and record the build id.
- Public App Store submission is a post-MVP human decision, not an executor goal.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Users expect auto MPG without discipline | Honest-empty states: engine explains *why* no MPG yet (named exclusions), never fakes a number. |
| Odometer typos poison math | Delta sanity band with user confirmation prompt; non-increasing odometers are excluded, not clamped. |
| GRDB cross-platform compile friction | Fleet-proven pinning recipe (GRDB ≥7.10 on Linux) + sqlite dev package in CI. |
| Fold hype pressure | Single layout seam; dual-screen stays documentation until real SDK support. |
| Scope creep to GPS/tax/OCR | Non-goals list in README + executor treats contract regressions as blocking defects. |

## Explicit non-goals

Same as README "Non-goals" (verbatim enumeration there), including: no Flutter,
React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity; no Android; no native
iPad support without explicit user opt-in; no network, accounts, ads, or
subscriptions; no location permissions; no OCR; no tax exports; no repair advice.
