package org.trailmesh.app.protocol

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.Base64
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ReportAdmissionInstrumentedTest {
    @Test
    fun everySharedVectorUsesSameRawEd25519AndCanonicalBytesOnDevice() {
        val bytes =
            InstrumentationRegistry.getInstrumentation()
                .context
                .assets
                .open("report-v1-vectors.json")
                .use { it.readBytes() }
        val root = StrictJSON.parse(bytes, 1_000_000, 16)
        val cases = (root["cases"] as ReportJSON.ArrayValue).values
        assertEquals(24, cases.size)
        for (case in cases) {
            val name = case["name"]!!.text
            val expected = case["expected"]!!
            val wire = Base64.getDecoder().decode(case["wire_base64"]!!.text)
            val result = ReportAdmission.validate(wire, case["now_ms"]!!.number!!)
            assertEquals(name, expected["outcome"]!!.text, result.outcome)
            result.verified?.let {
                assertEquals(name, expected["bundle_id"]!!.text, it.bundleID)
                assertArrayEquals(
                    name,
                    Base64.getDecoder().decode(expected["canonical_core_base64"]!!.text),
                    it.canonicalCore,
                )
                assertArrayEquals(
                    name,
                    Base64.getDecoder().decode(expected["canonical_envelope_base64"]!!.text),
                    it.canonicalEnvelope,
                )
            }
        }
    }
}
