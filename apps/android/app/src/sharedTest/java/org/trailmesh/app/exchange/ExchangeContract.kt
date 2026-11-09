package org.trailmesh.app.exchange

import kotlinx.coroutines.async
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

abstract class ExchangeContract {
    protected abstract fun resource(name: String): ByteArray

    @Test
    fun sharedLiteralFramesRoundTripAndInvalidFramesFail() {
        val cases = JSONObject(String(resource("exchange-v1-vectors.json"))).getJSONArray("cases")
        val native = mutableListOf<ByteArray>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val bytes = ExchangeWire.unhex(c.getString("wire_hex"))
            if (c.getString("expected") == "valid") {
                val expected = c.getJSONObject("frame")
                val f = expected.getJSONObject("fields")
                fun descriptor(o: JSONObject) =
                    ReportDescriptor(o.getString("id"), o.getInt("size"), o.getInt("hops"))
                val message =
                    when (expected.getString("kind")) {
                        "HELLO" ->
                            ExchangeMessage.Hello(
                                f.getLong("features"),
                                f.getInt("max_frame"),
                                f.getInt("max_chunk"),
                            )
                        "SUMMARY" -> {
                            val a = f.getJSONArray("entries")
                            ExchangeMessage.Summary(
                                f.getInt("page"),
                                f.getInt("more") == 1,
                                List(a.length()) { descriptor(a.getJSONObject(it)) },
                            )
                        }
                        "REQUEST" -> {
                            val a = f.getJSONArray("ids")
                            ExchangeMessage.Request(List(a.length()) { a.getString(it) })
                        }
                        "OFFER" ->
                            ExchangeMessage.Offer(
                                f.getInt("transfer"),
                                ReportDescriptor(
                                    f.getString("id"),
                                    f.getInt("total"),
                                    f.getInt("hops"),
                                ),
                            )
                        "CHUNK" ->
                            ExchangeMessage.Chunk(
                                f.getInt("transfer"),
                                f.getInt("offset"),
                                f.getInt("total"),
                                ExchangeWire.unhex(f.getString("data")),
                            )
                        "RECEIVED" ->
                            ExchangeMessage.Received(
                                f.getInt("transfer"),
                                f.getString("id"),
                                f.getInt("result"),
                            )
                        "CLOSE" -> ExchangeMessage.Close(f.getInt("reason"))
                        "DONE" -> ExchangeMessage.Done
                        else -> error("unknown vector")
                    }
                val authored =
                    ExchangeWire.encode(
                        ExchangeFrame(
                            expected.getString("source"),
                            expected.getString("destination"),
                            message,
                        ),
                    )
                assertArrayEquals(c.getString("name"), bytes, authored)
                native.add(authored)
                assertArrayEquals(
                    c.getString("name"),
                    authored,
                    ExchangeWire.encode(ExchangeWire.decode(bytes)),
                )
                val decoder = ExchangeDecoder()
                val frames = bytes.flatMap { decoder.feed(byteArrayOf(it)) }
                assertEquals(1, frames.size)
                decoder.finish()
            } else {
                try {
                    ExchangeWire.decode(bytes)
                    fail(c.getString("name"))
                } catch (e: ExchangeException) {
                    assertEquals(
                        c.getString("name"),
                        c.getString("expected") == "unsupported",
                        e.unsupported,
                    )
                }
            }
        }
        exportFrames(native)
    }

    @Test
    fun duplexRealRoomPersistsBytesAndLostAckReconnects() =
        kotlinx.coroutines.runBlocking {
            val context =
                androidx.test.core.app.ApplicationProvider.getApplicationContext<
                    android.content.Context,
                >()
            val aName = "exchange-${java.util.UUID.randomUUID()}.db"
            val bName = "exchange-${java.util.UUID.randomUUID()}.db"
            var a = org.trailmesh.app.persistence.ReportRepository.open(context, aName)
            var b = org.trailmesh.app.persistence.ReportRepository.open(context, bName)
            val root = JSONObject(String(resource("report-v1-vectors.json")))
            val cases = root.getJSONArray("cases")
            val c =
                (0 until cases.length())
                    .map { cases.getJSONObject(it) }
                    .first { it.getString("name") == "frozen-v1" }
            val now = c.getLong("now_ms")
            val wire = java.util.Base64.getDecoder().decode(c.getString("wire_base64"))
            a.ingest(wire, now)
            val key = com.google.crypto.tink.subtle.Ed25519Sign.KeyPair.newKeyPair()
            val signer =
                object : org.trailmesh.app.security.ReportSigner {
                    override val publicKey = key.publicKey

                    override fun sign(message: ByteArray) =
                        com.google.crypto.tink.subtle.Ed25519Sign(key.privateKey).sign(message)
                }
            b.author(
                org.trailmesh.app.persistence.ReportDraft(
                    "water",
                    "dry",
                    now,
                    0,
                    0,
                    1,
                    "duplex",
                    now + 3600000,
                    2,
                ),
                signer,
                now,
            )
            val sent = mutableListOf<ByteArray>()
            suspend fun encounter(dropAck: Boolean) {
                val left = ExchangeSession(RepositoryExchangeStore(a), "11".repeat(16), 1L) { now }
                val right = ExchangeSession(RepositoryExchangeStore(b), "22".repeat(16), 2L) { now }
                val queue = java.util.ArrayDeque<Pair<Boolean, ExchangeAction>>()
                left.start(0).forEach { queue.add(true to it) }
                right.start(0).forEach { queue.add(false to it) }
                var turns = 0
                while (queue.isNotEmpty()) {
                    check(turns++ < 200)
                    val (fromLeft, action) = queue.removeFirst()
                    sent.add(action.bytes)
                    if (
                        dropAck &&
                            ExchangeWire.decode(action.bytes).message is ExchangeMessage.Received
                    )
                        continue
                    val target = if (fromLeft) right else left
                    val token = if (fromLeft) 2L else 1L
                    // The link fragments every frame; framing must tolerate arbitrary callback
                    // boundaries.
                    action.bytes.toList().chunked(19).forEach { chunk ->
                        target.receive(token, chunk.toByteArray(), 1).forEach {
                            queue.add(!fromLeft to it)
                        }
                    }
                }
            }
            encounter(true)
            assertEquals(2, b.reports(now).size)
            a.close()
            b.close()
            a = org.trailmesh.app.persistence.ReportRepository.open(context, aName)
            b = org.trailmesh.app.persistence.ReportRepository.open(context, bName)
            encounter(false)
            assertEquals(2, a.reports(now).size)
            assertEquals(2, b.reports(now).size)
            assertTrue(b.forwardable(now).any { it.originalWire.contentEquals(wire) })
            a.close()
            b.close()
        }

    protected open fun exportFrames(frames: List<ByteArray>) {}

    @Test
    fun twoHopFakeLinksExhaustDurableBudgetAfterRestart() =
        kotlinx.coroutines.runBlocking {
            val (_, now) = signedFixture()
            val context =
                androidx.test.core.app.ApplicationProvider.getApplicationContext<
                    android.content.Context,
                >()
            val names = List(3) { "hop-${java.util.UUID.randomUUID()}.db" }
            val repos =
                names
                    .map { org.trailmesh.app.persistence.ReportRepository.open(context, it) }
                    .toMutableList()
            val key = com.google.crypto.tink.subtle.Ed25519Sign.KeyPair.newKeyPair()
            val signer =
                object : org.trailmesh.app.security.ReportSigner {
                    override val publicKey = key.publicKey

                    override fun sign(message: ByteArray) =
                        com.google.crypto.tink.subtle.Ed25519Sign(key.privateKey).sign(message)
                }
            repos[0].author(
                org.trailmesh.app.persistence.ReportDraft(
                    "water",
                    "dry",
                    now,
                    0,
                    0,
                    1,
                    "two hops",
                    now + 3600000,
                    2,
                ),
                signer,
                now,
            )
            val original = repos[0].forwardable(now).single().originalWire
            suspend fun link(
                a: org.trailmesh.app.persistence.ReportRepository,
                b: org.trailmesh.app.persistence.ReportRepository,
            ) {
                val left = ExchangeSession(RepositoryExchangeStore(a), localNonce, 1) { now }
                val right = ExchangeSession(RepositoryExchangeStore(b), peerNonce, 2) { now }
                val queue = java.util.ArrayDeque<Pair<Boolean, ExchangeAction>>()
                left.start(0).forEach { queue.add(true to it) }
                right.start(0).forEach { queue.add(false to it) }
                var turns = 0
                while (queue.isNotEmpty()) {
                    check(turns++ < 100)
                    val (fromLeft, action) = queue.removeFirst()
                    val target = if (fromLeft) right else left
                    target.receive(if (fromLeft) 2 else 1, action.bytes, 1).forEach {
                        queue.add(!fromLeft to it)
                    }
                }
            }
            link(repos[0], repos[1])
            repos[1].close()
            repos[1] = org.trailmesh.app.persistence.ReportRepository.open(context, names[1])
            assertEquals(1, repos[1].inventoryPage(null, 8, now).reports.single().hops)
            link(repos[1], repos[2])
            repos[2].close()
            repos[2] = org.trailmesh.app.persistence.ReportRepository.open(context, names[2])
            assertTrue(repos[2].forwardable(now).isEmpty())
            assertTrue(repos[2].inventoryPage(null, 8, now).reports.isEmpty())
            assertEquals(1, repos[2].reports(now).size)
            // Inspect durable bytes even at zero remaining hops; they are still the original
            // envelope.
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                repos[2]
                    .database
                    .openHelper
                    .readableDatabase
                    .query("SELECT original_wire FROM bundles")
                    .use { c ->
                        c.moveToFirst()
                        assertArrayEquals(original, c.getBlob(0))
                    }
            }
            repos.forEach { it.close() }
        }

    @Test
    fun realRoomForwardingFailureRollsBackAndNeverAcknowledges() =
        kotlinx.coroutines.runBlocking {
            val (wire, now) = signedFixture()
            val context =
                androidx.test.core.app.ApplicationProvider.getApplicationContext<
                    android.content.Context,
                >()
            val repo =
                org.trailmesh.app.persistence.ReportRepository.open(
                    context,
                    "rollback-${java.util.UUID.randomUUID()}.db",
                )
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                repo.database.openHelper.writableDatabase.execSQL(
                    "CREATE TRIGGER reject_forwarding BEFORE INSERT ON report_forwarding BEGIN SELECT RAISE(ABORT,'injected'); END",
                )
            }
            val (s, _) = inbound(RepositoryExchangeStore(repo), wire, now)
            assertEquals(
                listOf(ExchangeMessage.Close(4)),
                messages(s.receive(9, peerFrame(ExchangeMessage.Chunk(1, 0, wire.size, wire)), 2)),
            )
            assertTrue(repo.reports(now).isEmpty())
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                for (table in
                    listOf(
                        "bundles",
                        "reports",
                        "relay_state",
                        "report_forwarding",
                        "seen_ids",
                    )) repo.database.openHelper.readableDatabase
                    .query("SELECT COUNT(*) FROM $table")
                    .use { c ->
                        c.moveToFirst()
                        assertEquals(0, c.getInt(0))
                    }
            }
            repo.close()
        }

    @Test
    fun timeoutsAndStaleGenerationsHaveNoAcknowledgement() =
        kotlinx.coroutines.runBlocking {
            val store =
                object : ReportExchangeStore {
                    override suspend fun inventoryPage(afterID: String?, limit: Int, now: Long) =
                        InventoryPage(emptyList(), null, false)

                    override suspend fun currentIDs(ids: List<String>, now: Long) =
                        emptySet<String>()

                    override suspend fun load(id: String, now: Long): OutgoingReport? = null

                    override suspend fun ingest(
                        wire: ByteArray,
                        remainingHops: Int,
                        clock: () -> Long,
                    ) = org.trailmesh.app.persistence.StoreOutcome.Rejected("invalid")
                }
            val session = ExchangeSession(store, "11".repeat(16), 7) { 0 }
            session.start(0)
            assertTrue(session.receive(6, byteArrayOf(0), 1).isEmpty())
            assertTrue(session.tick(5000).isEmpty())
            assertEquals(5, session.localFailure)
            assertTrue(session.receive(7, byteArrayOf(0), 5001).isEmpty())
        }

    private val localNonce = "11".repeat(16)
    private val peerNonce = "22".repeat(16)

    private fun peerFrame(m: ExchangeMessage) =
        ExchangeWire.encode(
            ExchangeFrame(
                peerNonce,
                if (m is ExchangeMessage.Hello) ExchangeWire.ZERO else localNonce,
                m,
            ),
        )

    private fun messages(actions: List<ExchangeAction>) = actions.map {
        ExchangeWire.decode(it.bytes).message
    }

    private open class EmptyStore : ReportExchangeStore {
        override suspend fun inventoryPage(afterID: String?, limit: Int, now: Long) =
            InventoryPage(emptyList(), null, false)

        override suspend fun currentIDs(ids: List<String>, now: Long) = emptySet<String>()

        override suspend fun load(id: String, now: Long): OutgoingReport? = null

        override suspend fun ingest(
            wire: ByteArray,
            remainingHops: Int,
            clock: () -> Long,
        ): org.trailmesh.app.persistence.StoreOutcome =
            org.trailmesh.app.persistence.StoreOutcome.Rejected("invalid")
    }

    private suspend fun inbound(
        store: ReportExchangeStore,
        wire: ByteArray,
        now: Long,
    ): Pair<ExchangeSession, ReportDescriptor> {
        val id = org.trailmesh.app.protocol.ReportAdmission.validate(wire, now).verified!!.bundleID
        val descriptor = ReportDescriptor(id, wire.size, 2)
        val s = ExchangeSession(store, localNonce, 9) { now }
        s.start(0)
        s.receive(9, peerFrame(ExchangeMessage.Hello()), 1)
        s.receive(9, peerFrame(ExchangeMessage.Request(emptyList())), 1)
        s.receive(9, peerFrame(ExchangeMessage.Summary(0, false, listOf(descriptor))), 1)
        s.receive(9, peerFrame(ExchangeMessage.Offer(1, descriptor)), 1)
        return s to descriptor
    }

    private fun signedFixture(): Pair<ByteArray, Long> {
        val c =
            JSONObject(String(resource("report-v1-vectors.json")))
                .getJSONArray("cases")
                .getJSONObject(0)
        return java.util.Base64.getDecoder().decode(c.getString("wire_base64")) to
            c.getLong("now_ms")
    }

    @Test
    fun outOfOrderIdenticalOverlapsAndCompletedReplayWriteOnce() =
        kotlinx.coroutines.runBlocking {
            val (wire, now) = signedFixture()
            var writes = 0
            val store =
                object : EmptyStore() {
                    override suspend fun ingest(
                        wire: ByteArray,
                        remainingHops: Int,
                        clock: () -> Long,
                    ): org.trailmesh.app.persistence.StoreOutcome {
                        writes++
                        assertEquals(1, remainingHops)
                        return org.trailmesh.app.persistence.StoreOutcome.Stored("unused")
                    }
                }
            val (s, d) = inbound(store, wire, now)
            val split = wire.size / 2
            assertTrue(
                s.receive(
                        9,
                        peerFrame(
                            ExchangeMessage.Chunk(
                                1,
                                split,
                                wire.size,
                                wire.copyOfRange(split, wire.size),
                            ),
                        ),
                        2,
                    )
                    .isEmpty(),
            )
            assertTrue(
                s.receive(
                        9,
                        peerFrame(
                            ExchangeMessage.Chunk(
                                1,
                                split,
                                wire.size,
                                wire.copyOfRange(split, wire.size),
                            ),
                        ),
                        2,
                    )
                    .isEmpty(),
            )
            val first = ExchangeMessage.Chunk(1, 0, wire.size, wire.copyOfRange(0, split))
            val result =
                messages(s.receive(9, peerFrame(first), 2)).single() as ExchangeMessage.Received
            assertEquals(0, result.result)
            assertEquals(result, messages(s.receive(9, peerFrame(first), 2)).single())
            assertEquals(1, writes)
            val bad = first.data.copyOf()
            bad[0] = (bad[0].toInt() xor 1).toByte()
            assertEquals(
                ExchangeMessage.Close(3),
                messages(s.receive(9, peerFrame(first.copy(data = bad)), 2)).single(),
            )
        }

    @Test
    fun failuresHaveNoAckAndRejectionsRemainDistinct() =
        kotlinx.coroutines.runBlocking {
            val (wire, now) = signedFixture()
            for ((reason, code) in
                listOf(
                    "expired" to 2,
                    "invalid" to 3,
                    "quota" to 4,
                    "unsupported" to 5,
                    "exception" to 4,
                )) {
                val store =
                    object : EmptyStore() {
                        override suspend fun ingest(
                            wire: ByteArray,
                            remainingHops: Int,
                            clock: () -> Long,
                        ): org.trailmesh.app.persistence.StoreOutcome {
                            if (reason == "exception") error("storage")
                            return org.trailmesh.app.persistence.StoreOutcome.Rejected(reason)
                        }
                    }
                val (s, _) = inbound(store, wire, now)
                val out =
                    messages(
                        s.receive(9, peerFrame(ExchangeMessage.Chunk(1, 0, wire.size, wire)), 2),
                    )
                if (reason == "exception") assertEquals(listOf(ExchangeMessage.Close(4)), out)
                else assertEquals(code, (out.single() as ExchangeMessage.Received).result)
            }
        }

    @Test
    fun cancelledGenerationSuppressesAckAfterRealCommit() =
        kotlinx.coroutines.runBlocking {
            val (wire, now) = signedFixture()
            val context =
                androidx.test.core.app.ApplicationProvider.getApplicationContext<
                    android.content.Context,
                >()
            val repo =
                org.trailmesh.app.persistence.ReportRepository.open(
                    context,
                    "cancel-${java.util.UUID.randomUUID()}.db",
                )
            val committed = kotlinx.coroutines.CompletableDeferred<Unit>()
            val release = kotlinx.coroutines.CompletableDeferred<Unit>()
            val store =
                object : EmptyStore() {
                    override suspend fun ingest(
                        wire: ByteArray,
                        remainingHops: Int,
                        clock: () -> Long,
                    ): org.trailmesh.app.persistence.StoreOutcome {
                        val result = repo.ingestTransferred(wire, remainingHops, clock)
                        committed.complete(Unit)
                        release.await()
                        return result
                    }
                }
            val (s, _) = inbound(store, wire, now)
            val pending = async {
                s.receive(9, peerFrame(ExchangeMessage.Chunk(1, 0, wire.size, wire)), 2)
            }
            committed.await()
            s.cancel()
            assertFalse(s.isCurrent(9))
            release.complete(Unit)
            assertTrue(pending.await().isEmpty())
            assertEquals(1, repo.reports(now).size)
            repo.close()
        }

    @Test
    fun deadlineInvalidatesImmediatelyWhileCommitIsSuspended() =
        kotlinx.coroutines.runBlocking {
            val (wire, now) = signedFixture()
            val committed = kotlinx.coroutines.CompletableDeferred<Unit>()
            val release = kotlinx.coroutines.CompletableDeferred<Unit>()
            val store =
                object : EmptyStore() {
                    override suspend fun ingest(
                        wire: ByteArray,
                        remainingHops: Int,
                        clock: () -> Long,
                    ): org.trailmesh.app.persistence.StoreOutcome {
                        committed.complete(Unit)
                        release.await()
                        return org.trailmesh.app.persistence.StoreOutcome.Stored("unused")
                    }
                }
            val (s, _) = inbound(store, wire, now)
            val pending = async {
                s.receive(9, peerFrame(ExchangeMessage.Chunk(1, 0, wire.size, wire)), 2)
            }
            committed.await()
            val expired = async { s.tick(30000) }
            kotlinx.coroutines.yield()
            val immediate = expired.isCompleted
            val invalidated = !s.isCurrent(9)
            release.complete(Unit)
            val result = pending.await()
            expired.await()
            assertTrue("tick must complete while storage is suspended", immediate)
            assertTrue(invalidated)
            assertTrue(result.isEmpty())
            assertEquals(5, s.localFailure)
        }

    @Test
    fun queuedCallbackDoesNotTurnALaterTickIntoABackwardClock() =
        kotlinx.coroutines.runBlocking {
            val (wire, now) = signedFixture()
            val committed = kotlinx.coroutines.CompletableDeferred<Unit>()
            val release = kotlinx.coroutines.CompletableDeferred<Unit>()
            val store =
                object : EmptyStore() {
                    override suspend fun ingest(
                        wire: ByteArray,
                        remainingHops: Int,
                        clock: () -> Long,
                    ): org.trailmesh.app.persistence.StoreOutcome {
                        committed.complete(Unit)
                        release.await()
                        return org.trailmesh.app.persistence.StoreOutcome.Stored("unused")
                    }
                }
            val (s, _) = inbound(store, wire, now)
            val chunk = peerFrame(ExchangeMessage.Chunk(1, 0, wire.size, wire))
            val first = async { s.receive(9, chunk, 3) }
            committed.await()
            val queued = async { s.receive(9, chunk, 5) }
            kotlinx.coroutines.yield()
            s.tick(6)
            release.complete(Unit)
            assertTrue(messages(first.await()).single() is ExchangeMessage.Received)
            assertTrue(messages(queued.await()).single() is ExchangeMessage.Received)
            assertNull(s.localFailure)
        }

    @Test
    fun finalSummaryPageCannotPromiseAnotherPage() =
        kotlinx.coroutines.runBlocking {
            val s = ExchangeSession(EmptyStore(), localNonce, 9) { 0 }
            s.start(0)
            s.receive(9, peerFrame(ExchangeMessage.Hello()), 1)
            repeat(7) { page ->
                assertEquals(
                    listOf(ExchangeMessage.Request(emptyList())),
                    messages(
                        s.receive(
                            9,
                            peerFrame(ExchangeMessage.Summary(page, true, emptyList())),
                            1,
                        ),
                    ),
                )
            }
            // Start with a legal final page and mutate only the `more` flag on the wire.
            val illegal = peerFrame(ExchangeMessage.Summary(7, false, emptyList()))
            illegal[45] = 1
            assertEquals(listOf(ExchangeMessage.Close(3)), messages(s.receive(9, illegal, 1)))
        }

    @Test
    fun negotiatedLimitAppliesBeforeAllocationInCoalescedCallback() =
        kotlinx.coroutines.runBlocking {
            val s = ExchangeSession(EmptyStore(), localNonce, 9) { 0 }
            s.start(0)
            val hello = peerFrame(ExchangeMessage.Hello(maxFrame = 512, maxChunk = 64))
            // Only the next length prefix arrives: reject now, before allocating or waiting for its
            // body.
            val oversized = byteArrayOf(0, 0, 4, 0)
            val out = messages(s.receive(9, hello + oversized, 1))
            assertTrue(out.contains(ExchangeMessage.Close(3)))
        }

    @Test
    fun noncesUnsolicitedAckAndPrematureDoneAreRejected() =
        kotlinx.coroutines.runBlocking {
            for (m in
                listOf(
                    ExchangeMessage.Received(1, "01".repeat(32), 0),
                    ExchangeMessage.Done,
                    ExchangeMessage.Close(0),
                )) {
                val s = ExchangeSession(EmptyStore(), localNonce, 9) { 0 }
                s.start(0)
                s.receive(9, peerFrame(ExchangeMessage.Hello()), 1)
                assertEquals(
                    listOf(ExchangeMessage.Close(3)),
                    messages(s.receive(9, peerFrame(m), 2)),
                )
            }
            val s = ExchangeSession(EmptyStore(), localNonce, 9) { 0 }
            s.start(0)
            s.receive(9, peerFrame(ExchangeMessage.Hello()), 1)
            val wrong =
                ExchangeWire.encode(
                    ExchangeFrame("33".repeat(16), localNonce, ExchangeMessage.Done),
                )
            assertEquals(listOf(ExchangeMessage.Close(3)), messages(s.receive(9, wrong, 2)))
        }

    @Test
    fun offerBudgetIsCheckedBeforeAnOversizedRequestBatch() =
        kotlinx.coroutines.runBlocking {
            val all = (1..40).map { ReportDescriptor("%064x".format(it), 1, 1) }
            val store =
                object : EmptyStore() {
                    override suspend fun inventoryPage(
                        afterID: String?,
                        limit: Int,
                        now: Long,
                    ): InventoryPage {
                        val entries = all.filter { afterID == null || it.id > afterID }.take(8)
                        return InventoryPage(
                            entries,
                            entries.last().id,
                            entries.last() != all.last(),
                        )
                    }

                    override suspend fun load(id: String, now: Long) =
                        OutgoingReport(all.single { it.id == id }, byteArrayOf(1))
                }
            val s = ExchangeSession(store, localNonce, 9) { 0 }
            s.start(0)
            var out = messages(s.receive(9, peerFrame(ExchangeMessage.Hello()), 1))
            var count = 0
            while (out.none { it is ExchangeMessage.Close }) {
                val summary = out.filterIsInstance<ExchangeMessage.Summary>().single()
                out =
                    messages(
                        s.receive(
                            9,
                            peerFrame(ExchangeMessage.Request(summary.entries.map { it.id })),
                            1,
                        ),
                    )
                while (out.any { it is ExchangeMessage.Offer }) {
                    val offer = out.filterIsInstance<ExchangeMessage.Offer>().single()
                    count++
                    out =
                        messages(
                            s.receive(
                                9,
                                peerFrame(
                                    ExchangeMessage.Received(offer.transfer, offer.report.id, 0),
                                ),
                                1,
                            ),
                        )
                }
            }
            assertEquals(32, count)
            assertEquals(ExchangeMessage.Close(2), out.last())
        }

    @Test
    fun lengthCheckedBeforeAllocationAndTruncatedInputFails() {
        try {
            ExchangeDecoder().feed(byteArrayOf(-1, -1, -1, -1))
            fail("oversized")
        } catch (_: ExchangeException) {}
        val d = ExchangeDecoder()
        d.feed(byteArrayOf(0, 0, 1))
        try {
            d.finish()
            fail("truncated")
        } catch (_: ExchangeException) {}
    }
}
