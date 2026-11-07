package org.trailmesh.app.protocol

import java.util.Base64
import org.junit.Assert.*
import org.junit.Test

class ReportAdmissionTest {
    @Test
    fun exactFutureToleranceAndSignatureBeforeExpiryMatchReference() {
        val root =
            StrictJSON.parse(
                javaClass.classLoader!!.getResourceAsStream("report-v1-vectors.json")!!.readBytes(),
                1_000_000,
                16,
            )
        val cases = (root["cases"] as ReportJSON.ArrayValue).values
        val frozen = cases.first()
        val wire = Base64.getDecoder().decode(frozen["wire_base64"]!!.text)
        val checked = ReportAdmission.validate(wire, frozen["now_ms"]!!.number!!).verified!!
        assertEquals(
            "accepted",
            ReportAdmission.validate(wire, checked.createdAt - 300_000).outcome,
        )
        assertEquals("invalid", ReportAdmission.validate(wire, checked.createdAt - 300_001).outcome)
        val bad = cases.first { it["name"]!!.text == "invalid-signature" }
        assertEquals(
            "invalid",
            ReportAdmission.validate(
                    Base64.getDecoder().decode(bad["wire_base64"]!!.text),
                    checked.expiresAt + 1,
                )
                .outcome,
        )
    }

    @Test
    fun allLiteralVectorsHaveExactCanonicalBytesAndProjection() {
        val source =
            requireNotNull(javaClass.classLoader!!.getResourceAsStream("report-v1-vectors.json")) {
                "Missing authoritative vectors"
            }
        val root = StrictJSON.parse(source.readBytes(), maxBytes = 1_000_000, maxDepth = 16)
        val cases = (root["cases"] as ReportJSON.ArrayValue).values
        assertEquals(24, cases.size)
        for (case in cases) {
            val name = case["name"]!!.text!!
            val wire = Base64.getDecoder().decode(case["wire_base64"]!!.text)
            val expected = case["expected"]!!
            val actual = ReportAdmission.validate(wire, case["now_ms"]!!.number!!)
            assertEquals(name, expected["outcome"]!!.text, actual.outcome)
            if (actual.outcome == "accepted") {
                val verified = requireNotNull(actual.verified)
                assertEquals(name, expected["bundle_id"]!!.text, verified.bundleID)
                assertArrayEquals(
                    name,
                    Base64.getDecoder().decode(expected["canonical_core_base64"]!!.text),
                    verified.canonicalCore,
                )
                assertArrayEquals(
                    name,
                    Base64.getDecoder().decode(expected["canonical_envelope_base64"]!!.text),
                    verified.canonicalEnvelope,
                )
                assertArrayEquals(wire, verified.originalWire)
                val projection = expected["report"]!!
                val report = verified.report
                assertEquals(
                    projection["event_id"]!!.text,
                    report.eventID.joinToString("") { "%02x".format(it.toInt() and 255) },
                )
                assertEquals(projection["category"]!!.text, report.category)
                assertEquals(projection["status"]!!.text, report.status)
                assertEquals(projection["note"]!!.text, report.note)
                assertEquals(projection["observed_at_ms"]!!.number, report.observedAt)
                assertEquals(projection["lat_e7"]!!.number, report.latE7)
                assertEquals(projection["lon_e7"]!!.number, report.lonE7)
                assertEquals(projection["accuracy_m"]!!.number, report.accuracyM)
                assertEquals(projection["supersedes"]!!.text, report.supersedes)
            } else assertNull(name, actual.verified)
        }
    }

    @Test
    fun invalidCallerClockIsExplicit() {
        for (now in listOf(-1L, 9_007_199_254_740_992L)) {
            assertThrows(IllegalArgumentException::class.java) {
                ReportAdmission.validate(byteArrayOf(), now)
            }
        }
    }
}
