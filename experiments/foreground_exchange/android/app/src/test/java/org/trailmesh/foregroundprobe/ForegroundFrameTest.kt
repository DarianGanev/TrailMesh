package org.trailmesh.foregroundprobe

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ForegroundFrameTest {
    @Test
    fun deterministicTwoKibPayloadMatchesGoldenSha256() {
        val payload = ForegroundFrame.makeTestPayload(2048, attemptIndex = 0)

        assertEquals(2048, payload.size)
        assertEquals("b2a8170614e23194ae2951423d601987f518ce2f11205d7b0b708080103b9f76", ForegroundFrame.sha256Hex(payload))
    }

    @Test
    fun frameRoundTripsPayloadAndDataAttempt() {
        val payload = ForegroundFrame.makeTestPayload(2048, attemptIndex = 7)
        val message = ForegroundFrame.decodeDataMessage(ForegroundFrame.encodeDataMessage(7, payload))

        assertEquals(7, message.attemptIndex)
        assertArrayEquals(payload, message.frame.payload)
        assertEquals(ForegroundFrame.sha256Hex(payload), ForegroundFrame.hex(message.frame.digest))
    }

    @Test
    fun frameHeaderMatchesTheSharedPythonAndSwiftWireVector() {
        val payload = ForegroundFrame.makeTestPayload(2048, attemptIndex = 0)
        val frame = ForegroundFrame.encode(payload)

        assertEquals("00000800", ForegroundFrame.hex(frame.copyOfRange(0, 4)))
        assertEquals(
            "b2a8170614e23194ae2951423d601987f518ce2f11205d7b0b708080103b9f76",
            ForegroundFrame.hex(frame.copyOfRange(4, 36)),
        )
    }

    @Test
    fun frameRejectsCorruptionAndOversizedPayloads() {
        val damaged = ForegroundFrame.encode(ByteArray(8)).also { it[it.lastIndex] = 1 }

        assertFalse(runCatching { ForegroundFrame.decode(damaged) }.isSuccess)
        assertFalse(runCatching { ForegroundFrame.encode(ByteArray(ForegroundFrame.MAX_PAYLOAD_BYTES + 1)) }.isSuccess)
    }

    @Test
    fun acknowledgementRoundTripsAndRecognizesItsMessageType() {
        val digest = ForegroundFrame.sha256(ForegroundFrame.makeTestPayload(256, attemptIndex = 3))
        val encoded = ForegroundFrame.encodeAckMessage(3, accepted = true, digest = digest)
        val decoded = ForegroundFrame.decodeAckMessage(encoded)

        assertTrue(ForegroundFrame.isAckMessage(encoded))
        assertEquals(
            "544d41310000000301fab20605b31d3530c3072e00e660a170d3be0a06dcf1fd465726e2ef2630ea03",
            ForegroundFrame.hex(encoded),
        )
        assertEquals(3, decoded.attemptIndex)
        assertTrue(decoded.accepted)
        assertArrayEquals(digest, decoded.digest)
    }
}
