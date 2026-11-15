package org.trailmesh.app.relevance

import androidx.test.platform.app.InstrumentationRegistry

class RelevanceVectorsInstrumentedTest : RelevanceVectorContract() {
    override fun resource(name: String) = InstrumentationRegistry.getInstrumentation().context.assets.open(name).use { it.readBytes() }
}
