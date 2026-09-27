package org.trailmesh.foregroundprobe

import org.junit.Assert.assertEquals
import org.junit.Test

class NearbyOperationFailureTest {
    @Test
    fun includesGoogleStatusCodeAndNameInTheActionableMessage() {
        val failure = NearbyOperationFailure(
            operation = "Discovery",
            statusCode = 8029,
            statusName = "MISSING_PERMISSION_NEARBY_WIFI_DEVICES",
            exceptionType = "ApiException",
        )

        assertEquals(
            "Discovery failed (8029: MISSING_PERMISSION_NEARBY_WIFI_DEVICES, ApiException). See test log.",
            failure.userMessage(),
        )
    }

    @Test
    fun includesExceptionTypeWhenGoogleStatusCodeIsUnavailable() {
        val failure = NearbyOperationFailure(
            operation = "Discovery",
            statusCode = null,
            statusName = null,
            exceptionType = "IllegalStateException",
        )

        assertEquals("Discovery failed (IllegalStateException). See test log.", failure.userMessage())
    }
}
