package org.trailmesh.app.session

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.trailmesh.app.persistence.ReportRepository
import org.trailmesh.app.security.IdentityException
import org.trailmesh.app.security.IdentityFailure
import org.trailmesh.app.security.ProtectedSigningIdentityStore

internal object ProductReportAccess {
    private val identityLock = Mutex()
    private const val IDENTITY_INITIALIZED = "identity_initialized"

    suspend fun open(context: Context) = ReportRepository.open(context, "product-reports.sqlite")

    suspend fun signer(context: Context) = identityLock.withLock {
        withContext(Dispatchers.IO) {
            val preferences = context.getSharedPreferences("public-report-session", Context.MODE_PRIVATE)
            val identity = ProtectedSigningIdentityStore(context)
            ReportIdentityBootstrap.load(
                initialized = { preferences.getBoolean(IDENTITY_INITIALIZED, false) },
                markInitialized = {
                    if (!preferences.getBoolean(IDENTITY_INITIALIZED, false) &&
                        !preferences.edit().putBoolean(IDENTITY_INITIALIZED, true).commit()
                    ) throw IdentityException(IdentityFailure.STORAGE_FAILURE)
                },
                loadExisting = identity::loadExisting,
                createNew = identity::createNew,
            )
        }
    }
}
