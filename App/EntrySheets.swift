import Foundation
import PumpStore
import SwiftUI

struct AddVehicleSheet: View {
    let workflow: QuickLogWorkflow
    // MainActor + Sendable: View implies both Sendable and @MainActor on the
    // iOS 26 SDK under Swift 6 language mode; callers pass MainActor reloads.
    let onSave: @MainActor @Sendable () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form { TextField("Vehicle name", text: $name).accessibilityIdentifier("vehicle.name") }
                .navigationTitle("Add vehicle")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("vehicle.cancel") }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.accessibilityIdentifier("vehicle.save") }
                }
                .alert("Could not add vehicle", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("OK") { errorText = nil } } message: { Text(errorText ?? "") }
        }
    }

    private func save() {
        do { _ = try workflow.addVehicle(name); onSave(); dismiss() }
        catch { errorText = error.localizedDescription }
    }
}

struct FillSheet: View {
    let workflow: QuickLogWorkflow
    let vehicleID: UUID
    let original: FillEvent?
    let onSave: @MainActor @Sendable () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var odometer: String
    @State private var volume: String
    @State private var price: String
    @State private var classification: PumpClassification
    @State private var errorText: String?
    @State private var confirmLargeDelta = false

    init(workflow: QuickLogWorkflow, vehicleID: UUID, original: FillEvent?, onSave: @escaping @MainActor @Sendable () -> Void) {
        self.workflow = workflow; self.vehicleID = vehicleID; self.original = original; self.onSave = onSave
        _odometer = State(initialValue: original?.odometerDecimal.map(format) ?? "")
        _volume = State(initialValue: original.map { format($0.volumeDecimal) } ?? "")
        _price = State(initialValue: original.map { money($0.costCents).replacingOccurrences(of: "$", with: "") } ?? "")
        _classification = State(initialValue: original?.pumpClassification ?? .full)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Odometer (miles)", text: $odometer).keyboardType(.decimalPad).accessibilityIdentifier("fill.odometer")
                TextField("Volume (US gallons)", text: $volume).keyboardType(.decimalPad).accessibilityIdentifier("fill.volume")
                TextField("Total price ($)", text: $price).keyboardType(.decimalPad).accessibilityIdentifier("fill.price")
                Picker("Fill type", selection: $classification) {
                    Text("Full").tag(PumpClassification.full).accessibilityIdentifier("filltype.full")
                    Text("Partial").tag(PumpClassification.partial).accessibilityIdentifier("filltype.partial")
                    Text("Top-off").tag(PumpClassification.topoff).accessibilityIdentifier("filltype.topoff")
                }
                .accessibilityIdentifier("filltype.segment")
                .pickerStyle(.segmented)
            }
            .navigationTitle(original == nil ? "Log fill" : "Correct fill")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("fill.cancel") }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.accessibilityIdentifier("fill.save") }
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("fill.keyboard.cancel")
                    Spacer()
                    Button("Save") { save() }.accessibilityIdentifier("fill.keyboard.save")
                }
            }
            .confirmationDialog("Odometer jump exceeds 10,000 miles. Save this entry?", isPresented: $confirmLargeDelta) {
                Button("Save with this odometer") { save(confirmed: true) }.accessibilityIdentifier("fill.confirm.large.delta")
            }
            .alert("Could not save fill", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("OK") { errorText = nil } } message: { Text(errorText ?? "") }
        }
    }

    private func save(confirmed: Bool = false) {
        do {
            if let original {
                try workflow.correctFill(id: original.id, odometer: odometer, volume: volume, price: price, classification: classification, confirmLargeDelta: confirmed)
            } else {
                _ = try workflow.logFill(vehicleID: vehicleID, odometer: odometer, volume: volume, price: price, classification: classification, confirmLargeDelta: confirmed)
            }
            onSave(); dismiss()
        } catch QuickLogError.largeOdometerDelta { confirmLargeDelta = true }
        catch { errorText = error.localizedDescription }
    }
}

struct ServiceSheet: View {
    let workflow: QuickLogWorkflow
    let vehicleID: UUID
    let original: ServiceEvent?
    let onSave: @MainActor @Sendable () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var category: String
    @State private var price: String
    @State private var errorText: String?

    init(workflow: QuickLogWorkflow, vehicleID: UUID, original: ServiceEvent?, onSave: @escaping @MainActor @Sendable () -> Void) {
        self.workflow = workflow; self.vehicleID = vehicleID; self.original = original; self.onSave = onSave
        _category = State(initialValue: original?.category ?? "")
        _price = State(initialValue: original.map { money($0.costCents).replacingOccurrences(of: "$", with: "") } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Category", text: $category).accessibilityIdentifier("service.category")
                if original == nil { TextField("Total price ($)", text: $price).keyboardType(.decimalPad).accessibilityIdentifier("service.price") }
            }
            .navigationTitle(original == nil ? "Log service" : "Edit category")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("service.cancel") }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.accessibilityIdentifier("service.save") }
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("service.keyboard.cancel")
                    Spacer()
                    Button("Save") { save() }.accessibilityIdentifier("service.keyboard.save")
                }
            }
            .alert("Could not save service", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("OK") { errorText = nil } } message: { Text(errorText ?? "") }
        }
    }

    private func save() {
        do {
            if let original { try workflow.correctServiceCategory(id: original.id, category: category) }
            else { _ = try workflow.logService(vehicleID: vehicleID, category: category, price: price) }
            onSave(); dismiss()
        } catch { errorText = error.localizedDescription }
    }
}
