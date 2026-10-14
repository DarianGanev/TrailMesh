package org.trailmesh.foregroundprobe

internal enum class ProbePlatform(val wireCode: String) { ANDROID("A"), IOS("I") }

/** Ephemeral test metadata. A compatible context does not authenticate its peer. */
internal data class ProbePeerContext(val platform: ProbePlatform, val sessionID: String, val payloadSize: Int) {
    fun encode(): String {
        require(isValid()) { "invalid probe peer context" }
        return "TM2|${platform.wireCode}|$sessionID|$payloadSize"
    }

    fun isCompatible(peer: ProbePeerContext): Boolean =
        isValid() && peer.isValid() && sessionID != peer.sessionID && payloadSize == peer.payloadSize &&
            !(platform == ProbePlatform.IOS && peer.platform == ProbePlatform.IOS)

    fun canInitiate(peer: ProbePeerContext): Boolean = isCompatible(peer) && when {
        platform == ProbePlatform.IOS -> true
        peer.platform == ProbePlatform.IOS -> false
        else -> sessionID < peer.sessionID
    }

    private fun isValid(): Boolean = isValidSessionID(sessionID) && payloadSize in supportedPayloadSizes

    companion object {
        val supportedPayloadSizes: Set<Int> = setOf(256, 2048, 8192)

        fun isValidSessionID(value: String): Boolean =
            value.length == 32 && value.all { it in '0'..'9' || it in 'a'..'f' }

        fun parse(context: String): ProbePeerContext? {
            if (context.length !in 42..43 || context.any { it.code !in 32..126 }) return null
            val fields = context.split('|')
            if (fields.size != 4 || fields[0] != "TM2" || !isValidSessionID(fields[2])) return null
            val platform = when (fields[1]) { "A" -> ProbePlatform.ANDROID; "I" -> ProbePlatform.IOS; else -> return null }
            val payloadSize = when (fields[3]) { "256" -> 256; "2048" -> 2048; "8192" -> 8192; else -> return null }
            return ProbePeerContext(platform, fields[2], payloadSize)
        }
    }
}
