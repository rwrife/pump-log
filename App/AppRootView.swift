import Foundation
import PumpStore
import SwiftUI

struct AppRootView: View {
    private struct StoreFailure: Error, Sendable, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // Stored as a Sendable failure value: iOS 18+ SDK makes `View` imply
    // Sendable, so a bare `any Error` existential cannot be a stored property
    // in Swift 6 language mode.
    private let opened: Result<QuickLogWorkflow, StoreFailure>

    init() {
        do {
            opened = .success(try Self.makeWorkflow())
        } catch {
            opened = .failure(StoreFailure(message: error.localizedDescription))
        }
    }

    private static func makeWorkflow() throws -> QuickLogWorkflow {
        let fileManager = FileManager.default
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
#if DEBUG
        let testing = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        // A UI journey owns one database through relaunches; separate journeys
        // must not accidentally pick an older vehicle from a shared store.
        let testStore = ProcessInfo.processInfo.environment["PUMPLOG_UI_TEST_STORE"].flatMap(UUID.init(uuidString:))
        let directory = testing
            ? support.appendingPathComponent("UITests", isDirectory: true)
                .appendingPathComponent(testStore?.uuidString ?? "default", isDirectory: true)
            : support
#else
        let directory = support
#endif
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("PumpLog.sqlite")
#if DEBUG
        if testing && ProcessInfo.processInfo.arguments.contains("-reset-ui-store") {
            for suffix in ["", "-wal", "-shm"] {
                if fileManager.fileExists(atPath: databaseURL.path + suffix) { try fileManager.removeItem(atPath: databaseURL.path + suffix) }
            }
        }
#endif
        return QuickLogWorkflow(store: try PumpStore.open(at: databaseURL))
    }

    var body: some View {
        switch opened {
        case .success(let workflow): VehicleListView(workflow: workflow)
        case .failure(let error):
            ContentUnavailableView("Could not open local data", systemImage: "externaldrive.badge.exclamationmark", description: Text(error.localizedDescription))
        }
    }
}

struct VehicleListView: View {
    let workflow: QuickLogWorkflow
    @State private var vehicles: [Vehicle] = []
    @State private var showingAdd = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(vehicles, id: \.id) { vehicle in
                    NavigationLink(value: vehicle.id) {
                        VStack(alignment: .leading) {
                            Text(vehicle.nickname)
                            if vehicle.retiredAt != nil { Text("Retired · history available").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .accessibilityIdentifier("vehicle.row.\(vehicle.id.uuidString)")
                }
            }
            .overlay { if vehicles.isEmpty { ContentUnavailableView("No vehicles yet", systemImage: "car", description: Text("Add a vehicle to start logging fills.")) } }
            .navigationTitle("Pump Log")
            .toolbar { Button("Add vehicle", systemImage: "plus") { showingAdd = true }.accessibilityIdentifier("vehicle.add") }
            .navigationDestination(for: UUID.self) { id in
                if let vehicle = vehicles.first(where: { $0.id == id }) {
                    VehicleDetailView(workflow: workflow, vehicle: vehicle, onRetire: reload)
                }
            }
            .sheet(isPresented: $showingAdd) { AddVehicleSheet(workflow: workflow) { reload() } }
            .alert("Could not load vehicles", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK") { errorText = nil }
            } message: { Text(errorText ?? "") }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        do { vehicles = try workflow.store.vehicles.allVehicles() }
        catch { errorText = error.localizedDescription }
    }
}
