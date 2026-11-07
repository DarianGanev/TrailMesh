package org.trailmesh.app.persistence

import androidx.test.platform.app.InstrumentationRegistry
import com.google.crypto.tink.subtle.Ed25519Verify
import java.io.File
import java.util.Base64
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.trailmesh.app.protocol.*
import org.trailmesh.app.security.*

/** CI invokes verify in a second instrumentation process after force-stopping the app. */
class ProcessRestartInstrumentedTest {
    @Test
    fun reportAndDuplicateAccountingSurviveProcessRestart() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val root =
            StrictJSON.parse(
                instrumentation.context.assets.open("report-v1-vectors.json").use {
                    it.readBytes()
                },
                1_000_000,
                16,
            )
        val vector = (root["cases"] as ReportJSON.ArrayValue).values.first()
        val wire = Base64.getDecoder().decode(vector["wire_base64"]!!.text)
        val now = vector["now_ms"]!!.number!!
        val filename = "process-restart.sqlite"
        val marker = File(context.filesDir, "process-restart.pid")
        val publicKey = File(context.filesDir, "process-restart.public-key")
        val identityStore = ProtectedSigningIdentityStore(context)
        if (InstrumentationRegistry.getArguments().getString("phase") == "verify") {
            assertNotEquals(marker.readText().toInt(), android.os.Process.myPid())
            val repo = ReportRepository.open(context, filename)
            assertTrue(repo.ingest(wire, now + 1) is StoreOutcome.Duplicate)
            val reports = repo.forwardable(now + 1)
            assertEquals(2, reports.size)
            assertArrayEquals(
                wire,
                reports
                    .first { it.bundleID == vector["expected"]!!["bundle_id"]!!.text }
                    .originalWire,
            )
            val signer = identityStore.loadExisting()
            assertArrayEquals(publicKey.readBytes(), signer.publicKey)
            val message = "process restart verification".toByteArray()
            Ed25519Verify(signer.publicKey).verify(signer.sign(message), message)
            repo.close()
        } else {
            context.deleteDatabase(filename)
            val repo = ReportRepository.open(context, filename)
            assertTrue(repo.ingest(wire, now) is StoreOutcome.Stored)
            val signer =
                try {
                    identityStore.loadExisting()
                } catch (error: IdentityException) {
                    if (error.reason != IdentityFailure.MISSING_IDENTITY) throw error
                    identityStore.createNew()
                }
            assertTrue(
                repo.author(
                    ReportDraft(
                        "note",
                        "observed",
                        now,
                        0,
                        0,
                        1,
                        "Public process-restart fixture",
                        now + 3_600_000,
                    ),
                    signer,
                    now,
                ) is StoreOutcome.Stored,
            )
            publicKey.writeBytes(signer.publicKey)
            repo.close()
            marker.writeText(android.os.Process.myPid().toString())
        }
    }
}
