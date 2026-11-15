package org.trailmesh.foregroundprobe

import org.junit.Assert.*
import org.junit.Test

class LinkIngressTest {
    @Test fun queueReservationsAreBoundedAndOverflowIsReportedOnce() {
        val ingress = LinkIngress()
        repeat(64) { assertTrue(ingress.acquire()) }
        assertFalse(ingress.acquire())
        assertTrue(ingress.claimOverflowNotice())
        assertFalse(ingress.claimOverflowNotice())
        repeat(64) { ingress.release() }
        assertFalse(ingress.acquire())
    }

    @Test fun oneOverloadedPeerDoesNotConsumeOtherPeersReservations() {
        val stalled = LinkIngress()
        val healthy = LinkIngress()
        repeat(64) { assertTrue(stalled.acquire()) }
        assertFalse(stalled.acquire())
        repeat(100) { assertTrue(healthy.acquire()); healthy.release() }
        assertFalse(healthy.claimOverflowNotice())
    }
}
