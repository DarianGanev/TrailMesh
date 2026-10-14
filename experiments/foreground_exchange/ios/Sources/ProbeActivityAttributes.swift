import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct ProbeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var sent: Int
        var failed: Int
        var received: Int
    }
    var sessionID: String
}
