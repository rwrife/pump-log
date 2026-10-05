import Foundation
import PumpStore
import SwiftUI
import UniformTypeIdentifiers

struct BackupFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct CSVFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let data: Data
    init(text: String) { data = Data(text.utf8) }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

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
    @State private var navigationPath: [UUID] = []
    @State private var vehicles: [Vehicle] = []
    @State private var showingAdd = false
    @State private var errorText: String?
    @State private var backupFile: BackupFileDocument?
    @State private var csvFile: CSVFileDocument?
    @State private var csvName = "fills"
    @State private var exportingBackup = false
    @State private var exportingCSV = false
    @State private var importingBackup = false
    @State private var pendingBackup: Data?
    @State private var pendingPreview: BackupPreview?
    @State private var showingWipe = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                Section("Your data · local files only") {
                    Button("Save JSON backup to Files") { exportBackup() }
                        .accessibilityIdentifier("data.backup")
                    Button("Restore JSON backup from Files") { importingBackup = true }
                        .accessibilityIdentifier("data.restore")
                    Button("Export fills.csv") { exportCSV(fills: true) }
                        .accessibilityIdentifier("data.fills.csv")
                    Button("Export service.csv") { exportCSV(fills: false) }
                        .accessibilityIdentifier("data.service.csv")
                    Button("Erase all local data", role: .destructive) { showingWipe = true }
                        .accessibilityIdentifier("data.wipe")
                }
                if vehicles.isEmpty {
                    Section {
                        ContentUnavailableView("No vehicles yet", systemImage: "car", description: Text("Add a vehicle to start logging fills."))
                    }
                }
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

            .navigationTitle("Pump Log")
            .toolbar { Button("Add vehicle", systemImage: "plus") { showingAdd = true }.accessibilityIdentifier("vehicle.add") }
            .navigationDestination(for: UUID.self) { id in
                if let vehicle = vehicles.first(where: { $0.id == id }) {
                    VehicleDetailView(workflow: workflow, vehicle: vehicle, onRetire: reload)
                }
            }
            .sheet(isPresented: $showingAdd) { AddVehicleSheet(workflow: workflow) { reload() } }
            .sheet(isPresented: $showingWipe) {
                TypedDeleteSheet(prompt: "Type DELETE ALL to erase every vehicle, fill, service, and correction.", expected: "DELETE ALL") {
                    try workflow.store.wipeAll()
                    reload()
                }
            }
            .fileExporter(isPresented: $exportingBackup, document: backupFile, contentType: .json, defaultFilename: "pumplog-backup") { result in
                if case .failure(let error) = result { errorText = error.localizedDescription }
                backupFile = nil
            }
            .fileExporter(isPresented: $exportingCSV, document: csvFile, contentType: .commaSeparatedText, defaultFilename: csvName) { result in
                if case .failure(let error) = result { errorText = error.localizedDescription }
                csvFile = nil
            }
            .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    pendingPreview = try workflow.store.previewBackup(data)
                    pendingBackup = data
                } catch { errorText = error.localizedDescription }
            }
            .alert("Replace all local data?", isPresented: Binding(get: { pendingPreview != nil }, set: { if !$0 { pendingPreview = nil; pendingBackup = nil } })) {
                Button("Replace with backup", role: .destructive) {
                    guard let pendingBackup else { return }
                    do { try workflow.store.restoreBackup(pendingBackup); reload() }
                    catch { errorText = error.localizedDescription }
                    self.pendingBackup = nil
                    pendingPreview = nil
                }
                Button("Cancel", role: .cancel) { pendingBackup = nil; pendingPreview = nil }
            } message: {
                if let p = pendingPreview {
                    Text("\(p.vehicleCount) vehicles, \(p.fillCount) fills, \(p.serviceCount) services, \(p.correctionCount) corrections. Dates: \(p.earliestDate?.formatted(date: .abbreviated, time: .omitted) ?? "unknown") – \(p.latestDate?.formatted(date: .abbreviated, time: .omitted) ?? "unknown"). This REPLACES all current local data.")
                }
            }
            .alert("Could not load vehicles", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK") { errorText = nil }
            } message: { Text(errorText ?? "") }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        do {
            vehicles = try workflow.store.vehicles.allVehicles()
            let survivingIDs = Set(vehicles.map(\.id))
            navigationPath.removeAll { !survivingIDs.contains($0) }
        } catch { errorText = error.localizedDescription }
    }

    private func exportBackup() {
        do { backupFile = BackupFileDocument(data: try workflow.store.exportBackup()); exportingBackup = true }
        catch { errorText = error.localizedDescription }
    }

    private func exportCSV(fills: Bool) {
        do {
            csvName = fills ? "fills" : "service"
            csvFile = CSVFileDocument(text: try (fills ? workflow.store.exportFillsCSV() : workflow.store.exportServiceCSV()))
            exportingCSV = true
        } catch { errorText = error.localizedDescription }
    }
}

struct TypedDeleteSheet: View {
    let prompt: String
    let expected: String
    let onDelete: @MainActor @Sendable () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Text(prompt)
                TextField("Confirmation", text: $typed).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().accessibilityIdentifier("delete.confirmation")
                Button("Permanently delete", role: .destructive) {
                    do { try onDelete(); dismiss() }
                    catch { errorText = error.localizedDescription }
                }
                .disabled(typed != expected)
                .accessibilityIdentifier("delete.commit")
            }
            .navigationTitle("Confirm deletion")
            .toolbar { Button("Cancel") { dismiss() }.accessibilityIdentifier("delete.cancel") }
            .alert("Could not delete data", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK") { errorText = nil }
            } message: { Text(errorText ?? "") }
        }
    }
}
