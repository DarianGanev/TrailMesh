package org.trailmesh.foregroundprobe

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ForegroundFrameTest {
    @Test
    fun legacyPayloadGenerationDoesNotOverflowAtLargestSignedAttempt() {
        assertEquals(
            "a93ad1a83211655a5a8ede8c88e0724f0d72e48bb8232150e5f9a6fa2a05a16e",
            ForegroundFrame.sha256Hex(ForegroundFrame.makeTestPayload(256, Int.MAX_VALUE)),
        )
    }

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

    @Test
    fun helloMatchesCrossPlatformGoldenAndBindsBothSessions() {
        val encoded = ForegroundFrame.encodeHelloMessage(sessionID, peerSessionID, 2048)
        assertEquals("544d483200112233445566778899aabbccddeeffffeeddccbbaa998877665544332211000000080000000014", ForegroundFrame.hex(encoded))
        assertTrue(ForegroundFrame.isHelloMessage(encoded))
        val decoded = ForegroundFrame.decodeHelloMessage(encoded)
        assertEquals(sessionID, decoded.sessionID)
        assertEquals(peerSessionID, decoded.peerSessionID)
        assertEquals(2048, decoded.payloadSize)
        assertEquals(20, decoded.attemptCount)
    }

    @Test
    fun sessionDataMatchesCrossPlatformGoldenAndPreservesRawFrame() {
        val payload = "probe".toByteArray(Charsets.US_ASCII)
        val encoded = ForegroundFrame.encodeSessionDataMessage(sessionID, 3, payload)
        assertEquals("544d443200112233445566778899aabbccddeeff0000000300000005ba9c736f19e7f60b7f6764adb0b7908c0a2b394e09b6c09863528c7f2bc8609570726f6265", ForegroundFrame.hex(encoded))
        val decoded = ForegroundFrame.decodeSessionDataMessage(encoded)
        assertEquals(sessionID, decoded.sessionID)
        assertEquals(3, decoded.attemptIndex)
        assertArrayEquals(payload, decoded.frame.payload)
        assertArrayEquals(ForegroundFrame.encode(payload), encoded.copyOfRange(24, encoded.size))
    }

    @Test
    fun sessionAcknowledgementMatchesCrossPlatformGolden() {
        val digest = hexBytes("ba9c736f19e7f60b7f6764adb0b7908c0a2b394e09b6c09863528c7f2bc86095")
        val encoded = ForegroundFrame.encodeSessionAckMessage(sessionID, 3, true, digest)
        assertEquals("544d413200112233445566778899aabbccddeeff0000000301ba9c736f19e7f60b7f6764adb0b7908c0a2b394e09b6c09863528c7f2bc86095", ForegroundFrame.hex(encoded))
        assertTrue(ForegroundFrame.isSessionAckMessage(encoded))
        assertFalse(ForegroundFrame.isAckMessage(encoded))
        val decoded = ForegroundFrame.decodeSessionAckMessage(encoded)
        assertEquals(sessionID, decoded.sessionID)
        assertEquals(3, decoded.attemptIndex)
        assertTrue(decoded.accepted)
        assertArrayEquals(digest, decoded.digest)
    }

    @Test
    fun finishMatchesCrossPlatformGoldenAndEchoCanReverseSessions() {
        val encoded = ForegroundFrame.encodeFinishMessage(sessionID, peerSessionID, false, 18, 2)
        assertEquals("544d463200112233445566778899aabbccddeeffffeeddccbbaa99887766554433221100000000001200000002", ForegroundFrame.hex(encoded))
        assertTrue(ForegroundFrame.isFinishMessage(encoded))
        val decoded = ForegroundFrame.decodeFinishMessage(encoded)
        assertEquals(sessionID, decoded.sessionID)
        assertEquals(peerSessionID, decoded.peerSessionID)
        assertFalse(decoded.acknowledgement)
        assertEquals(18, decoded.successfulAttempts)
        assertEquals(2, decoded.failedAttempts)
        val ack = ForegroundFrame.decodeFinishMessage(
            ForegroundFrame.encodeFinishMessage(peerSessionID, sessionID, true, 18, 2),
        )
        assertTrue(ack.acknowledgement)
        assertEquals(peerSessionID, ack.sessionID)
        assertEquals(sessionID, ack.peerSessionID)
    }

    @Test
    fun sessionMessagesMatchIndependentRepositoryGoldenVectors() {
        val sender = "000102030405060708090a0b0c0d0e0f"
        val peer = "101112131415161718191a1b1c1d1e1f"
        val payload = byteArrayOf(3, 4, 5, 6)
        val digest = hexBytes("0488cd1104793edb7467998202babda2bef3061a13d7a940b6cb50f70c5d5070")
        assertEquals("544d4832000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f0000080000000014", ForegroundFrame.hex(ForegroundFrame.encodeHelloMessage(sender, peer, 2048)))
        assertEquals("544d4432000102030405060708090a0b0c0d0e0f00000003000000040488cd1104793edb7467998202babda2bef3061a13d7a940b6cb50f70c5d507003040506", ForegroundFrame.hex(ForegroundFrame.encodeSessionDataMessage(sender, 3, payload)))
        assertEquals("544d4132000102030405060708090a0b0c0d0e0f00000003010488cd1104793edb7467998202babda2bef3061a13d7a940b6cb50f70c5d5070", ForegroundFrame.hex(ForegroundFrame.encodeSessionAckMessage(sender, 3, true, digest)))
        assertEquals("544d4632000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f000000001300000001", ForegroundFrame.hex(ForegroundFrame.encodeFinishMessage(sender, peer, false, 19, 1)))
        assertEquals("544d4632101112131415161718191a1b1c1d1e1f000102030405060708090a0b0c0d0e0f010000001300000001", ForegroundFrame.hex(ForegroundFrame.encodeFinishMessage(peer, sender, true, 19, 1)))
    }

    @Test
    fun sessionDataRejectsEmptyOversizedCorruptAndOutOfBatchFrames() {
        for (index in listOf(-1, 20, Int.MAX_VALUE)) {
            assertRejected { ForegroundFrame.encodeSessionDataMessage(sessionID, index, byteArrayOf(1)) }
        }
        assertRejected { ForegroundFrame.encodeSessionDataMessage(sessionID, 0, byteArrayOf()) }
        assertRejected { ForegroundFrame.encodeSessionDataMessage(sessionID, 0, ByteArray(16 * 1024 + 1)) }
        val maximum = ForegroundFrame.encodeSessionDataMessage(sessionID, 19, ByteArray(16 * 1024))
        assertEquals(16 * 1024, ForegroundFrame.decodeSessionDataMessage(maximum).frame.payload.size)
        val valid = ForegroundFrame.encodeSessionDataMessage(sessionID, 0, byteArrayOf(1))
        assertRejected { ForegroundFrame.decodeSessionDataMessage(valid + 0) }
        assertRejected { ForegroundFrame.decodeSessionDataMessage(valid.copyOfRange(0, valid.size - 1)) }
        assertRejected { ForegroundFrame.decodeSessionDataMessage(valid.copyOf().also { it[it.lastIndex] = 2 }) }
        assertRejected { ForegroundFrame.decodeSessionDataMessage(valid.copyOf().also { it[23] = 20 }) }
        assertRejected { ForegroundFrame.decodeSessionDataMessage(valid.copyOf().also { it[20] = 0x80.toByte() }) }
        assertRejected { ForegroundFrame.decodeSessionDataMessage(ByteArray(16 * 1024 + 61)) }
        assertRejected { ForegroundFrame.decodeSessionDataMessage(hexBytes("544d4432") + hexBytes(sessionID) + ByteArray(4) + ForegroundFrame.encode(byteArrayOf())) }
    }

    @Test
    fun helloAndFinishRejectInvalidLengthsIdentitiesAndFields() {
        assertRejected { ForegroundFrame.encodeHelloMessage(sessionID, sessionID, 2048) }
        for (invalid in listOf("", sessionID.uppercase(), sessionID.dropLast(1), "z".repeat(32))) {
            assertRejected { ForegroundFrame.encodeHelloMessage(invalid, peerSessionID, 2048) }
            assertRejected { ForegroundFrame.encodeSessionDataMessage(invalid, 0, byteArrayOf(1)) }
        }
        assertRejected { ForegroundFrame.encodeHelloMessage(sessionID, peerSessionID, 1024) }
        val hello = ForegroundFrame.encodeHelloMessage(sessionID, peerSessionID, 2048)
        assertRejected { ForegroundFrame.decodeHelloMessage(hello + 0) }
        assertRejected { ForegroundFrame.decodeHelloMessage(hello.copyOf().also { it[43] = 21 }) }
        assertRejected { ForegroundFrame.decodeHelloMessage(hello.copyOf().also { it[0] = 0 }) }
        assertRejected { ForegroundFrame.decodeHelloMessage(hello.copyOf().also { hexBytes(sessionID).copyInto(it, 20) }) }
        for ((success, failure) in listOf(0 to 19, 20 to 1, -1 to 21, Int.MAX_VALUE to 0)) {
            assertRejected { ForegroundFrame.encodeFinishMessage(sessionID, peerSessionID, false, success, failure) }
        }
        val finish = ForegroundFrame.encodeFinishMessage(sessionID, peerSessionID, false, 20, 0)
        assertRejected { ForegroundFrame.decodeFinishMessage(finish + 0) }
        assertRejected { ForegroundFrame.decodeFinishMessage(finish.copyOf().also { it[36] = 2 }) }
        assertRejected { ForegroundFrame.decodeFinishMessage(finish.copyOf().also { it[40] = 19 }) }
        assertRejected { ForegroundFrame.decodeFinishMessage(finish.copyOf().also { it[37] = 0xff.toByte() }) }
    }

    @Test
    fun sessionAcknowledgementRejectsMalformedStatusDigestAndIndex() {
        val ack = ForegroundFrame.encodeSessionAckMessage(sessionID, 19, false, ByteArray(32))
        assertFalse(ForegroundFrame.decodeSessionAckMessage(ack).accepted)
        assertRejected { ForegroundFrame.encodeSessionAckMessage(sessionID, 20, true, ByteArray(32)) }
        assertRejected { ForegroundFrame.encodeSessionAckMessage(sessionID, 0, true, ByteArray(31)) }
        assertRejected { ForegroundFrame.decodeSessionAckMessage(ack + 0) }
        assertRejected { ForegroundFrame.decodeSessionAckMessage(ack.copyOf().also { it[24] = 2 }) }
        assertRejected { ForegroundFrame.decodeSessionAckMessage(ack.copyOf().also { it[23] = 20 }) }
        assertRejected { ForegroundFrame.decodeSessionAckMessage(ack.copyOf().also { it[20] = 0xff.toByte() }) }
    }

    private fun assertRejected(block: () -> Unit) {
        assertFalse(runCatching(block).isSuccess)
    }

    private fun hexBytes(value: String): ByteArray = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private val sessionID = "00112233445566778899aabbccddeeff"
    private val peerSessionID = "ffeeddccbbaa99887766554433221100"
}
