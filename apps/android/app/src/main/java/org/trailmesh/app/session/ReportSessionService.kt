package org.trailmesh.app.session

import android.app.*
import android.bluetooth.BluetoothManager
import android.content.*
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.*
import kotlinx.coroutines.*
import org.trailmesh.app.exchange.SelectedRepositoryExchangeStore
import org.trailmesh.app.persistence.*
import org.trailmesh.app.relevance.*
import org.trailmesh.app.security.*

/** User-started foreground owner. Binding the development panel never starts discovery. */
class ReportSessionService : Service() {
    inner class LocalBinder : Binder() {
        val session
            get() = this@ReportSessionService
    }

    private val binder = LocalBinder()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val handler = Handler(Looper.getMainLooper())
    private val diagnostics = ReportSessionDiagnostics()
    private var repository: ReportRepository? = null
    private var signer: ReportSigner? = null
    private var promoted = false
    private var extraPermissions = emptyList<String>()
    private lateinit var coordinator: ReportSessionCoordinator
    private val preferences by lazy { getSharedPreferences("public-report-session", MODE_PRIVATE) }
    @Volatile
    var message = "Opening protected report storage..."
        private set

    @Volatile
    var ready = false
        private set

    @Volatile
    var saved = emptyList<SavedTestReportEvidence>()
        private set

    val state
        get() =
            if (::coordinator.isInitialized) coordinator.state else ReportSessionState.interrupted

    val canResume
        get() = preferences.getBoolean("open_intent", false) && state != ReportSessionState.active

    val links
        get() = if (::coordinator.isInitialized) coordinator.liveLinks else 0

    val waiting
        get() = if (::coordinator.isInitialized) coordinator.waitingPeers else 0

    private val ticker =
        object : Runnable {
            override fun run() {
                if (::coordinator.isInitialized) {
                    coordinator.tick()
                    if (state != ReportSessionState.active && promoted) leaveForeground()
                }
                handler.postDelayed(this, ReportSessionLimits.TICK_MS)
            }
        }
    private val bluetoothReceiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (
                    ::coordinator.isInitialized &&
                        state == ReportSessionState.active &&
                        !bluetoothEnabled()
                ) {
                    coordinator.pause(ReportSessionState.radioUnavailable)
                    message = "Bluetooth is off. Enable it, then Resume."
                    leaveForeground()
                }
            }
        }

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java)
            .createNotificationChannel(
                NotificationChannel(
                    CHANNEL,
                    "Public report sharing",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        val filter = IntentFilter(android.bluetooth.BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33)
            registerReceiver(bluetoothReceiver, filter, RECEIVER_EXPORTED)
        else @Suppress("DEPRECATION") registerReceiver(bluetoothReceiver, filter)
        handler.post(ticker)
        scope.launch {
            try {
                repository =
                    ReportRepository.open(this@ReportSessionService, "product-reports.sqlite")
                signer =
                    withContext(Dispatchers.IO) {
                        val identity = ProtectedSigningIdentityStore(this@ReportSessionService)
                        ReportIdentityBootstrap.load(
                            initialized = { preferences.getBoolean("identity_initialized", false) },
                            markInitialized = {
                                if (
                                    !preferences.getBoolean("identity_initialized", false) &&
                                        !preferences
                                            .edit()
                                            .putBoolean("identity_initialized", true)
                                            .commit()
                                )
                                    throw IdentityException(IdentityFailure.STORAGE_FAILURE)
                            },
                            loadExisting = identity::loadExisting,
                            createNew = identity::createNew,
                        )
                    }
                val radio =
                    NearbyReportRadio(
                        this@ReportSessionService,
                        { coordinator },
                        {
                            extraPermissions = it
                            message =
                                "Nearby requires additional Location permission. Tap Resume to allow it."
                        },
                    )
                coordinator =
                    ReportSessionCoordinator(
                        radio,
                        { context ->
                            SelectedRepositoryExchangeStore(
                                repository!!,
                                context,
                                System::currentTimeMillis,
                            )
                        },
                        scope,
                        System::currentTimeMillis,
                        SystemClock::elapsedRealtime,
                        event = diagnostics::record,
                    )
                ready = true
                message =
                    if (canResume) "Interrupted session. Explicit Resume is required."
                    else "Ready. Synthetic Sofia test area; no radio session running."
                refresh()
            } catch (e: IdentityException) {
                message =
                    "Protected identity unavailable (${e.reason.name}). Existing identity was not replaced."
            } catch (_: Exception) {
                message = "Report storage unavailable. Resume requires working protected storage."
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START,
            ACTION_RESUME -> startSharing(intent.getBooleanExtra("consent", false))
            ACTION_STOP -> stopSharing()
            else -> if (!promoted) stopSelf()
        }
        return START_NOT_STICKY
    }

    fun startSharing(consent: Boolean) {
        if (!ready) {
            message = "Storage is still opening. Tap Start again when ready."
            stopSelf()
            return
        }
        if (!consent) {
            coordinator.start(TEST_CONTEXT, false)
            message = "Public sharing consent is required."
            stopSelf()
            return
        }
        if (neededPermissions().isNotEmpty()) {
            coordinator.pause(ReportSessionState.permissionDenied)
            message = "Nearby permissions denied. Allow them, then Resume."
            stopSelf()
            return
        }
        if (!bluetoothEnabled()) {
            coordinator.pause(ReportSessionState.radioUnavailable)
            message = "Bluetooth is off. Enable it, then Resume."
            stopSelf()
            return
        }
        try {
            val notification =
                Notification.Builder(this, CHANNEL)
                    .setSmallIcon(android.R.drawable.stat_sys_upload_done)
                    .setContentTitle("TrailMesh public sharing active")
                    .setContentText(
                        "Unverified nearby participants; up to four links. No screen-off guarantee.",
                    )
                    .setContentIntent(
                        PendingIntent.getActivity(
                            this,
                            0,
                            Intent(this, org.trailmesh.app.MainActivity::class.java),
                            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                        ),
                    )
                    .setOngoing(true)
                    .addAction(
                        Notification.Action.Builder(
                                null,
                                "Stop",
                                PendingIntent.getService(
                                    this,
                                    1,
                                    Intent(this, ReportSessionService::class.java)
                                        .setAction(ACTION_STOP),
                                    PendingIntent.FLAG_UPDATE_CURRENT or
                                        PendingIntent.FLAG_IMMUTABLE,
                                ),
                            )
                            .build(),
                    )
                    .build()
            if (Build.VERSION.SDK_INT >= 29)
                startForeground(
                    42,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                )
            else startForeground(42, notification)
            promoted = true
            if (!preferences.edit().putBoolean("open_intent", true).commit()) {
                coordinator.pause(ReportSessionState.storageFailure)
                leaveForeground()
                message = "Could not save session intent."
                return
            }
            coordinator.start(TEST_CONTEXT, true)
            if (state != ReportSessionState.active) {
                leaveForeground()
                message =
                    "Public sharing paused (${state.name}). Check permissions/radio and Resume."
                return
            }
            message =
                "Public session active. Reports/inventories are visible to nearby unverified participants; signatures protect report integrity, not a person's identity."
        } catch (_: SecurityException) {
            coordinator.pause(ReportSessionState.permissionDenied)
            leaveForeground()
            message = "Nearby or foreground permission denied."
            stopSelf()
        } catch (_: Exception) {
            coordinator.pause(ReportSessionState.radioUnavailable)
            leaveForeground()
            message = "Radio session could not start. Check settings, then Resume."
            stopSelf()
        }
    }

    fun stopSharing() {
        if (::coordinator.isInitialized) coordinator.stop()
        preferences.edit().putBoolean("open_intent", false).commit()
        leaveForeground()
        message = "Stopped. Committed reports remain saved locally."
        stopSelf()
    }

    fun createSyntheticReport() {
        if (!ready) return
        scope.launch {
            try {
                val now = System.currentTimeMillis()
                val unique = ReportAdvertisement.randomID().take(8)
                when (
                    val outcome =
                        repository!!.author(
                            ReportDraft(
                                "trail",
                                "muddy",
                                now,
                                426977000,
                                233219000,
                                1,
                                ReportSessionCoordinator.TEST_NOTE_PREFIX + unique,
                                now + 3600000,
                                3,
                            ),
                            signer!!,
                            System::currentTimeMillis,
                        )
                ) {
                    is StoreOutcome.Stored -> {
                        diagnostics.record(
                            ReportSessionEvent(
                                "report_authored",
                                System.currentTimeMillis(),
                                bundleID = outcome.id,
                            ),
                        )
                        message =
                            "Signed synthetic test report saved locally: ${outcome.id.take(12)}"
                    }
                    else ->
                        message =
                            "Test report was not saved: ${if(outcome is StoreOutcome.Rejected) outcome.reason else "duplicate"}."
                }
                refresh()
            } catch (e: ReportStoreException) {
                storageFailure(e)
            } catch (_: Exception) {
                message = "Signing or storage failed; no saved report was claimed."
            }
        }
    }

    fun refresh() {
        if (!ready) return
        scope.launch {
            try {
                saved = repository!!.syntheticTestEvidence(System::currentTimeMillis)
            } catch (e: ReportStoreException) {
                storageFailure(e)
            } catch (_: Exception) {
                message = "Saved report verification failed."
            }
        }
    }

    private fun storageFailure(e: ReportStoreException) {
        if (::coordinator.isInitialized)
            coordinator.pause(
                if (e.reason == StoreFailure.CLOCK) ReportSessionState.clockFailure
                else ReportSessionState.storageFailure,
            )
        message =
            if (e.reason == StoreFailure.CLOCK)
                "Clock moved backward. Confirm the correct clock before recovery."
            else "Stored report verification/storage failed. No success was inferred."
        leaveForeground()
    }

    suspend fun exportedLog(): String {
        val evidence = repository?.syntheticTestEvidence(System::currentTimeMillis) ?: emptyList()
        return diagnostics.export(
            "${Build.MANUFACTURER} ${Build.MODEL}",
            Build.VERSION.RELEASE,
            packageManager.getPackageInfo(packageName, 0).versionName ?: "development",
            null,
            if (::coordinator.isInitialized) coordinator.sessionID else null,
            state,
            evidence,
        )
    }

    fun recoverClockAfterConfirmation() {
        val repo = repository ?: return
        // Invalidate loaded report frames before quarantine begins. Keep this bound
        // service alive so the recovery transaction can finish after radio shutdown.
        if (::coordinator.isInitialized) coordinator.stop()
        preferences.edit().putBoolean("open_intent", false).commit()
        leaveForeground()
        scope.launch {
            try {
                repo.recoverClockAfterUserConfirmation(System::currentTimeMillis)
                message = "Clock recovery confirmed. Existing reports are quarantined history."
                refresh()
            } catch (e: ReportStoreException) {
                storageFailure(e)
            }
        }
    }

    fun cleanupAfterConfirmation() {
        if (!ready) return
        val repo = repository ?: return
        scope.launch {
            try {
                val count = repo.reclaimExpiredReportsAfterUserConfirmation(System::currentTimeMillis)
                message = "Removed $count expired records after confirmation."
                refresh()
            } catch (e: ReportStoreException) {
                storageFailure(e)
            }
        }
    }

    fun neededPermissions(): List<String> =
        (requiredPermissions() + extraPermissions).distinct().filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }

    private fun bluetoothEnabled() =
        try {
            getSystemService(BluetoothManager::class.java).adapter?.isEnabled == true
        } catch (_: SecurityException) {
            false
        }

    private fun leaveForeground() {
        if (promoted) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            promoted = false
        }
    }

    override fun onDestroy() {
        if (::coordinator.isInitialized) coordinator.stop()
        handler.removeCallbacks(ticker)
        unregisterReceiver(bluetoothReceiver)
        val repo = repository
        scope.cancel()
        if (repo != null) CoroutineScope(Dispatchers.IO).launch { repo.close() }
        super.onDestroy()
    }

    companion object {
        const val ACTION_START = "org.trailmesh.app.START_REPORT_SESSION"
        const val ACTION_RESUME = "org.trailmesh.app.RESUME_REPORT_SESSION"
        const val ACTION_STOP = "org.trailmesh.app.STOP_REPORT_SESSION"
        private const val CHANNEL = "public_report_session"
        val TEST_CONTEXT = RelevanceContext(manualArea = Area(GeoPoint(426977000, 233219000), 5000))

        fun requiredPermissions(): List<String> =
            ReportNearbyPermissions.required(Build.VERSION.SDK_INT)
    }
}
