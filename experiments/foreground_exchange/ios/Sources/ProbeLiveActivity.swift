import ActivityKit
import Foundation

/// A locally started, visible session activity. It requests no push token or APNs entitlement.
@available(iOS 16.1, *)
final class ProbeLiveActivity {
    private var activity: Activity<ProbeActivityAttributes>?
    private var stateTask: Task<Void, Never>?
    private var authorizationTask: Task<Void, Never>?
    var availabilityChanged: ((Bool) -> Void)?

    var allowsBackgroundBluetooth: Bool {
        guard #available(iOS 26.0, *), ActivityAuthorizationInfo().areActivitiesEnabled,
              let activity else { return false }
        return activity.activityState == .active || activity.activityState == .stale
    }

    func start(sessionID: String, content: ProbeActivityAttributes.ContentState) -> Bool {
        guard #available(iOS 26.0, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        if let existing = Activity<ProbeActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == sessionID && ($0.activityState == .active || $0.activityState == .stale)
        }) {
            activity = existing
        } else {
            do {
                activity = try Activity.request(attributes: ProbeActivityAttributes(sessionID: sessionID),
                                                content: ActivityContent(state: content, staleDate: nil),
                                                pushType: nil)
            } catch { return false }
        }
        observeChanges()
        return allowsBackgroundBluetooth
    }

    func update(_ content: ProbeActivityAttributes.ContentState) {
        guard #available(iOS 16.2, *), let activity else { return }
        Task { await activity.update(ActivityContent(state: content, staleDate: nil)) }
    }

    func end() {
        stateTask?.cancel()
        authorizationTask?.cancel()
        stateTask = nil
        authorizationTask = nil
        let oldActivity = activity
        activity = nil
        if #available(iOS 16.2, *), let oldActivity {
            Task { await oldActivity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    @available(iOS 16.2, *)
    static func endAllOwnedActivities() {
        // Activity.activities is scoped to this app and this attributes type.
        let activities = Activity<ProbeActivityAttributes>.activities
        Task {
            for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func observeChanges() {
        stateTask?.cancel()
        authorizationTask?.cancel()
        if let activity {
            stateTask = Task { [weak self] in
                for await _ in activity.activityStateUpdates {
                    guard !Task.isCancelled else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.availabilityChanged?(self.allowsBackgroundBluetooth)
                    }
                }
            }
        }
        authorizationTask = Task { [weak self] in
            for await _ in ActivityAuthorizationInfo().activityEnablementUpdates {
                guard !Task.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.availabilityChanged?(self.allowsBackgroundBluetooth)
                }
            }
        }
    }

    deinit { stateTask?.cancel(); authorizationTask?.cancel() }
}
