package org.trailmesh.app.maps

import java.io.ByteArrayInputStream
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.GZIPInputStream

/** Native PMTiles readers can honor an archive metadata tiles override: reject it before load. */
object PMTilesArchive {
    fun validate(file: File) {
        try {
            RandomAccessFile(file, "r").use { input ->
                need(input.length() >= 127)
                val header = ByteArray(127)
                input.readFully(header)
                need(
                    header.copyOfRange(0, 7).contentEquals("PMTiles".toByteArray()) &&
                        header[7].toInt() == 3
                )
                val h = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
                val offset = h.getLong(24)
                val length = h.getLong(32)
                need(offset >= 127 && length in 1..1024 * 1024 && offset <= input.length() - length)
                need(header[97].toInt() in 1..2 && header[98].toInt() in 1..2)
                input.seek(offset)
                val compressed = ByteArray(length.toInt())
                input.readFully(compressed)
                val metadata =
                    if (header[97].toInt() == 1) compressed
                    else
                        GZIPInputStream(ByteArrayInputStream(compressed)).use { stream ->
                            val out = java.io.ByteArrayOutputStream()
                            val buffer = ByteArray(16384)
                            while (true) {
                                val n = stream.read(buffer)
                                if (n < 0) break
                                need(out.size() + n <= 1024 * 1024)
                                out.write(buffer, 0, n)
                            }
                            out.toByteArray()
                        }
                val o = MapJson.parse(metadata, 1024 * 1024).obj()
                need(!o.containsKey("tiles"))
                // Attribution links are inert text. The native reader uses only tiles to override
                // fetches.
                fun inspect(value: Any?) {
                    when (value) {
                        is Map<*, *> ->
                            value.forEach { (key, v) ->
                                need(key != "tiles")
                                inspect(v)
                            }
                        is List<*> -> value.forEach { inspect(it) }
                    }
                }
                inspect(o)
            }
        } catch (e: MapFailure) {
            throw e
        } catch (_: Exception) {
            throw MapFailure(MapError.CORRUPT)
        }
    }
}
