package org.trailmesh.app.maps

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.valhalla.valhalla.Valhalla
import java.io.File
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.maplibre.android.MapLibre

@RunWith(AndroidJUnit4::class)
class NativeMapCompatibilityTest {
    @Test
    fun exactPinsLoadAndRouteMissingGraphFailsOnDevice() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        InstrumentationRegistry.getInstrumentation().runOnMainSync { MapLibre.getInstance(context) }
        val raw =
            Valhalla::class
                .java
                .getResourceAsStream("/com/valhalla/valhalla/default.json")!!
                .bufferedReader()
                .use { it.readText() }
        val config = JSONObject(raw)
        config.getJSONObject("mjolnir").apply {
            put("tile_extract", File(context.cacheDir, "absent.tar").absolutePath)
            remove("tile_url")
            put("tile_dir", "")
        }
        val file =
            File(context.cacheDir, "native-compatibility.json").apply {
                writeText(config.toString())
            }
        Valhalla(file.absolutePath).use { engine ->
            try {
                engine.routeRaw(
                    """{"locations":[{"lat":42.18,"lon":23.58},{"lat":42.2,"lon":23.6}],"costing":"pedestrian"}"""
                )
                fail("missing graph routed")
            } catch (expected: com.valhalla.valhalla.ValhallaException.Internal) {
                assertNotNull(expected.message)
            }
        }
        file.delete()
    }
}
