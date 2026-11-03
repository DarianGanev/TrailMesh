package org.trailmesh.foregroundprobe

import java.io.File
import org.junit.Assert.*
import org.junit.Test
import org.junit.Assume.assumeFalse

class SessionJournalTest {
    @Test fun diagnosticLossCounterRoundTripsAndOlderV2JournalStillLoads() {
        val folder = java.nio.file.Files.createTempDirectory("trailmesh-journal").toFile()
        try {
            val file = File(folder, "session.bin")
            val journal = SessionJournal(file) {}
            val current = SessionCheckpoint("0".repeat(32), 2048, evictedRecords = 809)
            journal.save(current)
            assertEquals(current, journal.load())
            val bytes = file.readBytes()
            file.writeBytes(bytes.copyOf(bytes.size - 8))
            assertEquals(current.copy(evictedRecords = 0), journal.load())
        } finally { folder.deleteRecursively() }
    }

    @Test fun checkpointRoundTripsUnacknowledgedProgressAndUniqueReceipts() {
        val folder = java.nio.file.Files.createTempDirectory("trailmesh-journal").toFile()
        try {
            val journal = SessionJournal(File(folder, "session.bin")) {}
            val ledger = SessionLedger(SessionCheckpoint("0".repeat(32), 2048), journal::save)
            ledger.selectPeer("1".repeat(32), "ios")
            ledger.beginTransmission("1".repeat(32))
            ledger.receive("1".repeat(32), 4, true)
            ledger.record(ProbeEvent("received", "2026-09-30T00:00:00Z", mapOf("index" to "4")))
            assertEquals(ledger.checkpoint, SessionJournal(File(folder, "session.bin")).load())
        } finally { folder.deleteRecursively() }
    }

    @Test fun missingFileIsNotAResumableSessionAndCorruptionIsRejected() {
        val folder = java.nio.file.Files.createTempDirectory("trailmesh-journal").toFile()
        try {
            val file = File(folder, "session.bin")
            val journal = SessionJournal(file) {}
            assertNull(journal.load())
            file.writeBytes(byteArrayOf(1, 2, 3))
            assertThrows(java.io.IOException::class.java) { journal.load() }
        } finally { folder.deleteRecursively() }
    }

    @Test fun failedReplacementLeavesLastCommittedCheckpointReadable() {
        val folder = java.nio.file.Files.createTempDirectory("trailmesh-journal").toFile()
        try {
            val file = File(folder, "session.bin")
            var syncs = 0
            val journal = SessionJournal(file) { syncs++ }
            val initial = SessionCheckpoint("0".repeat(32), 256)
            journal.save(initial)
            assertEquals(1, syncs)
            File(folder, "session.bin.pending").mkdir()
            assertThrows(java.io.IOException::class.java) { journal.save(initial.copy(open = false)) }
            assertEquals(1, syncs)
            assertEquals(initial, journal.load())
        } finally { folder.deleteRecursively() }
    }

    @Test fun directorySyncObservesTheReplacedCheckpointBeforeSaveReturns() {
        val folder = java.nio.file.Files.createTempDirectory("trailmesh-journal").toFile()
        try {
            val file = File(folder, "session.bin")
            val expected = SessionCheckpoint("0".repeat(32), 2048)
            var synced = false
            val journal = SessionJournal(file) { directory ->
                assertEquals(folder, directory)
                assertEquals(expected, SessionJournal(file).load())
                assertFalse(File(folder, "session.bin.pending").exists())
                synced = true
            }
            journal.save(expected)
            assertTrue(synced)
        } finally { folder.deleteRecursively() }
    }

    @Test fun directorySyncFailureCannotAcceptReceivedBytes() {
        val folder = java.nio.file.Files.createTempDirectory("trailmesh-journal").toFile()
        try {
            var failing = false
            val journal = SessionJournal(File(folder, "session.bin")) {
                if (failing) throw java.io.IOException("directory sync failed")
            }
            val ledger = SessionLedger(SessionCheckpoint("0".repeat(32), 2048), journal::save)
            val peer = "1".repeat(32)
            ledger.selectPeer(peer, "ios")
            failing = true
            assertThrows(java.io.IOException::class.java) { ledger.receive(peer, 0, true) }
            assertEquals(0, ledger.peer(peer)!!.receivedAccepted)
        } finally { folder.deleteRecursively() }
    }

    @Test fun defaultDirectorySyncRoundTripsOnSupportedFileSystem() {
        // Windows cannot open directory FileChannels; exercise the real path on Linux CI.
        // Other tests inject directory syncing to test ordering/failure and serialization on any host.
        assumeFalse(System.getProperty("os.name").orEmpty().startsWith("Windows"))
        val folder = java.nio.file.Files.createTempDirectory("trailmesh-journal").toFile()
        try {
            val journal = SessionJournal(File(folder, "session.bin"))
            val checkpoint = SessionCheckpoint("0".repeat(32), 2048)
            journal.save(checkpoint)
            assertEquals(checkpoint, journal.load())
        } finally { folder.deleteRecursively() }
    }
}
