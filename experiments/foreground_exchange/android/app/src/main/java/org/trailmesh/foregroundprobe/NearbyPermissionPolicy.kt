package org.trailmesh.foregroundprobe

import android.Manifest
import android.os.Build

internal object NearbyPermissionPolicy {
    const val STATUS_MISSING_COARSE_LOCATION = 8034
    const val STATUS_MISSING_FINE_LOCATION = 8036

    fun requiredPermissions(sdkInt: Int): List<String> = buildList {
        if (sdkInt >= Build.VERSION_CODES.S) {
            add(Manifest.permission.BLUETOOTH_ADVERTISE)
            add(Manifest.permission.BLUETOOTH_CONNECT)
            add(Manifest.permission.BLUETOOTH_SCAN)
        }
        if (sdkInt <= Build.VERSION_CODES.S) {
            add(Manifest.permission.ACCESS_COARSE_LOCATION)
        }
        if (sdkInt in Build.VERSION_CODES.Q..Build.VERSION_CODES.S) {
            add(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        if (sdkInt >= Build.VERSION_CODES.TIRAMISU) {
            add(Manifest.permission.NEARBY_WIFI_DEVICES)
        }
    }

    fun permissionsToRequest(sdkInt: Int, grantedPermissions: Set<String>): List<String> {
        val missing = requiredPermissions(sdkInt).filterNot(grantedPermissions::contains)
        val fineLocation = Manifest.permission.ACCESS_FINE_LOCATION
        if (sdkInt < Build.VERSION_CODES.S || fineLocation !in missing) return missing

        val locationPermissions = listOf(
            Manifest.permission.ACCESS_COARSE_LOCATION,
            fineLocation,
        )
        return locationPermissions + missing.filterNot(locationPermissions::contains)
    }

    fun permissionsForCompatibilityFailure(
        sdkInt: Int,
        operation: String,
        statusCode: Int?,
        grantedPermissions: Set<String>,
    ): List<String> {
        if (sdkInt < Build.VERSION_CODES.TIRAMISU || !operation.equals("discovery", ignoreCase = true)) {
            return emptyList()
        }

        val coarseLocation = Manifest.permission.ACCESS_COARSE_LOCATION
        val fineLocation = Manifest.permission.ACCESS_FINE_LOCATION
        return when (statusCode) {
            STATUS_MISSING_COARSE_LOCATION -> if (coarseLocation !in grantedPermissions) {
                listOf(coarseLocation)
            } else {
                emptyList()
            }
            STATUS_MISSING_FINE_LOCATION -> if (fineLocation !in grantedPermissions) {
                listOf(coarseLocation, fineLocation)
            } else {
                emptyList()
            }
            else -> emptyList()
        }
    }
}
