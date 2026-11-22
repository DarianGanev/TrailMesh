package org.trailmesh.app.session

import android.Manifest.permission.ACCESS_COARSE_LOCATION
import android.Manifest.permission.ACCESS_FINE_LOCATION
import android.Manifest.permission.NEARBY_WIFI_DEVICES
import org.junit.Assert.assertEquals
import org.junit.Test

class ReportNearbyPermissionsTest {
    @Test
    fun requestsBothLocationPermissionsWhenUpgradingOnAndroid12AndLater() {
        val missing = listOf(ACCESS_FINE_LOCATION, NEARBY_WIFI_DEVICES)

        assertEquals(missing, ReportNearbyPermissions.forRequest(30, missing))
        assertEquals(missing + ACCESS_COARSE_LOCATION, ReportNearbyPermissions.forRequest(31, missing))
        assertEquals(missing + ACCESS_COARSE_LOCATION, ReportNearbyPermissions.forRequest(37, missing))
        assertEquals(listOf(ACCESS_COARSE_LOCATION), ReportNearbyPermissions.forRequest(37, listOf(ACCESS_COARSE_LOCATION)))
    }
}
