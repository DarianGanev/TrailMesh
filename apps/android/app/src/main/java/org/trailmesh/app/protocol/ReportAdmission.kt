package org.trailmesh.app.protocol

class ReportProjection(
    eventID: ByteArray,
    val category: String,
    val status: String,
    val observedAt: Long,
    val latE7: Long,
    val lonE7: Long,
    val accuracyM: Long,
    val note: String,
    val supersedes: String?,
) {
    private val eventBytes = eventID.copyOf()
    val eventID: ByteArray
        get() = eventBytes.copyOf()
}

class VerifiedReport
internal constructor(
    val bundleID: String,
    canonicalCore: ByteArray,
    canonicalEnvelope: ByteArray,
    signature: ByteArray,
    originalWire: ByteArray,
    authorKey: ByteArray,
    val createdAt: Long,
    val expiresAt: Long,
    val maxHops: Int,
    val report: ReportProjection,
) {
    private val coreBytes = canonicalCore.copyOf()
    private val envelopeBytes = canonicalEnvelope.copyOf()
    private val signatureBytes = signature.copyOf()
    private val wireBytes = originalWire.copyOf()
    private val authorBytes = authorKey.copyOf()
    val canonicalCore: ByteArray
        get() = coreBytes.copyOf()

    val canonicalEnvelope: ByteArray
        get() = envelopeBytes.copyOf()

    val signature: ByteArray
        get() = signatureBytes.copyOf()

    val originalWire: ByteArray
        get() = wireBytes.copyOf()

    val authorKey: ByteArray
        get() = authorBytes.copyOf()
}

data class AdmissionResult(
    val outcome: String,
    val verified: VerifiedReport? = null,
    val reason: String? = null,
)

object ReportAdmission {
    private val statuses =
        mapOf(
            "water" to setOf("flowing", "low", "dry", "unknown"),
            "obstruction" to setOf("clear", "partial", "blocked", "unknown"),
            "trail" to setOf("good", "muddy", "icy", "damaged", "blocked", "unknown"),
            "weather" to setOf("clear", "rain", "snow", "storm", "fog", "unknown"),
            "campsite" to setOf("available", "occupied", "closed", "unknown"),
            "hut" to setOf("open", "closed", "unknown"),
            "crowding" to setOf("quiet", "moderate", "busy", "unknown"),
            "note" to setOf("observed", "unknown"),
        )

    fun encode(bytes: ByteArray): String =
        java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    fun binary(value: ReportJSON?, size: Int): ByteArray {
        val text = requireNotNull(value?.text)
        require(
            text.isNotEmpty() &&
                text.all {
                    it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '-' || it == '_'
                },
        )
        val bytes = java.util.Base64.getUrlDecoder().decode(text)
        require(bytes.size == size && encode(bytes) == text)
        return bytes
    }

    fun identifier(value: ReportJSON?): String {
        val id = requireNotNull(value?.text)
        require(id.length == 64 && id.all { it in '0'..'9' || it in 'a'..'f' })
        return id
    }

    private fun fields(value: ReportJSON?, vararg names: String) {
        require(value is ReportJSON.ObjectValue && value.members.keys == names.toSet())
    }

    fun validate(wire: ByteArray, now: Long): AdmissionResult {
        require(now in 0..ReportJSON.SAFE_INTEGER) { "Invalid caller clock" }
        try {
            val envelope = StrictJSON.parse(wire)
            fields(envelope, "core", "signature", "bundle_id")
            val core = envelope["core"]!!
            fields(
                core,
                "protocol",
                "version",
                "kind",
                "author_key",
                "nonce",
                "created_at_ms",
                "expires_at_ms",
                "max_hops",
                "body",
            )
            require(core["protocol"]?.text == "trailmesh")
            val version = requireNotNull(core["version"]?.number)
            val kind = requireNotNull(core["kind"]?.text)
            if (version != 1L || kind != "report") return AdmissionResult("unsupported")
            val body = core["body"]!!
            fields(
                body,
                "event_id",
                "category",
                "status",
                "observed_at_ms",
                "lat_e7",
                "lon_e7",
                "accuracy_m",
                "note",
                "supersedes",
            )
            val author = binary(core["author_key"], 32)
            binary(core["nonce"], 16)
            val event = binary(body["event_id"], 16)
            val signature = binary(envelope["signature"], 64)
            val id = identifier(envelope["bundle_id"])
            val supersedes =
                if (body["supersedes"] === ReportJSON.NullValue) null
                else identifier(body["supersedes"])
            val category = requireNotNull(body["category"]?.text)
            val status = requireNotNull(body["status"]?.text)
            require(statuses[category]?.contains(status) == true)
            val note = requireNotNull(body["note"]?.text)
            require(
                note.codePointCount(0, note.length) <= 500 &&
                    note.toByteArray(Charsets.UTF_8).size <= 2048,
            )
            val created = requireNotNull(core["created_at_ms"]?.number)
            val expires = requireNotNull(core["expires_at_ms"]?.number)
            val hops = requireNotNull(core["max_hops"]?.number)
            val observed = requireNotNull(body["observed_at_ms"]?.number)
            val lat = requireNotNull(body["lat_e7"]?.number)
            val lon = requireNotNull(body["lon_e7"]?.number)
            val accuracy = requireNotNull(body["accuracy_m"]?.number)
            require(
                observed >= 0 &&
                    observed <= created &&
                    created < expires &&
                    expires - created <= 259_200_000,
            )
            require(
                hops in 0..12 &&
                    lat in -900_000_000..900_000_000 &&
                    lon in -1_800_000_000..1_800_000_000 &&
                    accuracy >= 0,
            )
            val canonical = core.canonicalBytes()
            val computed =
                java.security.MessageDigest.getInstance("SHA-256")
                    .digest("TrailMesh/id/v1\n".toByteArray() + canonical)
                    .joinToString("") { "%02x".format(it.toInt() and 255) }
            require(id == computed)
            com.google.crypto.tink.subtle
                .Ed25519Verify(author)
                .verify(signature, "TrailMesh/core/v1\n".toByteArray() + canonical)
            require(created <= now + 300_000)
            if (now >= expires) return AdmissionResult("expired")
            return AdmissionResult(
                "accepted",
                VerifiedReport(
                    id,
                    canonical,
                    envelope.canonicalBytes(),
                    signature,
                    wire,
                    author,
                    created,
                    expires,
                    hops.toInt(),
                    ReportProjection(
                        event,
                        category,
                        status,
                        observed,
                        lat,
                        lon,
                        accuracy,
                        note,
                        supersedes,
                    ),
                ),
            )
        } catch (_: IllegalArgumentException) {
            return AdmissionResult("invalid")
        } catch (_: java.security.GeneralSecurityException) {
            return AdmissionResult("invalid")
        }
    }
}
