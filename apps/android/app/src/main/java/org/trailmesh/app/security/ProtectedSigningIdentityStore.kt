package org.trailmesh.app.security

import java.io.File
import java.security.SecureRandom
import javax.crypto.SecretKey

/** Raw Ed25519 public key (32 bytes) and signatures (64 bytes), without wire-format prefixes. */
interface ReportSigner {
    val publicKey: ByteArray

    fun sign(message: ByteArray): ByteArray
}

enum class IdentityFailure {
    MISSING_IDENTITY,
    ALREADY_EXISTS,
    MISSING_WRAPPING_KEY,
    KEY_UNAVAILABLE,
    CORRUPT_IDENTITY,
    STORAGE_FAILURE,
    SIGNING_FAILURE,
}

class IdentityException(val reason: IdentityFailure) : Exception("Signing identity: ${reason.name}")

internal interface WrappingKeyProvider {
    fun createNew(): SecretKey

    fun loadExisting(): SecretKey
}

internal interface IdentityBlobStorage {
    fun <T> exclusively(block: () -> T): T

    fun read(): ByteArray?

    fun createNew(bytes: ByteArray)
}

internal class FileIdentityBlobStorage(
    private val directory: File,
    private val syncDirectory: (File) -> Unit = ::syncAndroidDirectory,
) : IdentityBlobStorage {
    companion object {
        private val locks = java.util.concurrent.ConcurrentHashMap<String, Any>()
    }

    override fun <T> exclusively(block: () -> T): T =
        synchronized(locks.getOrPut(directory.canonicalPath) { Any() }) {
            if (!directory.isDirectory) {
                check(directory.mkdirs() || directory.isDirectory)
                syncDirectory(requireNotNull(directory.parentFile))
            }
            java.io.RandomAccessFile(File(directory, "identity.lock"), "rw").use { file ->
                file.channel.lock().use { block() }
            }
        }

    override fun read(): ByteArray? {
        val file = File(directory, "identity.v1")
        if (!file.exists()) return null
        if (file.length() != 61L) throw IdentityException(IdentityFailure.CORRUPT_IDENTITY)
        return file.readBytes()
    }

    override fun createNew(bytes: ByteArray) {
        val destination = File(directory, "identity.v1")
        if (destination.exists()) throw IdentityException(IdentityFailure.ALREADY_EXISTS)
        val temporary = File.createTempFile("identity-", ".tmp", directory)
        try {
            java.io.FileOutputStream(temporary).use { stream ->
                stream.write(bytes)
                stream.fd.sync()
            }
            java.nio.file.Files.move(
                temporary.toPath(),
                destination.toPath(),
                java.nio.file.StandardCopyOption.ATOMIC_MOVE,
            )
            syncDirectory(directory)
        } finally {
            temporary.delete()
        }
    }
}

private fun syncAndroidDirectory(directory: File) {
    val descriptor =
        android.system.Os.open(
            directory.path,
            android.system.OsConstants.O_RDONLY,
            0,
        )
    try {
        android.system.Os.fsync(descriptor)
    } finally {
        android.system.Os.close(descriptor)
    }
}

internal class IdentityStoreCore(
    private val storage: IdentityBlobStorage,
    private val wrappingKeys: WrappingKeyProvider,
    private val random: SecureRandom = SecureRandom(),
) {
    private val aad = "TrailMesh/signing-identity/v1".toByteArray(Charsets.UTF_8)

    private fun <T> access(block: () -> T): T =
        try {
            storage.exclusively(block)
        } catch (e: IdentityException) {
            throw e
        } catch (_: Exception) {
            throw IdentityException(IdentityFailure.STORAGE_FAILURE)
        }

    private fun key(create: Boolean): SecretKey =
        try {
            if (create) wrappingKeys.createNew() else wrappingKeys.loadExisting()
        } catch (e: IdentityException) {
            throw e
        } catch (_: Exception) {
            throw IdentityException(IdentityFailure.KEY_UNAVAILABLE)
        }

    fun createNew(): ReportSigner = access {
        if (storage.read() != null) throw IdentityException(IdentityFailure.ALREADY_EXISTS)
        val wrapping = key(true)
        val seed = ByteArray(32)
        try {
            random.nextBytes(seed)
            val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, wrapping)
            cipher.updateAAD(aad)
            val encrypted = byteArrayOf(1) + cipher.iv + cipher.doFinal(seed)
            check(encrypted.size == 61)
            storage.createNew(encrypted)
            signer(seed)
        } finally {
            seed.fill(0)
        }
    }

    private fun seed(): ByteArray {
        val record = storage.read() ?: throw IdentityException(IdentityFailure.MISSING_IDENTITY)
        if (record.size != 61 || record[0] != 1.toByte())
            throw IdentityException(IdentityFailure.CORRUPT_IDENTITY)
        val wrapping = key(false)
        return try {
            val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                javax.crypto.Cipher.DECRYPT_MODE,
                wrapping,
                javax.crypto.spec.GCMParameterSpec(128, record.copyOfRange(1, 13)),
            )
            cipher.updateAAD(aad)
            val plain = cipher.doFinal(record.copyOfRange(13, record.size))
            if (plain.size != 32) {
                plain.fill(0)
                throw IdentityException(IdentityFailure.CORRUPT_IDENTITY)
            }
            plain
        } catch (failure: IdentityException) {
            throw failure
        } catch (_: javax.crypto.AEADBadTagException) {
            throw IdentityException(IdentityFailure.CORRUPT_IDENTITY)
        } catch (_: Exception) {
            throw IdentityException(IdentityFailure.KEY_UNAVAILABLE)
        }
    }

    fun loadExisting(): ReportSigner = access {
        val seed = seed()
        try {
            signer(seed)
        } finally {
            seed.fill(0)
        }
    }

    private fun signer(seed: ByteArray): ReportSigner {
        val public =
            com.google.crypto.tink.subtle.Ed25519Sign.KeyPair.newKeyPairFromSeed(seed).publicKey
        return object : ReportSigner {
            override val publicKey: ByteArray
                get() = public.copyOf()

            override fun sign(message: ByteArray): ByteArray = access {
                val current = seed()
                try {
                    val pair =
                        com.google.crypto.tink.subtle.Ed25519Sign.KeyPair.newKeyPairFromSeed(
                            current,
                        )
                    if (!pair.publicKey.contentEquals(public))
                        throw IdentityException(IdentityFailure.CORRUPT_IDENTITY)
                    com.google.crypto.tink.subtle.Ed25519Sign(current).sign(message)
                } catch (e: IdentityException) {
                    throw e
                } catch (_: Exception) {
                    throw IdentityException(IdentityFailure.SIGNING_FAILURE)
                } finally {
                    current.fill(0)
                }
            }
        }
    }
}

/**
 * Explicit creation and loading; a lost or invalidated identity is never replaced automatically.
 */
class ProtectedSigningIdentityStore(context: android.content.Context) {
    private val application = context.applicationContext

    private fun core() =
        IdentityStoreCore(
            FileIdentityBlobStorage(File(application.noBackupFilesDir, "signing")),
            AndroidWrappingKeys(),
        )

    /** Creates once off the main thread; existing or orphaned wrapping keys are never replaced. */
    suspend fun createNew(): ReportSigner =
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { core().createNew() }

    /**
     * Loads an authenticated identity; missing, unavailable and corrupt identities fail explicitly.
     */
    suspend fun loadExisting(): ReportSigner =
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { core().loadExisting() }
}

private class AndroidWrappingKeys : WrappingKeyProvider {
    private val alias = "org.trailmesh.app.signing-wrap.v1"

    private fun store() = java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    override fun createNew(): SecretKey {
        if (store().containsAlias(alias)) throw IdentityException(IdentityFailure.ALREADY_EXISTS)
        val generator = javax.crypto.KeyGenerator.getInstance("AES", "AndroidKeyStore")
        generator.init(
            android.security.keystore.KeyGenParameterSpec.Builder(
                    alias,
                    android.security.keystore.KeyProperties.PURPOSE_ENCRYPT or
                        android.security.keystore.KeyProperties.PURPOSE_DECRYPT,
                )
                .setKeySize(256)
                .setBlockModes(android.security.keystore.KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(
                    android.security.keystore.KeyProperties.ENCRYPTION_PADDING_NONE,
                )
                .build(),
        )
        return generator.generateKey()
    }

    override fun loadExisting(): SecretKey =
        store().getKey(alias, null) as? SecretKey
            ?: throw IdentityException(IdentityFailure.MISSING_WRAPPING_KEY)
}
