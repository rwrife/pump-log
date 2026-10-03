# Dual-screen migration contract (issue #6)

Pump Log is an iPhone-only app. There is no fold SDK, no companion-screen
dependency, and no stubbed hardware API anywhere in this repository. This
document records the *only* seam that future dual-screen work must go
through, so "iPhone Duo support" stays a design decision rather than a
build-time assumption baked into today's screens.

## The seam: `FuelWorkspaceLayout`

Defined in `App/FuelWorkspaceLayout.swift`:

- `WorkspaceKind` names the two worlds: `compactSinglePane` (shipped) and
  `compactDualScreenCompanion` (reserved; **no shipped implementation**).
- `FuelWorkspaceLayout` is the protocol every stats/ledger surface asks
  about. Today exactly one type conforms:
  `CompactSinglePaneFuelWorkspaceLayout`.
- `VehicleDetailView` holds `let workspaceLayout: any FuelWorkspaceLayout`
  and initializes it with the compact single-pane layout. Screens render
  identically to today; the seam is consulted, not branched on.

Adding a second conformance is the *first* step of any future dual-screen
effort — screens should never check device class, screen count, or SDK
symbols directly.

## Adapter contract for a future iPhone Duo companion

Any future companion-screen adapter must provide, at minimum:

1. **Persistent quick-log companion pane.** The fill/service quick-entry
   sheet content (`EntrySheets.swift`) renders as a persistent secondary
   surface that survives primary-screen navigation. Entry validation stays
   in `QuickLogWorkflow`; the pane must not duplicate parsing.
2. **Spanned ledger/trends.** The fills ledger and stats screens
   (`EconomyStatsView`, `CostStatsView`) may span both screens, but every
   value still comes from `PumpKit` derivations + `StatsPresentation`.
   No new derivation math may appear in the adapter.
3. **Selection and scroll continuity.** Selecting a fill on one screen and
   continuing to scroll on the other keeps one authoritative selection +
   scroll position per ledger. Selection is app state, not per-screen
   state; the adapter only forwards events into the shared models.
4. **Accessibility parity.** Rotors, Dynamic Type up to AX sizes, and the
   `unknown` + named-exclusion doctrine carry over unchanged. A companion
   pane that clips AX text is a blocking defect, not a polish item.

## Explicit non-goals (binding)

- No fold SDK frameworks are referenced, imported, or stubbed — in code,
  docs, CI, or issues.
- No iPad behavior: `TARGETED_DEVICE_FAMILY` stays `1` in every app-target
  configuration (asserted by `Scripts/ci.sh` and the Apple CI job).
- No `tablet-friendly` layout branches. If a second screen ever ships, it
  arrives as a new `FuelWorkspaceLayout` implementation through this seam,
  with explicit user opt-in per the product contract.
- Zero-network stays true by construction; a companion pane introduces no
  network APIs.

## Migration rule for today's code

Any new screen takes the layout as an injected `any FuelWorkspaceLayout`
(defaulting to `CompactSinglePaneFuelWorkspaceLayout()`) instead of
hardcoding a single-pane assumption. This is why `VehicleDetailView`
already receives the seam even though only one implementation exists.
