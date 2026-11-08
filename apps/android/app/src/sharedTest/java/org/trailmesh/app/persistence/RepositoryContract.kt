package org.trailmesh.app.persistence

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.google.crypto.tink.subtle.Ed25519Sign
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.trailmesh.app.protocol.*
import org.trailmesh.app.security.ReportSigner

abstract class RepositoryContract {
    protected abstract fun resource(name: String): ByteArray

    @Test
    fun invalidDraftsAreRejectedBeforeSigningWithoutUncheckedCanonicalizationErrors() =
        runBlocking {
            val (_, now) = fixture()
            val repo = ReportRepository.open(context, name())
            val key = signer()
            var signs = 0
            val spy =
                object : ReportSigner {
                    override val publicKey
                        get() = key.publicKey

                    override fun sign(message: ByteArray): ByteArray {
                        signs++
                        return key.sign(message)
                    }
                }
            val good = draft(now)
            val bad =
                listOf(
                    good.copy(status = "flowing", category = "note"),
                    good.copy(observedAt = now + 1),
                    good.copy(observedAt = Long.MAX_VALUE),
                    good.copy(expiresAt = now + 259_200_001),
                    good.copy(expiresAt = now),
                    good.copy(maxHops = 13),
                    good.copy(latE7 = 900_000_001),
                    good.copy(lonE7 = 1_800_000_001),
                    good.copy(accuracyM = -1),
                    good.copy(note = "x".repeat(501)),
                    good.copy(note = "\ud800"),
                    good.copy(note = "\udc00"),
                )
            for (draft in bad) {
                assertEquals(StoreOutcome.Rejected("invalid"), repo.author(draft, spy, now))
                assertEquals(0, signs)
            }
            assertEquals(0, count(repo, "bundles"))
            repo.close()
        }

    @Test
    fun cancellationWhileQueuedBehindAnotherTransactionPreventsAdmission() = runBlocking {
        val (wire, now) = fixture()
        val repo = ReportRepository.open(context, name())
        val root = StrictJSON.parse(resource("report-v1-vectors.json"), 1_000_000, 16)
        val other =
            (root["cases"] as ReportJSON.ArrayValue).values.first {
                it["name"]!!.text == "unicode-and-boundaries"
            }
        val second = Base64.getDecoder().decode(other["wire_base64"]!!.text)
        val entered = CompletableDeferred<Unit>()
        val waiting = CompletableDeferred<Unit>()
        val release = java.util.concurrent.CountDownLatch(1)
        var calls = 0
        val first =
            async(Dispatchers.Default) {
                repo.ingest(wire) {
                    if (calls++ > 0) {
                        entered.complete(Unit)
                        check(release.await(10, java.util.concurrent.TimeUnit.SECONDS))
                    }
                    now
                }
            }
        entered.await()
        val queued =
            launch(Dispatchers.Default) {
                repo.ingest(second) {
                    waiting.complete(Unit)
                    now
                }
            }
        waiting.await()
        delay(200)
        try {
            withTimeout(2000) { queued.cancelAndJoin() }
        } finally {
            release.countDown()
        }
        assertTrue(first.await() is StoreOutcome.Stored)
        assertEquals(1, count(repo, "bundles"))
        repo.close()
    }

    @Test
    fun cancellationWhileWaitingForAnotherConnectionPreventsAdmission() = runBlocking {
        val (wire, now) = fixture()
        val file = name()
        val firstRepo = ReportRepository.open(context, file)
        val secondRepo = ReportRepository.open(context, file)
        val root = StrictJSON.parse(resource("report-v1-vectors.json"), 1_000_000, 16)
        val other =
            (root["cases"] as ReportJSON.ArrayValue).values.first {
                it["name"]!!.text == "unicode-and-boundaries"
            }
        val second = Base64.getDecoder().decode(other["wire_base64"]!!.text)
        val entered = CompletableDeferred<Unit>()
        val waiting = CompletableDeferred<Unit>()
        val release = java.util.concurrent.CountDownLatch(1)
        var calls = 0
        val first =
            async(Dispatchers.Default) {
                firstRepo.ingest(wire) {
                    if (calls++ > 0) {
                        entered.complete(Unit)
                        check(release.await(10, java.util.concurrent.TimeUnit.SECONDS))
                    }
                    now
                }
            }
        entered.await()
        val queued =
            launch(Dispatchers.Default) {
                secondRepo.ingest(second) {
                    waiting.complete(Unit)
                    now
                }
            }
        waiting.await()
        delay(200)
        queued.cancel()
        release.countDown()
        withTimeout(5000) { queued.join() }
        assertTrue(first.await() is StoreOutcome.Stored)
        assertEquals(1, count(firstRepo, "bundles"))
        firstRepo.close()
        secondRepo.close()
    }

    @Test
    fun missingPayloadIsNeverAcknowledgedAsDuplicate() = runBlocking {
        val (wire, now) = fixture()
        val repo = ReportRepository.open(context, name())
        val id = ReportAdmission.validate(wire, now).verified!!.bundleID
        sql(repo, "INSERT INTO seen_ids VALUES(?,?,'stored')", id, now + 1000)
        try {
            repo.ingest(wire, now)
            fail("Missing payload must not acknowledge duplicate")
        } catch (e: ReportStoreException) {
            assertEquals(StoreFailure.SEEN_WITHOUT_PAYLOAD, e.reason)
        }
        assertEquals(0, count(repo, "bundles"))
        repo.close()
    }

    @Test
    fun commitFailureCannotReturnStoredOrRetainPartialRows() = runBlocking {
        val (wire, now) = fixture()
        val repo = ReportRepository.open(context, name())
        sql(
            repo,
            "CREATE TRIGGER fail_commit AFTER INSERT ON seen_ids BEGIN INSERT INTO relay_state VALUES('missing-parent',1,1,0); END",
        )
        var calls = 0
        try {
            repo.ingest(wire) {
                if (calls++ > 0)
                    repo.database.openHelper.writableDatabase.execSQL(
                        "PRAGMA defer_foreign_keys=ON"
                    )
                now
            }
            fail("Deferred FK must fail at commit")
        } catch (_: android.database.SQLException) {}
        for (table in listOf("bundles", "reports", "relay_state", "seen_ids")) assertEquals(
            0,
            count(repo, table),
        )
        sql(repo, "DROP TRIGGER fail_commit")
        assertTrue(repo.ingest(wire, now) is StoreOutcome.Stored)
        repo.close()
    }

    @Test
    fun clockCorrectionDuringAuthoringCannotAdmitNewReport() = runBlocking {
        val (_, now) = fixture()
        val repo = ReportRepository.open(context, name())
        var calls = 0
        try {
            repo.author(draft(now), signer()) { if (calls++ == 0) now else now - 1 }
            fail("Author clock rollback")
        } catch (e: ReportStoreException) {
            assertEquals(StoreFailure.CLOCK, e.reason)
        }
        assertEquals(0, count(repo, "bundles"))
        repo.close()
    }

    private val context: Context
        get() = ApplicationProvider.getApplicationContext()

    private fun name() = "reports-${UUID.randomUUID()}.sqlite"

    private fun fixture(): Pair<ByteArray, Long> {
        val root = StrictJSON.parse(resource("report-v1-vectors.json"), 1_000_000, 16)
        val case = (root["cases"] as ReportJSON.ArrayValue).values.first()
        return Base64.getDecoder().decode(case["wire_base64"]!!.text) to case["now_ms"]!!.number!!
    }

    private fun signer(): ReportSigner {
        val seed = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
        val public = Ed25519Sign.KeyPair.newKeyPairFromSeed(seed).publicKey
        return object : ReportSigner {
            override val publicKey
                get() = public.copyOf()

            override fun sign(message: ByteArray) = Ed25519Sign(seed).sign(message)
        }
    }

    private fun draft(now: Long, note: String = "test") =
        ReportDraft("water", "dry", now, 0, 0, 1, note, now + 7_200_000, 1)

    @Test
    fun committedReportSurvivesReopenAndDuplicatePreservesFirstWire() = runBlocking {
        val (wire, now) = fixture()
        val file = name()
        var repo = ReportRepository.open(context, file)
        val saved = repo.ingest(wire, now) as StoreOutcome.Stored
        repo.close()
        repo = ReportRepository.open(context, file)
        assertEquals(StoreOutcome.Duplicate(saved.id), repo.ingest(wire, now))
        assertArrayEquals(wire, repo.forwardable(now).single().originalWire)
        assertEquals("No flow observed at the spring.", repo.reports(now).single().note)
        repo.close()
    }

    @Test
    fun concurrentConnectionsAdmitOnlyOneCopy() = runBlocking {
        val (wire, now) = fixture()
        val file = name()
        val a = ReportRepository.open(context, file)
        val b = ReportRepository.open(context, file)
        val results =
            awaitAll(
                async(Dispatchers.Default) { a.ingest(wire, now) },
                async(Dispatchers.Default) { b.ingest(wire, now) },
            )
        assertEquals(1, results.count { it is StoreOutcome.Stored })
        assertEquals(1, results.count { it is StoreOutcome.Duplicate })
        a.close()
        b.close()
    }

    @Test
    fun expiryIsInclusiveHistoryExplicitAndBoundsFilter() = runBlocking {
        val (wire, now) = fixture()
        val repo = ReportRepository.open(context, name())
        repo.ingest(wire, now)
        val expires = ReportAdmission.validate(wire, now).verified!!.expiresAt
        assertTrue(repo.reports(now, ReportBounds(0, 1, 0, 1)).isEmpty())
        assertTrue(repo.forwardable(expires).isEmpty())
        assertTrue(repo.reports(expires).isEmpty())
        assertTrue(repo.reports(expires, includeExpired = true).single().isExpired)
        assertEquals(StoreOutcome.Rejected("expired"), repo.ingest(wire, expires))
        repo.close()
    }

    @Test
    fun backwardClockNeedsExplicitQuarantineAndReopenPreservesIt() = runBlocking {
        val (wire, now) = fixture()
        val file = name()
        var repo = ReportRepository.open(context, file)
        repo.ingest(wire, now)
        try {
            repo.forwardable(now - 1)
            fail("Clock error expected")
        } catch (e: ReportStoreException) {
            assertEquals(StoreFailure.CLOCK, e.reason)
        }
        assertEquals(1, repo.recoverClockAfterUserConfirmation(now - 1))
        repo.close()
        repo = ReportRepository.open(context, file)
        assertTrue(repo.forwardable(now).isEmpty())
        assertTrue(repo.reports(now).isEmpty())
        assertTrue(repo.reports(now, includeExpired = true).single().isQuarantined)
        assertEquals(StoreOutcome.Rejected("expired"), repo.ingest(wire, now))
        repo.close()
    }

    @Test
    fun authoringPersistsNulAndEmptyNotesAndDoesNotExposeMutableBytes() = runBlocking {
        val (_, now) = fixture()
        val repo = ReportRepository.open(context, name())
        val key = signer()
        for (note in listOf("a\u0000b", "")) assertTrue(
            repo.author(draft(now, note), key, now) is StoreOutcome.Stored
        )
        assertEquals(setOf("a\u0000b", ""), repo.reports(now).map { it.note }.toSet())
        val wires = repo.forwardable(now)
        wires.first().originalWire.fill(0)
        assertEquals(2, repo.forwardable(now).size)
        repo.close()
    }

    @Test
    fun remoteRateLimitPersistsAndQuarantineDoesNotResetIt() = runBlocking {
        val (_, now) = fixture()
        val source = ReportRepository.open(context, name())
        val key = signer()
        repeat(22) { source.author(draft(now), key, now) }
        val wires = source.forwardable(now).map { it.originalWire }
        val file = name()
        var dest = ReportRepository.open(context, file)
        wires.take(20).forEach { assertTrue(dest.ingest(it, now) is StoreOutcome.Stored) }
        assertTrue(dest.ingest(wires[0], now) is StoreOutcome.Duplicate)
        dest.close()
        dest = ReportRepository.open(context, file)
        assertEquals(StoreOutcome.Rejected("quota"), dest.ingest(wires[20], now))
        dest.recoverClockAfterUserConfirmation(now - 1)
        assertEquals(StoreOutcome.Rejected("quota"), dest.ingest(wires[20], now - 1))
        assertTrue(dest.ingest(wires[20], now + 3_599_999) is StoreOutcome.Stored)
        source.close()
        dest.close()
    }

    @Test
    fun expiryIsRecheckedInsideTransaction() = runBlocking {
        val (wire, now) = fixture()
        val repo = ReportRepository.open(context, name())
        val expiry = ReportAdmission.validate(wire, now).verified!!.expiresAt
        var calls = 0
        assertEquals(
            StoreOutcome.Rejected("expired"),
            repo.ingest(wire) { if (calls++ == 0) now else expiry },
        )
        assertTrue(repo.reports(expiry, includeExpired = true).isEmpty())
        repo.close()
    }

    @Test
    fun futureClockDoesNotDeleteReportsBeforeCorrection() = runBlocking {
        val (wire, now) = fixture()
        val repo = ReportRepository.open(context, name())
        repo.ingest(wire, now)
        repo.forwardable(now + 8 * 86_400_000)
        assertEquals(1, repo.recoverClockAfterUserConfirmation(now))
        assertEquals(1, repo.reports(now, includeExpired = true).size)
        repo.close()
    }

    @Test
    fun cancelledBeforeAdmissionCannotStoreAnything() = runBlocking {
        val (wire, now) = fixture()
        val repo = ReportRepository.open(context, name())
        val job = launch(start = CoroutineStart.LAZY) { repo.ingest(wire, now) }
        job.cancel()
        job.join()
        assertTrue(repo.reports(now, includeExpired = true).isEmpty())
        repo.close()
    }

    private suspend fun sql(repo: ReportRepository, statement: String, vararg args: Any) =
        withContext(Dispatchers.IO) {
            repo.database.openHelper.writableDatabase.execSQL(statement, args)
        }

    private suspend fun count(repo: ReportRepository, table: String): Long =
        withContext(Dispatchers.IO) {
            repo.database.openHelper.writableDatabase.query("SELECT COUNT(*) FROM $table").use {
                it.moveToFirst()
                it.getLong(0)
            }
        }

    @Test
    fun projectionInsertFailureRollsBackAllTablesAndCanRetry() = runBlocking {
        val (wire, now) = fixture()
        val repo = ReportRepository.open(context, name())
        sql(
            repo,
            "CREATE TRIGGER fail_projection BEFORE INSERT ON reports BEGIN SELECT RAISE(ABORT,'test'); END",
        )
        try {
            repo.ingest(wire, now)
            fail("Expected SQLite failure")
        } catch (_: android.database.SQLException) {}
        for (table in listOf("bundles", "reports", "relay_state", "seen_ids")) assertEquals(
            0,
            count(repo, table),
        )
        sql(repo, "DROP TRIGGER fail_projection")
        assertTrue(repo.ingest(wire, now) is StoreOutcome.Stored)
        repo.close()
    }

    @Test
    fun authorFailureHasNoPartialOutboxAndCommitReturnsStoredAfterCancellation() = runBlocking {
        val (_, now) = fixture()
        val repo = ReportRepository.open(context, name())
        val key = signer()
        val failing =
            object : ReportSigner {
                override val publicKey
                    get() = key.publicKey

                override fun sign(message: ByteArray): ByteArray =
                    throw java.security.GeneralSecurityException("test")
            }
        try {
            repo.author(draft(now), failing, now)
            fail("Expected signing failure")
        } catch (_: java.security.GeneralSecurityException) {}
        assertEquals(0, count(repo, "bundles"))
        assertEquals(0, count(repo, "relay_state"))
        assertTrue(repo.author(draft(now), key, now) is StoreOutcome.Stored)
        val wire = repo.forwardable(now).single().originalWire
        val target = ReportRepository.open(context, name())
        val job = Job()
        var outcome: StoreOutcome? = null
        var calls = 0
        try {
            withContext(job) {
                outcome =
                    target.ingest(wire) {
                        if (calls++ > 0) job.cancel()
                        now
                    }
            }
        } catch (_: CancellationException) {}
        assertTrue(outcome is StoreOutcome.Stored)
        assertEquals(1, count(target, "bundles"))
        repo.close()
        target.close()
    }

    @Test
    fun corruptWireProjectionAndSqlTypeNeverProduceDuplicateOrForwarding() = runBlocking {
        val (wire, now) = fixture()
        for (change in
            listOf(
                "UPDATE bundles SET original_wire=x'00'",
                "UPDATE reports SET status='flowing'",
                "UPDATE bundles SET original_wire='text'",
                "UPDATE relay_state SET max_hops=2",
            )) {
            val repo = ReportRepository.open(context, name())
            repo.ingest(wire, now)
            sql(repo, change)
            try {
                repo.ingest(wire, now)
                fail("Corrupt duplicate")
            } catch (e: ReportStoreException) {
                assertEquals(StoreFailure.CORRUPT_STORED_REPORT, e.reason)
            }
            try {
                repo.forwardable(now)
                fail("Corrupt forwarding")
            } catch (e: ReportStoreException) {
                assertEquals(StoreFailure.CORRUPT_STORED_REPORT, e.reason)
            }
            try {
                repo.reports(now)
                fail("Corrupt projection")
            } catch (e: ReportStoreException) {
                assertEquals(StoreFailure.CORRUPT_STORED_REPORT, e.reason)
            }
            repo.close()
        }
    }

    @Test
    fun seenIdsRemainBoundedUntilConfirmedCleanup() = runBlocking {
        val (wire, now) = fixture()
        val repo = ReportRepository.open(context, name())
        sql(
            repo,
            "WITH RECURSIVE n(i) AS(SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<10000) INSERT INTO seen_ids SELECT printf('%064x',i),?,'test' FROM n",
            now + 1000,
        )
        assertEquals(StoreOutcome.Rejected("quota"), repo.ingest(wire, now))
        assertEquals(10000, count(repo, "seen_ids"))
        assertEquals(StoreOutcome.Rejected("quota"), repo.ingest(wire, now + 1000))
        repo.reclaimExpiredReportsAfterUserConfirmation(now + 1000)
        assertTrue(repo.ingest(wire, now + 1000) is StoreOutcome.Stored)
        assertEquals(1, count(repo, "seen_ids"))
        repo.close()
    }

    @Test
    fun remoteCapacityReservesFiveMebibytesForLocalAuthoring() = runBlocking {
        val (wire, now) = fixture()
        val repo = ReportRepository.open(context, name())
        sql(
            repo,
            "INSERT INTO bundles VALUES('quota-fixture',zeroblob(1),zeroblob(64),zeroblob(20971455),zeroblob(32),?,?,?,0)",
            now - 1,
            now + 7_200_000,
            now,
        )
        assertEquals(StoreOutcome.Rejected("quota"), repo.ingest(wire, now))
        assertTrue(repo.author(draft(now), signer(), now) is StoreOutcome.Stored)
        sql(
            repo,
            "UPDATE bundles SET original_wire=zeroblob(26214400) WHERE bundle_id='quota-fixture'",
        )
        assertEquals(StoreOutcome.Rejected("quota"), repo.author(draft(now), signer(), now))
        repo.close()
    }

    @Test
    fun confirmedCleanupKeepsReplayMarkersAndRecentRemoteRateWindows() = runBlocking {
        val (_, now) = fixture()
        val source = ReportRepository.open(context, name())
        source.author(draft(now), signer(), now)
        val wire = source.forwardable(now).single().originalWire
        val destination = ReportRepository.open(context, name())
        destination.ingest(wire, now)
        val expires = ReportAdmission.validate(wire, now).verified!!.expiresAt
        assertEquals(1, destination.reclaimExpiredReportsAfterUserConfirmation(expires))
        assertEquals(0, count(destination, "bundles"))
        assertEquals(1, count(destination, "seen_ids"))
        assertEquals(0, count(destination, "reports"))
        assertEquals(0, count(destination, "relay_state"))
        destination.reclaimExpiredReportsAfterUserConfirmation(expires + 86_400_000)
        assertEquals(0, count(destination, "seen_ids"))
        source.close()
        destination.close()
    }

    @Test
    fun cleanupValidatesSignedExpiryBeforeDeletingAnything() = runBlocking {
        val (wire, now) = fixture()
        val repo = ReportRepository.open(context, name())
        repo.ingest(wire, now)
        sql(repo, "UPDATE bundles SET expires_at_ms=?,is_local=1", now + 1)
        sql(repo, "UPDATE relay_state SET local_expiry_ms=?", now + 1)
        try {
            repo.reclaimExpiredReportsAfterUserConfirmation(now + 1)
            fail("Corrupt expiry")
        } catch (e: ReportStoreException) {
            assertEquals(StoreFailure.CORRUPT_STORED_REPORT, e.reason)
        }
        assertEquals(1, count(repo, "bundles"))
        assertEquals(1, count(repo, "seen_ids"))
        repo.close()
    }

    @Test
    fun validAlternateEncodingPreservesOriginalAndMapCanCrossAntimeridian() = runBlocking {
        val (wire, now) = fixture()
        val repo = ReportRepository.open(context, name())
        repo.ingest(wire, now)
        val canonical = ReportAdmission.validate(wire, now).verified!!.canonicalEnvelope
        assertTrue(repo.ingest(canonical, now) is StoreOutcome.Duplicate)
        assertArrayEquals(wire, repo.forwardable(now).single().originalWire)
        val root = StrictJSON.parse(resource("report-v1-vectors.json"), 1_000_000, 16)
        val vector =
            (root["cases"] as ReportJSON.ArrayValue).values.first {
                it["name"]?.text == "unicode-and-boundaries"
            }
        repo.ingest(Base64.getDecoder().decode(vector["wire_base64"]!!.text), now)
        assertEquals(
            1,
            repo
                .reports(
                    now,
                    ReportBounds(-900_000_000, -890_000_000, 1_700_000_000, -1_700_000_000),
                )
                .size,
        )
        repo.close()
    }

    @Test
    fun sqliteFullDoesNotReturnStoredAndTransactionCanBeRetried() = runBlocking {
        val (_, now) = fixture()
        val repo = ReportRepository.open(context, name())
        withContext(Dispatchers.IO) {
            val db = repo.database.openHelper.writableDatabase
            repo.database.runInTransaction {
                val pages =
                    db.query("PRAGMA page_count").use {
                        it.moveToFirst()
                        it.getLong(0)
                    }
                db.query("PRAGMA max_page_count=$pages").use {
                    it.moveToFirst()
                    assertEquals(pages, it.getLong(0))
                }
            }
        }
        val key = signer()
        val report = draft(now, "\ud83c\udfd4".repeat(500))
        var accepted = 0
        var full = false
        for (attempt in 0 until 50) {
            try {
                assertTrue(repo.author(report, key, now) is StoreOutcome.Stored)
                accepted++
            } catch (error: android.database.sqlite.SQLiteException) {
                // SQLite can auto-roll back SQLITE_FULL before Android's transaction wrapper rolls
                // back again.
                if (
                    error !is android.database.sqlite.SQLiteFullException &&
                        error.message?.contains("no transaction is active") != true
                )
                    throw error
                full = true
                break
            }
        }
        assertTrue("Expected real SQLITE_FULL", full)
        for (table in listOf("bundles", "reports", "relay_state", "seen_ids")) assertEquals(
            accepted.toLong(),
            count(repo, table),
        )
        withContext(Dispatchers.IO) {
            repo.database.runInTransaction {
                repo.database.openHelper.writableDatabase
                    .query("PRAGMA max_page_count=1073741823")
                    .use { it.moveToFirst() }
            }
        }
        assertTrue(repo.author(report, key, now) is StoreOutcome.Stored)
        repo.close()
    }

    @Test
    fun transferredHopBudgetSurvivesRestartAndNeverIncreases() = runBlocking {
        val (wire, now) = fixture()
        val file = name()
        var repo = ReportRepository.open(context, file)
        assertTrue(repo.ingestTransferred(wire, 1) { now } is StoreOutcome.Stored)
        assertEquals(1, repo.inventoryPage(null, 8, now).reports.single().hops)
        assertTrue(repo.ingestTransferred(wire, 8) { now } is StoreOutcome.Duplicate)
        assertEquals(1, repo.inventoryPage(null, 8, now).reports.single().hops)
        repo.ingestTransferred(wire, 0) { now }
        repo.close()
        repo = ReportRepository.open(context, file)
        assertTrue(repo.inventoryPage(null, 8, now).reports.isEmpty())
        assertTrue(repo.forwardable(now).isEmpty())
        assertEquals(1, repo.reports(now).size)
        repo.close()
    }

    @Test
    fun inventoryAdvancesPastFilteredCandidatesAndValidatesHopMetadata() = runBlocking {
        val (_, now) = fixture()
        val repo = ReportRepository.open(context, name())
        repeat(10) { repo.author(draft(now), signer(), now) }
        sql(repo, "INSERT INTO report_forwarding SELECT bundle_id,0 FROM bundles")
        val page = repo.inventoryPage(null, 8, now)
        assertTrue(page.reports.isEmpty())
        assertTrue(page.hasMore)
        assertNotNull(page.nextCursor)
        assertFalse(repo.inventoryPage(page.nextCursor, 8, now).hasMore)
        sql(repo, "DROP TRIGGER report_forwarding_check_update")
        sql(repo, "UPDATE report_forwarding SET remaining_hops='bad'")
        try {
            repo.inventoryPage(null, 8, now)
            fail("corrupt hop metadata")
        } catch (e: ReportStoreException) {
            assertEquals(StoreFailure.CORRUPT_STORED_REPORT, e.reason)
        }
        repo.close()
    }

    @Test
    fun inventoryRotationSurvivesRestartAndReachesBeyondFirst64() = runBlocking {
        val (_, now) = fixture()
        val file = name()
        var repo = ReportRepository.open(context, file)
        val key = signer()
        repeat(70) { repo.author(draft(now), key, now) }
        val adapter = org.trailmesh.app.exchange.RepositoryExchangeStore(repo)
        var cursor = adapter.initialCursor(now)
        val first = mutableSetOf<String>()
        repeat(8) {
            val page = adapter.inventoryPage(cursor, 8, now)
            first.addAll(page.reports.map { it.id })
            cursor = page.nextCursor
        }
        assertEquals(64, first.size)
        repo.close()
        repo = ReportRepository.open(context, file)
        val next = org.trailmesh.app.exchange.RepositoryExchangeStore(repo)
        assertEquals(cursor, next.initialCursor(now))
        val page = next.inventoryPage(next.initialCursor(now), 8, now)
        assertEquals(6, page.reports.size)
        assertTrue(page.reports.none { it.id in first })
        assertNull(next.initialCursor(now))
        repo.close()
    }

    private suspend fun legacy(version: Int): String =
        withContext(Dispatchers.IO) {
            val file = name()
            val schema =
                org.json
                    .JSONObject(
                        String(
                            resource("org.trailmesh.app.persistence.ReportDatabase/$version.json"),
                            Charsets.UTF_8,
                        )
                    )
                    .getJSONObject("database")
            val db = context.openOrCreateDatabase(file, 0, null)
            try {
                val entities = schema.getJSONArray("entities")
                for (i in 0 until entities.length()) {
                    val entity = entities.getJSONObject(i)
                    val table = entity.getString("tableName")
                    db.execSQL(entity.getString("createSql").replace("\u0024{TABLE_NAME}", table))
                    val indexes = entity.optJSONArray("indices")
                    if (indexes != null)
                        for (j in 0 until indexes.length()) db.execSQL(
                            indexes
                                .getJSONObject(j)
                                .getString("createSql")
                                .replace("\u0024{TABLE_NAME}", table)
                        )
                }
                val setup = schema.getJSONArray("setupQueries")
                for (i in 0 until setup.length()) db.execSQL(setup.getString(i))
                val (wire, now) = fixture()
                val v = ReportAdmission.validate(wire, now).verified!!
                val p = v.report
                db.execSQL(
                    "INSERT INTO bundles VALUES(?,?,?,?,?,?,?,?,?)",
                    arrayOf<Any?>(
                        v.bundleID,
                        v.canonicalCore,
                        v.signature,
                        wire,
                        v.authorKey,
                        v.createdAt,
                        v.expiresAt,
                        now,
                        0,
                    ),
                )
                db.execSQL(
                    "INSERT INTO reports VALUES(?,?,?,?,?,?,?,?,?,?)",
                    arrayOf<Any?>(
                        v.bundleID,
                        p.eventID,
                        p.category,
                        p.status,
                        p.observedAt,
                        p.latE7,
                        p.lonE7,
                        p.accuracyM,
                        p.note.toByteArray(),
                        p.supersedes,
                    ),
                )
                db.execSQL(
                    "INSERT INTO relay_state VALUES(?,?,?,0)",
                    arrayOf<Any?>(v.bundleID, v.expiresAt, v.maxHops),
                )
                db.execSQL(
                    "INSERT INTO seen_ids VALUES(?,?,'stored')",
                    arrayOf<Any?>(v.bundleID, v.expiresAt + 86_400_000),
                )
                if (version >= 2)
                    db.execSQL("INSERT INTO repository_clock VALUES(1,?)", arrayOf<Any?>(now))
                db.version = version
            } finally {
                db.close()
            }
            file
        }

    @Test
    fun bothPreReleaseSchemasMigrateWithoutChangingSignedBlobsOrProjection() = runBlocking {
        val (wire, now) = fixture()
        val verified = ReportAdmission.validate(wire, now).verified!!
        for (version in listOf(1, 2, 3)) {
            val file = legacy(version)
            val repo = ReportRepository.open(context, file)
            assertEquals(StoreOutcome.Duplicate(verified.bundleID), repo.ingest(wire, now))
            assertArrayEquals(wire, repo.forwardable(now).single().originalWire)
            assertEquals(verified.report.note, repo.reports(now).single().note)
            withContext(Dispatchers.IO) {
                val db = repo.database.openHelper.writableDatabase
                db.query("SELECT canonical_core,signature,author_key FROM bundles").use {
                    it.moveToFirst()
                    assertArrayEquals(verified.canonicalCore, it.getBlob(0))
                    assertArrayEquals(verified.signature, it.getBlob(1))
                    assertArrayEquals(verified.authorKey, it.getBlob(2))
                }
                db.query("SELECT name FROM sqlite_master WHERE type='index'").use { c ->
                    val names = buildSet { while (c.moveToNext()) add(c.getString(0)) }
                    assertTrue(
                        names.containsAll(
                            listOf(
                                "bundles_expiry",
                                "bundles_author_admission",
                                "reports_event",
                                "reports_location",
                                "relay_expiry",
                                "seen_retention",
                            )
                        )
                    )
                }
            }
            assertEquals(1, count(repo, "seen_ids"))
            assertEquals(1, count(repo, "relay_state"))
            repo.close()
        }
    }

    @Test
    fun failedMigrationRollsBackAndCanBeRetriedWithoutDataLoss() = runBlocking {
        val file = legacy(1)
        withContext(Dispatchers.IO) {
            val faulty =
                androidx.room.Room.databaseBuilder(context, ReportDatabase::class.java, file)
                    .addMigrations(
                        object : androidx.room.migration.Migration(1, 2) {
                            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                                ReportDatabase.MIGRATION_1_2.migrate(db)
                                throw android.database.SQLException("injected migration failure")
                            }
                        },
                        ReportDatabase.MIGRATION_2_3,
                        ReportDatabase.MIGRATION_3_4,
                    )
                    .build()
            try {
                faulty.openHelper.writableDatabase
                fail("Expected migration failure")
            } catch (_: android.database.SQLException) {} finally {
                faulty.close()
            }
            context.openOrCreateDatabase(file, 0, null).use { db ->
                assertEquals(1, db.version)
                db.rawQuery("SELECT COUNT(*) FROM bundles", null).use {
                    it.moveToFirst()
                    assertEquals(1, it.getInt(0))
                }
            }
        }
        val repo = ReportRepository.open(context, file)
        assertEquals(1, repo.forwardable(fixture().second).size)
        repo.close()
    }

    @Test
    fun unknownNewerSchemaFailsWithoutDestructiveDowngrade() = runBlocking {
        val file = name()
        val (wire, now) = fixture()
        val repo = ReportRepository.open(context, file)
        repo.ingest(wire, now)
        repo.close()
        withContext(Dispatchers.IO) {
            context.openOrCreateDatabase(file, 0, null).use { it.version = 5 }
        }
        try {
            ReportRepository.open(context, file)
            fail("Unsupported schema must fail")
        } catch (_: IllegalStateException) {}
        withContext(Dispatchers.IO) {
            context.openOrCreateDatabase(file, 0, null).use { db ->
                assertEquals(5, db.version)
                db.rawQuery("SELECT original_wire FROM bundles", null).use {
                    it.moveToFirst()
                    assertArrayEquals(wire, it.getBlob(0))
                }
            }
        }
    }

    @Test
    fun databaseRejectsMalformedSignatureAndImpossibleRelayState() = runBlocking {
        val (wire, now) = fixture()
        val repo = ReportRepository.open(context, name())
        repo.ingest(wire, now)
        for (statement in
            listOf(
                "UPDATE bundles SET signature=zeroblob(1)",
                "UPDATE bundles SET author_key=zeroblob(1)",
                "UPDATE relay_state SET max_hops=13",
                "UPDATE repository_clock SET singleton=2",
            )) {
            try {
                sql(repo, statement)
                fail("Database constraint missing")
            } catch (_: android.database.SQLException) {}
        }
        assertTrue(repo.ingest(wire, now) is StoreOutcome.Duplicate)
        repo.close()
    }
}
