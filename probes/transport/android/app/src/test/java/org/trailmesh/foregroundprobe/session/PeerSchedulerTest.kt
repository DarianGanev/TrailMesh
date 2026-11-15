package org.trailmesh.foregroundprobe

import org.junit.Assert.*
import org.junit.Test

class PeerSchedulerTest {
    private fun peer(index: Int) = ProbePeerContext(ProbePlatform.ANDROID, "%032x".format(index), 2048)

    @Test fun fourReservedConnectionsLeaveOtherCandidatesWaitingInArrivalOrder() {
        val scheduler = PeerScheduler()
        for (index in 1..7) assertTrue(scheduler.discover("endpoint-$index", peer(index)))
        assertEquals((1..4).map { "endpoint-$it" }, List(4) { scheduler.takeNext(0) { true }!!.endpoint })
        assertNull(scheduler.takeNext(0) { true })
        assertEquals(4, scheduler.activeCount)
        assertEquals(3, scheduler.waitingCount)
        scheduler.release("endpoint-2")
        assertEquals("endpoint-5", scheduler.takeNext(0) { true }!!.endpoint)
    }

    @Test fun retryWaitsBehindExistingCandidatesAndRetainsItsDeadline() {
        val scheduler = PeerScheduler()
        scheduler.discover("first", peer(1))
        scheduler.takeNext(0) { true }
        scheduler.discover("waiting", peer(2))
        scheduler.release("first", 1000)
        assertEquals("waiting", scheduler.takeNext(10) { true }!!.endpoint)
        assertNull(scheduler.takeNext(999) { true })
        assertEquals(1000L, scheduler.nextReadyAt)
        assertEquals("first", scheduler.takeNext(1000) { true }!!.endpoint)
    }

    @Test fun discoveryFloodAndIncomingRequestsRespectBoundsAndDistinctPeers() {
        val scheduler = PeerScheduler()
        for (index in 1..32) assertTrue(scheduler.discover("endpoint-$index", peer(index)))
        assertFalse(scheduler.discover("overflow", peer(33)))
        assertTrue(scheduler.reserveIncoming("endpoint-1", peer(1)))
        assertFalse(scheduler.reserveIncoming("second-endpoint", peer(1)))
        assertFalse(scheduler.reserveIncoming("endpoint-1", peer(40)))
        assertEquals(1, scheduler.activeCount)
        assertFalse(scheduler.discover("duplicate", peer(1)))
        for (index in 34..36) assertTrue(scheduler.reserveIncoming("incoming-$index", peer(index)))
        assertFalse(scheduler.reserveIncoming("fifth", peer(37)))
        assertEquals(4, scheduler.activeCount)
        assertTrue(scheduler.waitingCount <= 32)
    }

    @Test fun discoveryLossAndIneligibleCandidatesCannotBlockHealthyPeers() {
        val scheduler = PeerScheduler()
        scheduler.discover("gone", peer(1))
        scheduler.discover("ineligible", peer(2))
        scheduler.discover("healthy", peer(3))
        scheduler.lost("gone")
        assertEquals("healthy", scheduler.takeNext(0) { it.peer.sessionID != peer(2).sessionID }!!.endpoint)
        assertEquals(0, scheduler.waitingCount)
        scheduler.clear()
        assertEquals(0, scheduler.activeCount)
    }

    @Test fun refreshedEndpointKeepsItsWaitingTurnAndRetryDeadlineAtCapacity() {
        val scheduler = PeerScheduler()
        scheduler.discover("old", peer(1), 1000)
        for (index in 2..32) scheduler.discover("endpoint-$index", peer(index), 1000)
        assertTrue(scheduler.discover("new", peer(1)))
        scheduler.lost("old")
        assertEquals(32, scheduler.waitingCount)
        assertNull(scheduler.takeNext(999) { true })
        assertEquals("new", scheduler.takeNext(1000) { true }!!.endpoint)
        assertEquals("endpoint-2", scheduler.takeNext(1000) { true }!!.endpoint)
    }

    @Test fun queuedPeerRefreshRejectsChangedContextAndAnotherPeersEndpoint() {
        val scheduler = PeerScheduler()
        scheduler.discover("original", peer(1), 1000)
        scheduler.discover("occupied", peer(2), 1000)
        assertFalse(scheduler.discover("changed", peer(1).copy(platform = ProbePlatform.IOS)))
        assertFalse(scheduler.discover("occupied", peer(1)))
        assertEquals("original", scheduler.takeNext(1000) { true }!!.endpoint)
        assertEquals("occupied", scheduler.takeNext(1000) { true }!!.endpoint)
    }
}
