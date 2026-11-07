package org.trailmesh.app.persistence

import androidx.test.core.app.ApplicationProvider
import com.google.crypto.tink.subtle.Ed25519Sign
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.trailmesh.app.security.ReportSigner

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class AndroidInteropTest {
    @Test
    fun exportPublicTestReportForIndependentPythonVerification() = runBlocking {
        val seed = ByteArray(32) { it.toByte() }
        val public = Ed25519Sign.KeyPair.newKeyPairFromSeed(seed).publicKey
        val signer =
            object : ReportSigner {
                override val publicKey
                    get() = public.copyOf()

                override fun sign(message: ByteArray) = Ed25519Sign(seed).sign(message)
            }
        val repo =
            ReportRepository.open(
                ApplicationProvider.getApplicationContext(),
                "interop-${UUID.randomUUID()}.sqlite",
            )
        val now = 1_789_647_000_000L
        assertTrue(
            repo.author(
                ReportDraft(
                    "water",
                    "dry",
                    now,
                    421790000,
                    235850000,
                    30,
                    "Public interop fixture",
                    now + 3_600_000,
                    12,
                ),
                signer,
                now,
            ) is StoreOutcome.Stored,
        )
        val bytes = repo.forwardable(now).single().originalWire
        File("build/interop/android-authored.json").apply {
            requireNotNull(parentFile).mkdirs()
            writeBytes(bytes)
        }
        repo.close()
    }
}
