package org.trailmesh.app.maps

import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.ConcurrentHashMap

class InstallCancellation {
    private var cancelled = false

    @Synchronized
    fun cancel() {
        cancelled = true
    }

    @Synchronized
    fun check() {
        if (cancelled) throw MapFailure(MapError.CANCELLED)
    }

    @Synchronized
    internal fun publish(block: () -> Unit) {
        check()
        block()
    }
}

interface AssetTransport {
    fun open(url: String, offset: Long): AssetResponse
}

class AssetResponse(
    val status: Int,
    val contentRange: String?,
    val body: InputStream,
    private val finish: () -> Unit = {},
) : Closeable {
    override fun close() {
        try {
            body.close()
        } finally {
            finish()
        }
    }
}

/** Redirects must remain HTTPS; no credentials or arbitrary URLs from pack metadata. */
class HttpsAssetTransport : AssetTransport {
    override fun open(url: String, offset: Long): AssetResponse {
        var current = URL(url)
        repeat(6) {
            need(current.protocol == "https" && current.userInfo == null, MapError.UNAVAILABLE)
            val c = current.openConnection() as HttpURLConnection
            c.connectTimeout = 15000
            c.readTimeout = 30000
            c.instanceFollowRedirects = false
            c.setRequestProperty("Accept-Encoding", "identity")
            if (offset > 0) c.setRequestProperty("Range", "bytes=$offset-")
            try {
                val status = c.responseCode
                if (status in listOf(301, 302, 303, 307, 308)) {
                    val next =
                        c.getHeaderField("Location") ?: throw MapFailure(MapError.UNAVAILABLE)
                    current = URL(current, next)
                    c.disconnect()
                } else {
                    need(status == 200 || status == 206, MapError.UNAVAILABLE)
                    need(
                        c.contentEncoding == null || c.contentEncoding == "identity",
                        MapError.CORRUPT,
                    )
                    return AssetResponse(status, c.getHeaderField("Content-Range"), c.inputStream) {
                        c.disconnect()
                    }
                }
            } catch (e: Exception) {
                c.disconnect()
                throw e
            }
        }
        throw MapFailure(MapError.UNAVAILABLE)
    }
}

data class InstalledRegion(val manifest: RegionManifest, val directory: File) {
    fun places() = PlaceIndex.parse(File(directory, "places.json").readBytes(), manifest.bounds)

    fun style() =
        ClosedStyle.resolve(File(directory, "style.json").readBytes(), manifest, directory)
}

class RegionLease
internal constructor(val region: InstalledRegion, private val release: () -> Unit) : Closeable {
    private var closed = false

    @Synchronized
    override fun close() {
        if (!closed) {
            closed = true
            release()
        }
    }
}

/**
 * Synchronous I/O core: callers use a worker. SDK consumers must hold a lease until native close.
 */
class RegionStore(val root: File, private val freeBytes: () -> Long = { root.usableSpace }) {
    private class State {
        val leases = mutableMapOf<String, Int>()
    }

    companion object {
        private val states = ConcurrentHashMap<String, State>()
    }

    private val state: State

    init {
        need(!Files.isSymbolicLink(root.toPath()))
        root.mkdirs()
        need(root.isDirectory)
        state = states.computeIfAbsent(root.canonicalPath) { State() }
        synchronized(state) { recoverTrash() }
    }

    private fun deleteTree(directory: File) {
        safe(directory)
        // Files.walk does not follow symbolic links. Delete a child link, never its target.
        Files.walk(directory.toPath()).use { paths ->
            paths.sorted(Comparator.reverseOrder()).forEach { Files.delete(it) }
        }
    }

    private fun recoverTrash() {
        root
            .listFiles()
            .orEmpty()
            .filter { it.name.startsWith(".trash-") }
            .forEach { deleteTree(it) }
    }

    private fun key(i: String, r: String): String {
        need(listOf(i, r).all { it.matches(Regex("[a-z0-9]+(?:-[a-z0-9]+)*")) && it.length <= 64 })
        return "$i--$r"
    }

    private fun safe(file: File): File {
        val base = root.absoluteFile.normalize().toPath()
        val target = file.absoluteFile.normalize().toPath()
        need(target.startsWith(base))
        var walk = target
        while (walk.startsWith(base)) {
            need(!Files.isSymbolicLink(walk))
            if (walk == base) break
            walk = walk.parent
        }
        return file
    }

    private fun write(file: File, bytes: ByteArray) {
        safe(file)
        file.parentFile!!.mkdirs()
        FileOutputStream(file).use {
            it.write(bytes)
            it.fd.sync()
        }
    }

    private fun verified(dir: File): InstalledRegion {
        safe(dir)
        need(dir.isDirectory)
        val manifestFile = safe(File(dir, "manifest.json"))
        need(manifestFile.length() in 1..262144)
        val hashFile = safe(File(dir, "manifest.sha256"))
        need(hashFile.length() == 64L)
        val m = RegionManifest.parse(manifestFile.readBytes(), hashFile.readText())
        need(dir.name == key(m.id, m.revision))
        verifyFiles(dir, m)
        return InstalledRegion(m, dir)
    }

    private fun verifyFiles(dir: File, m: RegionManifest) {
        for (f in m.files) {
            val file = safe(File(dir, f.path))
            need(file.isFile && file.length() == f.bytes && sha256(file) == f.sha256)
        }
        for (f in m.files.filter { it.path.endsWith(".pmtiles") }) PMTilesArchive.validate(
            File(dir, f.path)
        )
        val style = File(dir, "style.json")
        need(style.length() <= MAX_STYLE_BYTES)
        ClosedStyle.resolve(style.readBytes(), m, dir)
        val places = File(dir, "places.json")
        need(places.length() <= MAX_PLACE_BYTES)
        PlaceIndex.parse(places.readBytes(), m.bounds)
        // Readers must never consume a symlink, including an unlisted path injected after staging.
        Files.walk(dir.toPath()).use { paths -> paths.forEach { need(!Files.isSymbolicLink(it)) } }
    }

    fun discover(): List<InstalledRegion> =
        synchronized(state) {
            root
                .listFiles()
                .orEmpty()
                .filter { it.isDirectory && !it.name.startsWith('.') }
                .mapNotNull {
                    try {
                        verified(it)
                    } catch (_: Exception) {
                        null
                    }
                }
                .sortedBy { it.manifest.id + "/" + it.manifest.revision }
        }

    fun acquire(i: String, r: String): RegionLease =
        synchronized(state) {
            val k = key(i, r)
            val directory = safe(File(root, k))
            need(directory.exists(), MapError.UNAVAILABLE)
            val region = verified(directory)
            state.leases[k] = (state.leases[k] ?: 0) + 1
            RegionLease(region) {
                synchronized(state) {
                    val n = (state.leases[k] ?: 1) - 1
                    if (n == 0) state.leases.remove(k) else state.leases[k] = n
                }
            }
        }

    fun remove(i: String, r: String) =
        synchronized(state) {
            val k = key(i, r)
            need((state.leases[k] ?: 0) == 0, MapError.BUSY)
            val dir = safe(File(root, k))
            if (dir.exists()) {
                val trash = safe(File(root, ".trash-$k"))
                if (trash.exists()) deleteTree(trash)
                Files.move(dir.toPath(), trash.toPath(), StandardCopyOption.ATOMIC_MOVE)
                deleteTree(trash)
            }
        }

    fun install(
        b: ByteArray,
        h: String,
        t: AssetTransport,
        u: String,
        c: InstallCancellation = InstallCancellation(),
    ): InstalledRegion =
        synchronized(state) {
            try {
                c.check()
                val m = RegionManifest.parse(b, h)
                val k = key(m.id, m.revision)
                val base = URI(u)
                need(
                    base.scheme == "https" &&
                        base.host != null &&
                        base.rawUserInfo == null &&
                        base.rawQuery == null &&
                        base.rawFragment == null &&
                        u.endsWith('/'),
                    MapError.UNAVAILABLE,
                )
                val destination = safe(File(root, k))
                if (destination.exists()) {
                    val existing = verified(destination)
                    need(File(destination, "manifest.sha256").readText() == h, MapError.CORRUPT)
                    return@synchronized existing
                }
                val stage = safe(File(root, ".stage-$k-$h"))
                stage.mkdirs()
                need(stage.isDirectory)
                val partialRoot = safe(File(stage, ".partials"))
                partialRoot.mkdirs()
                write(File(stage, "manifest.json"), b)
                write(File(stage, "manifest.sha256"), h.toByteArray())
                // Resume only this manifest's staging area. Finished files are always rehashed.
                var remaining = 0L
                for (f in m.files) {
                    val file = safe(File(stage, f.path))
                    if (file.exists() && (file.length() != f.bytes || sha256(file) != f.sha256))
                        need(file.delete())
                    if (!file.exists()) {
                        val p = safe(File(partialRoot, f.asset))
                        if (
                            p.length() > f.bytes || (p.length() == f.bytes && sha256(p) != f.sha256)
                        )
                            need(p.delete())
                        remaining += f.bytes - p.length()
                    }
                }
                need(freeBytes() >= remaining + 8 * 1024 * 1024, MapError.SPACE)
                for (f in m.files) {
                    c.check()
                    val file = safe(File(stage, f.path))
                    if (file.exists()) continue
                    file.parentFile!!.mkdirs()
                    val partial = safe(File(partialRoot, f.asset))
                    var offset = partial.length()
                    if (offset < f.bytes) {
                        val asset = URI(null, null, f.asset, null).rawPath
                        t.open(u + asset, offset).use { response ->
                            if (response.status == 200) {
                                offset = 0L
                            } else {
                                need(response.status == 206)
                                val range =
                                    response.contentRange?.let {
                                        Regex("bytes ([0-9]+)-([0-9]+)/([0-9]+)").matchEntire(it)
                                    }
                                need(range != null)
                                val values =
                                    range!!.groupValues.drop(1).map {
                                        it.toLongOrNull() ?: throw MapFailure(MapError.CORRUPT)
                                    }
                                need(
                                    values[0] == offset &&
                                        values[1] == f.bytes - 1 &&
                                        values[2] == f.bytes
                                )
                            }
                            FileOutputStream(partial, offset > 0).use { out ->
                                val buffer = ByteArray(65536)
                                var received = offset
                                while (true) {
                                    c.check()
                                    val n = response.body.read(buffer)
                                    if (n < 0) break
                                    need(n <= f.bytes - received)
                                    out.write(buffer, 0, n)
                                    received += n
                                }
                                out.fd.sync()
                                need(received == f.bytes, MapError.UNAVAILABLE)
                            }
                        }
                    }
                    c.check()
                    if (partial.length() != f.bytes || sha256(partial) != f.sha256) {
                        need(partial.delete())
                        throw MapFailure(MapError.CORRUPT)
                    }
                    Files.move(partial.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE)
                }
                c.check()
                verifyFiles(stage, m)
                need(partialRoot.deleteRecursively())
                c.publish {
                    Files.move(stage.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE)
                }
                InstalledRegion(m, destination)
            } catch (e: MapFailure) {
                throw e
            } catch (_: Exception) {
                c.check()
                throw MapFailure(MapError.UNAVAILABLE)
            }
        }
}
