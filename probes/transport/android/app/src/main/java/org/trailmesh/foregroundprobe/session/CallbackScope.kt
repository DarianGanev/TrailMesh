package org.trailmesh.foregroundprobe

internal data class CallbackToken(val session: Long, val radio: Long, val link: Long, val endpoint: String?)

/** Independent link generations share a radio generation. All access is serialized by the owner. */
internal class CallbackScope {
    private var active = false
    private var session = 0L
    private var radio = 0L
    private var link = 0L
    private val endpoints = mutableMapOf<String, Long>()

    fun start() { session++; active = true; restartRadio() }
    fun stop() { active = false; session++; endpoints.clear() }
    fun restartRadio() { radio++; endpoints.clear() }
    fun select(endpoint: String): CallbackToken {
        endpoints[endpoint] = ++link
        return CallbackToken(session, radio, link, endpoint)
    }
    fun retire(endpoint: String) { endpoints.remove(endpoint) }
    fun capture() = CallbackToken(session, radio, 0, null)
    fun accepts(token: CallbackToken, endpoint: String? = token.endpoint): Boolean =
        acceptsRadio(token) && endpoint != null && token.endpoint == endpoint && endpoints[endpoint] == token.link
    fun acceptsRadio(token: CallbackToken): Boolean = active && token.session == session && token.radio == radio
}
