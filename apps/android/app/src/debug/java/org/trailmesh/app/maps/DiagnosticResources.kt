package org.trailmesh.app.maps

import java.io.Closeable
import java.util.concurrent.Executors
import java.util.concurrent.Future

/** Debug work has one owner; teardown runs after the active task and skips queued/new tasks. */
class DiagnosticWorker(private val cleanup: () -> Unit) {
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "trailmesh-map-diagnostics")
    }
    @Volatile private var closed = false
    private var closing: Future<*>? = null

    @Synchronized
    fun execute(task: () -> Unit): Boolean {
        if (closed) return false
        worker.execute { if (!closed) task() }
        return true
    }

    @Synchronized
    fun closeAsync(): Future<*> {
        closing?.let {
            return it
        }
        closed = true
        val result = worker.submit { cleanup() }
        closing = result
        worker.shutdown()
        return result
    }
}

/** Each callback owns one operation; an older completion cannot release a newer map's lease. */
class SnapshotOperation private constructor(private val lease: Closeable) : Closeable {
    private var closed = false
    private var cancel: (() -> Unit)? = null

    @Synchronized
    fun attachCancel(cancel: () -> Unit) {
        if (closed) cancel() else this.cancel = cancel
    }

    @Synchronized
    override fun close() {
        if (closed) return
        closed = true
        val action = cancel
        cancel = null
        try {
            action?.invoke()
        } finally {
            lease.close()
        }
    }

    companion object {
        fun <T> prepare(lease: Closeable, load: () -> T): PreparedSnapshot<T> {
            val operation = SnapshotOperation(lease)
            return try {
                PreparedSnapshot(operation, load())
            } catch (error: Throwable) {
                operation.close()
                throw error
            }
        }
    }
}

data class PreparedSnapshot<T>(val operation: SnapshotOperation, val value: T)
