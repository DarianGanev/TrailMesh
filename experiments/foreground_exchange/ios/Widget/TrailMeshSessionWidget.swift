import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TrailMeshSessionWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ProbeActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Label("TrailMesh test session", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Text(context.state.status).font(.caption)
                HStack {
                    Label("\(context.state.sent) sent", systemImage: "arrow.up")
                    Spacer()
                    Label("\(context.state.received) received", systemImage: "arrow.down")
                }.font(.caption.monospacedDigit())
                Text("Generated test bytes · Open TrailMesh to stop")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
            .activityBackgroundTint(Color(white: 0.12))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("TrailMesh", systemImage: "point.3.connected.trianglepath.dotted")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("↑\(context.state.sent) ↓\(context.state.received)").monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.status).font(.caption)
                }
            } compactLeading: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            } compactTrailing: {
                Text("\(context.state.received)").monospacedDigit()
            } minimal: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            .keylineTint(.green)
        }
    }
}
