import Foundation
import PumpKit
import PumpStore
import SwiftUI

/// Economy stats screen (issue #6): per-fill MPG point series, rolling
/// windows with sample counts, and every excluded interval with its named
/// exclusion reason. All strings come from `StatsPresentation` so the honest
/// `unknown` doctrine is unit-tested in PumpKit on Linux CI.
///
/// VoiceOver: dedicated rotors ("MPG points", "Exclusions") let listeners step
/// evidence-by-evidence. Rows are plain List text (no fixed frames), so
/// Dynamic Type up to AX sizes wraps without clipping.
///
/// Layout seam: the screen receives `any FuelWorkspaceLayout` and switches on
/// `workspaceKind`. Only `.compactSinglePane` ships today; the future
/// companion-screen layout plugs in here without hardware checks
/// (docs/dual-screen.md).
struct EconomyStatsView: View {
    private struct RotorItem: Identifiable, Hashable {
        let id: Int
        let label: String
    }

    let stats: VehicleStats
    let workspaceLayout: any FuelWorkspaceLayout

    init(stats: VehicleStats, workspaceLayout: any FuelWorkspaceLayout = CompactSinglePaneFuelWorkspaceLayout()) {
        self.stats = stats
        self.workspaceLayout = workspaceLayout
    }

    var body: some View {
        switch workspaceLayout.workspaceKind {
        case .compactSinglePane:
            compactSinglePane
        case .compactDualScreenCompanion:
            // No companion implementation ships (docs/dual-screen.md); an
            // unknown kind must not render a half-built layout, so the single
            // pane remains the safe fallback.
            compactSinglePane
        }
    }

    private var compactSinglePane: some View {
        List {
            if stats.economy.intervals.isEmpty {
                Section("MPG") {
                    Text(StatsPresentation.economySeriesLabel(stats.economy))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("economy.unknown")
                }
            }
            if !stats.economy.intervals.isEmpty {
                Section("MPG points") {
                    ForEach(pointItems) { item in
                        Text(verbatim: item.label)
                            .accessibilityIdentifier("economy.point.\(item.id)")
                    }
                }
                Section("Rolling windows") {
                    ForEach([stats.economy.rolling3, stats.economy.rolling5, stats.economy.rolling10], id: \.pairWindow) { window in
                        Text(StatsPresentation.rollingWindowLabel(window))
                            .accessibilityIdentifier("economy.window.\(window.pairWindow)")
                    }
                }
            }
            Section("Excluded intervals") {
                if stats.economy.exclusions.isEmpty {
                    Text("No excluded intervals.")
                        .accessibilityIdentifier("economy.exclusions.none")
                } else {
                    ForEach(exclusionItems) { item in
                        Text(verbatim: item.label)
                            .accessibilityIdentifier("economy.exclusion.\(item.id)")
                    }
                }
            }
        }
        .navigationTitle("Economy stats")
        // Rotor builder overload (iOS 15+): the selection-binding spelling does
        // not exist in the iOS 26 SDK (verified by the Apple runner's compiler
        // — only `accessibilityRotor(_:textRanges:)` matches 2-arg form).
        .accessibilityRotor("MPG points") {
            ForEach(pointItems) { item in
                AccessibilityRotorEntry(Text(verbatim: item.label), id: item.id)
            }
        }
        .accessibilityRotor("Exclusions") {
            ForEach(exclusionItems) { item in
                AccessibilityRotorEntry(Text(verbatim: item.label), id: item.id)
            }
        }
    }

    private var pointItems: [RotorItem] {
        stats.economy.intervals.enumerated().map { index, interval in
            RotorItem(id: index, label: pointLabel(index: index, interval: interval))
        }
    }

    private var exclusionItems: [RotorItem] {
        stats.economy.exclusions.enumerated().map { index, exclusion in
            RotorItem(id: index, label: exclusionLabel(exclusion))
        }
    }

    private func pointLabel(index: Int, interval: EconomyInterval) -> String {
        let date = stats.fillDatesByID[interval.evidence.endFillID].map { StatsPresentation.formattedDate($0) + " · " } ?? ""
        return "\(date)\(StatsPresentation.economyPointLabel(interval))"
    }

    private func exclusionLabel(_ exclusion: EconomyExclusion) -> String {
        let date = stats.fillDatesByID[exclusion.fillID].map { StatsPresentation.formattedDate($0) + " · " } ?? ""
        return "\(date)\(StatsPresentation.exclusionReasonLabel(exclusion.reason))"
    }
}

/// Cost stats screen (issue #6): per-category totals and cost/mile with the
/// coverage percentage stated in text — never implied by a lone number.
struct CostStatsView: View {
    private struct RotorItem: Identifiable, Hashable {
        let id: Int
        let label: String
    }

    let stats: VehicleStats
    let workspaceLayout: any FuelWorkspaceLayout

    init(stats: VehicleStats, workspaceLayout: any FuelWorkspaceLayout = CompactSinglePaneFuelWorkspaceLayout()) {
        self.stats = stats
        self.workspaceLayout = workspaceLayout
    }

    var body: some View {
        switch workspaceLayout.workspaceKind {
        case .compactSinglePane, .compactDualScreenCompanion:
            // Only the single pane ships; see docs/dual-screen.md.
            compactSinglePane
        }
    }

    private var compactSinglePane: some View {
        Group {
            if let cost = stats.cost {
                List {
                    Section("Window") {
                        Text(StatsPresentation.windowLabel(cost.window))
                            .accessibilityIdentifier("cost.window")
                    }
                    Section("Per-category totals") {
                        ForEach(sortedCategories, id: \.key) { category, cents in
                            Text(StatsPresentation.categoryTotalLabel(category: category, cents: cents))
                                .accessibilityIdentifier("cost.category.\(category)")
                        }
                        Text("All categories: \(StatsPresentation.dollarsString(cents: cost.totalCostCents))")
                            .accessibilityIdentifier("cost.total")
                    }
                    Section("Cost per mile") {
                        Text(StatsPresentation.costPerMileLabel(cost))
                            .accessibilityIdentifier("cost.permile")
                        Text("Confirmed odometer miles: \(StatsPresentation.decimalString(cost.confirmedMiles))")
                            .accessibilityIdentifier("cost.confirmed-miles")
                    }
                }
                .navigationTitle("Cost stats")
                .accessibilityRotor("Categories") {
                    ForEach(categoryItems) { item in
                        AccessibilityRotorEntry(Text(verbatim: item.label), id: item.id)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No ledger entries yet",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Log a fill or service to see cost totals.")
                )
                .navigationTitle("Cost stats")
            }
        }
    }

    private var sortedCategories: [(key: String, value: Int)] {
        (stats.cost?.categoryTotalsCents ?? [:]).sorted { $0.key < $1.key }
    }

    private var categoryItems: [RotorItem] {
        sortedCategories.enumerated().map { index, pair in
            RotorItem(id: index, label: StatsPresentation.categoryTotalLabel(category: pair.key, cents: pair.value))
        }
    }
}
