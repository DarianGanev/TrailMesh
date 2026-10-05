package org.trailmesh.foregroundprobe

import java.io.File
import org.junit.Assert.*
import org.junit.Test

class SessionJournalTest {
    @Test fun checkpointRoundTripsUnacknowledgedProgressAndUniqueReceipts() {
        val folder = java.nio.file.Files.createTempDirectory("trailmesh-journal").toFile()
        try {
            val journal = SessionJournal(File(folder, "session.bin"))
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
            val journal = SessionJournal(file)
            assertNull(journal.load())
            file.writeBytes(byteArrayOf(1, 2, 3))
            assertThrows(java.io.IOException::class.java) { journal.load() }
        } finally { folder.deleteRecursively() }
    }

    @Test fun failedReplacementLeavesLastCommittedCheckpointReadable() {
        val folder = java.nio.file.Files.createTempDirectory("trailmesh-journal").toFile()
        try {
            val file = File(folder, "session.bin")
            val journal = SessionJournal(file)
            val initial = SessionCheckpoint("0".repeat(32), 256)
            journal.save(initial)
            File(folder, "session.bin.pending").mkdir()
            assertThrows(java.io.IOException::class.java) { journal.save(initial.copy(open = false)) }
            assertEquals(initial, journal.load())
        } finally { folder.deleteRecursively() }
    }
}
