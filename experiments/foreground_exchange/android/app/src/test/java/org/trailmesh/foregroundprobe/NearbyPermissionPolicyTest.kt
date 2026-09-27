package org.trailmesh.foregroundprobe

import org.junit.Assert.assertEquals
import org.junit.Test

class NearbyPermissionPolicyTest {
    @Test
    fun android13RequestsCoarseLocationAlongsideNearbyAndBluetoothPermissions() {
        assertEquals(
            setOf(
                "android.permission.BLUETOOTH_ADVERTISE",
                "android.permission.BLUETOOTH_CONNECT",
                "android.permission.BLUETOOTH_SCAN",
                "android.permission.NEARBY_WIFI_DEVICES",
                "android.permission.ACCESS_COARSE_LOCATION",
            ),
            NearbyPermissionPolicy.requiredPermissions(33).toSet(),
        )
    }

    @Test
    fun android10RequestsCoarseAndFineLocationTogether() {
        assertEquals(
            setOf(
                "android.permission.ACCESS_COARSE_LOCATION",
                "android.permission.ACCESS_FINE_LOCATION",
            ),
            NearbyPermissionPolicy.requiredPermissions(29).toSet(),
        )
    }

    @Test
    fun android12RetriesFineLocationTogetherWithCoarseWhenApproximateWasGranted() {
        val fineLocation = "android.permission.ACCESS_FINE_LOCATION"
        val granted = NearbyPermissionPolicy.requiredPermissions(31)
            .filterNot { it == fineLocation }
            .toSet()

        assertEquals(
            setOf(
                "android.permission.ACCESS_COARSE_LOCATION",
                fineLocation,
            ),
            NearbyPermissionPolicy.permissionsToRequest(31, granted).toSet(),
        )
    }

    @Test
    fun android13StillRequestsOnlyPermissionsThatAreMissing() {
        val nearbyWifiDevices = "android.permission.NEARBY_WIFI_DEVICES"
        val granted = NearbyPermissionPolicy.requiredPermissions(33)
            .filterNot { it == nearbyWifiDevices }
            .toSet()

        assertEquals(
            listOf(nearbyWifiDevices),
            NearbyPermissionPolicy.permissionsToRequest(33, granted),
        )
    }
}
