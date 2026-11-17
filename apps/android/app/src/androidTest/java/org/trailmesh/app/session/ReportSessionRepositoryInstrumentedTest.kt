package org.trailmesh.app.session

import androidx.test.platform.app.InstrumentationRegistry

class ReportSessionRepositoryInstrumentedTest : ReportSessionRepositoryContract() {
    override fun resource(name: String) =
        InstrumentationRegistry.getInstrumentation().context.assets.open(name).use {
            it.readBytes()
        }
}
