package org.trailmesh.app.persistence

import androidx.room.testing.MigrationTestHelper
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
import org.junit.Test

class RoomMigrationInstrumentedTest {
    @get:Rule
    val helper =
        MigrationTestHelper(
            InstrumentationRegistry.getInstrumentation(),
            ReportDatabase::class.java,
        )

    @Test
    fun roomValidatesTheFullV1ToV3MigrationSchema() {
        helper.createDatabase("room-migration-helper.sqlite", 1).close()
        helper
            .runMigrationsAndValidate(
                "room-migration-helper.sqlite",
                3,
                true,
                ReportDatabase.MIGRATION_1_2,
                ReportDatabase.MIGRATION_2_3,
            )
            .close()
    }
}
