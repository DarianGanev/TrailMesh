package org.trailmesh.foregroundprobe

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionCallbackGuardTest {
    @Test
    fun acceptsCallbackOnlyForActiveMatchingSession() {
        assertTrue(SessionCallbackGuard.isCurrent(active = true, currentGeneration = 4L, callbackGeneration = 4L))
        assertFalse(SessionCallbackGuard.isCurrent(active = false, currentGeneration = 4L, callbackGeneration = 4L))
        assertFalse(SessionCallbackGuard.isCurrent(active = true, currentGeneration = 5L, callbackGeneration = 4L))
    }
}
