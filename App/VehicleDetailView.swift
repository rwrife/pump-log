import Foundation
import PumpKit
import PumpStore
import SwiftUI

struct VehicleDetailView: View {
    let workflow: QuickLogWorkflow
    let vehicle: Vehicle
    // MainActor + Sendable for Swift 6 language mode: View implies Sendable
    // on the iOS 26 SDK, and callers pass MainActor-isolated reload closures.
    let onRetire: @MainActor @Sendable () -> Void
    // Issue #6 layout seam: the compact single-pane layout is the only shipped
    // implementation; see App/FuelWorkspaceLayout.swift and docs/dual-screen.md.
    let workspaceLayout: any FuelWorkspaceLayout
    @State private var fills: [FillEvent] = []
    @State private var services: [ServiceEvent] = []
    @State private var economy: EconomyDerivation?
    @State private var stats: VehicleStats?
    @State private var retired = false
    @State private var showingFill = false
    @State private var showingService = false
    @State private var selectedFill: FillEvent?
    @State private var selectedService: ServiceEvent?
    @State private var showingRetire = false
    @State private var errorText: String?

    init(workflow: QuickLogWorkflow, vehicle: Vehicle, onRetire: @escaping @MainActor @Sendable () -> Void, workspaceLayout: any FuelWorkspaceLayout = CompactSinglePaneFuelWorkspaceLayout()) {
        self.workflow = workflow
        self.vehicle = vehicle
        self.onRetire = onRetire
        self.workspaceLayout = workspaceLayout
    }

    private var economyStats: VehicleStats {
        stats ?? VehicleStats(economy: EconomyDerivation(intervals: [], exclusions: [], rolling3: .empty(window: 3), rolling5: .empty(window: 5), rolling10: .empty(window: 10)), cost: nil, serviceDue: [])
    }

    var body: some View {
        List {
            Section("Economy") {
                if let interval = economy?.intervals.last {
                    Text("\(format(interval.mpgUS)) MPG (US)")
                        .font(.title2.bold())
                        .accessibilityIdentifier("economy.mpg")
                    Text("Evidence: \(format(interval.evidence.milesTravelled)) miles ÷ \(format(interval.evidence.gallonsUsed)) US gallons; fills \(interval.evidence.startFillID.uuidString) → \(interval.evidence.endFillID.uuidString)")
                        .font(.caption)
                        .accessibilityIdentifier("economy.evidence")
                } else {
                    Text("MPG unknown (\(economy?.exclusions.last?.reason.rawValue ?? "insufficient-valid-full-fill-evidence")): two qualifying full fills with increasing odometer miles are needed.")
                        .accessibilityIdentifier("economy.unknown")
                }
                NavigationLink { EconomyStatsView(stats: economyStats, workspaceLayout: workspaceLayout) } label: {
                    Text("Economy stats")
                }
                .accessibilityIdentifier("stats-link.economy")
                NavigationLink { CostStatsView(stats: economyStats, workspaceLayout: workspaceLayout) } label: {
                    Text("Cost stats")
                }
                .accessibilityIdentifier("stats-link.cost")
            }
            if let stats, !stats.serviceDue.isEmpty {
                Section("Service due windows") {
                    ForEach(Array(stats.serviceDue.enumerated()), id: \.element.category) { index, due in
                        Text(StatsPresentation.serviceDueLabel(due))
                            // service.due.* would collide with service.* row queries.
                            .accessibilityIdentifier("servicedue.row.\(index)")
                    }
                }
            }
            Section("Fills") {
                ForEach(fills, id: \.id) { fill in
                    Button {
                        selectedFill = fill
                    } label: {
                        VStack(alignment: .leading) {
                            Text("\(format(fill.odometerDecimal ?? 0)) miles · \(fill.pumpClassification.rawValue)")
                            Text("\(format(fill.volumeDecimal)) US gallons · \(money(fill.costCents))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let original = try? workflow.store.fills.event(id: fill.id), original != fill {
                                Text("Corrected version \((try? workflow.store.corrections.corrections(fillEventID: fill.id).last?.version) ?? 1) · original: \(format(original.odometerDecimal ?? 0)) miles, \(format(original.volumeDecimal)) US gallons, \(money(original.costCents))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("fill.\(fill.id.uuidString)")
                }
            }
            Section("Service") {
                ForEach(services, id: \.id) { event in
                    Button { selectedService = event } label: {
                        VStack(alignment: .leading) {
                            Text(event.category)
                            Text(money(event.costCents)).font(.caption).foregroundStyle(.secondary)
                            if let original = try? workflow.store.service.event(id: event.id), original != event {
                                Text("Corrected version \((try? workflow.store.corrections.corrections(serviceEventID: event.id).last?.version) ?? 1) · original category: \(original.category)").font(.caption)
                            }
                        }
                    }
                    .accessibilityIdentifier("service.\(event.id.uuidString)")
                }
            }
            if !retired {
                Section {
                    Button("Retire vehicle", role: .destructive) { showingRetire = true }
                        .accessibilityIdentifier("vehicle.retire")
                }
            }
        }
        .navigationTitle(vehicle.nickname)
        .toolbar {
            if !retired {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Log fill") { showingFill = true }.accessibilityIdentifier("fill-log.add")
                    Button("Log service") { showingService = true }.accessibilityIdentifier("service-log.add")
                }
            }
        }
        .sheet(isPresented: $showingFill) { FillSheet(workflow: workflow, vehicleID: vehicle.id, original: nil, onSave: reload) }
        .sheet(item: $selectedFill) { fill in FillSheet(workflow: workflow, vehicleID: vehicle.id, original: fill, onSave: reload) }
        .sheet(isPresented: $showingService) { ServiceSheet(workflow: workflow, vehicleID: vehicle.id, original: nil, onSave: reload) }
        .sheet(item: $selectedService) { service in ServiceSheet(workflow: workflow, vehicleID: vehicle.id, original: service, onSave: reload) }
        .confirmationDialog("Retire \(vehicle.nickname)? History and corrections remain visible.", isPresented: $showingRetire) {
            Button("Retire vehicle", role: .destructive) {
                do { try workflow.retireVehicle(id: vehicle.id); reload(); onRetire() }
                catch { errorText = error.localizedDescription }
            }.accessibilityIdentifier("vehicle.retire.confirm")
        }
        .alert("Could not load history", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") { errorText = nil }
        } message: { Text(errorText ?? "") }
        .onAppear(perform: reload)
    }

    private func reload() {
        do {
            retired = try workflow.store.vehicles.vehicle(id: vehicle.id)?.retiredAt != nil
            fills = try workflow.resolvedFills(vehicleID: vehicle.id)
            services = try workflow.resolvedServices(vehicleID: vehicle.id)
            stats = try workflow.vehicleStats(vehicleID: vehicle.id)
            economy = stats?.economy
        } catch { errorText = error.localizedDescription }
    }
}

extension FillEvent: @retroactive Identifiable {}
extension ServiceEvent: @retroactive Identifiable {}

func format(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
func money(_ cents: Int) -> String { "$\(cents / 100).\(String(format: "%02d", cents % 100))" }
