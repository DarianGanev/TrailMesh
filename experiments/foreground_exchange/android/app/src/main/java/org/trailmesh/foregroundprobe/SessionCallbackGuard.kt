package org.trailmesh.foregroundprobe

internal object SessionCallbackGuard {
    fun isCurrent(active: Boolean, currentGeneration: Long, callbackGeneration: Long): Boolean =
        active && currentGeneration == callbackGeneration
}
