package org.trailmesh.app.persistence

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ReportRepositoryInstrumentedTest : RepositoryContract() {
    override fun resource(name: String) =
        InstrumentationRegistry.getInstrumentation().context.assets.open(name).use {
            it.readBytes()
        }
}
