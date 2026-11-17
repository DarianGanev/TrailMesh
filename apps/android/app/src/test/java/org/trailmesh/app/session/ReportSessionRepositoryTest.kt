package org.trailmesh.app.session

import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class ReportSessionRepositoryTest : ReportSessionRepositoryContract() {
    override fun resource(name: String) =
        javaClass.classLoader!!.getResourceAsStream(name)!!.readBytes()
}
