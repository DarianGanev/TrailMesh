package org.trailmesh.foregroundprobe

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.Locale

internal object ForegroundFrame {
    const val MAX_PAYLOAD_BYTES = 16 * 1024
    const val ATTEMPTS_PER_BATCH = 20
    private const val FRAME_HEADER_BYTES = 4 + 32
    private const val SESSION_DATA_HEADER_BYTES = 4 + 16 + 4 + FRAME_HEADER_BYTES
    private val dataMagic = "TMD1".toByteArray(Charsets.US_ASCII)
    private val ackMagic = "TMA1".toByteArray(Charsets.US_ASCII)
    private val helloMagic = "TMH2".toByteArray(Charsets.US_ASCII)
    private val sessionDataMagic = "TMD2".toByteArray(Charsets.US_ASCII)
    private val sessionAckMagic = "TMA2".toByteArray(Charsets.US_ASCII)
    private val finishMagic = "TMF2".toByteArray(Charsets.US_ASCII)

    data class DecodedFrame(val payload: ByteArray, val digest: ByteArray)
    data class DataMessage(val attemptIndex: Int, val frame: DecodedFrame)
    data class AckMessage(val attemptIndex: Int, val accepted: Boolean, val digest: ByteArray)
    data class HelloMessage(val sessionID: String, val peerSessionID: String, val payloadSize: Int, val attemptCount: Int)
    data class SessionDataMessage(val sessionID: String, val attemptIndex: Int, val frame: DecodedFrame)
    data class SessionAckMessage(val sessionID: String, val attemptIndex: Int, val accepted: Boolean, val digest: ByteArray)
    data class FinishMessage(val sessionID: String, val peerSessionID: String, val acknowledgement: Boolean, val successfulAttempts: Int, val failedAttempts: Int)

    fun makeTestPayload(size: Int, attemptIndex: Int): ByteArray {
        require(size in 1..MAX_PAYLOAD_BYTES) { "payload size is outside the 16 KiB limit" }
        require(attemptIndex >= 0) { "attempt index must be non-negative" }
        return ByteArray(size) { index -> ((index + attemptIndex % 251) % 251).toByte() }
    }

    fun sha256(payload: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(payload)

    fun sha256Hex(payload: ByteArray): String = hex(sha256(payload))

    fun hex(bytes: ByteArray): String = bytes.joinToString("") {
        "%02x".format(Locale.ROOT, it.toInt() and 0xff)
    }

    fun encode(payload: ByteArray): ByteArray {
        require(payload.size <= MAX_PAYLOAD_BYTES) { "payload exceeds the 16 KiB limit" }
        val buffer = ByteBuffer.allocate(FRAME_HEADER_BYTES + payload.size).order(ByteOrder.BIG_ENDIAN)
        buffer.putInt(payload.size)
        buffer.put(sha256(payload))
        buffer.put(payload)
        return buffer.array()
    }

    fun decode(frame: ByteArray): DecodedFrame {
        require(frame.size >= FRAME_HEADER_BYTES) { "frame is truncated" }
        val buffer = ByteBuffer.wrap(frame).order(ByteOrder.BIG_ENDIAN)
        val size = buffer.int
        require(size in 0..MAX_PAYLOAD_BYTES) { "payload exceeds the 16 KiB limit" }
        require(frame.size == FRAME_HEADER_BYTES + size) { "frame length does not match payload length" }
        val expectedDigest = ByteArray(32).also { buffer.get(it) }
        val payload = ByteArray(size).also { buffer.get(it) }
        val actualDigest = sha256(payload)
        require(MessageDigest.isEqual(expectedDigest, actualDigest)) { "payload checksum mismatch" }
        return DecodedFrame(payload, actualDigest)
    }

    fun encodeDataMessage(attemptIndex: Int, payload: ByteArray): ByteArray {
        require(attemptIndex >= 0) { "attempt index must be non-negative" }
        require(payload.size <= MAX_PAYLOAD_BYTES) { "payload exceeds the 16 KiB limit" }
        return ByteBuffer.allocate(dataMagic.size + 4 + FRAME_HEADER_BYTES + payload.size)
            .order(ByteOrder.BIG_ENDIAN)
            .put(dataMagic)
            .putInt(attemptIndex)
            .put(encode(payload))
            .array()
    }

    fun decodeDataMessage(message: ByteArray): DataMessage {
        require(message.size >= dataMagic.size + 4 + FRAME_HEADER_BYTES) { "data message is truncated" }
        require(message.size <= dataMagic.size + 4 + FRAME_HEADER_BYTES + MAX_PAYLOAD_BYTES) { "data message exceeds the 16 KiB payload limit" }
        val buffer = ByteBuffer.wrap(message).order(ByteOrder.BIG_ENDIAN)
        require(ByteArray(dataMagic.size).also { buffer.get(it) }.contentEquals(dataMagic)) { "unknown message type" }
        val attemptIndex = buffer.int
        require(attemptIndex >= 0) { "attempt index must be non-negative" }
        val frame = ByteArray(buffer.remaining()).also(buffer::get)
        return DataMessage(attemptIndex, decode(frame))
    }

    fun encodeAckMessage(attemptIndex: Int, accepted: Boolean, digest: ByteArray): ByteArray {
        require(attemptIndex >= 0) { "attempt index must be non-negative" }
        require(digest.size == 32) { "SHA-256 digest must be 32 bytes" }
        return ByteBuffer.allocate(4 + 4 + 1 + 32).order(ByteOrder.BIG_ENDIAN)
            .put(ackMagic)
            .putInt(attemptIndex)
            .put(if (accepted) 1 else 0)
            .put(digest)
            .array()
    }

    fun decodeAckMessage(message: ByteArray): AckMessage {
        require(message.size == 41) { "acknowledgement has an invalid size" }
        val buffer = ByteBuffer.wrap(message).order(ByteOrder.BIG_ENDIAN)
        require(ByteArray(4).also(buffer::get).contentEquals(ackMagic)) { "unknown message type" }
        val attemptIndex = buffer.int
        require(attemptIndex >= 0) { "attempt index must be non-negative" }
        val accepted = when (buffer.get().toInt() and 0xff) {
            0 -> false
            1 -> true
            else -> throw IllegalArgumentException("acknowledgement status is invalid")
        }
        return AckMessage(attemptIndex, accepted, ByteArray(32).also { buffer.get(it) })
    }

    fun isAckMessage(message: ByteArray): Boolean = message.size >= ackMagic.size &&
        message.copyOfRange(0, ackMagic.size).contentEquals(ackMagic)

    fun encodeHelloMessage(sessionID: String, peerSessionID: String, payloadSize: Int): ByteArray {
        require(sessionID != peerSessionID) { "peer sessions must be distinct" }
        require(payloadSize in ProbePeerContext.supportedPayloadSizes) { "unsupported probe payload size" }
        return ByteBuffer.allocate(44).order(ByteOrder.BIG_ENDIAN)
            .put(helloMagic).put(sessionBytes(sessionID)).put(sessionBytes(peerSessionID))
            .putInt(payloadSize).putInt(ATTEMPTS_PER_BATCH).array()
    }

    fun decodeHelloMessage(message: ByteArray): HelloMessage {
        val buffer = messageBuffer(message, 44, helloMagic)
        val sessionID = readSessionID(buffer)
        val peerSessionID = readSessionID(buffer)
        val payloadSize = buffer.int
        val attemptCount = buffer.int
        require(sessionID != peerSessionID) { "peer sessions must be distinct" }
        require(payloadSize in ProbePeerContext.supportedPayloadSizes) { "unsupported probe payload size" }
        require(attemptCount == ATTEMPTS_PER_BATCH) { "unsupported probe attempt count" }
        return HelloMessage(sessionID, peerSessionID, payloadSize, attemptCount)
    }

    fun encodeSessionDataMessage(sessionID: String, attemptIndex: Int, payload: ByteArray): ByteArray {
        requireAttempt(attemptIndex)
        require(payload.size in 1..MAX_PAYLOAD_BYTES) { "probe payload size is outside the limit" }
        return ByteBuffer.allocate(SESSION_DATA_HEADER_BYTES + payload.size).order(ByteOrder.BIG_ENDIAN)
            .put(sessionDataMagic).put(sessionBytes(sessionID)).putInt(attemptIndex).put(encode(payload)).array()
    }

    fun decodeSessionDataMessage(message: ByteArray): SessionDataMessage {
        require(message.size in (SESSION_DATA_HEADER_BYTES + 1)..(SESSION_DATA_HEADER_BYTES + MAX_PAYLOAD_BYTES)) { "probe data message has an invalid size" }
        val buffer = ByteBuffer.wrap(message).order(ByteOrder.BIG_ENDIAN)
        requireMagic(buffer, sessionDataMagic)
        val sessionID = readSessionID(buffer)
        val attemptIndex = buffer.int
        requireAttempt(attemptIndex)
        val payloadSize = buffer.getInt(24)
        require(payloadSize in 1..MAX_PAYLOAD_BYTES && message.size == SESSION_DATA_HEADER_BYTES + payloadSize) { "probe payload length is invalid" }
        val frame = ByteArray(buffer.remaining()).also(buffer::get)
        return SessionDataMessage(sessionID, attemptIndex, decode(frame))
    }

    fun encodeSessionAckMessage(sessionID: String, attemptIndex: Int, accepted: Boolean, digest: ByteArray): ByteArray {
        requireAttempt(attemptIndex)
        require(digest.size == 32) { "SHA-256 digest must be 32 bytes" }
        return ByteBuffer.allocate(57).order(ByteOrder.BIG_ENDIAN)
            .put(sessionAckMagic).put(sessionBytes(sessionID)).putInt(attemptIndex)
            .put(if (accepted) 1 else 0).put(digest).array()
    }

    fun decodeSessionAckMessage(message: ByteArray): SessionAckMessage {
        val buffer = messageBuffer(message, 57, sessionAckMagic)
        val sessionID = readSessionID(buffer)
        val attemptIndex = buffer.int
        requireAttempt(attemptIndex)
        val status = buffer.get().toInt() and 0xff
        require(status in 0..1) { "acknowledgement status is invalid" }
        return SessionAckMessage(sessionID, attemptIndex, status == 1, ByteArray(32).also(buffer::get))
    }

    fun encodeFinishMessage(sessionID: String, peerSessionID: String, acknowledgement: Boolean, successfulAttempts: Int, failedAttempts: Int): ByteArray {
        require(sessionID != peerSessionID) { "peer sessions must be distinct" }
        requireTotals(successfulAttempts, failedAttempts)
        return ByteBuffer.allocate(45).order(ByteOrder.BIG_ENDIAN)
            .put(finishMagic).put(sessionBytes(sessionID)).put(sessionBytes(peerSessionID))
            .put(if (acknowledgement) 1 else 0).putInt(successfulAttempts).putInt(failedAttempts).array()
    }

    fun decodeFinishMessage(message: ByteArray): FinishMessage {
        val buffer = messageBuffer(message, 45, finishMagic)
        val sessionID = readSessionID(buffer)
        val peerSessionID = readSessionID(buffer)
        require(sessionID != peerSessionID) { "peer sessions must be distinct" }
        val kind = buffer.get().toInt() and 0xff
        require(kind in 0..1) { "finish status is invalid" }
        val success = buffer.int
        val failure = buffer.int
        requireTotals(success, failure)
        return FinishMessage(sessionID, peerSessionID, kind == 1, success, failure)
    }

    fun isHelloMessage(message: ByteArray): Boolean = hasMagic(message, helloMagic)
    fun isSessionAckMessage(message: ByteArray): Boolean = hasMagic(message, sessionAckMagic)
    fun isFinishMessage(message: ByteArray): Boolean = hasMagic(message, finishMagic)

    private fun requireAttempt(attemptIndex: Int) {
        require(attemptIndex in 0 until ATTEMPTS_PER_BATCH) { "attempt index is outside the batch" }
    }

    private fun requireTotals(success: Int, failure: Int) {
        require(success in 0..ATTEMPTS_PER_BATCH && failure in 0..ATTEMPTS_PER_BATCH && success + failure == ATTEMPTS_PER_BATCH) { "finish totals must describe exactly one batch" }
    }

    private fun sessionBytes(sessionID: String): ByteArray {
        require(ProbePeerContext.isValidSessionID(sessionID)) { "session ID must contain 32 lowercase hex characters" }
        return ByteArray(16) { index -> sessionID.substring(index * 2, index * 2 + 2).toInt(16).toByte() }
    }

    private fun readSessionID(buffer: ByteBuffer): String = hex(ByteArray(16).also(buffer::get))

    private fun messageBuffer(message: ByteArray, size: Int, magic: ByteArray): ByteBuffer {
        require(message.size == size) { "probe message has an invalid size" }
        return ByteBuffer.wrap(message).order(ByteOrder.BIG_ENDIAN).also { requireMagic(it, magic) }
    }

    private fun requireMagic(buffer: ByteBuffer, magic: ByteArray) {
        require(ByteArray(4).also(buffer::get).contentEquals(magic)) { "unknown message type" }
    }

    private fun hasMagic(message: ByteArray, magic: ByteArray): Boolean =
        message.size >= 4 && (0 until 4).all { message[it] == magic[it] }
}
