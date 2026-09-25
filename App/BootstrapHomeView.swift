import PumpKit
import SwiftUI

struct BootstrapHomeView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "fuelpump.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Pump Log")
                        .font(.largeTitle.bold())
                    Text("A local-first fuel log for honest full-tank-to-full-tank MPG.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Native iPhone foundation is ready", systemImage: "checkmark.circle")
                        Text("Quick-log fills, unknown-safe odometer-gap exclusions, and cost-per-mile derivations land in the next milestones.")
                            .foregroundStyle(.secondary)
                        Text("Domain core milestone: \(PumpKit.milestone).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .navigationTitle("Home")
        }
        .accessibilityIdentifier("bootstrap.home")
    }
}
