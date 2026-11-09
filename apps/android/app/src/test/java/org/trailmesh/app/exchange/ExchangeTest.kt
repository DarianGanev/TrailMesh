package org.trailmesh.app.exchange

import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class ExchangeTest : ExchangeContract() {
    override fun exportFrames(frames: List<ByteArray>) {
        val target = java.io.File("build/interop/android-exchange-frames.json")
        target.parentFile!!.mkdirs()
        target.writeText(
            frames.joinToString(prefix = "[", postfix = "]") {
                "{\"wire_hex\":\"${ExchangeWire.hex(it)}\"}"
            }
        )
    }

    override fun resource(name: String) =
        javaClass.classLoader!!.getResourceAsStream(name)!!.readBytes()
}
