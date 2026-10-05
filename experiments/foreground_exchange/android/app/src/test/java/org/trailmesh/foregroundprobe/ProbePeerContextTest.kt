package org.trailmesh.foregroundprobe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProbePeerContextTest {
    private val first = "00112233445566778899aabbccddeeff"
    private val second = "ffeeddccbbaa99887766554433221100"

    @Test
    fun contextRoundTripsStrictAsciiMetadata() {
        val android = ProbePeerContext(ProbePlatform.ANDROID, first, 2048)
        assertEquals("TM2|A|00112233445566778899aabbccddeeff|2048", android.encode())
        assertEquals(android, ProbePeerContext.parse(android.encode()))
        assertEquals(ProbePeerContext(ProbePlatform.IOS, second, 8192), ProbePeerContext.parse("TM2|I|$second|8192"))
        assertEquals(256, ProbePeerContext.parse("TM2|A|$first|256")?.payloadSize)
    }

    @Test
    fun contextRejectsUnboundedNoncanonicalAndUnsupportedMetadata() {
        for (invalid in listOf(
            "", "TM1|A|$first|2048", "TM2|X|$first|2048", "TM2|A|${first.uppercase()}|2048",
            "TM2|A|${first.dropLast(1)}|2048", "TM2|A|${"z".repeat(32)}|2048", "TM2|A|$first|02048",
            "TM2|A|$first|1024", "TM2|A|$first|0", "TM2|A|$first|-256", "TM2|A|$first|2048|extra",
            " TM2|A|$first|2048", "TM2|A|$first|2048\n", "TM2|A|$first|2048\u0000", "x".repeat(4096),
        )) {
            assertNull(invalid, ProbePeerContext.parse(invalid))
        }
    }

    @Test
    fun compatibilityRequiresDistinctSessionsSameSizeAndSupportedPlatformPair() {
        val android = ProbePeerContext(ProbePlatform.ANDROID, first, 2048)
        assertTrue(android.isCompatible(ProbePeerContext(ProbePlatform.IOS, second, 2048)))
        assertFalse(android.isCompatible(ProbePeerContext(ProbePlatform.IOS, first, 2048)))
        assertFalse(android.isCompatible(ProbePeerContext(ProbePlatform.IOS, second, 8192)))
        assertFalse(ProbePeerContext(ProbePlatform.IOS, first, 2048).isCompatible(ProbePeerContext(ProbePlatform.IOS, second, 2048)))
    }

    @Test
    fun initiationPolicyElectsExactlyOneCompatibleDevice() {
        val android = ProbePeerContext(ProbePlatform.ANDROID, first, 2048)
        val otherAndroid = ProbePeerContext(ProbePlatform.ANDROID, second, 2048)
        val ios = ProbePeerContext(ProbePlatform.IOS, second, 2048)
        assertTrue(android.canInitiate(otherAndroid))
        assertFalse(otherAndroid.canInitiate(android))
        assertFalse(android.canInitiate(ios))
        assertTrue(ios.canInitiate(android))
        assertFalse(android.canInitiate(android))
        assertFalse(android.canInitiate(ProbePeerContext(ProbePlatform.IOS, second, 8192)))
    }
}
