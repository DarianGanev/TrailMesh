import SwiftUI

@main
struct TrailMeshTransportProbeApp: App {
    @StateObject private var model = ProbeModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
