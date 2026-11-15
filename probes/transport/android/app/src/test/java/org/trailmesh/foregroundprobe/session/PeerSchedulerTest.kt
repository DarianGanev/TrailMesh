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
}
