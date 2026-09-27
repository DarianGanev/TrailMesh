package org.trailmesh.foregroundprobe

import android.Manifest
import android.os.Build

internal object NearbyPermissionPolicy {
    fun requiredPermissions(sdkInt: Int): List<String> = buildList {
        if (sdkInt >= Build.VERSION_CODES.S) {
            add(Manifest.permission.BLUETOOTH_ADVERTISE)
            add(Manifest.permission.BLUETOOTH_CONNECT)
            add(Manifest.permission.BLUETOOTH_SCAN)
        }
        add(Manifest.permission.ACCESS_COARSE_LOCATION)
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
        if (sdkInt != Build.VERSION_CODES.S || fineLocation !in missing) return missing

        val locationPermissions = listOf(
            Manifest.permission.ACCESS_COARSE_LOCATION,
            fineLocation,
        )
        return locationPermissions + missing.filterNot(locationPermissions::contains)
    }
}
