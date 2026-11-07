package org.trailmesh.app.security

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.crypto.tink.subtle.Ed25519Verify
import java.io.File
import java.security.KeyStore
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidIdentityTest {
    @Test
    fun ciphertextTamperingFailsAuthenticationWithoutReplacingIdentity() = runBlocking {
        ProtectedSigningIdentityStore(context).createNew()
        val file = File(context.noBackupFilesDir, "signing/identity.v1")
        val corrupt =
            file.readBytes().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() }
        file.writeBytes(corrupt)
        try {
            ProtectedSigningIdentityStore(context).loadExisting()
            fail("Tampered identity")
        } catch (e: IdentityException) {
            assertEquals(IdentityFailure.CORRUPT_IDENTITY, e.reason)
        }
        try {
            ProtectedSigningIdentityStore(context).createNew()
            fail("Must not replace corrupt identity")
        } catch (e: IdentityException) {
            assertEquals(IdentityFailure.ALREADY_EXISTS, e.reason)
        }
        assertArrayEquals(corrupt, file.readBytes())
    }

    private val context
        get() = ApplicationProvider.getApplicationContext<android.content.Context>()

    private val alias = "org.trailmesh.app.signing-wrap.v1"

    @Before fun cleanBefore() = cleanup()

    @After fun cleanAfter() = cleanup()

    private fun cleanup() {
        KeyStore.getInstance("AndroidKeyStore").apply {
            load(null)
            deleteEntry(alias)
        }
        File(context.noBackupFilesDir, "signing").deleteRecursively()
    }

    @Test
    fun keystoreWrappedIdentityReopensAndKeyIsNonExportable() = runBlocking {
        val signer = ProtectedSigningIdentityStore(context).createNew()
        val reopened = ProtectedSigningIdentityStore(context).loadExisting()
        assertArrayEquals(signer.publicKey, reopened.publicKey)
        Ed25519Verify(signer.publicKey).verify(reopened.sign(byteArrayOf(1, 2)), byteArrayOf(1, 2))
        val key = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.getKey(alias, null)
        assertNull(key.encoded)
        assertEquals("AES", key.algorithm)
        assertEquals(61, File(context.noBackupFilesDir, "signing/identity.v1").length())
    }

    @Test
    fun deletedWrappingKeyFailsWithoutReplacingIdentity() = runBlocking {
        val signer = ProtectedSigningIdentityStore(context).createNew()
        val file = File(context.noBackupFilesDir, "signing/identity.v1")
        val before = file.readBytes()
        KeyStore.getInstance("AndroidKeyStore").apply {
            load(null)
            deleteEntry(alias)
        }
        try {
            signer.sign(byteArrayOf(1))
            fail("Expected lost key")
        } catch (e: IdentityException) {
            assertEquals(IdentityFailure.MISSING_WRAPPING_KEY, e.reason)
        }
        try {
            ProtectedSigningIdentityStore(context).createNew()
            fail("Must not replace identity")
        } catch (e: IdentityException) {
            assertEquals(IdentityFailure.ALREADY_EXISTS, e.reason)
        }
        assertArrayEquals(before, file.readBytes())
    }
}
