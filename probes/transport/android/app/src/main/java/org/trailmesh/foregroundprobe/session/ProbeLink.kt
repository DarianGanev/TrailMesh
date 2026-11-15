package org.trailmesh.foregroundprobe

import android.os.Handler

internal data class ProbeTransfer(val token: CallbackToken, val purpose: String, val sendSerial: Long? = null)

/** One endpoint's protocol, timers and payload ownership. No mutable current-peer alias exists. */
internal class ProbeLink(val endpoint: String, val peer: ProbePeerContext, val token: CallbackToken) {
    var accepted = false
    var connected = false
    val exchange = LinkExchange()
    val ingress = LinkIngress()
    val timers = mutableMapOf<String, Runnable>()
    val transfers = mutableMapOf<Long, ProbeTransfer>()
    var finishingGrace = false
    var finishTransmissions = 0
    val helloReceived get() = exchange.helloReceived
    val localFinishAcknowledged get() = exchange.localFinishAcknowledged
    val pendingSend get() = exchange.pending

    fun cancelTimers(handler: Handler) {
        timers.values.forEach(handler::removeCallbacks)
        timers.clear()
    }
}
