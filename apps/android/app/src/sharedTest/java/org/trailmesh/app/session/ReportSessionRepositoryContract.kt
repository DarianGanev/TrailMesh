package org.trailmesh.app.session

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.google.crypto.tink.subtle.Ed25519Sign
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedQueue
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.trailmesh.app.exchange.*
import org.trailmesh.app.persistence.*
import org.trailmesh.app.relevance.*
import org.trailmesh.app.security.ReportSigner

abstract class ReportSessionRepositoryContract {
    protected abstract fun resource(name: String): ByteArray

    private val context
        get() = ApplicationProvider.getApplicationContext<Context>()

    private val area = RelevanceContext(manualArea = Area(GeoPoint(426977000, 233219000), 5000))
    private val now = 1800000000000L

    private fun signer(): ReportSigner {
        val key = Ed25519Sign.KeyPair.newKeyPair()
        return object : ReportSigner {
            override val publicKey = key.publicKey

            override fun sign(message: ByteArray) = Ed25519Sign(key.privateKey).sign(message)
        }
    }

    private fun draft(note: String) =
        ReportDraft(
            "trail",
            "muddy",
            now,
            426977000,
            233219000,
            1,
            ReportSessionCoordinator.TEST_NOTE_PREFIX + note,
            now + 3600000,
            3,
        )

    private class Node(
        val number: Int,
        val repo: ReportRepository,
        val owner: ReportSessionCoordinator,
        val radio: BusRadio,
    )

    private class Bus {
        val nodes = mutableMapOf<Int, Node>()
        val jobs = ConcurrentLinkedQueue<() -> Unit>()
        val stalled = mutableSetOf<Int>()
        val connections =
            java.util.concurrent.ConcurrentHashMap<Pair<Int, String>, Pair<Int, ReportLinkToken>>()
        var maxHubLinks = 0

        fun enqueue(action: () -> Unit) {
            jobs.add(action)
        }

        suspend fun pumpUntil(condition: suspend () -> Boolean) {
            withTimeout(20000) {
                while (!condition()) {
                    repeat(100) { jobs.poll()?.invoke() }
                    delay(2)
                }
                repeat(100) { jobs.poll()?.invoke() }
            }
        }
    }

    private class BusRadio(private val bus: Bus, private val number: Int) : ReportSessionRadio {
        lateinit var owner: ReportSessionCoordinator
        val requested = mutableListOf<ReportLinkToken>()
        val sent = java.util.concurrent.CopyOnWriteArrayList<ByteArray>()

        override fun start(epoch: Long, advertisement: String) {}

        override fun stop() {}

        override fun accept(token: ReportLinkToken) {}

        override fun reject(endpoint: String) {}

        override fun request(token: ReportLinkToken, advertisement: String) {
            requested.add(token)
            bus.enqueue {
                if (!owner.isLive(token)) return@enqueue
                val other = bus.nodes[token.endpoint.substringAfter("peer-").toInt()]!!
                val incoming =
                    other.owner.initiated(other.owner.epoch, "peer-$number", advertisement)
                        ?: return@enqueue
                val outgoing =
                    owner.initiated(token.epoch, token.endpoint, "TMR1|${other.owner.sessionID}")
                        ?: return@enqueue
                bus.connections[number to token.endpoint] = other.number to incoming
                bus.connections[other.number to incoming.endpoint] = number to outgoing
                owner.acceptInitiation(outgoing)
                other.owner.acceptInitiation(incoming)
                owner.connected(outgoing)
                other.owner.connected(incoming)
                bus.maxHubLinks = maxOf(bus.maxHubLinks, bus.nodes[1]!!.owner.liveLinks)
            }
        }

        override fun disconnect(token: ReportLinkToken) {
            val target = bus.connections[number to token.endpoint] ?: return
            bus.enqueue { bus.nodes[target.first]?.owner?.disconnected(target.second) }
        }

        override fun send(token: ReportLinkToken, bytes: ByteArray, completion: (Boolean) -> Unit) {
            sent.add(bytes.copyOf())
            bus.enqueue {
                if (
                    number in bus.stalled ||
                        token.endpoint.substringAfter("peer-").toInt() in bus.stalled
                )
                    return@enqueue
                val target = bus.connections[number to token.endpoint]
                if (target != null && owner.isLive(token)) {
                    bus.nodes[target.first]!!.owner.receive(target.second, bytes)
                    completion(true)
                }
            }
        }
    }

    private suspend fun node(
        bus: Bus,
        n: Int,
        scope: CoroutineScope,
        clock: () -> Long = { 0 },
        store: ((ReportRepository, RelevanceContext) -> ReportExchangeStore)? = null,
    ): Node {
        val repo = ReportRepository.open(context, "s-${UUID.randomUUID().toString().take(8)}.db")
        val radio = BusRadio(bus, n)
        val owner =
            ReportSessionCoordinator(
                radio,
                { c -> store?.invoke(repo, c) ?: SelectedRepositoryExchangeStore(repo, c) },
                scope,
                { now },
                clock,
                { n.toString(16).padStart(32, '0') },
                { 0 },
            )
        radio.owner = owner
        return Node(n, repo, owner, radio).also {
            bus.nodes[n] = it
            owner.start(area, true)
        }
    }

    private suspend fun close(bus: Bus, scope: CoroutineScope) {
        bus.nodes.values.forEach { it.owner.stop() }
        scope.cancel()
        bus.nodes.values.forEach { it.repo.close() }
    }

    @Test
    fun fourRealRepositoriesExchangeBidirectionallyAndDeduplicateAcrossPeers() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val bus = Bus()
        try {
            repeat(5) { node(bus, it + 1, scope) }
            val hub = bus.nodes[1]!!
            val hubID = (hub.repo.author(draft("hub"), signer(), now) as StoreOutcome.Stored).id
            val shared =
                (bus.nodes[2]!!.repo.author(draft("common"), signer(), now) as StoreOutcome.Stored)
                    .id
            val commonWire = bus.nodes[2]!!.repo.loadForExchange(shared, now)!!.wire
            val peerIDs = mutableListOf<String>()
            for (n in 2..5) {
                val peer = bus.nodes[n]!!
                if (n != 2) assertTrue(peer.repo.ingest(commonWire, now) is StoreOutcome.Stored)
                peerIDs.add(
                    (peer.repo.author(draft("peer$n"), signer(), now) as StoreOutcome.Stored).id,
                )
                hub.owner.found(hub.owner.epoch, "peer-$n", "TMR1|${peer.owner.sessionID}")
            }
            assertEquals(4, hub.owner.liveLinks)
            bus.pumpUntil {
                hub.repo.reports(now).map { it.bundleID }.containsAll(peerIDs + shared) &&
                    (2..5).all { hubID in bus.nodes[it]!!.repo.currentIDs(listOf(hubID), now) }
            }
            assertEquals(6, hub.repo.reports(now).size)
            assertEquals(4, bus.maxHubLinks)
            assertEquals(
                2,
                hub.repo.syntheticTestEvidence(now).first { it.bundleID == shared }.remainingHops,
            )
            val hashes = hub.repo.syntheticTestEvidence(now).first { it.bundleID == shared }
            assertEquals(
                bus.nodes[2]!!
                    .repo
                    .syntheticTestEvidence(now)
                    .first { it.bundleID == shared }
                    .canonicalCoreSHA256,
                hashes.canonicalCoreSHA256,
            )
        } finally {
            close(bus, scope)
        }
    }

    @Test
    fun stalledPeerDoesNotBlockHealthyPeersAndWaitingPeerRefillsReleasedSlot() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val bus = Bus()
        var elapsed = 0L
        try {
            repeat(6) { node(bus, it + 1, scope, { elapsed }) }
            bus.stalled.add(2)
            val hub = bus.nodes[1]!!
            val expected = mutableListOf<String>()
            for (n in 2..6) {
                val peer = bus.nodes[n]!!
                val id =
                    (peer.repo.author(draft("refill$n"), signer(), now) as StoreOutcome.Stored).id
                if (n != 2) expected.add(id)
                hub.owner.found(hub.owner.epoch, "peer-$n", "TMR1|${peer.owner.sessionID}")
            }
            bus.pumpUntil { hub.repo.reports(now).size >= 3 }
            // Fail only the deliberately stalled transport. Jumping a shared fake clock here
            // can expire a newly refilled healthy HELLO before its queued fake-radio delivery.
            hub.owner.failed(hub.radio.requested.first { it.endpoint == "peer-2" })
            bus.pumpUntil { hub.repo.reports(now).map { it.bundleID }.containsAll(expected) }
            assertTrue(hub.radio.requested.any { it.endpoint == "peer-6" })
            assertEquals(ReportSessionState.active, hub.owner.state)
        } finally {
            close(bus, scope)
        }
    }

    @Test
    fun stopDuringRealCommitKeepsStoredReportWithoutStaleAckOrSessionEvents() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val bus = Bus()
        val committed = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val events = mutableListOf<ReportSessionEvent>()
        try {
            val hub =
                node(
                    bus,
                    1,
                    scope,
                    store = { repo, c ->
                        val delegate = SelectedRepositoryExchangeStore(repo, c)
                        object : ReportExchangeStore by delegate {
                            override suspend fun ingest(
                                wire: ByteArray,
                                remainingHops: Int,
                                clock: () -> Long,
                            ): StoreOutcome {
                                val outcome = delegate.ingest(wire, remainingHops, clock)
                                committed.complete(Unit)
                                release.await()
                                return outcome
                            }
                        }
                    },
                )
            val peer = node(bus, 2, scope)
            val id =
                (peer.repo.author(draft("stop during commit"), signer(), now)
                        as StoreOutcome.Stored)
                    .id
            hub.owner.found(hub.owner.epoch, "peer-2", "TMR1|${peer.owner.sessionID}")
            bus.pumpUntil { committed.isCompleted }
            val before = hub.radio.sent.size
            hub.owner.stop()
            release.complete(Unit)
            delay(30)
            repeat(100) { bus.jobs.poll()?.invoke() }
            assertEquals(before, hub.radio.sent.size)
            assertEquals(setOf(id), hub.repo.currentIDs(listOf(id), now))
        } finally {
            release.complete(Unit)
            close(bus, scope)
        }
    }

    @Test
    fun sharedSessionProfileMatchesActualProductContractAndDiagnosticsAreBounded() {
        val p = JSONObject(String(resource("session-v1-profile.json")))
        assertEquals(p.getString("service_id"), ReportAdvertisement.SERVICE)
        assertEquals(p.getString("field_service_id"), ReportAdvertisement.FIELD_SERVICE)
        assertEquals(p.getString("test_note_prefix"), ReportSessionCoordinator.TEST_NOTE_PREFIX)
        assertEquals(p.getInt("advertisement_bytes"), ("TMR1|" + "1".repeat(32)).toByteArray().size)
        val limits = p.getJSONObject("limits")
        assertEquals(limits.getInt("active_links"), ReportSessionLimits.ACTIVE_LINKS)
        assertEquals(limits.getInt("queued_callbacks"), ReportSessionLimits.QUEUED_CALLBACKS)
        assertEquals(limits.getLong("queued_bytes"), ReportSessionLimits.QUEUED_BYTES)
        val log = ReportSessionDiagnostics()
        repeat(600) { log.record(ReportSessionEvent("link_closed", it.toLong())) }
        val exported =
            JSONObject(
                log.export(
                    "emulator",
                    "8",
                    "test",
                    null,
                    "1".repeat(32),
                    ReportSessionState.stopped,
                    emptyList(),
                ),
            )
        assertEquals(limits.getInt("export_events"), exported.getJSONArray("events").length())
        assertFalse(exported.toString().contains("lat_e7"))
        assertFalse(exported.toString().contains("private_key"))
    }
}
