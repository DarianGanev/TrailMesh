package org.trailmesh.app.exchange

import java.nio.ByteBuffer
import java.nio.ByteOrder

class ExchangeException(val unsupported: Boolean = false) :
    Exception(if (unsupported) "unsupported" else "protocol")

/** Values are binary protocol fields; report bytes are never reserialized. */
sealed class ExchangeMessage {
    data class Hello(val features: Long = 1, val maxFrame: Int = 16384, val maxChunk: Int = 1024) :
        ExchangeMessage()

    data class Summary(val page: Int, val more: Boolean, val entries: List<ReportDescriptor>) :
        ExchangeMessage()

    data class Request(val ids: List<String>) : ExchangeMessage()

    data class Offer(val transfer: Int, val report: ReportDescriptor) : ExchangeMessage()

    data class Chunk(val transfer: Int, val offset: Int, val total: Int, val data: ByteArray) :
        ExchangeMessage()

    data class Received(val transfer: Int, val id: String, val result: Int) : ExchangeMessage()

    data class Close(val reason: Int) : ExchangeMessage()

    data object Done : ExchangeMessage()
}

data class ExchangeFrame(val source: String, val destination: String, val message: ExchangeMessage)

object ExchangeWire {
    const val ZERO = "00000000000000000000000000000000"

    fun unhex(value: String): ByteArray {
        require(value.length % 2 == 0)
        return value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    }

    fun hex(value: ByteArray) = value.joinToString("") { "%02x".format(it.toInt() and 255) }

    private fun check(value: Boolean) {
        if (!value) throw ExchangeException()
    }

    private fun nonce(value: String) = value.matches(Regex("[0-9a-f]{32}"))

    private fun id(value: String) = value.matches(Regex("[0-9a-f]{64}"))

    private fun descriptor(d: ReportDescriptor) {
        check(id(d.id) && d.total in 1..8192 && d.hops in 1..12)
    }

    fun encode(frame: ExchangeFrame, maxFrame: Int = 16384): ByteArray {
        check(nonce(frame.source) && nonce(frame.destination) && frame.source != ZERO)
        val b = ByteBuffer.allocate(16388).order(ByteOrder.BIG_ENDIAN)
        b.position(4)
        b.put(byteArrayOf(84, 77, 88, 82, 1, 0))
        val m = frame.message
        val kind =
            when (m) {
                is ExchangeMessage.Hello -> 1
                is ExchangeMessage.Summary -> 2
                is ExchangeMessage.Request -> 3
                is ExchangeMessage.Offer -> 4
                is ExchangeMessage.Chunk -> 5
                is ExchangeMessage.Received -> 6
                is ExchangeMessage.Close -> 7
                ExchangeMessage.Done -> 8
            }
        check(
            if (kind == 1) frame.destination == ZERO
            else frame.destination != ZERO && frame.source != frame.destination
        )
        b.put(kind.toByte())
        b.put(unhex(frame.source))
        b.put(unhex(frame.destination))
        fun u8(n: Int) {
            b.put(n.toByte())
        }
        fun u16(n: Int) {
            b.putShort(n.toShort())
        }
        fun ids(values: List<String>) {
            check(
                values.size <= 8 &&
                    values.all(::id) &&
                    values.zipWithNext().all { it.first < it.second }
            )
            u8(values.size)
            values.forEach { b.put(unhex(it)) }
        }
        when (m) {
            is ExchangeMessage.Hello -> {
                check(
                    m.features in 0..0xffffffffL &&
                        m.maxFrame in 512..16384 &&
                        m.maxChunk in 64..1024
                )
                if (m.features and 1L == 0L) throw ExchangeException(true)
                b.putInt(m.features.toInt())
                u16(m.maxFrame)
                u16(m.maxChunk)
            }
            is ExchangeMessage.Summary -> {
                check(
                    m.page in 0..7 &&
                        m.entries.size <= 8 &&
                        m.entries.zipWithNext().all { it.first.id < it.second.id }
                )
                u16(m.page)
                u8(if (m.more) 1 else 0)
                u8(m.entries.size)
                m.entries.forEach {
                    descriptor(it)
                    b.put(unhex(it.id))
                    u16(it.total)
                    u8(it.hops)
                }
            }
            is ExchangeMessage.Request -> ids(m.ids)
            is ExchangeMessage.Offer -> {
                check(m.transfer in 1..32)
                descriptor(m.report)
                b.putInt(m.transfer)
                b.put(unhex(m.report.id))
                u16(m.report.total)
                u8(m.report.hops)
            }
            is ExchangeMessage.Chunk -> {
                check(
                    m.transfer in 1..32 &&
                        m.total in 1..8192 &&
                        m.offset >= 0 &&
                        m.data.size in 1..1024 &&
                        m.offset.toLong() + m.data.size <= m.total
                )
                b.putInt(m.transfer)
                u16(m.offset)
                u16(m.total)
                b.put(m.data)
            }
            is ExchangeMessage.Received -> {
                check(m.transfer in 1..32 && id(m.id) && m.result in 0..5)
                b.putInt(m.transfer)
                b.put(unhex(m.id))
                u8(m.result)
            }
            is ExchangeMessage.Close -> {
                check(m.reason in 0..7)
                u8(m.reason)
            }
            ExchangeMessage.Done -> Unit
        }
        val size = b.position() - 4
        check(size <= maxFrame)
        b.putInt(0, size)
        return b.array().copyOf(size + 4)
    }

    fun decode(bytes: ByteArray, maxFrame: Int = 16384): ExchangeFrame {
        try {
            check(bytes.size >= 43)
            val b = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
            val length = b.int.toLong() and 0xffffffffL
            check(length in 1..minOf(maxFrame, 16384).toLong() && length == bytes.size - 4L)
            check(b.int == 0x544d5852)
            val major = b.get().toInt() and 255
            val minor = b.get().toInt() and 255
            if (major != 1 || minor != 0) throw ExchangeException(true)
            fun u8() = b.get().toInt() and 255
            fun u16() = b.short.toInt() and 65535
            fun raw(n: Int) = ByteArray(n).also { b.get(it) }
            fun id() = hex(raw(32))
            fun transfer(): Int {
                val t = b.int
                check(t in 1..32)
                return t
            }
            val kind = u8()
            val source = hex(raw(16))
            val dest = hex(raw(16))
            val m =
                when (kind) {
                    1 -> ExchangeMessage.Hello(b.int.toLong() and 0xffffffffL, u16(), u16())
                    2 -> {
                        val page = u16()
                        val more = u8()
                        check(more in 0..1)
                        val count = u8()
                        check(count <= 8)
                        ExchangeMessage.Summary(
                            page,
                            more == 1,
                            List(count) { ReportDescriptor(id(), u16(), u8()) },
                        )
                    }
                    3 -> {
                        val count = u8()
                        check(count <= 8)
                        ExchangeMessage.Request(List(count) { id() })
                    }
                    4 -> ExchangeMessage.Offer(transfer(), ReportDescriptor(id(), u16(), u8()))
                    5 -> {
                        val t = transfer()
                        val offset = u16()
                        val total = u16()
                        check(b.remaining() in 1..1024)
                        ExchangeMessage.Chunk(t, offset, total, raw(b.remaining()))
                    }
                    6 -> ExchangeMessage.Received(transfer(), id(), u8())
                    7 -> ExchangeMessage.Close(u8())
                    8 -> ExchangeMessage.Done
                    else -> throw ExchangeException()
                }
            check(!b.hasRemaining())
            val frame = ExchangeFrame(source, dest, m)
            encode(frame, maxFrame) // one validation path for ranges, ordering, destinations.
            return frame
        } catch (e: ExchangeException) {
            throw e
        } catch (_: Exception) {
            throw ExchangeException()
        }
    }
}

/** At most one bounded frame allocation; callback output and input are also bounded. */
class ExchangeDecoder(var maxFrame: Int = 16384) {
    private val prefix = ByteArray(4)
    private var prefixCount = 0
    private var payload: ByteArray? = null
    private var count = 0

    internal fun consume(value: Byte): ExchangeFrame? {
        var target = payload
        if (target == null) {
            prefix[prefixCount++] = value
            if (prefixCount == 4) {
                val length = ByteBuffer.wrap(prefix).int.toLong() and 0xffffffffL
                if (length !in 1..minOf(maxFrame, 16384).toLong()) throw ExchangeException()
                target = ByteArray(length.toInt() + 4)
                prefix.copyInto(target)
                payload = target
                count = 4
            }
        } else {
            target[count++] = value
            if (count == target.size) {
                val frame = ExchangeWire.decode(target, maxFrame)
                payload = null
                prefixCount = 0
                count = 0
                return frame
            }
        }
        return null
    }

    fun feed(bytes: ByteArray): List<ExchangeFrame> {
        if (bytes.size > 262144) throw ExchangeException()
        val result = mutableListOf<ExchangeFrame>()
        for (value in bytes) {
            val frame = consume(value) ?: continue
            if (result.size == 64) throw ExchangeException()
            result.add(frame)
        }
        return result
    }

    fun finish() {
        if (prefixCount != 0 || payload != null) throw ExchangeException()
    }
}
