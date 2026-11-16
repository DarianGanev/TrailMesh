package org.trailmesh.app.session

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.trailmesh.app.exchange.*
import org.trailmesh.app.persistence.*
import org.trailmesh.app.relevance.*

class ReportSessionCoordinatorTest {
    private open class EmptyStore : ReportExchangeStore {
        override suspend fun inventoryPage(afterID: String?, limit: Int, now: Long) =
            InventoryPage(emptyList(), null, false)

        override suspend fun currentIDs(ids: List<String>, now: Long) = emptySet<String>()

        override suspend fun load(id: String, now: Long): OutgoingReport? = null

        override suspend fun ingest(wire: ByteArray, remainingHops: Int, clock: () -> Long) =
            StoreOutcome.Rejected("invalid")
    }

    private class Radio : ReportSessionRadio {
        val requested = mutableListOf<ReportLinkToken>()
        val sends = mutableListOf<Pair<ReportLinkToken, ByteArray>>()
        val completions = mutableListOf<(Boolean) -> Unit>()
        var starts = 0

        override fun start(epoch: Long, advertisement: String) {
            starts++
        }

        override fun stop() {}

        override fun request(token: ReportLinkToken, advertisement: String) {
            requested.add(token)
        }

        override fun accept(token: ReportLinkToken) {}

        override fun reject(endpoint: String) {}

        override fun disconnect(token: ReportLinkToken) {}

        override fun send(token: ReportLinkToken, bytes: ByteArray, completion: (Boolean) -> Unit) {
            sends.add(token to bytes)
            completions.add(completion)
        }
    }

    private val context = RelevanceContext(manualArea = Area(GeoPoint(0, 0), 1000))

    @Test
    fun admissionConsentBoundsFourLinksAndStopInvalidatesCapturedGenerations() = runBlocking {
        val radio = Radio()
        var now = 0L
        val owner =
            ReportSessionCoordinator(
                radio,
                { EmptyStore() },
                this,
                { 100 },
                { now },
                { "0".repeat(31) + "1" },
            )
        assertEquals(ReportSessionState.consentRequired, owner.start(context, false))
        assertEquals(ReportSessionState.configurationRequired, owner.start(null, true))
        assertEquals(ReportSessionState.active, owner.start(context, true))
        val epoch = owner.epoch
        repeat(40) { owner.found(epoch, "e$it", "TMR1|" + (it + 2).toString(16).padStart(32, '0')) }
        assertEquals(4, owner.liveLinks)
        assertEquals(32, owner.waitingPeers)
        val token = radio.requested.first()
        owner.connected(token)
        delay(10)
        owner.stop()
        assertFalse(owner.isLive(token))
        owner.connected(token)
        owner.receive(token, byteArrayOf(1))
        now = 100000
        owner.tick()
        assertEquals(0, owner.liveLinks)
        assertEquals(ReportSessionState.stopped, owner.state)
    }

    @Test
    fun completionWaitsForTerminalSendsAndTimeoutRefillsFifo() = runBlocking {
        val radio = Radio()
        var now = 0L
        val owner =
            ReportSessionCoordinator(
                radio,
                { EmptyStore() },
                this,
                { 100 },
                { now },
                { "0".repeat(31) + "1" },
            )
        owner.start(context, true)
        repeat(5) {
            owner.found(owner.epoch, "e$it", "TMR1|" + (it + 2).toString(16).padStart(32, '0'))
        }
        val old = radio.requested.first()
        now = 15000
        owner.tick()
        assertFalse(owner.isLive(old))
        assertTrue(radio.requested.any { it.endpoint == "e4" })
        owner.stop()
    }

    @Test
    fun advertisementsRejectExtraFieldsAndZeroAndUppercase() {
        assertNull(ReportAdvertisement.parse("TMR1|" + "0".repeat(32)))
        assertNull(ReportAdvertisement.parse("TMR1|" + "A".repeat(32)))
        assertNull(ReportAdvertisement.parse("TMR1|" + "1".repeat(32) + "|route"))
        assertEquals("1".repeat(32), ReportAdvertisement.parse("TMR1|" + "1".repeat(32)))
    }

    @Test
    fun aggregateIngressRejectsBeforeLaunchingAndStopDiscardsQueuedOldEpochWork() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val store =
            object : EmptyStore() {
                override suspend fun inventoryPage(
                    afterID: String?,
                    limit: Int,
                    now: Long,
                ): InventoryPage {
                    entered.complete(Unit)
                    release.await()
                    return InventoryPage(emptyList(), null, false)
                }
            }
        val radio = Radio()
        val owner =
            ReportSessionCoordinator(
                radio,
                { store },
                scope,
                { 100 },
                { 0 },
                { "0".repeat(31) + "1" },
            )
        try {
            owner.start(context, true)
            repeat(2) {
                owner.found(owner.epoch, "e$it", "TMR1|" + (it + 2).toString(16).padStart(32, '0'))
            }
            val token = radio.requested[0]
            val healthy = radio.requested[1]
            owner.connected(token)
            owner.connected(healthy)
            val hello =
                ExchangeWire.encode(
                    ExchangeFrame("a".repeat(32), ExchangeWire.ZERO, ExchangeMessage.Hello()),
                )
            owner.receive(token, hello)
            entered.await()
            repeat(63) { owner.receive(token, byteArrayOf(0)) }
            assertEquals(64, owner.queuedCallbacks)
            owner.receive(token, byteArrayOf(0))
            assertFalse(owner.isLive(token))
            assertTrue(owner.isLive(healthy))
            val sent = radio.sends.size
            owner.stop()
            owner.start(context, true)
            release.complete(Unit)
            delay(50)
            assertEquals(sent, radio.sends.size)
            assertEquals(0, owner.queuedCallbacks)
            val newer = owner.epoch
            owner.connected(token)
            assertEquals(newer, owner.epoch)
            owner.found(owner.epoch, "large", "TMR1|" + "b".repeat(32))
            val large = radio.requested.last()
            owner.connected(large)
            owner.receive(large, ByteArray(262145))
            assertFalse(owner.isLive(large))
            assertEquals(0, owner.queuedBytes)
        } finally {
            owner.stop()
            release.complete(Unit)
            scope.cancel()
        }
    }

    @Test
    fun contextChangesAndSdkSendFailureInvalidateOldTokensAndAllowOverEightPeers() = runBlocking {
        val radio = Radio()
        var time = 0L
        val owner =
            ReportSessionCoordinator(
                radio,
                { EmptyStore() },
                this,
                { 100 },
                { time },
                { "0".repeat(31) + "1" },
            )
        owner.start(context, true)
        repeat(12) { i ->
            owner.found(
                owner.epoch,
                "reused-endpoint",
                "TMR1|" + (i + 2).toString(16).padStart(32, '0'),
            )
            val token = radio.requested.last()
            owner.connected(token)
            radio.completions.last()(false)
            assertFalse(owner.isLive(token))
            time += 1000
            owner.tick()
            owner.connected(token)
        }
        assertEquals(12, radio.requested.size)
        assertTrue(radio.starts > 8)
        owner.found(owner.epoch, "context", "TMR1|" + "f".repeat(32))
        val old = radio.requested.last()
        assertEquals(ReportSessionState.active, owner.updateContext(context, true))
        assertFalse(owner.isLive(old))
        owner.stop()
    }

    @Test
    fun terminalCloseDrainsSdkCompletionsBeforeDisconnectAndHasTwoSecondDeadline() = runBlocking {
        val radio = Radio()
        var time = 0L
        val owner =
            ReportSessionCoordinator(
                radio,
                { EmptyStore() },
                this,
                { 100 },
                { time },
                { "0".repeat(31) + "1" },
            )
        owner.start(context, true)
        owner.found(owner.epoch, "e", "TMR1|" + "2".repeat(32))
        val token = radio.requested.single()
        owner.connected(token)
        val peer = "a".repeat(32)
        val local = ExchangeWire.decode(radio.sends.first().second).source
        fun frame(m: ExchangeMessage) =
            ExchangeWire.encode(
                ExchangeFrame(
                    peer,
                    if (m is ExchangeMessage.Hello) ExchangeWire.ZERO else local,
                    m,
                ),
            )
        owner.receive(token, frame(ExchangeMessage.Hello()))
        owner.receive(token, frame(ExchangeMessage.Summary(0, false, emptyList())))
        owner.receive(token, frame(ExchangeMessage.Request(emptyList())))
        owner.receive(token, frame(ExchangeMessage.Done))
        assertTrue(owner.isLive(token))
        assertTrue(
            radio.sends.any { ExchangeWire.decode(it.second).message is ExchangeMessage.Close },
        )
        time = 1999
        owner.tick()
        assertTrue(owner.isLive(token))
        radio.completions.toList().forEach { it(true) }
        assertFalse(owner.isLive(token))
        owner.tick()
        owner.found(owner.epoch, "deadline", "TMR1|" + "3".repeat(32))
        val timed = radio.requested.last()
        owner.connected(timed)
        val local2 = ExchangeWire.decode(radio.sends.last().second).source
        fun other(m: ExchangeMessage) =
            ExchangeWire.encode(
                ExchangeFrame(
                    peer,
                    if (m is ExchangeMessage.Hello) ExchangeWire.ZERO else local2,
                    m,
                ),
            )
        owner.receive(timed, other(ExchangeMessage.Hello()))
        owner.receive(timed, other(ExchangeMessage.Summary(0, false, emptyList())))
        owner.receive(timed, other(ExchangeMessage.Request(emptyList())))
        owner.receive(timed, other(ExchangeMessage.Done))
        time += 2000
        owner.tick()
        assertFalse(owner.isLive(timed))
        owner.stop()
    }

    @Test
    fun normalActionsBecomeStaleAfterProtocolCloseWhileTerminalCloseCanDrain() = runBlocking {
        val engine = ExchangeSession(EmptyStore(), "1".repeat(32), 1, { 100 })
        val normal = engine.start(0)
        val hello =
            ExchangeWire.encode(
                ExchangeFrame("2".repeat(32), ExchangeWire.ZERO, ExchangeMessage.Hello()),
            )
        val summary = engine.receive(1, hello, 0)
        val terminal = engine.receive(1, hello, 0)
        assertTrue(engine.isComplete)
        assertTrue((normal + summary).none { engine.isLive(it) })
        assertTrue(terminal.isNotEmpty())
        assertTrue(terminal.all { it.terminal && engine.isLive(it) })
        engine.cancel()
        assertTrue(terminal.none { engine.isLive(it) })
    }

    @Test
    fun asymmetricDoneOrderKeepsNewDoneLiveUntilPeerCanObserveIt() = runBlocking {
        val local = "1".repeat(32)
        val peer = "2".repeat(32)
        val engine = ExchangeSession(EmptyStore(), local, 1, { 100 })
        engine.start(0)
        fun frame(message: ExchangeMessage) =
            ExchangeWire.encode(
                ExchangeFrame(
                    peer,
                    if (message is ExchangeMessage.Hello) ExchangeWire.ZERO else local,
                    message,
                ),
            )
        engine.receive(1, frame(ExchangeMessage.Hello()), 0)
        engine.receive(1, frame(ExchangeMessage.Summary(0, false, emptyList())), 0)
        engine.receive(1, frame(ExchangeMessage.Done), 0)
        val actions = engine.receive(1, frame(ExchangeMessage.Request(emptyList())), 0)
        val live =
            actions.filter { engine.isLive(it) }.map { ExchangeWire.decode(it.bytes).message }
        assertTrue(
            "The peer must receive our DONE before a graceful CLOSE",
            live.any { it is ExchangeMessage.Done },
        )
        assertFalse(engine.isComplete)
        assertFalse(live.any { it is ExchangeMessage.Close })
        engine.receive(1, frame(ExchangeMessage.Close(0)), 0)
        assertTrue(engine.isComplete)
        engine.cancel()
    }

    @Test
    fun coalescedGracefulCompletionPreservesAllNewNormalActions() = runBlocking {
        val local = "1".repeat(32)
        val peer = "2".repeat(32)
        val engine = ExchangeSession(EmptyStore(), local, 1, { 100 })
        engine.start(0)
        fun frame(message: ExchangeMessage) =
            ExchangeWire.encode(
                ExchangeFrame(
                    peer,
                    if (message is ExchangeMessage.Hello) ExchangeWire.ZERO else local,
                    message,
                ),
            )
        engine.receive(1, frame(ExchangeMessage.Hello()), 0)
        val callback =
            frame(ExchangeMessage.Summary(0, false, emptyList())) +
                frame(ExchangeMessage.Request(emptyList())) +
                frame(ExchangeMessage.Done)
        val actions = engine.receive(1, callback, 0)
        val live =
            actions.filter { engine.isLive(it) }.map { ExchangeWire.decode(it.bytes).message }
        assertEquals(2, live.size)
        assertTrue(live[0] is ExchangeMessage.Request)
        assertTrue(live[1] is ExchangeMessage.Done)
        assertFalse(engine.isComplete)
        engine.receive(1, frame(ExchangeMessage.Close(0)), 0)
        assertTrue(engine.isComplete)
        engine.cancel()
    }

    @Test
    fun queuedArrivalSurvivesLaterTickAndActualRollbackStillFails() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val clock = java.util.concurrent.atomic.AtomicLong(0)
        val store =
            object : EmptyStore() {
                override suspend fun inventoryPage(
                    afterID: String?,
                    limit: Int,
                    now: Long,
                ): InventoryPage {
                    entered.complete(Unit)
                    release.await()
                    return InventoryPage(emptyList(), null, false)
                }
            }
        val radio = Radio()
        val owner =
            ReportSessionCoordinator(
                radio,
                { store },
                scope,
                { 100 },
                clock::get,
                { "0".repeat(31) + "1" },
            )
        try {
            owner.start(context, true)
            owner.found(owner.epoch, "queued", "TMR1|" + "2".repeat(32))
            val token = radio.requested.single()
            owner.connected(token)
            val hello =
                ExchangeWire.encode(
                    ExchangeFrame("a".repeat(32), ExchangeWire.ZERO, ExchangeMessage.Hello()),
                )
            clock.set(10)
            owner.receive(token, hello)
            entered.await()
            clock.set(15)
            owner.receive(token, byteArrayOf(0)) // valid partial prefix queues behind storage
            assertEquals(2, owner.queuedCallbacks)
            clock.set(20)
            owner.tick()
            release.complete(Unit)
            withTimeout(5000) { while (owner.queuedCallbacks != 0) delay(1) }
            assertTrue(
                "An arrival registered at 15 must not become a rollback after tick 20",
                owner.isLive(token),
            )
            clock.set(19)
            owner.receive(token, byteArrayOf(0))
            withTimeout(5000) { while (owner.isLive(token)) delay(1) }
            assertFalse(owner.isLive(token))
        } finally {
            owner.stop()
            release.complete(Unit)
            scope.cancel()
        }
    }

    @Test
    fun retainedPayloadBudgetRemainsChargedAcrossRotationStopAndRestart() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var calls = 0
        val store =
            object : EmptyStore() {
                override suspend fun inventoryPage(
                    afterID: String?,
                    limit: Int,
                    now: Long,
                ): InventoryPage {
                    calls++
                    entered.complete(Unit)
                    release.await()
                    return InventoryPage(emptyList(), null, false)
                }
            }
        val radio = Radio()
        val owner =
            ReportSessionCoordinator(
                radio,
                { store },
                scope,
                { 100 },
                { 0 },
                { "0".repeat(31) + "1" },
            )
        try {
            owner.start(context, true)
            owner.found(owner.epoch, "old", "TMR1|" + "2".repeat(32))
            val old = radio.requested.single()
            owner.connected(old)
            val hello =
                ExchangeWire.encode(
                    ExchangeFrame("a".repeat(32), ExchangeWire.ZERO, ExchangeMessage.Hello()),
                )
            owner.receive(old, hello)
            entered.await()
            owner.receive(old, ByteArray(120000))
            val retained = hello.size.toLong() + 120000
            assertEquals(retained, owner.queuedBytes)
            owner.failed(old)
            owner.tick() // retire the old SDK epoch while its repository operation is suspended
            assertEquals(retained, owner.queuedBytes)
            owner.stop()
            assertEquals(retained, owner.queuedBytes)
            owner.start(context, true)
            assertEquals(retained, owner.queuedBytes)
            owner.found(owner.epoch, "new", "TMR1|" + "3".repeat(32))
            val current = radio.requested.last()
            owner.connected(current)
            owner.receive(current, hello + ByteArray(150000 - hello.size))
            assertFalse(owner.isLive(current)) // would exceed the aggregate 256 KiB limit
            assertEquals(retained, owner.queuedBytes)
            assertEquals(2, owner.queuedCallbacks)
            assertEquals(1, calls)
            release.complete(Unit)
            withTimeout(5000) { while (owner.queuedCallbacks != 0) delay(1) }
            assertEquals(0L, owner.queuedBytes)
        } finally {
            owner.stop()
            release.complete(Unit)
            scope.cancel()
        }
    }

    @Test
    fun arrivalTicketsAreBoundToOneEngineAndCannotBeReplayedAfterAQueuedReceive() = runBlocking {
        val first = ExchangeSession(EmptyStore(), "1".repeat(32), 1, { 100 })
        val other = ExchangeSession(EmptyStore(), "2".repeat(32), 2, { 100 })
        first.start(0)
        other.start(0)
        val hello =
            ExchangeWire.encode(
                ExchangeFrame("a".repeat(32), ExchangeWire.ZERO, ExchangeMessage.Hello()),
            )
        val arrival = requireNotNull(first.registerArrival(1) { 10 })
        assertTrue(other.receive(arrival, hello).isEmpty())
        first.tick { 20 }
        assertTrue(
            first.receive(arrival, hello).any {
                ExchangeWire.decode(it.bytes).message is ExchangeMessage.Summary
            },
        )
        assertTrue(first.receive(arrival, hello).isEmpty())
        assertTrue(
            first.isCurrent(1),
        ) // replay did not turn into a duplicate-HELLO protocol failure
        first.tick { 19 }
        assertFalse(first.isCurrent(1))
        assertEquals(4, first.localFailure)
        first.cancel()
        other.cancel()
    }
}
