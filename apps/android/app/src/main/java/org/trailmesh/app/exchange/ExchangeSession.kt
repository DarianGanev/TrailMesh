package org.trailmesh.app.exchange

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.trailmesh.app.persistence.StoreOutcome

class ExchangeAction(val generation: Long, bytes: ByteArray) {
    private val wire = bytes.copyOf()
    val bytes
        get() = wire.copyOf()
}

data class ClaimedPeerOutcome(val id: String, val result: Int)

/**
 * Transport-independent, serialized duplex stop-and-wait exchange. No delivery claim is inferred.
 */
class ExchangeSession(
    private val store: ReportExchangeStore,
    private val nonce: String,
    val generation: Long,
    private val wallClock: () -> Long,
) {
    private val access = Mutex()
    private val invalidated = AtomicBoolean(false)
    @Volatile private var closed = false
    @Volatile private var started = false
    private val clockAccess = Any()
    private val queued = AtomicInteger()
    private val queuedBytes = AtomicLong()
    @Volatile private var peer: String? = null
    private var startTime = 0L
    private var lastTime = 0L
    private var lastActivity = 0L
    private var bytesUsed = 0L
    private var maxFrame = 16384
    private var maxChunk = 1024
    @Volatile private var decoder = ExchangeDecoder()
    @Volatile
    var inventoryCursor: String? = null
        private set

    private var cursor: String? = null
    private var pageNumber = 0
    private var localPage: ExchangeMessage.Summary? = null
    private var waitingRequest = false
    private val outgoing = java.util.ArrayDeque<ReportDescriptor>()
    private var offered = 0
    private var pendingAck: ExchangeMessage.Offer? = null
    private val completedAcks = mutableMapOf<Int, ExchangeMessage.Received>()
    private var localDone = false
    private var peerDone = false
    private var remotePage = 0
    private var remoteLastID: String? = null
    private var remoteMore = true
    private var remoteSummarySeen = false
    private val requested = java.util.ArrayDeque<ReportDescriptor>()
    @Volatile private var incoming: Assembly? = null
    @Volatile private var completed: Map<Int, Completed> = emptyMap()
    private var incomingOffers = 0
    private val claims = mutableListOf<ClaimedPeerOutcome>()
    @Volatile
    var localFailure: Int? = null
        private set

    private data class Assembly(
        val offer: ExchangeMessage.Offer,
        val bytes: ByteArray,
        val seen: BooleanArray,
        var count: Int = 0,
    )

    private data class Completed(
        val offer: ExchangeMessage.Offer,
        val bytes: ByteArray,
        val ack: ExchangeMessage.Received,
    )

    init {
        require(nonce.matches(Regex("[0-9a-f]{32}")) && nonce != ExchangeWire.ZERO)
    }

    fun isCurrent(token: Long) = token == generation && !invalidated.get()

    suspend fun peerOutcomes(): List<ClaimedPeerOutcome> = access.withLock { claims.toList() }

    /** Invalidates immediately, including while a repository commit is suspended. */
    fun cancel() {
        invalidate(1)
    }

    fun disconnect() {
        invalidate(7)
    }

    private fun invalidate(reason: Int) {
        invalidated.set(true)
        localFailure = reason
        incoming = null
        completed = emptyMap()
        decoder = ExchangeDecoder(maxFrame)
    }

    suspend fun start(elapsedMs: Long): List<ExchangeAction> =
        access.withLock {
            if (started || invalidated.get()) return@withLock emptyList()
            if (elapsedMs < 0) {
                invalidate(4)
                return@withLock emptyList()
            }
            synchronized(clockAccess) {
                startTime = elapsedMs
                lastTime = elapsedMs
                lastActivity = elapsedMs
                started = true
            }
            val actions = mutableListOf<ExchangeAction>()
            emit(ExchangeMessage.Hello(), actions)
            actions
        }

    /** Deadlines invalidate immediately; they never queue behind a suspended durable commit. */
    suspend fun tick(elapsedMs: Long): List<ExchangeAction> {
        if (!started || closed || invalidated.get()) return emptyList()
        val reason = deadline(elapsedMs)
        if (reason != null) invalidate(reason)
        return emptyList()
    }

    suspend fun receive(token: Long, bytes: ByteArray, elapsedMs: Long): List<ExchangeAction> {
        if (!isCurrent(token) || closed || !started) return emptyList()
        // Validate event ordering at arrival, before waiting behind repository work. A later
        // timer tick may advance the processing clock while this already-valid callback queues.
        val arrivalReason = deadline(elapsedMs)
        if (arrivalReason != null) {
            invalidate(arrivalReason)
            return emptyList()
        }
        val reservations = queued.incrementAndGet()
        val reservedBytes = queuedBytes.addAndGet(bytes.size.toLong())
        try {
            if (reservations > 64 || reservedBytes > 262144) {
                invalidate(2)
                return emptyList()
            }
            val snapshot = bytes.copyOf()
            return access.withLock {
                if (!isCurrent(token) || closed || !started) return@withLock emptyList()
                val reason = synchronized(clockAccess) { deadline(maxOf(lastTime, elapsedMs)) }
                if (reason != null) return@withLock close(reason)
                bytesUsed += bytes.size
                if (bytesUsed > 262144) return@withLock close(2)
                val actions = mutableListOf<ExchangeAction>()
                try {
                    var count = 0
                    for (value in snapshot) {
                        if (closed || invalidated.get()) break
                        val frame = decoder.consume(value) ?: continue
                        if (++count > 64) throw ExchangeException()
                        synchronized(clockAccess) { lastActivity = maxOf(lastActivity, elapsedMs) }
                        // Handle each frame before reading the next prefix: HELLO negotiation can
                        // reduce allocation limits inside this very same coalesced callback.
                        handle(frame, actions)
                        if (!invalidated.get()) maybeComplete(actions)
                    }
                } catch (e: ExchangeException) {
                    actions.addAll(close(if (e.unsupported) 6 else 3))
                } catch (e: CancellationException) {
                    invalidate(1)
                    throw e
                } catch (_: Exception) {
                    actions.addAll(close(4))
                }
                if (invalidated.get()) {
                    incoming = null
                    completed = emptyMap()
                    emptyList()
                } else actions
            }
        } finally {
            queued.decrementAndGet()
            queuedBytes.addAndGet(-bytes.size.toLong())
        }
    }

    private fun deadline(now: Long): Int? =
        synchronized(clockAccess) {
            if (now < 0 || now < lastTime) return@synchronized 4
            lastTime = now
            if (
                now - startTime >= 30000 ||
                    (peer == null && now - startTime >= 5000) ||
                    now - lastActivity >= 10000
            )
                5
            else null
        }

    private fun emit(message: ExchangeMessage, actions: MutableList<ExchangeAction>) {
        if (invalidated.get() || closed) return
        val bytes =
            ExchangeWire.encode(
                ExchangeFrame(
                    nonce,
                    if (message is ExchangeMessage.Hello) ExchangeWire.ZERO
                    else peer ?: ExchangeWire.ZERO,
                    message,
                ),
                maxFrame,
            )
        if (bytesUsed + bytes.size > 262144) {
            actions.addAll(close(2))
            return
        }
        bytesUsed += bytes.size
        actions.add(ExchangeAction(generation, bytes))
    }

    private fun close(reason: Int): List<ExchangeAction> {
        if (closed || invalidated.get()) return emptyList()
        localFailure = if (reason == 0) null else reason
        val destination = peer
        closed = true
        incoming = null
        completed = emptyMap()
        decoder = ExchangeDecoder(maxFrame)
        outgoing.clear()
        requested.clear()
        return if (destination == null) {
            // A pre-negotiation failure cannot address a nonce-bound CLOSE; expose the local
            // reason.
            emptyList()
        } else {
            val bytes =
                ExchangeWire.encode(
                    ExchangeFrame(nonce, destination, ExchangeMessage.Close(reason)),
                    maxFrame,
                )
            if (bytesUsed + bytes.size > 262144) emptyList()
            else {
                bytesUsed += bytes.size
                listOf(ExchangeAction(generation, bytes))
            }
        }
    }

    private fun protocol(value: Boolean) {
        if (!value) throw ExchangeException()
    }

    private suspend fun handle(frame: ExchangeFrame, actions: MutableList<ExchangeAction>) {
        val message = frame.message
        if (message is ExchangeMessage.Hello) {
            protocol(
                peer == null && frame.source != nonce && frame.destination == ExchangeWire.ZERO
            )
            peer = frame.source
            maxFrame = minOf(maxFrame, message.maxFrame)
            maxChunk = minOf(maxChunk, message.maxChunk, maxFrame - 47)
            decoder.maxFrame = maxFrame
            advertise(actions)
            return
        }
        protocol(peer != null && frame.source == peer && frame.destination == nonce)
        when (message) {
            is ExchangeMessage.Summary -> {
                protocol(
                    !peerDone &&
                        incoming == null &&
                        requested.isEmpty() &&
                        remoteMore &&
                        message.page == remotePage &&
                        !(message.page == 7 && message.more) &&
                        (message.entries.isEmpty() ||
                            remoteLastID == null ||
                            remoteLastID!! < message.entries.first().id)
                )
                remoteSummarySeen = true
                remotePage++
                remoteMore = message.more
                if (message.entries.isNotEmpty()) remoteLastID = message.entries.last().id
                val known = store.currentIDs(message.entries.map { it.id }, wallClock())
                if (invalidated.get()) return
                requested.addAll(message.entries.filter { it.id !in known })
                emit(ExchangeMessage.Request(requested.map { it.id }), actions)
            }
            is ExchangeMessage.Request -> {
                protocol(waitingRequest && pendingAck == null)
                val summary = localPage!!
                val requestedIDs = message.ids.toSet()
                protocol(
                    message.ids == summary.entries.filter { it.id in requestedIDs }.map { it.id }
                )
                if (offered + message.ids.size > 32) {
                    actions.addAll(close(2))
                    return
                }
                waitingRequest = false
                outgoing.addAll(summary.entries.filter { it.id in requestedIDs })
                sendNext(actions)
            }
            is ExchangeMessage.Offer -> {
                protocol(
                    !peerDone &&
                        incoming == null &&
                        requested.isNotEmpty() &&
                        message.report == requested.first &&
                        message.transfer == incomingOffers + 1
                )
                incomingOffers++
                protocol(incomingOffers <= 32)
                incoming =
                    Assembly(
                        message,
                        ByteArray(message.report.total),
                        BooleanArray(message.report.total),
                    )
            }
            is ExchangeMessage.Chunk -> acceptChunk(message, actions)
            is ExchangeMessage.Received -> {
                val completed = completedAcks[message.transfer]
                if (completed != null) {
                    protocol(completed == message)
                    return
                }
                val offered = pendingAck
                protocol(
                    offered != null &&
                        message.transfer == offered.transfer &&
                        message.id == offered.report.id
                )
                completedAcks[message.transfer] = message
                claims.add(ClaimedPeerOutcome(message.id, message.result))
                pendingAck = null
                sendNext(actions)
            }
            ExchangeMessage.Done -> {
                protocol(
                    !peerDone &&
                        remoteSummarySeen &&
                        !remoteMore &&
                        incoming == null &&
                        requested.isEmpty()
                )
                peerDone = true
            }
            is ExchangeMessage.Close -> {
                if (message.reason == 0)
                    protocol(
                        localDone &&
                            peerDone &&
                            incoming == null &&
                            requested.isEmpty() &&
                            pendingAck == null
                    )
                closed = true
                incoming = null
                completed = emptyMap()
                decoder = ExchangeDecoder(maxFrame)
                requested.clear()
                outgoing.clear()
                localFailure = if (message.reason == 0) null else message.reason
            }
            is ExchangeMessage.Hello -> throw ExchangeException()
        }
    }

    private suspend fun advertise(actions: MutableList<ExchangeAction>) {
        if (invalidated.get()) return
        if (pageNumber == 8 || (offered == 32 && localPage?.more == true)) {
            actions.addAll(close(2))
            return
        }
        if (pageNumber == 0) cursor = store.initialCursor(wallClock())
        if (invalidated.get()) return
        val page = store.inventoryPage(cursor, 8, wallClock())
        if (invalidated.get()) return
        cursor = page.nextCursor
        inventoryCursor = cursor
        val more = page.hasMore && pageNumber < 7
        val summary = ExchangeMessage.Summary(pageNumber++, more, page.reports)
        localPage = summary
        waitingRequest = true
        emit(summary, actions)
    }

    private suspend fun sendNext(actions: MutableList<ExchangeAction>) {
        if (invalidated.get()) return
        if (outgoing.isEmpty()) {
            if (localPage!!.more) advertise(actions)
            else {
                localDone = true
                emit(ExchangeMessage.Done, actions)
            }
            return
        }
        val descriptor = outgoing.removeFirst()
        val report = store.load(descriptor.id, wallClock())
        if (invalidated.get()) return
        if (report == null || report.descriptor != descriptor) {
            actions.addAll(close(4))
            return
        }
        val offer = ExchangeMessage.Offer(++offered, descriptor)
        pendingAck = offer
        emit(offer, actions)
        val wire = report.wire
        var offset = 0
        while (offset < wire.size && !closed && !invalidated.get()) {
            val end = minOf(offset + maxChunk, wire.size)
            emit(
                ExchangeMessage.Chunk(
                    offer.transfer,
                    offset,
                    wire.size,
                    wire.copyOfRange(offset, end),
                ),
                actions,
            )
            offset = end
        }
    }

    private suspend fun acceptChunk(
        chunk: ExchangeMessage.Chunk,
        actions: MutableList<ExchangeAction>,
    ) {
        protocol(chunk.data.size <= maxChunk)
        val replay = completed[chunk.transfer]
        if (replay != null) {
            protocol(
                chunk.total == replay.bytes.size &&
                    chunk.data.indices.all { replay.bytes[chunk.offset + it] == chunk.data[it] }
            )
            emit(replay.ack, actions)
            return
        }
        val assembly = incoming
        protocol(
            assembly != null &&
                chunk.transfer == assembly.offer.transfer &&
                chunk.total == assembly.bytes.size
        )
        assembly!!
        for (i in chunk.data.indices) {
            val index = chunk.offset + i
            if (assembly.seen[index]) protocol(assembly.bytes[index] == chunk.data[i])
            else {
                assembly.seen[index] = true
                assembly.bytes[index] = chunk.data[i]
                assembly.count++
            }
        }
        if (assembly.count != assembly.bytes.size) return
        // The repository verifies ID, author cap and expiry; compare the untrusted inventory ID
        // too.
        val now = wallClock()
        if (now !in 0..org.trailmesh.app.protocol.ReportJSON.SAFE_INTEGER) error("clock")
        store.currentIDs(
            emptyList(),
            now,
        ) // also checks the durable repository clock before any ACK
        if (invalidated.get()) {
            incoming = null
            return
        }
        val validation =
            withContext(Dispatchers.Default) {
                org.trailmesh.app.protocol.ReportAdmission.validate(assembly.bytes, now)
            }
        if (invalidated.get()) {
            incoming = null
            return
        }
        val verified = validation.verified
        val outcome =
            if (verified != null && verified.bundleID != assembly.offer.report.id)
                StoreOutcome.Rejected("invalid")
            else store.ingest(assembly.bytes, assembly.offer.report.hops - 1, wallClock)
        if (invalidated.get()) {
            incoming = null
            return
        }
        val result =
            when (outcome) {
                is StoreOutcome.Stored -> 0
                is StoreOutcome.Duplicate -> 1
                is StoreOutcome.Rejected ->
                    when (outcome.reason) {
                        "expired" -> 2
                        "quota" -> 4
                        "unsupported" -> 5
                        else -> 3
                    }
            }
        val ack =
            ExchangeMessage.Received(assembly.offer.transfer, assembly.offer.report.id, result)
        completed =
            completed + (assembly.offer.transfer to Completed(assembly.offer, assembly.bytes, ack))
        incoming = null
        requested.removeFirst()
        emit(ack, actions)
    }

    private fun maybeComplete(actions: MutableList<ExchangeAction>) {
        if (localDone && peerDone && incoming == null && requested.isEmpty() && pendingAck == null)
            actions.addAll(close(0))
    }
}
