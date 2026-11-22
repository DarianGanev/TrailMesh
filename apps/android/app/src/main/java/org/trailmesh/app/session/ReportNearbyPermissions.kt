package org.trailmesh.app.session

import android.Manifest

/**
 * Runtime grants for the pinned Nearby SDK, including its explicit location compatibility codes.
 */
object ReportNearbyPermissions {
    fun required(sdk: Int): List<String> = buildList {
        if (sdk >= 31)
            addAll(
                listOf(
                    Manifest.permission.BLUETOOTH_ADVERTISE,
                    Manifest.permission.BLUETOOTH_CONNECT,
                    Manifest.permission.BLUETOOTH_SCAN,
                ),
            )
        if (sdk <= 32) add(Manifest.permission.ACCESS_COARSE_LOCATION)
        if (sdk in 29..32) add(Manifest.permission.ACCESS_FINE_LOCATION)
        if (sdk >= 33) add(Manifest.permission.NEARBY_WIFI_DEVICES)
    }

    fun compatibility(sdk: Int, code: Int?): List<String> =
        if (sdk < 33) emptyList()
        else
            when (code) {
                8034 -> listOf(Manifest.permission.ACCESS_COARSE_LOCATION)
                8036 ->
                    listOf(
                        Manifest.permission.ACCESS_COARSE_LOCATION,
                        Manifest.permission.ACCESS_FINE_LOCATION,
                    )
                else -> emptyList()
            }

    fun forRequest(sdk: Int, missing: List<String>): List<String> {
        val fine = Manifest.permission.ACCESS_FINE_LOCATION
        val coarse = Manifest.permission.ACCESS_COARSE_LOCATION
        // Android 12+ expects both in the same request, even if coarse was already granted.
        return if (sdk >= 31 && fine in missing && coarse !in missing) missing + coarse else missing
    }
}
