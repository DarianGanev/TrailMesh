package org.trailmesh.app.persistence

import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.Base64
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.trailmesh.app.protocol.*

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
        if (InstrumentationRegistry.getArguments().getString("phase") == "verify") {
            assertNotEquals(marker.readText().toInt(), android.os.Process.myPid())
            val repo = ReportRepository.open(context, filename)
            assertTrue(repo.ingest(wire, now + 1) is StoreOutcome.Duplicate)
            assertArrayEquals(wire, repo.forwardable(now + 1).single().originalWire)
            repo.close()
        } else {
            context.deleteDatabase(filename)
            val repo = ReportRepository.open(context, filename)
            assertTrue(repo.ingest(wire, now) is StoreOutcome.Stored)
            repo.close()
            marker.writeText(android.os.Process.myPid().toString())
        }
    }
}
