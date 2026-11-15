package org.trailmesh.foregroundprobe

import org.junit.Assert.*
import org.junit.Test

class ProbeLinkRegistryTest {
    private val local = ProbePeerContext(ProbePlatform.ANDROID, "f".repeat(32), 2048)
    private fun peer(index: Int) = ProbePeerContext(ProbePlatform.ANDROID, "%032x".format(index), 2048)

    @Test fun fourLiveProtocolsRouteIndependentlyAndOneFailureRefillsItsSlot() {
        val scope = CallbackScope().apply { start() }
        val registry = ProbeLinkRegistry(scope)
        val scheduler = PeerScheduler()
        for (index in 1..5) scheduler.discover("endpoint-$index", peer(index))
        val links = List(4) {
            val candidate = scheduler.takeNext(0) { true }!!
            registry.add(candidate.endpoint, candidate.peer)!!
        }
        for ((index, link) in links.withIndex()) {
            link.exchange.hello(ForegroundFrame.HelloMessage(link.peer.sessionID, local.sessionID, 2048, 20), local, link.peer)
            link.exchange.beginSend(index, ForegroundFrame.sha256(ForegroundFrame.makeTestPayload(2048, index)))
            assertSame(link, registry.current(link.token))
        }
        assertNull(registry.add("sixth", peer(6)))
        val failed = links[1]
        assertTrue(registry.retire(failed))
        scheduler.release(failed.endpoint, 1000)
        val next = scheduler.takeNext(0) { true }!!
        val replacement = registry.add(next.endpoint, next.peer)!!
        assertEquals("endpoint-5", replacement.endpoint)
        assertNull(registry.current(failed.token))
        for (link in links.filter { it !== failed }) {
            assertSame(link, registry.current(link.token))
            assertNotNull(link.pendingSend)
        }
        assertEquals(4, registry.links.size)
    }

    @Test fun capturedLifecycleAndPayloadTokensNeverBorrowAReplacementEndpoint() {
        val scope = CallbackScope().apply { start() }
        val registry = ProbeLinkRegistry(scope)
        val old = registry.add("endpoint", peer(1))!!
        val callback = LinkCallbacks()
        assertTrue(callback.initiate(old))
        registry.retire(old)
        assertNull(registry.add("endpoint", peer(1)))
        scope.restartRadio()
        registry.clear()
        val replacement = registry.add("endpoint", peer(1))!!
        assertNull(registry.current(callback.token("endpoint")!!))
        assertFalse(callback.initiate(replacement))
        assertSame(replacement, registry.current(replacement.token))
        assertNull(registry.current(replacement.token, "another-endpoint"))
        scope.stop()
        assertNull(registry.current(replacement.token))
    }

    @Test fun duplicatePeerCannotOccupyTwoSlotsAndClearInvalidatesEveryEndpoint() {
        val scope = CallbackScope().apply { start() }
        val registry = ProbeLinkRegistry(scope)
        val first = registry.add("first", peer(1))!!
        assertNull(registry.add("second", peer(1)))
        assertNull(registry.add("first", peer(2)))
        val second = registry.add("second", peer(2))!!
        registry.clear()
        assertNull(registry.current(first.token))
        assertNull(registry.current(second.token))
        assertTrue(registry.links.isEmpty())
    }
}
