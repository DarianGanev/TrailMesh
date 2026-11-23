#if TRAILMESH_DEVELOPMENT
import SwiftUI

struct ReportDevelopmentView: View {
    @ObservedObject var model: ReportDevelopmentModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRecovery = false
    @State private var confirmCleanup = false
    #if targetEnvironment(simulator)
    @State private var captureMaps = false
    #endif
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Offline map backend diagnostics") { MapDevelopmentView() }
                Section("Development test controls") {
                    Text("Signed public-report exchange in the synthetic Sofia area, 5 km radius").font(.headline)
                    Text("Keep TrailMesh open. Backgrounding pauses and closes links; returning resumes an active session. After process restart, tap Resume. Physical radio and lifecycle behavior still require testing.")
                    Text(model.status).fontWeight(.semibold).accessibilityAddTraits(.updatesFrequently)
                    Text("\(model.activeLinks) active links, \(model.waitingPeers) waiting peers")
                }
                Section("Public sharing consent") {
                    Text("Nearby unverified participants can see public inventories and selected public reports. Signatures protect integrity; they do not authenticate a person or prove a report is true. Routes, interests and private messages are never exchanged.")
                    Toggle("I agree to share public reports during this session", isOn: $model.consent)
                        .onChange(of: model.consent) { _ in model.consentChanged() }
                    Button(model.needsResume ? "Resume public session" : "Start public session") { model.start() }
                        .disabled(!model.ready || !model.consent)
                    Button("Stop public session", role: .destructive) { model.stop() }
                }
                Section("Synthetic reports only") {
                    Button("Create signed test report") { model.createTestReport() }.disabled(!model.ready)
                    Text("Creation is explicit. Reports are labelled synthetic, observed now, expire after one hour, and start with a three-hop budget. SDK send completion is not durable receipt; peer receipt is a peer claim.")
                    ForEach(model.records, id: \.bundleID) { report in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(report.bundleID.prefix(16))).font(.system(.body, design: .monospaced))
                            Text(report.isQuarantined ? "Quarantined history" : report.isExpired ? "Expired history" : "Saved locally")
                            Text("Remaining hops: \(report.remainingHops)").font(.caption)
                        }.accessibilityElement(children: .combine)
                    }
                }
                Section("Redacted diagnostics") {
                    Button("Prepare verified diagnostics export") { model.exportDiagnostics() }.disabled(!model.ready)
                    if let url = model.exportURL { ShareLink("Share diagnostics JSON", item: url) }
                    if !model.notice.isEmpty { Text(model.notice) }
                    Button("Confirm corrected device clock?") { confirmRecovery = true }.disabled(!model.ready)
                    Button("Remove expired history?", role: .destructive) { confirmCleanup = true }.disabled(!model.ready)
                }
            }
            .navigationTitle("TrailMesh Dev")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.load() }
            #if targetEnvironment(simulator)
            .navigationDestination(isPresented: $captureMaps) { MapDevelopmentView() }
            .onAppear {
                switch ScreenCapture.name {
                case "diagnostics-clock-confirmation": confirmRecovery = true
                case "diagnostics-cleanup-confirmation": confirmCleanup = true
                case "diagnostics-maps": captureMaps = true
                default: break
                }
            }
            #endif
            .alert("Confirm corrected device clock?", isPresented: $confirmRecovery) {
                Button("I corrected the clock") { model.recoverClockAfterConfirmation() }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Stop sharing and quarantine existing reports as history after a backward clock correction. Reports will not be forwarded as current.") }
            .alert("Remove expired history?", isPresented: $confirmCleanup) {
                Button("Confirm clock and clean up", role: .destructive) { model.cleanupAfterConfirmation() }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Only continue after confirming the device clock. Eligible expired history will be permanently removed.") }
        }
    }
}
#endif
