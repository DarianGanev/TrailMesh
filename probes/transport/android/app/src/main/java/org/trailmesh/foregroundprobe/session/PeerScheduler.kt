package org.trailmesh.foregroundprobe

internal data class PeerCandidate(val endpoint: String, val peer: ProbePeerContext, val readyAt: Long = 0)

/** Bounded FIFO admission. A failed link rejoins behind peers already waiting, outside live slots. */
internal class PeerScheduler {
    private val waiting = linkedMapOf<String, PeerCandidate>()
    private val active = linkedMapOf<String, PeerCandidate>()
    val activeCount get() = active.size
    val waitingCount get() = waiting.size
    val nextReadyAt get() = waiting.values.minOfOrNull { it.readyAt }

    fun discover(endpoint: String, peer: ProbePeerContext, readyAt: Long = 0): Boolean {
        if (active.containsKey(endpoint) || active.values.any { it.peer.sessionID == peer.sessionID }) return false
        if (waiting.values.any { it.endpoint == endpoint && it.peer.sessionID != peer.sessionID }) return false
        val existing = waiting[peer.sessionID]
        if (existing != null || waiting.size >= MAX_CANDIDATES) return false
        waiting[peer.sessionID] = PeerCandidate(endpoint, peer, readyAt)
        return true
    }

    fun lost(endpoint: String) { waiting.entries.removeAll { it.value.endpoint == endpoint } }

    fun reserveIncoming(endpoint: String, peer: ProbePeerContext): Boolean {
        if (active.size >= MAX_LINKS || active.containsKey(endpoint) ||
            active.values.any { it.peer.sessionID == peer.sessionID }) return false
        if (waiting.values.any { it.endpoint == endpoint && it.peer != peer }) return false
        waiting.remove(peer.sessionID)
        active[endpoint] = PeerCandidate(endpoint, peer)
        return true
    }

    fun takeNext(now: Long, eligible: (PeerCandidate) -> Boolean): PeerCandidate? =
        takeNext(now, eligible) { true }

    fun takeNext(now: Long, eligible: (PeerCandidate) -> Boolean, available: (PeerCandidate) -> Boolean): PeerCandidate? {
        if (active.size >= MAX_LINKS) return null
        val iterator = waiting.iterator()
        while (iterator.hasNext()) {
            val candidate = iterator.next().value
            if (!eligible(candidate)) { iterator.remove(); continue }
            if (candidate.readyAt > now || !available(candidate)) continue
            iterator.remove()
            active[candidate.endpoint] = candidate
            return candidate
        }
        return null
    }

    fun release(endpoint: String, retryAt: Long? = null) {
        val candidate = active.remove(endpoint) ?: return
        if (retryAt != null) discover(candidate.endpoint, candidate.peer, retryAt)
    }

    fun clear() { waiting.clear(); active.clear() }

    companion object {
        const val MAX_LINKS = 4
        const val MAX_CANDIDATES = 32
    }
}
