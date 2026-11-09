package org.trailmesh.app.persistence

import android.os.Bundle
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import com.google.crypto.tink.subtle.Ed25519Sign
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.Callable
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.trailmesh.app.protocol.*

/** Explicit opt-in API26 emulator evidence, never part of the ordinary test run. */
class ExchangePerformanceInstrumentedTest {
    @Test
    fun nearCapacityVerifiedQueriesAndConcurrentIngest() = runBlocking {
        if (InstrumentationRegistry.getArguments().getString("mode") != "benchmark")
            return@runBlocking
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val name = "exchange-performance.sqlite"
        context.deleteDatabase(name)
        val repo = ReportRepository.open(context, name)
        val root =
            StrictJSON.parse(
                instrumentation.context.assets.open("report-v1-vectors.json").use {
                    it.readBytes()
                },
                1000000,
                16,
            )
        val vector = (root["cases"] as ReportJSON.ArrayValue).values.first()
        val fixture = StrictJSON.parse(Base64.getDecoder().decode(vector["wire_base64"]!!.text))
        val base = fixture["core"] as ReportJSON.ObjectValue
        val body = base["body"] as ReportJSON.ObjectValue
        val now = vector["now_ms"]!!.number!!
        val key = Ed25519Sign.KeyPair.newKeyPair()
        val signer = Ed25519Sign(key.privateKey)
        fun text(s: String) = ReportJSON.StringValue(s)
        fun signed(index: Int): VerifiedReport {
            val serial = ByteBuffer.allocate(16).putLong(0).putLong(index.toLong()).array()
            val p =
                ReportJSON.ObjectValue(
                    body.members +
                        mapOf(
                            "event_id" to text(ReportAdmission.encode(serial)),
                            "note" to text("\uD83C\uDFD4".repeat(500)),
                        )
                )
            val core =
                ReportJSON.ObjectValue(
                    base.members +
                        mapOf(
                            "author_key" to text(ReportAdmission.encode(key.publicKey)),
                            "nonce" to text(ReportAdmission.encode(serial)),
                            "body" to p,
                        )
                )
            val bytes = core.canonicalBytes()
            val id =
                MessageDigest.getInstance("SHA-256")
                    .digest("TrailMesh/id/v1\n".toByteArray() + bytes)
                    .joinToString("") { "%02x".format(it.toInt() and 255) }
            val envelope =
                ReportJSON.ObjectValue(
                    mapOf(
                        "core" to core,
                        "bundle_id" to text(id),
                        "signature" to
                            text(
                                ReportAdmission.encode(
                                    signer.sign("TrailMesh/core/v1\n".toByteArray() + bytes)
                                )
                            ),
                    )
                )
            return requireNotNull(ReportAdmission.validate(envelope.canonicalBytes(), now).verified)
        }
        var count = 0
        var logicalBytes = 0L
        val seedStarted = SystemClock.elapsedRealtimeNanos()
        withContext(Dispatchers.IO) {
            repo.database.runInTransaction(
                Callable {
                    while (true) {
                        val v = signed(count + 1)
                        val charge = v.originalWire.size + v.canonicalCore.size + v.signature.size
                        if (logicalBytes + charge > 25L * 1024 * 1024 - 65536) break
                        val p = v.report
                        repo.database
                            .records()
                            .insert(
                                BundleRow(
                                    v.bundleID,
                                    v.canonicalCore,
                                    v.signature,
                                    v.originalWire,
                                    v.authorKey,
                                    v.createdAt,
                                    v.expiresAt,
                                    now,
                                    1,
                                )
                            )
                        repo.database
                            .records()
                            .insert(
                                ProjectionRow(
                                    v.bundleID,
                                    p.eventID,
                                    p.category,
                                    p.status,
                                    p.observedAt,
                                    p.latE7,
                                    p.lonE7,
                                    p.accuracyM,
                                    p.note.toByteArray(),
                                    p.supersedes,
                                )
                            )
                        repo.database
                            .records()
                            .insert(RelayRow(v.bundleID, v.expiresAt, v.maxHops, 1))
                        repo.database
                            .records()
                            .insert(SeenRow(v.bundleID, v.expiresAt + 86400000, "stored"))
                        logicalBytes += charge
                        count++
                    }
                    repo.database.openHelper.writableDatabase.execSQL(
                        "UPDATE repository_clock SET last_now_ms=? WHERE singleton=1",
                        arrayOf<Any?>(now),
                    )
                }
            )
        }
        assertTrue(logicalBytes > 24L * 1024 * 1024)
        fun ms(start: Long) = (SystemClock.elapsedRealtimeNanos() - start) / 1000000.0
        val seedMs = ms(seedStarted)
        var t = SystemClock.elapsedRealtimeNanos()
        assertEquals(count, repo.reports(now).size)
        val mapMs = ms(t)
        t = SystemClock.elapsedRealtimeNanos()
        assertEquals(count, repo.reports(now, includeExpired = true).size)
        val historyMs = ms(t)
        t = SystemClock.elapsedRealtimeNanos()
        assertEquals(count, repo.forwardable(now).size)
        val forwardingMs = ms(t)
        t = SystemClock.elapsedRealtimeNanos()
        assertEquals(8, repo.inventoryPage(null, 8, now).reports.size)
        val pageMs = ms(t)
        val extra = withContext(Dispatchers.Default) { signed(count + 1).originalWire }
        val query =
            async(Dispatchers.Default) {
                val start = SystemClock.elapsedRealtimeNanos()
                repo.reports(now, includeExpired = true)
                ms(start)
            }
        delay(20)
        t = SystemClock.elapsedRealtimeNanos()
        assertTrue(repo.ingest(extra, now) is StoreOutcome.Stored)
        val concurrentIngestMs = ms(t)
        val concurrentQueryMs = query.await()
        val output =
            "{\"rows\":$count,\"logical_bytes\":$logicalBytes,\"seed_ms\":$seedMs,\"map_ms\":$mapMs,\"history_ms\":$historyMs,\"forwarding_ms\":$forwardingMs,\"bounded_page_ms\":$pageMs,\"concurrent_history_ms\":$concurrentQueryMs,\"concurrent_ingest_ms\":$concurrentIngestMs,\"sdk\":${android.os.Build.VERSION.SDK_INT},\"timing\":\"elapsedRealtimeNanos\"}"
        instrumentation.sendStatus(
            0,
            Bundle().apply { putString("stream", "\nTrailMeshBenchmark $output\n") },
        )
        android.util.Log.i("TrailMeshBenchmark", output)
        repo.close()
        context.deleteDatabase(name)
    }
}
