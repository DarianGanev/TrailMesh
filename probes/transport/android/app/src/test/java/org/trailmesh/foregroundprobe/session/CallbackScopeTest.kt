package org.trailmesh.foregroundprobe

import org.junit.Assert.*
import org.junit.Test

class CallbackScopeTest {
    @Test fun stopAndNewSessionRejectAllOldSdkAndTimerCallbacks() {
        val scope = CallbackScope()
        scope.start()
        val old = scope.select("peer")
        scope.stop()
        assertFalse(scope.accepts(old))
        scope.start()
        assertFalse(scope.accepts(old))
        assertTrue(scope.acceptsRadio(scope.capture()))
    }

    @Test fun simultaneousPeersHaveIndependentGenerationsAndRetirement() {
        val scope = CallbackScope()
        scope.start()
        val first = scope.select("first")
        val second = scope.select("second")
        assertTrue(scope.accepts(first, "first"))
        assertTrue(scope.accepts(second, "second"))
        assertFalse(scope.accepts(first, "second"))
        scope.retire("first")
        val replacement = scope.select("first")
        assertFalse(scope.accepts(first))
        assertTrue(scope.accepts(second))
        assertTrue(scope.accepts(replacement))
        scope.restartRadio()
        assertFalse(scope.accepts(second))
        assertFalse(scope.accepts(replacement))
    }

    @Test fun advertisingInitiationRemainsScopedToItsRadioButOldRadioIsRejected() {
        val scope = CallbackScope()
        scope.start()
        val advertisement = scope.capture()
        scope.select("peer")
        assertTrue(scope.acceptsRadio(advertisement))
        scope.restartRadio()
        assertFalse(scope.acceptsRadio(advertisement))
    }
}
