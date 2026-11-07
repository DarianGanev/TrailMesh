# Android product report storage

This is the native Android product target (`org.trailmesh.app`), separate from `probes/transport/android`. Its development screen does not yet expose report creation, maps, radio sessions, clock recovery, or storage cleanup. Those workflows and radio integration are separate issues; repository tests do not establish physical report exchange.

## Build and verify

Use JDK 17 and Android SDK 36 to compile. The supported minimum is API 26. Dependencies are pinned: AGP 9.4.1, Kotlin 2.4.21, KSP 2.3.12, Room 2.8.5, Tink Android 1.24.0, and coroutines 1.11.0. Host database tests use Robolectric 4.17 at API 28; device CI runs the same repository contract on API 26 and Android 17/API 37, plus actual Keystore and Room migration tests.

```powershell
.\gradlew.bat testDebugUnitTest assembleDebug assembleDebugAndroidTest
.\gradlew.bat connectedDebugAndroidTest
```

The application APK is `app/build/outputs/apk/debug/app-debug.apk`; the test APK is `app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk`. CI publishes them under distinct `TrailMeshProduct` artifact names, verifies nonzero passing tests, and independently checks an Android-authored public test report with Python. Shared authoritative vectors are loaded directly from `protocol/` through source sets, rather than maintained as a second copy.

## Repository contract

`ReportRepository.open(context, databaseName)` opens Room and applies non-destructive migrations off the UI thread. `author` creates an immutable signed report and commits the bundle, report projection, relay/outbox state, and replay marker atomically. `ingest` verifies strict UTF-8/JSON, canonical bytes, content ID, Ed25519 signature and freshness before a short transaction rechecks expiry, duplicates, budgets and the clock. `Stored` is returned only after commit; signature authenticity does not establish that an observation is true.

Use `reports(now, bounds, includeExpired)` for immutable map projections, including bounds crossing the antimeridian. History requires `includeExpired=true`. `forwardable(now)` returns a copy of the original accepted wire, without changing signed timestamps or resigning. Stored signatures, bytes, SQL types, and projection fields are checked before display, forwarding, duplicate confirmation, or cleanup. Lost payloads with a live seen marker produce an explicit error rather than a false duplicate acknowledgement. Storage, signing and clock failures propagate; exchange code must not map them to success.

The initial shared policy is 25 MiB of logical signed-data bytes, with remote admissions limited to 20 MiB, reserving 5 MiB for local authoring. SQLite pages, indexes and WAL overhead are additional. Remote authors may contribute at most 20 newly accepted reports per rolling local hour; duplicates and failed transactions consume no allowance. Seen IDs remain until signed expiry plus 24 hours and are capped at 10,000. Admission rejects quota rather than evicting reports or replay markers under an unverified clock. Forwarding ends at the earlier of signed expiry and admission plus 72 hours; zero-hop reports are retained but not forwarded.

A backward clock returns an explicit clock failure. Only after user confirmation, `recoverClockAfterUserConfirmation` quarantines existing reports as identifiable expired history and resumes at the corrected time. Quarantined reports cannot become current or forwardable. Remote entries conservatively retain their author allowance for one hour after each recovery. Only `reclaimExpiredReportsAfterUserConfirmation`, after confirmation of clock accuracy and deletion, removes expired history and elapsed seen markers; recent remote rate windows are preserved. This intentionally replaces automatic seven-day deletion. The product UI still needs to expose these actions.

Database work and signing run off the main thread. Cancellation before an operation enters its protected transaction prevents mutation. Once the transaction begins, it finishes and returns its committed outcome, allowing the caller to make an honest acknowledgement decision. A SQLite failure closes and reopens that repository's connection pool before permitting reuse, because a failed commit can leave Android's connection state uncertain. It still reports the failure; it never infers success from recovery. A caller may lose a response or terminate after commit; retrying a valid retained report is safe.

## Signing identity

`ProtectedSigningIdentityStore.createNew()` is an explicit one-time action. `loadExisting()` never creates a replacement identity. A 32-byte Ed25519 seed is encrypted with AES-256-GCM using a non-exportable Android Keystore wrapping key, authenticated with a versioned domain, and stored atomically under app-private `noBackupFilesDir`. A file lock serializes creation across instances and processes. No seed is stored in SQLite. Backup is disabled for this development product.

The wrapped-seed fallback is **not** a non-exportable Ed25519 Keystore key or a promise of hardware backing. Signing unwraps the seed into process memory and checks identity continuity. Missing/invalidated keys, corrupt ciphertext and failed persistence fail explicitly without replacing the identity. A failed first save can leave an orphan wrapping key; creation then fails safely and requires a future explicit reset flow, rather than silently selecting a new identity.

## Schema and evidence

Committed Room exports cover deliberate pre-release v1, additive v2 (persisted clock), and v3 (quarantine). They do not represent previously shipped Android databases. Tests seed real signed bytes in older on-disk schemas, migrate and compare signed blobs, projections, relay/replay state and indexes, and verify migration rollback/retry and refusal of unknown newer schemas. Runtime constraint triggers supplement Room's exported schema for binary widths, signed time ordering, origin flags, relay caps and the singleton clock.

Regression tests cover malformed/valid vectors, real signing, reopen and concurrent duplicate admission, immutable original wire, transaction rollback, SQLite exhaustion, capacity reserve, author rate limits, bounded seen IDs, expiry boundaries, explicit history, corrupted stored data, backward/future clocks, quarantine, confirmed cleanup, cancellation, migrations and actual Android Keystore behavior. A separate device test stores a report, force-stops the application, and verifies the same bytes and duplicate result in a new process. These are local/emulator results, not physical radio or lifecycle evidence.
