package org.trailmesh.foregroundprobe

internal data class CallbackToken(val session: Long, val radio: Long, val link: Long, val endpoint: String?)
internal class CallbackScope {
    private var active = false
    private var session = 0L
    private var radio = 0L
    private var link = 0L
    private var endpoint: String? = null
    fun start() { session++; active = true; restartRadio() }
    fun stop() { active = false; session++; endpoint = null }
    fun restartRadio() { radio++; link++; endpoint = null }
    fun select(endpoint: String) { link++; this.endpoint = endpoint }
    fun capture() = CallbackToken(session, radio, link, endpoint)
    fun accepts(token: CallbackToken, endpoint: String? = token.endpoint): Boolean =
        acceptsRadio(token) && token.link == link && token.endpoint == this.endpoint && endpoint == this.endpoint
    fun acceptsRadio(token: CallbackToken): Boolean = active && token.session == session && token.radio == radio
}
