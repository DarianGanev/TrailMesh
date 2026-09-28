package org.trailmesh.foregroundprobe

import org.junit.Assert.assertEquals
import org.junit.Test

class NearbyPermissionPolicyTest {
    @Test
    fun android13UsesNearbyPermissionsWithoutRequestingLocationByDefault() {
        assertEquals(
            setOf(
                "android.permission.BLUETOOTH_ADVERTISE",
                "android.permission.BLUETOOTH_CONNECT",
                "android.permission.BLUETOOTH_SCAN",
                "android.permission.NEARBY_WIFI_DEVICES",
            ),
            NearbyPermissionPolicy.requiredPermissions(33).toSet(),
        )
    }

    @Test
    fun android13RequestsCoarseOnlyAfterNearbyReportsItMissing() {
        val coarseLocation = "android.permission.ACCESS_COARSE_LOCATION"
        val granted = NearbyPermissionPolicy.requiredPermissions(33)
            .toSet()

        assertEquals(
            listOf(coarseLocation),
            NearbyPermissionPolicy.permissionsForCompatibilityFailure(
                sdkInt = 33,
                operation = "discovery",
                statusCode = NearbyPermissionPolicy.STATUS_MISSING_COARSE_LOCATION,
                grantedPermissions = granted,
            ),
        )
    }

    @Test
    fun android13RequestsLocationPairOnlyAfterNearbyReportsFineLocationMissing() {
        val coarseLocation = "android.permission.ACCESS_COARSE_LOCATION"
        val fineLocation = "android.permission.ACCESS_FINE_LOCATION"
        val granted = NearbyPermissionPolicy.requiredPermissions(33)
            .plus(coarseLocation)
            .toSet()

        assertEquals(
            listOf(coarseLocation, fineLocation),
            NearbyPermissionPolicy.permissionsForCompatibilityFailure(
                sdkInt = 33,
                operation = "discovery",
                statusCode = NearbyPermissionPolicy.STATUS_MISSING_FINE_LOCATION,
                grantedPermissions = granted,
            ),
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
    fun android13IgnoresLocationPermissionsWhenCheckingNormalStartupRequirements() {
        val granted = NearbyPermissionPolicy.requiredPermissions(33).toSet()

        assertEquals(
            emptyList<String>(),
            NearbyPermissionPolicy.permissionsToRequest(33, granted),
        )
    }

    @Test
    fun android13DoesNotRequestCompatibilityLocationForOtherFailures() {
        val granted = NearbyPermissionPolicy.requiredPermissions(33).toSet()

        assertEquals(
            emptyList<String>(),
            NearbyPermissionPolicy.permissionsForCompatibilityFailure(
                sdkInt = 33,
                operation = "discovery",
                statusCode = 8000,
                grantedPermissions = granted,
            ),
        )
    }

    @Test
    fun android13DoesNotRepeatTheFineLocationFallbackWhenFineIsAlreadyGranted() {
        val granted = NearbyPermissionPolicy.requiredPermissions(33).toSet() + setOf(
            "android.permission.ACCESS_COARSE_LOCATION",
            "android.permission.ACCESS_FINE_LOCATION",
        )

        assertEquals(
            emptyList<String>(),
            NearbyPermissionPolicy.permissionsForCompatibilityFailure(
                sdkInt = 33,
                operation = "discovery",
                statusCode = NearbyPermissionPolicy.STATUS_MISSING_FINE_LOCATION,
                grantedPermissions = granted,
            ),
        )
    }

    @Test
    fun android13DoesNotRequestCompatibilityLocationForAdvertisingFailures() {
        assertEquals(
            emptyList<String>(),
            NearbyPermissionPolicy.permissionsForCompatibilityFailure(
                sdkInt = 33,
                operation = "advertising",
                statusCode = NearbyPermissionPolicy.STATUS_MISSING_FINE_LOCATION,
                grantedPermissions = emptySet(),
            ),
        )
    }
}
