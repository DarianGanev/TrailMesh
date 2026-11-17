package org.trailmesh.app.session

import java.security.SecureRandom
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.trailmesh.app.exchange.*
import org.trailmesh.app.persistence.*
import org.trailmesh.app.protocol.ReportJSON
import org.trailmesh.app.relevance.*

object ReportAdvertisement {
    const val SERVICE = "org.trailmesh.reports.v1"

    fun parse(value: String): String? =
        value
            .takeIf { it.matches(Regex("TMR1\\|[0-9a-f]{32}")) }
            ?.substring(5)
            ?.takeUnless { it == ExchangeWire.ZERO }

    fun randomID(): String =
        ByteArray(16)
            .also { SecureRandom().nextBytes(it) }
            .joinToString("") { "%02x".format(it.toInt() and 255) }
            .let { if (it == ExchangeWire.ZERO) randomID() else it }
}

object ReportSessionLimits {
    const val ACTIVE_LINKS = 4
    const val WAITING_CANDIDATES = 32
    const val EPOCH_ENDPOINTS = 32
    const val QUEUED_CALLBACKS = 64
    const val QUEUED_BYTES = 262144L
    const val OUTBOUND_PAYLOADS = 64
    const val COOLDOWNS = 64
    const val CONNECT_MS = 15000L
    const val TICK_MS = 250L
    const val DRAIN_MS = 2000L
    const val EXPORT_EVENTS = 512
    const val EXPORT_REPORTS = 64
}

data class ReportLinkToken(val epoch: Long, val generation: Long, val endpoint: String)

enum class ReportSessionState {
    stopped,
    active,
    consentRequired,
    configurationRequired,
    invalidConfiguration,
    permissionDenied,
    radioUnavailable,
    clockFailure,
    storageFailure,
    interrupted,
}

/**
 * SDK operations carry a captured token. Adapters must recheck isLive immediately before dispatch.
 */
interface ReportSessionRadio {
    fun start(epoch: Long, advertisement: String)

    fun stop()

    fun request(token: ReportLinkToken, advertisement: String)

    fun accept(token: ReportLinkToken)

    fun reject(endpoint: String)

    fun disconnect(token: ReportLinkToken)

    fun send(token: ReportLinkToken, bytes: ByteArray, completion: (Boolean) -> Unit)
}

data class ReportSessionEvent(
    val code: String,
    val timestamp: Long,
    val peer: String? = null,
    val bundleID: String? = null,
)

/** Four independent exchange engines; no repository wait holds this owner's admission lock. */
class ReportSessionCoordinator(
    private val radio: ReportSessionRadio,
    private val storeFactory: (RelevanceContext) -> ReportExchangeStore,
    private val scope: CoroutineScope,
    private val wall: () -> Long,
    private val elapsed: () -> Long,
    private val randomID: () -> String = ReportAdvertisement::randomID,
    private val jitter: () -> Long = { kotlin.random.Random.nextLong(0, 501) },
    private val event: (ReportSessionEvent) -> Unit = {},
) {
    private val gate = Any()
    @Volatile
    var state = ReportSessionState.stopped
        private set

    @Volatile
    var epoch = 0L
        private set

    @Volatile
    var sessionID = ""
        private set

    private var serial = 0L
    private var rotatePending = false
    private var context: RelevanceContext? = null

    private data class Candidate(val endpoint: String, val peer: String)

    private data class Cooldown(var failures: Int = 0, var until: Long = 0)

    private class Budget(var callbacks: Int = 0, var bytes: Long = 0)

    // Reservations belong to retained callback work, not an SDK or user-session generation.
    private val budget = Budget()

    private class Link(val token: ReportLinkToken, val peer: String, val created: Long) {
        val processing = Mutex()
        var engine: ExchangeSession? = null
        var draining = false
        var drainUntil = 0L
        var pending = 0
        var accepted = false
        var claimCount = 0
    }

    private data class ReservedInput(
        val link: Link,
        val budget: Budget,
        val bytes: ByteArray,
        val arrival: ExchangeSession.Arrival,
    )

    private val links = linkedMapOf<String, Link>()
    private val waiting = linkedMapOf<String, Candidate>()
    private val tombstones = linkedSetOf<String>()
    private val cooldowns =
        object : LinkedHashMap<String, Cooldown>(ReportSessionLimits.COOLDOWNS, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Cooldown>?) =
                size > ReportSessionLimits.COOLDOWNS
        }
    val liveLinks
        get() = synchronized(gate) { links.size }

    val waitingPeers
        get() = synchronized(gate) { waiting.size }

    val queuedCallbacks
        get() = synchronized(gate) { budget.callbacks }

    val queuedBytes
        get() = synchronized(gate) { budget.bytes }

    fun isLive(token: ReportLinkToken): Boolean = synchronized(gate) { current(token) != null }

    private fun current(token: ReportLinkToken): Link? =
        links[token.endpoint]?.takeIf {
            state == ReportSessionState.active && it.token == token && token.epoch == epoch
        }

    private fun record(code: String, link: Link? = null, bundleID: String? = null) =
        event(
            ReportSessionEvent(
                code,
                wall().coerceIn(0, ReportJSON.SAFE_INTEGER),
                link?.peer,
                bundleID,
            ),
        )

    fun start(value: RelevanceContext?, consent: Boolean): ReportSessionState =
        synchronized(gate) {
            if (state == ReportSessionState.active) return@synchronized state
            if (!consent) {
                state = ReportSessionState.consentRequired
                return@synchronized state
            }
            val decision =
                RelevancePolicy.evaluate(
                    RelevantReport("configuration", 0, ReportJSON.SAFE_INTEGER, GeoPoint(0, 0)),
                    value,
                    wall(),
                )
            if (decision == RelevanceDecision.configurationRequired || value == null) {
                state = ReportSessionState.configurationRequired
                return@synchronized state
            }
            if (decision == RelevanceDecision.invalidConfiguration) {
                state = ReportSessionState.invalidConfiguration
                return@synchronized state
            }
            rotatePending = false
            context = value
            sessionID = randomID().also { require(ReportAdvertisement.parse("TMR1|$it") != null) }
            epoch++
            links.clear()
            waiting.clear()
            tombstones.clear()
            cooldowns.clear()
            state = ReportSessionState.active
            record("session_started")
            radio.start(epoch, "TMR1|$sessionID")
            state
        }

    fun stop() = synchronized(gate) { invalidate(ReportSessionState.stopped, "session_stopped") }

    fun pause(reason: ReportSessionState) =
        synchronized(gate) {
            require(reason != ReportSessionState.active)
            invalidate(reason, "session_paused")
        }

    private fun invalidate(reason: ReportSessionState, code: String) {
        epoch++
        state = reason
        links.values.forEach { it.engine?.cancel() }
        links.clear()
        waiting.clear()
        tombstones.clear()
        radio.stop()
        record(code)
    }

    fun updateContext(value: RelevanceContext?, consent: Boolean): ReportSessionState =
        synchronized(gate) {
            invalidate(ReportSessionState.stopped, "session_stopped")
            start(value, consent)
        }

    fun found(origin: Long, endpoint: String, advertisement: String) =
        synchronized(gate) {
            if (origin != epoch || state != ReportSessionState.active) return@synchronized
            val peer = ReportAdvertisement.parse(advertisement) ?: return@synchronized
            if (
                peer <= sessionID ||
                    links.containsKey(endpoint) ||
                    links.values.any { it.peer == peer } ||
                    waiting.values.any { it.endpoint == endpoint && it.peer != peer }
            )
                return@synchronized
            if (waiting.containsKey(peer) || waiting.size < ReportSessionLimits.WAITING_CANDIDATES)
                waiting[peer] = Candidate(endpoint, peer)
            pump()
        }

    fun lost(origin: Long, endpoint: String) =
        synchronized(gate) {
            if (origin == epoch) waiting.entries.removeAll { it.value.endpoint == endpoint }
        }

    fun initiated(origin: Long, endpoint: String, advertisement: String): ReportLinkToken? =
        synchronized(gate) {
            val peer = ReportAdvertisement.parse(advertisement)
            if (
                origin != epoch ||
                    state != ReportSessionState.active ||
                    peer == null ||
                    peer == sessionID ||
                    endpoint in tombstones
            )
                return@synchronized null
            var link = links[endpoint]
            if (link != null && link.peer != peer) return@synchronized null
            if (link == null) {
                if (
                    peer >= sessionID ||
                        links.size >= ReportSessionLimits.ACTIVE_LINKS ||
                        tombstones.size + links.size >= ReportSessionLimits.EPOCH_ENDPOINTS ||
                        links.values.any { it.peer == peer } ||
                        elapsed() < (cooldowns[peer]?.until ?: 0)
                )
                    return@synchronized null
                waiting.remove(peer)
                link = Link(ReportLinkToken(epoch, ++serial, endpoint), peer, elapsed())
                links[endpoint] = link
            }
            link.token
        }

    fun acceptInitiation(token: ReportLinkToken) =
        synchronized(gate) {
            val link = current(token) ?: return@synchronized
            if (!link.accepted) {
                link.accepted = true
                radio.accept(token)
            }
        }

    fun radioFailed(origin: Long) =
        synchronized(gate) {
            if (origin != epoch || state != ReportSessionState.active) return@synchronized
            record("radio_unavailable")
            if (links.isEmpty()) pause(ReportSessionState.radioUnavailable)
            else rotatePending = true
        }

    private fun pump() {
        if (state != ReportSessionState.active || rotatePending) return
        val iterator = waiting.iterator()
        while (
            links.size < ReportSessionLimits.ACTIVE_LINKS &&
                tombstones.size + links.size < ReportSessionLimits.EPOCH_ENDPOINTS &&
                iterator.hasNext()
        ) {
            val c = iterator.next().value
            if (c.endpoint in tombstones || elapsed() < (cooldowns[c.peer]?.until ?: 0)) continue
            iterator.remove()
            val link = Link(ReportLinkToken(epoch, ++serial, c.endpoint), c.peer, elapsed())
            links[c.endpoint] = link
            radio.request(link.token, "TMR1|$sessionID")
        }
    }

    fun connected(token: ReportLinkToken) =
        synchronized(gate) {
            val link = current(token) ?: return@synchronized
            if (link.engine != null) return@synchronized
            val frozen = requireNotNull(context)
            val delegate = storeFactory(frozen)
            val monitored =
                object : ReportExchangeStore by delegate {
                    private suspend fun <T> check(operation: suspend () -> T): T =
                        try {
                            operation()
                        } catch (e: ReportStoreException) {
                            synchronized(gate) {
                                if (current(link.token) === link) {
                                    record("storage_failure", link)
                                    pause(
                                        if (e.reason == StoreFailure.CLOCK)
                                            ReportSessionState.clockFailure
                                        else ReportSessionState.storageFailure,
                                    )
                                }
                            }
                            throw e
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            synchronized(gate) {
                                if (current(link.token) === link) {
                                    record("storage_failure", link)
                                    pause(ReportSessionState.storageFailure)
                                }
                            }
                            throw e
                        }

                    override suspend fun initialCursor(now: Long) = check {
                        delegate.initialCursor(now)
                    }

                    override suspend fun inventoryPage(afterID: String?, limit: Int, now: Long) =
                        check {
                            delegate.inventoryPage(afterID, limit, now)
                        }

                    override suspend fun currentIDs(ids: List<String>, now: Long) = check {
                        delegate.currentIDs(ids, now)
                    }

                    override suspend fun load(id: String, now: Long) = check {
                        delegate.load(id, now)
                    }

                    override suspend fun ingest(
                        wire: ByteArray,
                        remainingHops: Int,
                        clock: () -> Long,
                    ): StoreOutcome {
                        val result = check { delegate.ingest(wire, remainingHops, clock) }
                        val verified =
                            org.trailmesh.app.protocol.ReportAdmission.validate(wire, clock())
                                .verified
                        synchronized(gate) {
                            if (current(link.token) === link) {
                                if (result is StoreOutcome.Stored) cooldowns[link.peer] = Cooldown()
                                if (
                                    verified?.report?.note?.startsWith(TEST_NOTE_PREFIX) == true &&
                                        (result is StoreOutcome.Stored ||
                                            result is StoreOutcome.Duplicate)
                                )
                                    record(
                                        if (result is StoreOutcome.Stored) "report_stored"
                                        else "report_duplicate",
                                        link,
                                        verified.bundleID,
                                    )
                            }
                        }
                        return result
                    }
                }
            val engine =
                ExchangeSession(monitored, ReportAdvertisement.randomID(), token.generation, wall)
            link.engine = engine
            record("link_connected", link)
            scope.launch(start = CoroutineStart.UNDISPATCHED) {
                link.processing.withLock { dispatch(link, engine.start(elapsed())) }
            }
        }

    /**
     * Admission reserves aggregate capacity synchronously, before copying or creating a coroutine.
     */
    fun receive(token: ReportLinkToken, bytes: ByteArray) {
        val reservation: ReservedInput =
            synchronized(gate) {
                val link = current(token) ?: return
                val engine = link.engine ?: return
                if (link.draining) return
                val b = budget
                if (
                    b.callbacks >= ReportSessionLimits.QUEUED_CALLBACKS ||
                        b.bytes + bytes.size > ReportSessionLimits.QUEUED_BYTES
                ) {
                    record("queue_overflow", link)
                    finish(link, false)
                    return
                }
                val arrival = engine.registerArrival(token.generation, elapsed)
                if (arrival == null) {
                    if (!engine.isCurrent(token.generation)) finish(link, false)
                    return
                }
                b.callbacks++
                b.bytes += bytes.size
                ReservedInput(link, b, bytes.copyOf(), arrival)
            }
        val (link, b, snapshot, arrival) = reservation
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                link.processing.withLock {
                    if (isLive(token)) dispatch(link, link.engine!!.receive(arrival, snapshot))
                }
            } finally {
                synchronized(gate) {
                    b.callbacks--
                    b.bytes -= snapshot.size
                }
            }
        }
    }

    private suspend fun dispatch(link: Link, actions: List<ExchangeAction>) {
        val claims = link.engine?.peerOutcomes().orEmpty()
        synchronized(gate) {
            if (current(link.token) !== link) return
            for (claim in claims.drop(link.claimCount)) record(
                "peer_received_claim",
                link,
            ) // peer claims are never durable receipts
            link.claimCount = claims.size
            val engine = link.engine ?: return
            if (!engine.isCurrent(link.token.generation)) {
                finish(link, false)
                return
            }
            val valid = actions.filter { engine.isLive(it) }
            // A stale normal batch must not retire the link before a concurrent terminal batch
            // drains.
            if (actions.isNotEmpty() && valid.isEmpty() && engine.isComplete) return
            if (engine.isComplete) {
                link.draining = true
                link.drainUntil = elapsed() + ReportSessionLimits.DRAIN_MS
            }
            if (link.pending + valid.size > ReportSessionLimits.COOLDOWNS) {
                record("queue_overflow", link)
                finish(link, false)
                return
            }
            link.pending += valid.size
            for (action in valid) {
                if (current(link.token) !== link) return
                if (!engine.isLive(action)) {
                    link.pending--
                    continue
                }
                radio.send(link.token, action.bytes) { success -> sent(link.token, success) }
            }
            if (link.draining && link.pending == 0) finish(link, engine.localFailure == null)
        }
    }

    private fun sent(token: ReportLinkToken, success: Boolean) =
        synchronized(gate) {
            val link = current(token) ?: return@synchronized
            if (!success) {
                record("send_failed", link)
                finish(link, false)
                return@synchronized
            }
            link.pending--
            if (link.draining && link.pending == 0) finish(link, link.engine?.localFailure == null)
        }

    fun disconnected(token: ReportLinkToken) =
        synchronized(gate) {
            current(token)?.let { finish(it, it.draining && it.engine?.localFailure == null) }
        }

    fun pauseIfLive(token: ReportLinkToken, reason: ReportSessionState) =
        synchronized(gate) { if (current(token) != null) pause(reason) }

    fun failed(token: ReportLinkToken) =
        synchronized(gate) { current(token)?.let { finish(it, false) } }

    fun tick() {
        val snapshot =
            synchronized(gate) {
                if (state != ReportSessionState.active) return
                links.values.toList()
            }
        for (link in snapshot) {
            synchronized(gate) {
                if (current(link.token) !== link) return@synchronized
                if (
                    link.engine == null &&
                        elapsed() - link.created >= ReportSessionLimits.CONNECT_MS
                )
                    finish(link, false)
                else if (link.draining && elapsed() >= link.drainUntil)
                    finish(link, link.engine?.localFailure == null)
            }
            val engine = link.engine ?: continue
            // tick never takes the engine's repository mutex and remains live while a commit waits.
            scope.launch(start = CoroutineStart.UNDISPATCHED) {
                engine.tick(elapsed)
                synchronized(gate) {
                    if (current(link.token) === link && !engine.isCurrent(link.token.generation))
                        finish(link, false)
                }
            }
        }
        synchronized(gate) {
            if (state != ReportSessionState.active) return
            pump()
            if (links.isEmpty() && (tombstones.isNotEmpty() || rotatePending)) {
                radio.stop()
                epoch++
                tombstones.clear()
                waiting.clear()
                rotatePending = false
                radio.start(epoch, "TMR1|$sessionID")
            }
        }
    }

    private fun finish(link: Link, success: Boolean) {
        if (current(link.token) !== link) return
        link.engine?.disconnect()
        links.remove(link.token.endpoint)
        tombstones.add(link.token.endpoint)
        radio.disconnect(link.token)
        val previous = cooldowns[link.peer] ?: Cooldown()
        if (success) {
            previous.failures = 0
            previous.until = elapsed() + 30000
        } else {
            previous.failures = minOf(5, previous.failures + 1)
            previous.until =
                if (previous.failures >= 5) Long.MAX_VALUE
                else
                    elapsed() +
                        minOf(
                            30000,
                            (1000L shl (previous.failures - 1)) + jitter().coerceIn(0, 500),
                        )
        }
        cooldowns[link.peer] = previous
        if (
            !success &&
                previous.failures < 5 &&
                waiting.size < ReportSessionLimits.WAITING_CANDIDATES
        )
            waiting[link.peer] = Candidate(link.token.endpoint, link.peer)
        record("link_closed", link)
        pump()
    }

    companion object {
        const val TEST_NOTE_PREFIX = "SYNTHETIC TrailMesh test "
    }
}
