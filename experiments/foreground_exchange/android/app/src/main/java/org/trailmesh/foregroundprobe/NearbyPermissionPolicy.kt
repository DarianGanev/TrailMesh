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
}
