package org.trailmesh.foregroundprobe

import java.io.File
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.ByteArrayOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption

internal class SessionJournal(private val file: File) {
    fun save(checkpoint: SessionCheckpoint) {
        SessionLedger.validate(checkpoint)
        val pending = File(file.parentFile, file.name + ".pending")
        val bytes = ByteArrayOutputStream()
        DataOutputStream(bytes).use { data ->
            data.writeInt(0x544d4a32)
            data.writeInt(2)
            data.writeUTF(checkpoint.sessionID)
            data.writeInt(checkpoint.payloadSize)
            data.writeBoolean(checkpoint.open)
            data.writeInt(checkpoint.peers.size)
            for (peer in checkpoint.peers) {
                data.writeUTF(peer.sessionID)
                data.writeUTF(peer.platform)
                data.writeInt(peer.nextOutgoing)
                data.writeInt(peer.successfulOutgoing)
                data.writeInt(peer.failedOutgoing)
                data.writeInt(peer.transmissions)
                data.writeInt(peer.recoveries)
                peer.incoming.forEach(data::writeByte)
                data.writeInt(peer.remoteSuccesses ?: -1)
                data.writeInt(peer.remoteFailures ?: -1)
                data.writeBoolean(peer.complete)
                data.writeBoolean(peer.exhausted)
                data.writeLong(peer.completedAt)
                data.writeInt(peer.completionRequests)
                data.writeBoolean(peer.completionReconciled)
            }
            data.writeInt(checkpoint.events.size)
            for (event in checkpoint.events) {
                data.writeUTF(event.name)
                data.writeUTF(event.time)
                data.writeInt(event.fields.size)
                for ((key, value) in event.fields) { data.writeUTF(key); data.writeUTF(value) }
            }
            data.flush()
        }
        if (bytes.size() > MAX_JOURNAL_BYTES) throw IOException("checkpoint exceeds limit")
        FileOutputStream(pending).use { stream -> stream.write(bytes.toByteArray()); stream.fd.sync() }
        // Internal app storage supports rename; never remove the previous checkpoint first.
        Files.move(pending.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    fun load(): SessionCheckpoint? {
        if (!file.exists()) return null
        if (file.length() > MAX_JOURNAL_BYTES) throw IOException("checkpoint exceeds limit")
        try {
            return DataInputStream(BufferedInputStream(FileInputStream(file))).use { data ->
                require(data.readInt() == 0x544d4a32 && data.readInt() == 2)
                val id = data.readUTF()
                val size = data.readInt()
                val open = data.readBoolean()
                val peerCount = data.readInt().also { require(it in 0..SessionLedger.MAX_PEERS) }
                val peers = List(peerCount) {
                    PeerJournal(
                        data.readUTF(), data.readUTF(), data.readInt(), data.readInt(), data.readInt(),
                        data.readInt(), data.readInt(), List(20) { data.readUnsignedByte() },
                        data.readInt().let { if (it == -1) null else it },
                        data.readInt().let { if (it == -1) null else it }, data.readBoolean(), data.readBoolean(),
                        data.readLong(), data.readInt(), data.readBoolean(),
                    )
                }
                val count = data.readInt().also { require(it in 0..SessionLedger.MAX_EVENTS) }
                val events = List(count) {
                    val name = data.readUTF()
                    val time = data.readUTF()
                    val fields = data.readInt().also { require(it in 0..12) }
                    ProbeEvent(name, time, buildMap { repeat(fields) { put(data.readUTF(), data.readUTF()) } })
                }
                require(data.read() == -1)
                SessionCheckpoint(id, size, open, peers, events).also(SessionLedger::validate)
            }
        } catch (exception: IllegalArgumentException) {
            throw IOException("invalid checkpoint", exception)
        }
    }

    companion object { const val MAX_JOURNAL_BYTES = 256 * 1024 }
}
