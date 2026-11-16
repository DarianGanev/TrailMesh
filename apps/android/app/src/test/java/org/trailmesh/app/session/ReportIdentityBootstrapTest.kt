package org.trailmesh.app.session

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.trailmesh.app.security.*

class ReportIdentityBootstrapTest {
    private val signer =
        object : ReportSigner {
            override val publicKey = ByteArray(32)

            override fun sign(message: ByteArray) = ByteArray(64)
        }

    @Test
    fun firstInitializationMarksBeforeCreationAndEstablishedMissingIdentityIsNeverReplaced() =
        runBlocking {
            var initialized = false
            var creations = 0
            val load: suspend () -> ReportSigner = {
                throw IdentityException(IdentityFailure.MISSING_IDENTITY)
            }
            val result =
                ReportIdentityBootstrap.load(
                    { initialized },
                    { initialized = true },
                    load,
                    {
                        assertTrue(initialized)
                        creations++
                        signer
                    },
                )
            assertSame(signer, result)
            try {
                ReportIdentityBootstrap.load(
                    { initialized },
                    { initialized = true },
                    load,
                    {
                        creations++
                        signer
                    },
                )
                fail("Established identity must not be replaced")
            } catch (e: IdentityException) {
                assertEquals(IdentityFailure.MISSING_IDENTITY, e.reason)
            }
            assertEquals(1, creations)
        }

    @Test
    fun successfulExistingLoadMarksEstablishedAndFailedMarkerPreventsCreation() = runBlocking {
        var initialized = false
        var creations = 0
        assertSame(
            signer,
            ReportIdentityBootstrap.load(
                { initialized },
                { initialized = true },
                { signer },
                {
                    creations++
                    signer
                },
            ),
        )
        assertTrue(initialized)
        assertEquals(0, creations)
        try {
            ReportIdentityBootstrap.load(
                { false },
                { throw IdentityException(IdentityFailure.STORAGE_FAILURE) },
                { throw IdentityException(IdentityFailure.MISSING_IDENTITY) },
                {
                    creations++
                    signer
                },
            )
            fail("Failed marker must prevent identity creation")
        } catch (e: IdentityException) {
            assertEquals(IdentityFailure.STORAGE_FAILURE, e.reason)
        }
        assertEquals(0, creations)
    }
}
