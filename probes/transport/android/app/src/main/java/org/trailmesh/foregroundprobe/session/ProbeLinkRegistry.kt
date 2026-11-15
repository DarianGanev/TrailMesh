package org.trailmesh.foregroundprobe

/** Endpoint dispatch used by SDK callbacks and timers. Every lookup requires its captured token. */
internal class ProbeLinkRegistry(private val scope: CallbackScope) {
    private val live = linkedMapOf<String, ProbeLink>()
    private val retired = mutableSetOf<String>()
    val links: Map<String, ProbeLink> get() = live
    val hasRetiredEndpoints get() = retired.isNotEmpty()

    fun wasRetired(endpoint: String) = endpoint in retired

    fun add(endpoint: String, peer: ProbePeerContext): ProbeLink? {
        if (live.size >= PeerScheduler.MAX_LINKS || endpoint in retired || endpoint in live ||
            live.values.any { it.peer.sessionID == peer.sessionID }) return null
        val link = ProbeLink(endpoint, peer, scope.select(endpoint))
        live[endpoint] = link
        return link
    }

    fun current(token: CallbackToken, endpoint: String? = token.endpoint): ProbeLink? {
        if (!scope.accepts(token, endpoint)) return null
        return live[endpoint]?.takeIf { it.token == token }
    }

    fun retire(link: ProbeLink): Boolean {
        if (live[link.endpoint] !== link) return false
        live.remove(link.endpoint)
        retired.add(link.endpoint)
        scope.retire(link.endpoint)
        return true
    }

    fun clear() {
        live.keys.forEach(scope::retire)
        live.clear()
        retired.clear()
    }
}

/** The shared advertiser delegate retains its original attempt token even after disconnection. */
internal class LinkCallbacks(private val requested: CallbackToken? = null) {
    private val initiated = mutableMapOf<String, CallbackToken>()
    fun initiate(link: ProbeLink): Boolean {
        if (requested != null) return requested == link.token
        val previous = initiated.putIfAbsent(link.endpoint, link.token)
        return previous == null || previous == link.token
    }
    fun token(endpoint: String): CallbackToken? = requested ?: initiated[endpoint]
}
