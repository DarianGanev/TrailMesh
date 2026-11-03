package org.trailmesh.foregroundprobe

internal data class OutgoingLease(val index: Int, val serial: Long, val digest: ByteArray)
internal class LinkExchange {
    var helloReceived = false
        private set
    var pending: OutgoingLease? = null
        private set
    var localFinishAcknowledged = false
        private set
    var remoteFinishSeen = false
        private set
    var remoteFinishAckDelivered = false
        private set
    private var serial = 0L
    private var packets = 0
    fun hello(value: ForegroundFrame.HelloMessage, local: ProbePeerContext, peer: ProbePeerContext) {
        require(value.sessionID == peer.sessionID && value.peerSessionID == local.sessionID &&
            value.payloadSize == local.payloadSize && value.attemptCount == SessionLedger.ATTEMPTS)
        helloReceived = true
    }
    fun beginSend(index: Int, digest: ByteArray): OutgoingLease {
        require(helloReceived && pending == null && index in 0 until SessionLedger.ATTEMPTS && digest.size == 32)
        return OutgoingLease(index, ++serial, digest.copyOf()).also { pending = it }
    }
    fun matchesAck(value: ForegroundFrame.SessionAckMessage, localID: String): Boolean =
        helloReceived && value.sessionID == localID && pending?.let {
            it.index == value.attemptIndex && it.digest.contentEquals(value.digest)
        } == true
    fun clearPending() { pending = null }
    fun finishAck(value: ForegroundFrame.FinishMessage, localID: String, peer: PeerJournal) {
        require(helloReceived && value.acknowledgement && value.sessionID == peer.sessionID &&
            value.peerSessionID == localID && peer.nextOutgoing == SessionLedger.ATTEMPTS &&
            value.successfulAttempts == peer.successfulOutgoing && value.failedAttempts == peer.failedOutgoing)
        localFinishAcknowledged = true
    }
    fun remoteFinished() { remoteFinishSeen = true; remoteFinishAckDelivered = false }
    fun finishAckDelivered() { remoteFinishAckDelivered = true }
    fun canDepart(outgoingComplete: Boolean) =
        outgoingComplete && helloReceived && localFinishAcknowledged && remoteFinishSeen && remoteFinishAckDelivered
    fun acceptPacket(): Boolean = if (packets >= 256) false else { packets++; true }
}
