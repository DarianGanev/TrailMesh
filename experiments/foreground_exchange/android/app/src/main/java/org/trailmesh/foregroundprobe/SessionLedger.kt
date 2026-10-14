package org.trailmesh.foregroundprobe

internal data class ProbeEvent(val name: String, val time: String, val fields: Map<String, String> = emptyMap())
internal data class PeerJournal(
    val sessionID: String, val platform: String,
    val nextOutgoing: Int = 0, val successfulOutgoing: Int = 0, val failedOutgoing: Int = 0,
    val transmissions: Int = 0, val recoveries: Int = 0,
    val incoming: List<Int> = List(20) { 0 },
    val remoteSuccesses: Int? = null, val remoteFailures: Int? = null,
    val complete: Boolean = false, val exhausted: Boolean = false,
    val completedAt: Long = 0, val completionRequests: Int = 0, val completionReconciled: Boolean = false,
) { val receivedAccepted: Int get() = incoming.count { it == 1 } }
internal data class SessionCheckpoint(
    val sessionID: String, val payloadSize: Int, val open: Boolean = true,
    val peers: List<PeerJournal> = emptyList(), val events: List<ProbeEvent> = emptyList(),
    val evictedRecords: Long = 0,
)
internal data class IncomingDecision(val accepted: Boolean, val duplicate: Boolean)

/** All callers run on the service's main queue; a commit must succeed before any positive ACK. */
internal class SessionLedger(initial: SessionCheckpoint, private val persist: (SessionCheckpoint) -> Unit) {
    var checkpoint: SessionCheckpoint = initial
        private set
    fun peer(sessionID: String): PeerJournal? = checkpoint.peers.firstOrNull { it.sessionID == sessionID }
    init { validate(initial) }

    private fun commit(next: SessionCheckpoint) {
        validate(next)
        persist(next)
        checkpoint = next
    }

    private fun replace(next: PeerJournal, evidence: ProbeEvent? = null) {
        val updated = checkpoint.copy(peers = checkpoint.peers.map { if (it.sessionID == next.sessionID) next else it })
        commit(if (evidence == null) updated else appendEvent(updated, evidence))
    }

    private fun appendEvent(state: SessionCheckpoint, event: ProbeEvent): SessionCheckpoint {
        val events = (state.events + event).toMutableList()
        var evicted = state.evictedRecords
        while (events.size > MAX_EVENTS) {
            val index = events.indexOfFirst { it.name !in EVIDENCE_EVENTS }
            require(index >= 0) { "evidence exceeds session bounds" }
            events.removeAt(index)
            if (evicted < Long.MAX_VALUE) evicted++
        }
        return state.copy(events = events, evictedRecords = evicted)
    }

    fun selectPeer(sessionID: String, platform: String): PeerJournal? {
        require(checkpoint.open)
        require(sessionID != checkpoint.sessionID && validID(sessionID))
        require(platform in listOf("android", "ios"))
        peer(sessionID)?.let { return it.takeUnless { journal -> journal.complete || journal.exhausted } }
        if (checkpoint.peers.size >= MAX_PEERS) return null
        val next = PeerJournal(sessionID, platform)
        commit(checkpoint.copy(peers = checkpoint.peers + next))
        return next
    }

    fun receive(sessionID: String, index: Int, accepted: Boolean, evidence: ProbeEvent? = null): IncomingDecision {
        require(index in 0 until ATTEMPTS)
        val current = requireNotNull(peer(sessionID))
        val previous = current.incoming[index]
        if (previous != 0) {
            evidence?.let(::record)
            return IncomingDecision(previous == 1, true)
        }
        require(!current.complete)
        val incoming = current.incoming.toMutableList().apply { this[index] = if (accepted) 1 else 2 }
        replace(current.copy(incoming = incoming), evidence)
        return IncomingDecision(accepted, false)
    }

    fun beginTransmission(sessionID: String): Boolean {
        val current = requireNotNull(peer(sessionID))
        if (current.nextOutgoing >= ATTEMPTS || current.transmissions >= MAX_TRANSMISSIONS) return false
        replace(current.copy(transmissions = current.transmissions + 1))
        return true
    }

    fun completeOutgoing(sessionID: String, success: Boolean, evidence: ProbeEvent? = null) {
        val current = requireNotNull(peer(sessionID))
        require(current.nextOutgoing < ATTEMPTS && current.transmissions > 0)
        replace(current.copy(
            nextOutgoing = current.nextOutgoing + 1,
            successfulOutgoing = current.successfulOutgoing + if (success) 1 else 0,
            failedOutgoing = current.failedOutgoing + if (success) 0 else 1,
            transmissions = 0,
        ), evidence)
    }

    fun nextRecovery(sessionID: String): Long? {
        val current = requireNotNull(peer(sessionID))
        if (current.recoveries >= MAX_RECOVERIES) return null
        val count = current.recoveries + 1
        replace(current.copy(recoveries = count))
        return (1_000L shl (count - 1)).coerceAtMost(16_000L)
    }

    fun remoteFinished(sessionID: String, successes: Int, failures: Int) {
        require(successes in 0..ATTEMPTS && failures in 0..ATTEMPTS && successes + failures == ATTEMPTS)
        val current = requireNotNull(peer(sessionID))
        require(current.remoteSuccesses == null ||
            current.remoteSuccesses == successes && current.remoteFailures == failures)
        replace(current.copy(remoteSuccesses = successes, remoteFailures = failures))
    }

    fun markComplete(sessionID: String) {
        val current = requireNotNull(peer(sessionID))
        require(current.nextOutgoing == ATTEMPTS && current.remoteSuccesses != null)
        replace(current.copy(complete = true, completedAt = if (current.complete) current.completedAt else System.currentTimeMillis(),
            completionReconciled = current.complete))
    }

    fun canReplayCompletion(sessionID: String, now: Long): Boolean = peer(sessionID)?.let {
        it.complete && !it.exhausted && !it.completionReconciled && it.completionRequests < 3 &&
            now - it.completedAt in 0..60_000
    } == true
    fun beginCompletionReplay(sessionID: String, now: Long): Boolean {
        if (!canReplayCompletion(sessionID, now)) return false
        val peer = requireNotNull(peer(sessionID))
        replace(peer.copy(completionRequests = peer.completionRequests + 1))
        return true
    }

    fun abandon(sessionID: String) = replace(requireNotNull(peer(sessionID)).copy(exhausted = true))
    fun resume() {
        require(checkpoint.open)
        commit(checkpoint.copy(peers = checkpoint.peers.map { it.copy(recoveries = 0, exhausted = false) }))
    }

    fun record(event: ProbeEvent) = commit(appendEvent(checkpoint, event))
    fun close() = commit(checkpoint.copy(open = false))

    companion object {
        const val ATTEMPTS = 20
        const val MAX_TRANSMISSIONS = 3
        const val MAX_RECOVERIES = 5
        const val MAX_PEERS = 8
        const val MAX_EVENTS = 512
        private val EVIDENCE_EVENTS = setOf("session_started", "session_stopped", "attempt_result", "payload_received")
        fun validID(value: String) = value.matches(Regex("[0-9a-f]{32}"))
        fun validate(value: SessionCheckpoint) {
            require(validID(value.sessionID) && value.payloadSize in listOf(256, 2048, 8192))
            require(value.peers.size <= MAX_PEERS && value.peers.map { it.sessionID }.toSet().size == value.peers.size)
            for (peer in value.peers) {
                require(validID(peer.sessionID) && peer.sessionID != value.sessionID)
                require(peer.platform in listOf("android", "ios"))
                require(peer.nextOutgoing in 0..ATTEMPTS && peer.successfulOutgoing in 0..ATTEMPTS && peer.failedOutgoing in 0..ATTEMPTS)
                require(peer.successfulOutgoing + peer.failedOutgoing == peer.nextOutgoing)
                require(peer.transmissions in 0..MAX_TRANSMISSIONS && peer.recoveries in 0..MAX_RECOVERIES)
                require(peer.incoming.size == ATTEMPTS && peer.incoming.all { it in 0..2 })
                require((peer.remoteSuccesses == null) == (peer.remoteFailures == null))
                if (peer.remoteSuccesses != null) require(peer.remoteSuccesses in 0..ATTEMPTS &&
                    peer.remoteFailures!! in 0..ATTEMPTS && peer.remoteSuccesses + peer.remoteFailures == ATTEMPTS)
                require(!peer.complete || peer.nextOutgoing == ATTEMPTS && peer.remoteSuccesses != null)
                require(peer.completionRequests in 0..3 && peer.completedAt >= 0 && (!peer.completionReconciled || peer.complete))
            }
            require(value.events.size <= MAX_EVENTS && value.evictedRecords >= 0)
            for (event in value.events) {
                require(event.name.length in 1..64 && event.time.length <= 64 && event.fields.size <= 12)
                require(event.fields.all { it.key.length in 1..64 && it.value.length <= 160 })
            }
        }
    }
}
