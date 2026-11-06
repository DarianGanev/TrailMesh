import SwiftUI
import TrailMeshReports

@main
struct TrailMeshApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("TrailMesh").font(.largeTitle.bold())
                Text("More features are coming soon").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
