package org.trailmesh.app.persistence

import android.content.Context
import android.database.Cursor
import androidx.sqlite.db.SupportSQLiteDatabase
import java.util.concurrent.Callable
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.trailmesh.app.protocol.*
import org.trailmesh.app.security.ReportSigner

sealed class StoreOutcome {
    data class Stored(val id: String) : StoreOutcome()

    data class Duplicate(val id: String) : StoreOutcome()

    data class Rejected(val reason: String) : StoreOutcome()
}

enum class StoreFailure {
    CLOCK,
    INVALID_BOUNDS,
    SEEN_WITHOUT_PAYLOAD,
    CORRUPT_STORED_REPORT,
}

class ReportStoreException(val reason: StoreFailure) : Exception("Report store: ${reason.name}")

data class ReportBounds(
    val south: Long = -900_000_000,
    val north: Long = 900_000_000,
    val west: Long = -1_800_000_000,
    val east: Long = 1_800_000_000,
)

data class ReportDraft(
    val category: String,
    val status: String,
    val observedAt: Long,
    val latE7: Long,
    val lonE7: Long,
    val accuracyM: Long,
    val note: String,
    val expiresAt: Long,
    val maxHops: Int = 12,
    val supersedes: String? = null,
)

class StoredReport(
    val bundleID: String,
    val note: String,
    val category: String,
    val status: String,
    val observedAt: Long,
    val admittedAt: Long,
    val expiresAt: Long,
    val latE7: Long,
    val lonE7: Long,
    val accuracyM: Long,
    val supersedes: String?,
    val isExpired: Boolean,
    val isQuarantined: Boolean,
    eventID: ByteArray,
    authorKey: ByteArray,
) {
    private val event = eventID.copyOf()
    private val author = authorKey.copyOf()
    val eventID
        get() = event.copyOf()

    val authorKey
        get() = author.copyOf()
}

class ForwardableReport(val bundleID: String, originalWire: ByteArray) {
    private val wire = originalWire.copyOf()
    val originalWire
        get() = wire.copyOf()
}

/**
 * Durable public reports; successful outcomes are returned only after the Room transaction commits.
 */
class ReportRepository
private constructor(
    internal var database: ReportDatabase,
    private val application: Context,
    private val name: String,
) {
    private val access = Mutex()

    companion object {
        /**
         * Opens and migrates off the main thread; unknown schemas never trigger destructive
         * fallback.
         */
        suspend fun open(context: Context, name: String): ReportRepository =
            withContext(Dispatchers.IO) {
                ReportRepository(
                    ReportDatabase.open(context, name),
                    context.applicationContext,
                    name,
                )
            }

        private const val COLUMNS =
            "b.*, r.event_id,r.category,r.status,r.observed_at_ms,r.lat_e7,r.lon_e7,r.accuracy_m,r.note,r.supersedes,s.local_expiry_ms,s.max_hops,f.remaining_hops,CASE WHEN q.bundle_id IS NULL THEN 0 ELSE 1 END AS quarantined"
        private const val JOIN =
            "FROM bundles b LEFT JOIN reports r ON r.bundle_id=b.bundle_id LEFT JOIN relay_state s ON s.bundle_id=b.bundle_id LEFT JOIN quarantined_ids q ON q.bundle_id=b.bundle_id LEFT JOIN report_forwarding f ON f.bundle_id=b.bundle_id"
    }

    private suspend fun <T> transaction(block: (SupportSQLiteDatabase) -> T): T {
        val caller = currentCoroutineContext()
        caller.ensureActive()
        // Once admitted to the transaction, cancellation must not discard a committed outcome.
        return access.withLock {
            currentCoroutineContext().ensureActive()
            withContext(NonCancellable) {
                withContext(Dispatchers.IO) {
                    try {
                        database.runInTransaction(
                            Callable {
                                // SQLite may have waited for another instance or process before
                                // acquiring its write lock. Admission starts only after this check.
                                caller.ensureActive()
                                block(database.openHelper.writableDatabase)
                            }
                        )
                    } catch (failure: android.database.sqlite.SQLiteException) {
                        // A failed COMMIT can leave Android's connection with an open SQL
                        // transaction
                        // after its wrapper has forgotten it. Closing the pool rolls it back. Never
                        // reuse that connection or convert this uncertain outcome into success.
                        try {
                            database.close()
                            database = ReportDatabase.open(application, name)
                        } catch (recovery: Exception) {
                            failure.addSuppressed(recovery)
                        }
                        throw failure
                    }
                }
            }
        }
    }

    private fun validClock(now: Long) {
        if (now !in 0..ReportJSON.SAFE_INTEGER) throw ReportStoreException(StoreFailure.CLOCK)
    }

    private fun scalar(db: SupportSQLiteDatabase, sql: String, vararg args: Any): Long =
        db.query(sql, args).use {
            if (!it.moveToFirst()) throw ReportStoreException(StoreFailure.CORRUPT_STORED_REPORT)
            it.getLong(0)
        }

    private fun observe(db: SupportSQLiteDatabase, now: Long) {
        validClock(now)
        val previous = scalar(db, "SELECT last_now_ms FROM repository_clock WHERE singleton=1")
        if (now < previous) throw ReportStoreException(StoreFailure.CLOCK)
        db.execSQL(
            "UPDATE repository_clock SET last_now_ms=? WHERE singleton=1",
            arrayOf<Any?>(now),
        )
    }

    /** Verifies a snapshot and transactionally applies duplicate, expiry and quota policy. */
    suspend fun ingest(wire: ByteArray, now: Long): StoreOutcome = ingest(wire) { now }

    /** Samples the clock for validation and again inside the protected write transaction. */
    suspend fun ingest(wire: ByteArray, clock: () -> Long): StoreOutcome {
        currentCoroutineContext().ensureActive()
        if (wire.size > 8192) {
            validClock(clock())
            return StoreOutcome.Rejected("invalid")
        }
        return store(wire.copyOf(), clock, false)
    }

    /** Incoming transfer budget is committed atomically with the immutable signed report. */
    suspend fun ingestTransferred(
        wire: ByteArray,
        hopsAfterReceipt: Int,
        clock: () -> Long,
    ): StoreOutcome {
        require(hopsAfterReceipt in 0..11)
        if (wire.size > 8192) {
            validClock(clock())
            return StoreOutcome.Rejected("invalid")
        }
        return store(wire.copyOf(), clock, false, hopsAfterReceipt = hopsAfterReceipt)
    }

    private suspend fun store(
        wire: ByteArray,
        clock: () -> Long,
        local: Boolean,
        minimumNow: Long = 0,
        hopsAfterReceipt: Int? = null,
    ): StoreOutcome {
        currentCoroutineContext().ensureActive()
        val validationNow = clock()
        validClock(validationNow)
        if (validationNow < minimumNow) throw ReportStoreException(StoreFailure.CLOCK)
        val result =
            withContext(Dispatchers.Default) { ReportAdmission.validate(wire, validationNow) }
        val report = result.verified
        if (report == null && result.outcome != "expired")
            return StoreOutcome.Rejected(result.outcome)
        return transaction { db ->
            val now = clock()
            validClock(now)
            if (now < validationNow) throw ReportStoreException(StoreFailure.CLOCK)
            observe(db, now)
            if (report == null || now >= report.expiresAt)
                return@transaction StoreOutcome.Rejected("expired")
            if (hopsAfterReceipt != null && report.maxHops <= hopsAfterReceipt)
                return@transaction StoreOutcome.Rejected("invalid")
            db.query("SELECT $COLUMNS $JOIN WHERE b.bundle_id=?", arrayOf<Any?>(report.bundleID))
                .use { cursor ->
                    if (cursor.moveToFirst()) {
                        val existing = verified(cursor, now)
                        if (
                            !existing.verified.canonicalCore.contentEquals(report.canonicalCore) ||
                                !existing.verified.signature.contentEquals(report.signature)
                        )
                            throw ReportStoreException(StoreFailure.CORRUPT_STORED_REPORT)
                        if (hopsAfterReceipt != null && !existing.report.isExpired) {
                            val remaining = minOf(existing.remainingHops, hopsAfterReceipt)
                            db.execSQL(
                                "INSERT OR REPLACE INTO report_forwarding VALUES(?,?)",
                                arrayOf<Any?>(report.bundleID, remaining),
                            )
                        }
                        return@transaction if (existing.report.isExpired)
                            StoreOutcome.Rejected("expired")
                        else StoreOutcome.Duplicate(report.bundleID)
                    }
                }
            if (
                scalar(
                    db,
                    "SELECT COUNT(*) FROM seen_ids WHERE bundle_id=? AND retain_until_ms>?",
                    report.bundleID,
                    now,
                ) > 0
            )
                throw ReportStoreException(StoreFailure.SEEN_WITHOUT_PAYLOAD)
            val charge = wire.size.toLong() + report.canonicalCore.size + report.signature.size
            val total =
                scalar(
                    db,
                    "SELECT COALESCE(SUM(length(original_wire)+length(canonical_core)+length(signature)),0) FROM bundles",
                )
            val remote =
                scalar(
                    db,
                    "SELECT COALESCE(SUM(length(original_wire)+length(canonical_core)+length(signature)),0) FROM bundles WHERE is_local=0",
                )
            val rate =
                scalar(
                    db,
                    "SELECT COUNT(*) $JOIN WHERE b.is_local=0 AND b.author_key=? AND ((q.bundle_id IS NULL AND b.admitted_at_ms>?) OR (q.bundle_id IS NOT NULL AND q.rate_hold_until_ms>?))",
                    report.authorKey,
                    now - 3_600_000,
                    now,
                )
            if (
                total + charge > 25 * 1024 * 1024 ||
                    scalar(db, "SELECT COUNT(*) FROM seen_ids") >= 10_000 ||
                    (!local && (remote + charge > 20 * 1024 * 1024 || rate >= 20))
            )
                return@transaction StoreOutcome.Rejected("quota")
            val p = report.report
            database
                .records()
                .insert(
                    BundleRow(
                        report.bundleID,
                        report.canonicalCore,
                        report.signature,
                        wire,
                        report.authorKey,
                        report.createdAt,
                        report.expiresAt,
                        now,
                        if (local) 1 else 0,
                    )
                )
            database
                .records()
                .insert(
                    ProjectionRow(
                        report.bundleID,
                        p.eventID,
                        p.category,
                        p.status,
                        p.observedAt,
                        p.latE7,
                        p.lonE7,
                        p.accuracyM,
                        p.note.toByteArray(Charsets.UTF_8),
                        p.supersedes,
                    )
                )
            database
                .records()
                .insert(
                    RelayRow(
                        report.bundleID,
                        minOf(report.expiresAt, now + 259_200_000),
                        report.maxHops,
                        if (local) 1 else 0,
                    )
                )
            database
                .records()
                .insert(SeenRow(report.bundleID, report.expiresAt + 86_400_000, "stored"))
            if (hopsAfterReceipt != null)
                db.execSQL(
                    "INSERT INTO report_forwarding VALUES(?,?)",
                    arrayOf<Any?>(report.bundleID, hopsAfterReceipt),
                )
            StoreOutcome.Stored(report.bundleID)
        }
    }

    /**
     * Rejects invalid drafts before signing and commits the report and initial outbox state
     * together.
     */
    suspend fun author(draft: ReportDraft, signer: ReportSigner, now: Long): StoreOutcome =
        author(draft, signer) { now }

    /** Preserves signing/storage failures and detects clock corrections during authoring. */
    suspend fun author(draft: ReportDraft, signer: ReportSigner, clock: () -> Long): StoreOutcome {
        currentCoroutineContext().ensureActive()
        val created = clock()
        validClock(created)
        val wire =
            withContext(Dispatchers.IO) {
                fun text(value: String) = ReportJSON.StringValue(value)
                fun number(value: Long) = ReportJSON.IntegerValue(value)
                fun random() =
                    ReportAdmission.encode(
                        ByteArray(16).also { java.security.SecureRandom().nextBytes(it) }
                    )
                val body =
                    ReportJSON.ObjectValue(
                        mapOf(
                            "event_id" to text(random()),
                            "category" to text(draft.category),
                            "status" to text(draft.status),
                            "observed_at_ms" to number(draft.observedAt),
                            "lat_e7" to number(draft.latE7),
                            "lon_e7" to number(draft.lonE7),
                            "accuracy_m" to number(draft.accuracyM),
                            "note" to text(draft.note),
                            "supersedes" to
                                (draft.supersedes?.let { text(it) } ?: ReportJSON.NullValue),
                        )
                    )
                val core =
                    ReportJSON.ObjectValue(
                        mapOf(
                            "protocol" to text("trailmesh"),
                            "version" to number(1),
                            "kind" to text("report"),
                            "author_key" to text(ReportAdmission.encode(signer.publicKey)),
                            "nonce" to text(random()),
                            "created_at_ms" to number(created),
                            "expires_at_ms" to number(draft.expiresAt),
                            "max_hops" to number(draft.maxHops.toLong()),
                            "body" to body,
                        )
                    )
                val canonical =
                    try {
                        ReportAdmission.validateCoreFields(core)
                        core.canonicalBytes()
                    } catch (_: IllegalArgumentException) {
                        return@withContext null
                    } catch (_: IllegalStateException) {
                        return@withContext null
                    }
                val id =
                    java.security.MessageDigest.getInstance("SHA-256")
                        .digest("TrailMesh/id/v1\n".toByteArray() + canonical)
                        .joinToString("") { "%02x".format(it.toInt() and 255) }
                val signature = signer.sign("TrailMesh/core/v1\n".toByteArray() + canonical)
                ReportJSON.ObjectValue(
                        mapOf(
                            "core" to core,
                            "bundle_id" to text(id),
                            "signature" to text(ReportAdmission.encode(signature)),
                        )
                    )
                    .canonicalBytes()
            }
        if (wire == null) return StoreOutcome.Rejected("invalid")
        return store(wire, clock, true, created)
    }

    /**
     * Returns verified projections; antimeridian bounds are supported and history requires opt-in.
     */
    suspend fun reports(
        now: Long,
        bounds: ReportBounds = ReportBounds(),
        includeExpired: Boolean = false,
    ): List<StoredReport> {
        validClock(now)
        if (
            bounds.south !in -900_000_000..900_000_000 ||
                bounds.north !in -900_000_000..900_000_000 ||
                bounds.south > bounds.north ||
                bounds.west !in -1_800_000_000..1_800_000_000 ||
                bounds.east !in -1_800_000_000..1_800_000_000
        )
            throw ReportStoreException(StoreFailure.INVALID_BOUNDS)
        return transaction { db ->
            observe(db, now)
            val longitude =
                if (bounds.west <= bounds.east) "r.lon_e7 BETWEEN ? AND ?"
                else "(r.lon_e7>=? OR r.lon_e7<=?)"
            db.query(
                    "SELECT $COLUMNS $JOIN WHERE r.lat_e7 BETWEEN ? AND ? AND $longitude AND (?=1 OR (q.bundle_id IS NULL AND b.expires_at_ms>? AND s.local_expiry_ms>?)) ORDER BY r.observed_at_ms DESC,b.bundle_id",
                    arrayOf<Any?>(
                        bounds.south,
                        bounds.north,
                        bounds.west,
                        bounds.east,
                        if (includeExpired) 1 else 0,
                        now,
                        now,
                    ),
                )
                .use { c -> buildList { while (c.moveToNext()) add(verified(c, now).report) } }
        }
    }

    /**
     * Returns original wire copies only for current, non-quarantined reports with a positive hop
     * cap.
     */
    suspend fun forwardable(now: Long): List<ForwardableReport> = transaction { db ->
        observe(db, now)
        db.query(
                "SELECT $COLUMNS $JOIN WHERE q.bundle_id IS NULL AND b.expires_at_ms>? AND s.local_expiry_ms>? AND s.max_hops>0 ORDER BY b.bundle_id",
                arrayOf<Any?>(now, now),
            )
            .use { c ->
                buildList {
                    while (c.moveToNext()) {
                        val checked = verified(c, now)
                        if (checked.remainingHops > 0)
                            add(
                                ForwardableReport(
                                    checked.report.bundleID,
                                    checked.verified.originalWire,
                                )
                            )
                    }
                }
            }
    }

    suspend fun exchangeInventoryCursor(now: Long): String? = transaction { db ->
        observe(db, now)
        db.query("SELECT singleton,after_id FROM exchange_cursor").use { c ->
            if (!c.moveToFirst()) null
            else {
                if (
                    c.getType(0) != Cursor.FIELD_TYPE_INTEGER ||
                        c.getInt(0) != 1 ||
                        (!c.isNull(1) &&
                            (c.getType(1) != Cursor.FIELD_TYPE_STRING ||
                                !c.getString(1).matches(Regex("[0-9a-f]{64}"))))
                )
                    throw ReportStoreException(StoreFailure.CORRUPT_STORED_REPORT)
                val result = if (c.isNull(1)) null else c.getString(1)
                if (c.moveToNext()) throw ReportStoreException(StoreFailure.CORRUPT_STORED_REPORT)
                result
            }
        }
    }

    suspend fun recordExchangeInventoryProgress(cursor: String?, hasMore: Boolean, now: Long) =
        transaction { db ->
            observe(db, now)
            require(cursor == null || cursor.matches(Regex("[0-9a-f]{64}")))
            db.execSQL(
                "INSERT OR REPLACE INTO exchange_cursor VALUES(1,?)",
                arrayOf<Any?>(if (hasMore) cursor else null),
            )
        }

    suspend fun inventoryPage(
        afterID: String?,
        limit: Int,
        now: Long,
    ): org.trailmesh.app.exchange.InventoryPage {
        require(limit in 1..8)
        require(afterID == null || afterID.matches(Regex("[0-9a-f]{64}")))
        return transaction { db ->
            observe(db, now)
            val items = mutableListOf<org.trailmesh.app.exchange.ReportDescriptor>()
            var cursor: String? = null
            var more = false
            db.query(
                    "SELECT $COLUMNS $JOIN WHERE b.bundle_id>? ORDER BY b.bundle_id LIMIT ?",
                    arrayOf<Any?>(afterID ?: "", limit + 1),
                )
                .use { c ->
                    var scanned = 0
                    while (c.moveToNext()) {
                        if (scanned++ == limit) {
                            more = true
                            break
                        }
                        val checked = verified(c, now)
                        cursor = checked.report.bundleID
                        if (!checked.report.isExpired && checked.remainingHops > 0)
                            items.add(
                                org.trailmesh.app.exchange.ReportDescriptor(
                                    cursor,
                                    checked.verified.originalWire.size,
                                    checked.remainingHops,
                                )
                            )
                    }
                }
            org.trailmesh.app.exchange.InventoryPage(items, cursor, more)
        }
    }

    suspend fun currentIDs(ids: List<String>, now: Long): Set<String> {
        require(ids.size <= 8)
        return transaction { db ->
            observe(db, now)
            buildSet {
                for (id in ids) {
                    require(id.matches(Regex("[0-9a-f]{64}")))
                    db.query("SELECT $COLUMNS $JOIN WHERE b.bundle_id=?", arrayOf<Any?>(id)).use { c
                        ->
                        if (c.moveToFirst()) {
                            val checked = verified(c, now)
                            if (!checked.report.isExpired) add(id)
                        }
                    }
                }
            }
        }
    }

    suspend fun loadForExchange(id: String, now: Long): org.trailmesh.app.exchange.OutgoingReport? =
        transaction { db ->
            observe(db, now)
            db.query("SELECT $COLUMNS $JOIN WHERE b.bundle_id=?", arrayOf<Any?>(id)).use { c ->
                if (!c.moveToFirst()) null
                else {
                    val checked = verified(c, now)
                    if (checked.report.isExpired || checked.remainingHops == 0) null
                    else
                        org.trailmesh.app.exchange.OutgoingReport(
                            org.trailmesh.app.exchange.ReportDescriptor(
                                id,
                                checked.verified.originalWire.size,
                                checked.remainingHops,
                            ),
                            checked.verified.originalWire,
                        )
                }
            }
        }

    /** Only after explicit confirmation that the backward correction is intentional. */
    suspend fun recoverClockAfterUserConfirmation(now: Long): Int = transaction { db ->
        validClock(now)
        if (now >= scalar(db, "SELECT last_now_ms FROM repository_clock WHERE singleton=1"))
            throw ReportStoreException(StoreFailure.CLOCK)
        db.execSQL(
            "INSERT OR IGNORE INTO quarantined_ids SELECT bundle_id,? FROM bundles",
            arrayOf<Any?>(now + 3_600_000),
        )
        db.execSQL(
            "UPDATE quarantined_ids SET rate_hold_until_ms=?",
            arrayOf<Any?>(now + 3_600_000),
        )
        db.execSQL(
            "UPDATE repository_clock SET last_now_ms=? WHERE singleton=1",
            arrayOf<Any?>(now),
        )
        scalar(db, "SELECT COUNT(*) FROM quarantined_ids").toInt()
    }

    /** Only after the user confirms the clock and agrees to delete expired history. */
    suspend fun reclaimExpiredReportsAfterUserConfirmation(now: Long): Int = transaction { db ->
        observe(db, now)
        val ids =
            db.query(
                    "SELECT $COLUMNS $JOIN WHERE (b.is_local=1 OR (q.bundle_id IS NULL AND b.admitted_at_ms<=?) OR (q.bundle_id IS NOT NULL AND q.rate_hold_until_ms<=?)) AND (b.expires_at_ms<=? OR (q.bundle_id IS NULL AND s.local_expiry_ms<=?))",
                    arrayOf<Any?>(now - 3_600_000, now, now, now),
                )
                .use { c ->
                    buildList { while (c.moveToNext()) add(verified(c, now).report.bundleID) }
                }
        ids.forEach { db.execSQL("DELETE FROM bundles WHERE bundle_id=?", arrayOf<Any?>(it)) }
        db.execSQL("DELETE FROM seen_ids WHERE retain_until_ms<=?", arrayOf<Any?>(now))
        ids.size
    }

    private data class Checked(
        val verified: VerifiedReport,
        val report: StoredReport,
        val remainingHops: Int,
    )

    private fun verified(c: Cursor, now: Long): Checked {
        try {
            fun column(name: String, type: Int): Int {
                val i = c.getColumnIndexOrThrow(name)
                require(c.getType(i) == type)
                return i
            }
            fun text(name: String) = c.getString(column(name, Cursor.FIELD_TYPE_STRING))
            fun number(name: String) = c.getLong(column(name, Cursor.FIELD_TYPE_INTEGER))
            fun bytes(name: String) = c.getBlob(column(name, Cursor.FIELD_TYPE_BLOB))
            val id = text("bundle_id")
            val admitted = number("admitted_at_ms")
            val expiry = number("expires_at_ms")
            val local = number("local_expiry_ms")
            require(
                admitted in 0..ReportJSON.SAFE_INTEGER &&
                    local >= admitted &&
                    local == minOf(expiry, admitted + 259_200_000)
            )
            val v =
                requireNotNull(ReportAdmission.validate(bytes("original_wire"), admitted).verified)
            val remaining =
                if (c.isNull(c.getColumnIndexOrThrow("remaining_hops"))) v.maxHops
                else number("remaining_hops").also { require(it in 0..v.maxHops.toLong()) }.toInt()
            val p = v.report
            require(
                v.bundleID == id &&
                    v.canonicalCore.contentEquals(bytes("canonical_core")) &&
                    v.signature.contentEquals(bytes("signature")) &&
                    v.authorKey.contentEquals(bytes("author_key"))
            )
            require(
                v.createdAt == number("created_at_ms") &&
                    v.expiresAt == expiry &&
                    v.maxHops.toLong() == number("max_hops") &&
                    p.eventID.contentEquals(bytes("event_id"))
            )
            require(
                p.category == text("category") &&
                    p.status == text("status") &&
                    p.note.toByteArray(Charsets.UTF_8).contentEquals(bytes("note"))
            )
            require(
                p.observedAt == number("observed_at_ms") &&
                    p.latE7 == number("lat_e7") &&
                    p.lonE7 == number("lon_e7") &&
                    p.accuracyM == number("accuracy_m")
            )
            val supersedes =
                if (c.isNull(c.getColumnIndexOrThrow("supersedes"))) null else text("supersedes")
            require(supersedes == p.supersedes)
            val q = number("quarantined") == 1L
            return Checked(
                v,
                StoredReport(
                    id,
                    p.note,
                    p.category,
                    p.status,
                    p.observedAt,
                    admitted,
                    expiry,
                    p.latE7,
                    p.lonE7,
                    p.accuracyM,
                    p.supersedes,
                    q || now >= minOf(expiry, local),
                    q,
                    p.eventID,
                    v.authorKey,
                ),
                remaining,
            )
        } catch (_: Exception) {
            throw ReportStoreException(StoreFailure.CORRUPT_STORED_REPORT)
        }
    }

    /** Waits for an active transaction and closes the pool without interrupting its commit. */
    suspend fun close() {
        withContext(NonCancellable) {
            access.withLock { withContext(Dispatchers.IO) { database.close() } }
        }
    }
}
