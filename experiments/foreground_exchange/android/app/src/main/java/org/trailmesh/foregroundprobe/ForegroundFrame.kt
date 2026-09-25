package org.trailmesh.foregroundprobe

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.Locale

internal object ForegroundFrame {
    const val MAX_PAYLOAD_BYTES = 16 * 1024
    private const val FRAME_HEADER_BYTES = 4 + 32
    private val dataMagic = "TMD1".toByteArray(Charsets.US_ASCII)
    private val ackMagic = "TMA1".toByteArray(Charsets.US_ASCII)

    data class DecodedFrame(val payload: ByteArray, val digest: ByteArray)
    data class DataMessage(val attemptIndex: Int, val frame: DecodedFrame)
    data class AckMessage(val attemptIndex: Int, val accepted: Boolean, val digest: ByteArray)

    fun makeTestPayload(size: Int, attemptIndex: Int): ByteArray {
        require(size in 1..MAX_PAYLOAD_BYTES) { "payload size is outside the 16 KiB limit" }
        require(attemptIndex >= 0) { "attempt index must be non-negative" }
        return ByteArray(size) { index -> ((index + attemptIndex) % 251).toByte() }
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
        return ByteBuffer.allocate(dataMagic.size + 4 + FRAME_HEADER_BYTES + payload.size)
            .order(ByteOrder.BIG_ENDIAN)
            .put(dataMagic)
            .putInt(attemptIndex)
            .put(encode(payload))
            .array()
    }

    fun decodeDataMessage(message: ByteArray): DataMessage {
        require(message.size >= dataMagic.size + 4 + FRAME_HEADER_BYTES) { "data message is truncated" }
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
}
