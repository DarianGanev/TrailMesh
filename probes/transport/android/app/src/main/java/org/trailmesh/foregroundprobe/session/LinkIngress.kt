package org.trailmesh.foregroundprobe

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Bounds SDK callbacks waiting for the serialized owner, including transfer-progress callbacks. */
internal class LinkIngress {
    private val pending = AtomicInteger()
    private val overloaded = AtomicBoolean()
    private val reported = AtomicBoolean()

    fun acquire(): Boolean {
        if (overloaded.get()) return false
        if (pending.incrementAndGet() <= 64) return true
        pending.decrementAndGet()
        overloaded.set(true)
        return false
    }
    fun release() { pending.decrementAndGet() }
    fun claimOverflowNotice(): Boolean = overloaded.get() && reported.compareAndSet(false, true)
}
