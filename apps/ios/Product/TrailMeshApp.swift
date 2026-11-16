import SwiftUI

@main
struct TrailMeshApp: App {
    var body: some Scene {
        WindowGroup {
            #if TRAILMESH_DEVELOPMENT
            ReportDevelopmentView()
            #else
            Text("TrailMesh").font(.largeTitle.bold())
            #endif
        }
    }
}
