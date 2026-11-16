package org.trailmesh.app.session

import org.trailmesh.app.security.*

/** Bootstrap never replaces a missing established identity, including an interrupted first save. */
internal object ReportIdentityBootstrap {
    suspend fun load(
        initialized: () -> Boolean,
        markInitialized: () -> Unit,
        loadExisting: suspend () -> ReportSigner,
        createNew: suspend () -> ReportSigner,
    ): ReportSigner {
        val signer =
            try {
                loadExisting()
            } catch (e: IdentityException) {
                if (e.reason != IdentityFailure.MISSING_IDENTITY || initialized()) throw e
                // Persist intent before creation so an uncertain creation/save cannot silently
                // retry.
                markInitialized()
                createNew()
            }
        markInitialized()
        return signer
    }
}
