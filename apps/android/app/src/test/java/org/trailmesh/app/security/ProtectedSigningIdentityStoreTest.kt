package org.trailmesh.app.security

import com.google.crypto.tink.subtle.Ed25519Verify
import java.io.File
import java.io.IOException
import java.security.KeyStoreException
import java.security.SecureRandom
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ProtectedSigningIdentityStoreTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test
    fun createdIdentityReopensAndSignsRawEd25519WithoutPersistingPlaintextSeed() {
        val keys = TestKeys()
        val directory = temporary.newFolder()
        val created = store(directory, keys).createNew()
        val reopened = store(directory, keys).loadExisting()
        assertEquals(32, created.publicKey.size)
        assertArrayEquals(created.publicKey, reopened.publicKey)
        val message = "TrailMesh/core/v1\nfixture".toByteArray()
        val signature = reopened.sign(message)
        assertEquals(64, signature.size)
        Ed25519Verify(created.publicKey).verify(signature, message)
        val blob = File(directory, "identity.v1").readBytes()
        // A GCM envelope cannot be a raw seed, and stores only its fixed encrypted record.
        assertEquals(61, blob.size)
        assertFalse(blob.contentEquals(created.publicKey))
    }

    @Test
    fun loadingAbsentIdentityDoesNotCreateOne() {
        val directory = temporary.newFolder()
        failure(IdentityFailure.MISSING_IDENTITY) { store(directory, TestKeys()).loadExisting() }
        assertFalse(File(directory, "identity.v1").exists())
    }

    @Test
    fun creationNeverOverwritesExistingIdentity() {
        val directory = temporary.newFolder()
        val keys = TestKeys()
        val first = store(directory, keys).createNew()
        val bytes = File(directory, "identity.v1").readBytes()
        failure(IdentityFailure.ALREADY_EXISTS) { store(directory, keys).createNew() }
        assertArrayEquals(bytes, File(directory, "identity.v1").readBytes())
        assertArrayEquals(first.publicKey, store(directory, keys).loadExisting().publicKey)
    }

    @Test
    fun missingWrappingKeyCannotReplaceExistingIdentity() {
        val directory = temporary.newFolder()
        val keys = TestKeys()
        store(directory, keys).createNew()
        val bytes = File(directory, "identity.v1").readBytes()
        keys.key = null
        failure(IdentityFailure.MISSING_WRAPPING_KEY) { store(directory, keys).loadExisting() }
        failure(IdentityFailure.ALREADY_EXISTS) { store(directory, keys).createNew() }
        assertArrayEquals(bytes, File(directory, "identity.v1").readBytes())
    }

    @Test
    fun unavailableWrappingKeyFailsWithRedactedErrorAndPreservesIdentity() {
        val directory = temporary.newFolder()
        val keys = TestKeys()
        store(directory, keys).createNew()
        val bytes = File(directory, "identity.v1").readBytes()
        keys.unavailable = true
        val exception =
            failure(IdentityFailure.KEY_UNAVAILABLE) { store(directory, keys).loadExisting() }
        assertNull(exception.cause)
        assertFalse(exception.toString().contains("sensitive diagnostic"))
        assertArrayEquals(bytes, File(directory, "identity.v1").readBytes())
    }

    @Test
    fun authenticatedCiphertextCorruptionNeverProducesSignerOrNewIdentity() {
        val directory = temporary.newFolder()
        val keys = TestKeys()
        store(directory, keys).createNew()
        val file = File(directory, "identity.v1")
        val corrupted =
            file.readBytes().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() }
        file.writeBytes(corrupted)
        failure(IdentityFailure.CORRUPT_IDENTITY) { store(directory, keys).loadExisting() }
        failure(IdentityFailure.ALREADY_EXISTS) { store(directory, keys).createNew() }
        assertArrayEquals(corrupted, file.readBytes())
    }

    @Test
    fun failedSaveCannotReturnUsableIdentityOrSilentlyRecreateOrphanKey() {
        val directory = temporary.newFolder()
        val storage = FileIdentityBlobStorage(directory)
        val keys = TestKeys()
        val failing =
            object : IdentityBlobStorage by storage {
                override fun createNew(bytes: ByteArray) {
                    throw IOException("sensitive diagnostic")
                }
            }
        failure(IdentityFailure.STORAGE_FAILURE) { IdentityStoreCore(failing, keys).createNew() }
        failure(IdentityFailure.MISSING_IDENTITY) { store(directory, keys).loadExisting() }
        failure(IdentityFailure.ALREADY_EXISTS) { store(directory, keys).createNew() }
    }

    @Test
    fun parallelCreationAcrossStoreInstancesProducesOnlyOneIdentity() {
        val directory = temporary.newFolder()
        val keys = TestKeys()
        val executor = Executors.newFixedThreadPool(4)
        try {
            val results =
                executor
                    .invokeAll(
                        (1..12).map {
                            Callable {
                                try {
                                    store(directory, keys).createNew().publicKey
                                } catch (e: IdentityException) {
                                    assertEquals(IdentityFailure.ALREADY_EXISTS, e.reason)
                                    null
                                }
                            }
                        },
                    )
                    .map { it.get() }
                    .filterNotNull()
            assertEquals(1, results.size)
            assertArrayEquals(results.single(), store(directory, keys).loadExisting().publicKey)
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun publicKeyCannotBeMutatedThroughReturnedArray() {
        val directory = temporary.newFolder()
        val keys = TestKeys()
        val identity = store(directory, keys).createNew()
        val expected = identity.publicKey
        identity.publicKey.fill(0)
        assertArrayEquals(expected, identity.publicKey)
        Ed25519Verify(expected).verify(identity.sign(byteArrayOf(1)), byteArrayOf(1))
    }

    @Test
    fun publicRfc8032SeedProducesExactRawPublicKeyAndSignatureButNeverAppearsOnDisk() {
        val directory = temporary.newFolder()
        val seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        val random =
            object : SecureRandom() {
                override fun nextBytes(bytes: ByteArray) {
                    seed.copyInto(bytes)
                }
            }
        val signer =
            IdentityStoreCore(FileIdentityBlobStorage(directory), TestKeys(), random).createNew()
        assertArrayEquals(
            hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"),
            signer.publicKey,
        )
        assertArrayEquals(
            hex(
                "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
            ),
            signer.sign(byteArrayOf()),
        )
        directory.listFiles()!!.forEach { file ->
            assertFalse(file.readBytes().toList().windowed(seed.size).any { it == seed.toList() })
        }
    }

    @Test
    fun alreadyLoadedSignerFailsAfterWrappingKeyDisappears() {
        val directory = temporary.newFolder()
        val keys = TestKeys()
        val signer = store(directory, keys).createNew()
        keys.key = null
        failure(IdentityFailure.MISSING_WRAPPING_KEY) { signer.sign(byteArrayOf(1)) }
    }

    @Test
    fun malformedVersionAndTruncatedOrOversizedRecordsFailClosed() {
        listOf(byteArrayOf(), ByteArray(60), ByteArray(61) { 7 }, ByteArray(62), ByteArray(100_000))
            .forEach { malformed ->
                val directory = temporary.newFolder()
                val keys = TestKeys()
                store(directory, keys).createNew()
                File(directory, "identity.v1").writeBytes(malformed)
                failure(IdentityFailure.CORRUPT_IDENTITY) { store(directory, keys).loadExisting() }
            }
    }

    private fun store(directory: File, keys: TestKeys) =
        IdentityStoreCore(FileIdentityBlobStorage(directory), keys)

    private fun hex(value: String): ByteArray =
        value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private fun failure(reason: IdentityFailure, block: () -> Unit): IdentityException {
        try {
            block()
            fail("Expected $reason")
        } catch (e: IdentityException) {
            assertEquals(reason, e.reason)
            return e
        }
        throw AssertionError("Unreachable")
    }

    private class TestKeys : WrappingKeyProvider {
        var key: SecretKey? = null
        var unavailable = false

        override fun createNew(): SecretKey {
            if (key != null) throw IdentityException(IdentityFailure.ALREADY_EXISTS)
            return KeyGenerator.getInstance("AES")
                .apply { init(256) }
                .generateKey()
                .also { key = it }
        }

        override fun loadExisting(): SecretKey {
            if (unavailable) throw KeyStoreException("sensitive diagnostic")
            return key ?: throw IdentityException(IdentityFailure.MISSING_WRAPPING_KEY)
        }
    }
}
