package org.trailmesh.app.maps

import java.io.Closeable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class MapDiagnosticsLifecycleTest {
    @Test
    fun `destroy skips queued work and closes resources created by inflight work on owner worker`() {
        val entered = CountDownLatch(1)
        val resume = CountDownLatch(1)
        val done = CountDownLatch(1)
        val closed = AtomicInteger()
        val queued = AtomicInteger()
        var owned: Closeable? = null
        var workerName: String? = null
        var closeName: String? = null
        val worker = DiagnosticWorker { owned?.close() }
        worker.execute {
            workerName = Thread.currentThread().name
            entered.countDown()
            assertTrue(resume.await(5, TimeUnit.SECONDS))
            owned = Closeable {
                closed.incrementAndGet()
                closeName = Thread.currentThread().name
            }
            done.countDown()
        }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        worker.execute { queued.incrementAndGet() }
        val closing = worker.closeAsync()
        assertFalse(worker.execute { queued.incrementAndGet() })
        resume.countDown()
        assertTrue(done.await(5, TimeUnit.SECONDS))
        closing.get(5, TimeUnit.SECONDS)
        assertEquals(1, closed.get())
        assertEquals(0, queued.get())
        assertEquals(workerName, closeName)
    }

    @Test
    fun `stale snapshot callback releases only its own lease once`() {
        val olderClosed = AtomicInteger()
        val newerClosed = AtomicInteger()
        val cancelled = AtomicInteger()
        val old =
            SnapshotOperation.prepare(Closeable { olderClosed.incrementAndGet() }) { "old" }
                .operation
        old.attachCancel { cancelled.incrementAndGet() }
        val newer =
            SnapshotOperation.prepare(Closeable { newerClosed.incrementAndGet() }) { "new" }
                .operation
        old.close()
        old.close()
        assertEquals(1, olderClosed.get())
        assertEquals(0, newerClosed.get())
        assertEquals(1, cancelled.get())
        newer.close()
        assertEquals(1, newerClosed.get())
    }

    @Test
    fun `failed style preparation releases acquired lease`() {
        val released = AtomicInteger()
        try {
            SnapshotOperation.prepare(Closeable { released.incrementAndGet() }) {
                throw MapFailure(MapError.CORRUPT)
            }
            fail("style unexpectedly loaded")
        } catch (_: MapFailure) {}
        assertEquals(1, released.get())
    }
}
