import Foundation

struct ProbePeerCandidate: Equatable {
    let endpointID: String
    let context: ProbePeerContext
}

struct ProbePeerReservation: Equatable {
    let candidate: ProbePeerCandidate
    let generation: UInt64
}

/// Main-queue admission bookkeeping. Reservations include connecting, active and
/// finishing links. Releasing one reservation never invalidates another peer.
struct ProbePeerPool {
    static let maximumLinks = 4
    static let maximumCandidates = 32
    static let maximumRetiredEndpoints = 32
    private var waiting: [ProbePeerCandidate] = []
    private var active: [String: ProbePeerReservation] = [:]
    private var generation: UInt64 = 0
    private var retired: Set<String> = []

    var activeCount: Int { active.count }
    var waitingCount: Int { waiting.count }
    var retiredCount: Int { retired.count }

    @discardableResult
    mutating func offer(_ candidate: ProbePeerCandidate) -> Bool {
        guard active[candidate.endpointID] == nil, !retired.contains(candidate.endpointID),
              !active.values.contains(where: { $0.candidate.context.sessionID == candidate.context.sessionID }) else { return false }
        if let previous = waiting.firstIndex(where: { $0.endpointID == candidate.endpointID }) {
            // A changed advertisement must not replace a previously queued identity.
            return waiting[previous] == candidate
        }
        if let previous = waiting.firstIndex(where: { $0.context.sessionID == candidate.context.sessionID }) {
            guard waiting[previous].context == candidate.context else { return false }
            waiting[previous] = candidate
            return true
        }
        guard waiting.count < Self.maximumCandidates else { return false }
        waiting.append(candidate)
        return true
    }

    mutating func reserveNext(eligible: (ProbePeerCandidate) -> Bool) -> ProbePeerReservation? {
        guard active.count < Self.maximumLinks, retired.count + active.count < Self.maximumRetiredEndpoints,
              let index = waiting.firstIndex(where: eligible) else { return nil }
        return reserveIncoming(waiting.remove(at: index))
    }

    mutating func reserveIncoming(_ candidate: ProbePeerCandidate) -> ProbePeerReservation? {
        guard active.count < Self.maximumLinks, retired.count + active.count < Self.maximumRetiredEndpoints,
              active[candidate.endpointID] == nil, !retired.contains(candidate.endpointID),
              !active.values.contains(where: { $0.candidate.context.sessionID == candidate.context.sessionID }) else { return nil }
        if let previous = waiting.first(where: { $0.endpointID == candidate.endpointID }), previous != candidate { return nil }
        if let previous = waiting.first(where: { $0.context.sessionID == candidate.context.sessionID }),
           previous.context != candidate.context { return nil }
        waiting.removeAll { $0.endpointID == candidate.endpointID || $0.context.sessionID == candidate.context.sessionID }
        generation &+= 1
        let reservation = ProbePeerReservation(candidate: candidate, generation: generation)
        active[candidate.endpointID] = reservation
        return reservation
    }

    func contains(_ reservation: ProbePeerReservation) -> Bool {
        active[reservation.candidate.endpointID] == reservation
    }

    @discardableResult
    mutating func release(_ reservation: ProbePeerReservation) -> Bool {
        guard contains(reservation) else { return false }
        active.removeValue(forKey: reservation.candidate.endpointID)
        retired.insert(reservation.candidate.endpointID)
        return true
    }

    mutating func removeWaiting(endpointID: String) {
        waiting.removeAll { $0.endpointID == endpointID }
    }

    mutating func reset() {
        active.removeAll()
        waiting.removeAll()
        retired.removeAll()
    }
}
