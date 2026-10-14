package org.trailmesh.foregroundprobe

import org.junit.Assert.*
import org.junit.Test

class CallbackScopeTest {
    @Test fun stopAndNewSessionRejectAllOldSdkAndTimerCallbacks() {
        val scope = CallbackScope()
        scope.start()
        val old = scope.capture()
        scope.stop()
        assertFalse(scope.accepts(old))
        scope.start()
        assertFalse(scope.accepts(old))
        assertTrue(scope.accepts(scope.capture()))
    }

    @Test fun radioRestartAndPeerChangeInvalidateEndpointBoundCallbacks() {
        val scope = CallbackScope()
        scope.start()
        val radio = scope.capture()
        scope.select("first")
        val first = scope.capture()
        assertFalse(scope.accepts(radio))
        assertTrue(scope.accepts(first, "first"))
        assertFalse(scope.accepts(first, "second"))
        scope.select("second")
        assertFalse(scope.accepts(first, "first"))
        val second = scope.capture()
        scope.restartRadio()
        assertFalse(scope.accepts(second, "second"))
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
