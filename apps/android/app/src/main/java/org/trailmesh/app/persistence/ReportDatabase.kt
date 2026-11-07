package org.trailmesh.app.persistence

import android.content.Context
import androidx.room.*
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Entity(
    tableName = "bundles",
    indices =
        [
            Index(value = ["expires_at_ms"], name = "bundles_expiry"),
            Index(value = ["author_key", "admitted_at_ms"], name = "bundles_author_admission"),
        ],
)
internal data class BundleRow(
    @PrimaryKey val bundle_id: String,
    val canonical_core: ByteArray,
    val signature: ByteArray,
    val original_wire: ByteArray,
    val author_key: ByteArray,
    val created_at_ms: Long,
    val expires_at_ms: Long,
    val admitted_at_ms: Long,
    val is_local: Int,
)

@Entity(
    tableName = "reports",
    foreignKeys =
        [
            ForeignKey(
                entity = BundleRow::class,
                parentColumns = ["bundle_id"],
                childColumns = ["bundle_id"],
                onDelete = ForeignKey.CASCADE,
            ),
        ],
    indices =
        [
            Index(value = ["event_id"], name = "reports_event"),
            Index(value = ["lat_e7", "lon_e7"], name = "reports_location"),
        ],
)
internal data class ProjectionRow(
    @PrimaryKey val bundle_id: String,
    val event_id: ByteArray,
    val category: String,
    val status: String,
    val observed_at_ms: Long,
    val lat_e7: Long,
    val lon_e7: Long,
    val accuracy_m: Long,
    val note: ByteArray,
    val supersedes: String?,
)

@Entity(
    tableName = "relay_state",
    foreignKeys =
        [
            ForeignKey(
                entity = BundleRow::class,
                parentColumns = ["bundle_id"],
                childColumns = ["bundle_id"],
                onDelete = ForeignKey.CASCADE,
            ),
        ],
    indices = [Index(value = ["local_expiry_ms"], name = "relay_expiry")],
)
internal data class RelayRow(
    @PrimaryKey val bundle_id: String,
    val local_expiry_ms: Long,
    val max_hops: Int,
    val outbox: Int,
)

@Entity(
    tableName = "seen_ids",
    indices = [Index(value = ["retain_until_ms", "bundle_id"], name = "seen_retention")],
)
internal data class SeenRow(
    @PrimaryKey val bundle_id: String,
    val retain_until_ms: Long,
    val reason: String,
)

@Entity(tableName = "repository_clock")
internal data class ClockRow(@PrimaryKey val singleton: Int, val last_now_ms: Long)

@Entity(
    tableName = "quarantined_ids",
    foreignKeys =
        [
            ForeignKey(
                entity = BundleRow::class,
                parentColumns = ["bundle_id"],
                childColumns = ["bundle_id"],
                onDelete = ForeignKey.CASCADE,
            ),
        ],
)
internal data class QuarantineRow(@PrimaryKey val bundle_id: String, val rate_hold_until_ms: Long)

@Dao
internal interface ReportDao {
    @Insert fun insert(row: BundleRow)

    @Insert fun insert(row: ProjectionRow)

    @Insert fun insert(row: RelayRow)

    @Insert(onConflict = OnConflictStrategy.REPLACE) fun insert(row: SeenRow)
}

/** Versions 1 and 2 are deliberate pre-release schemas, never deployed product databases. */
@Database(
    entities =
        [
            BundleRow::class,
            ProjectionRow::class,
            RelayRow::class,
            SeenRow::class,
            ClockRow::class,
            QuarantineRow::class,
        ],
    version = 3,
    exportSchema = true,
)
internal abstract class ReportDatabase : RoomDatabase() {
    abstract fun records(): ReportDao

    companion object {
        val MIGRATION_1_2 =
            object : Migration(1, 2) {
                override fun migrate(db: SupportSQLiteDatabase) {
                    db.execSQL(
                        "CREATE TABLE IF NOT EXISTS repository_clock (singleton INTEGER NOT NULL, last_now_ms INTEGER NOT NULL, PRIMARY KEY(singleton))",
                    )
                    db.execSQL(
                        "INSERT INTO repository_clock SELECT 1, COALESCE(MAX(admitted_at_ms),0) FROM bundles",
                    )
                }
            }
        val MIGRATION_2_3 =
            object : Migration(2, 3) {
                override fun migrate(db: SupportSQLiteDatabase) {
                    db.execSQL(
                        "CREATE TABLE IF NOT EXISTS quarantined_ids (bundle_id TEXT NOT NULL, rate_hold_until_ms INTEGER NOT NULL, PRIMARY KEY(bundle_id), FOREIGN KEY(bundle_id) REFERENCES bundles(bundle_id) ON UPDATE NO ACTION ON DELETE CASCADE)",
                    )
                }
            }

        fun open(context: Context, name: String): ReportDatabase {
            return Room.databaseBuilder(
                    context.applicationContext,
                    ReportDatabase::class.java,
                    name,
                )
                .addMigrations(MIGRATION_1_2, MIGRATION_2_3)
                .addCallback(
                    object : Callback() {
                        override fun onCreate(db: SupportSQLiteDatabase) {
                            db.execSQL("INSERT INTO repository_clock VALUES(1,0)")
                        }

                        override fun onOpen(db: SupportSQLiteDatabase) {
                            // Room exports do not represent CHECK clauses. These constraints apply
                            // to
                            // fresh and migrated databases without rewriting any signed report
                            // bytes.
                            val checks =
                                mapOf(
                                    "bundles" to
                                        "length(NEW.signature)=64 AND length(NEW.author_key)=32 AND NEW.created_at_ms>=0 AND NEW.created_at_ms<NEW.expires_at_ms AND NEW.admitted_at_ms>=0 AND NEW.is_local IN(0,1)",
                                    "reports" to
                                        "length(NEW.event_id)=16 AND typeof(NEW.note)='blob'",
                                    "relay_state" to
                                        "NEW.max_hops BETWEEN 0 AND 12 AND NEW.outbox IN(0,1)",
                                    "repository_clock" to "NEW.singleton=1 AND NEW.last_now_ms>=0",
                                )
                            db.beginTransaction()
                            try {
                                for ((table, condition) in checks) for (operation in
                                    listOf("INSERT", "UPDATE")) {
                                    db.execSQL(
                                        "CREATE TRIGGER IF NOT EXISTS ${table}_check_${operation.lowercase()} BEFORE $operation ON $table WHEN NOT($condition) BEGIN SELECT RAISE(ABORT,'report constraint'); END",
                                    )
                                }
                                db.setTransactionSuccessful()
                            } finally {
                                db.endTransaction()
                            }
                        }
                    },
                )
                .build()
                .also { database ->
                    try {
                        database.openHelper.writableDatabase
                    } catch (failure: Exception) {
                        try {
                            database.close()
                        } catch (cleanup: Exception) {
                            failure.addSuppressed(cleanup)
                        }
                        throw failure
                    }
                }
        }
    }
}
