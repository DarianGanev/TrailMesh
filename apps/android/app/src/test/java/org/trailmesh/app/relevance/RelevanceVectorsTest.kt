package org.trailmesh.app.relevance

import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class RelevanceVectorsTest : RelevanceVectorContract() {
    override fun resource(name: String) = javaClass.classLoader!!.getResourceAsStream(name)!!.readBytes()
}
