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
open class ReportSessionService : Service() {
    protected open val fieldSession = false

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
    private var opening: Job? = null
    private var pendingFieldPlan: FieldSessionPlan? = null
    internal var fieldPlan: FieldSessionPlan? = null
        private set
    internal var fieldStarting = false
        private set
    internal var stopRevision = 0L
        private set
    private var extraPermissions = emptyList<String>()
    private lateinit var coordinator: ReportSessionCoordinator
    private val preferences by lazy {
        getSharedPreferences(if (fieldSession) "field-report-session" else "public-report-session", MODE_PRIVATE)
    }
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
                    if (state != ReportSessionState.active && promoted) {
                        leaveForeground()
                        if (fieldSession) stopSelf()
                    }
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
                    if (fieldSession) stopSelf()
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
        opening = scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    repository = if (fieldSession) ProductReportAccess.open(this@ReportSessionService)
                        else ProductReportAccess.openDiagnostics(this@ReportSessionService)
                }
                if (!fieldSession) signer = ProductReportAccess.signer(this@ReportSessionService, diagnostic = true)
                val radio =
                    NearbyReportRadio(
                        this@ReportSessionService,
                        { coordinator },
                        {
                            extraPermissions = it
                            message =
                                "Nearby requires additional Location permission. Tap Resume to allow it."
                        },
                        if (fieldSession) ReportAdvertisement.FIELD_SERVICE else ReportAdvertisement.SERVICE,
                        { ReportRadioOwner.isOwnedBy(this@ReportSessionService) },
                    )
                coordinator =
                    ReportSessionCoordinator(
                        radio,
                        { context ->
                            SelectedRepositoryExchangeStore(
                                repository!!,
                                context,
                                System::currentTimeMillis,
                                productOnly = fieldSession,
                            )
                        },
                        scope,
                        System::currentTimeMillis,
                        SystemClock::elapsedRealtime,
                        event = { event -> if (!fieldSession) diagnostics.record(event) },
                        reportCommitted = { if (fieldSession) FieldReportUpdates.publish() },
                        recordSyntheticEvidence = !fieldSession,
                    )
                ready = true
                message =
                    if (canResume) "Interrupted session. Explicit Resume is required."
                    else if (fieldSession) "Ready to share public reports."
                    else "Ready. Synthetic Sofia test area; no radio session running."
                refresh()
            } catch (cancelled: CancellationException) {
                throw cancelled
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
        when (val action = intent?.action) {
            ACTION_START, ACTION_RESUME, ACTION_START_FIELD ->
                launchRequestedSession(action, intent.getBooleanExtra("consent", false))
            ACTION_STOP -> stopSharing()
            else -> if (!promoted && !fieldStarting) stopSelf()
        }
        return START_NOT_STICKY
    }

    /** Route and consent are submitted through the in-process binder, never an Intent extra. */
    internal fun startFieldSharing(plan: FieldSessionPlan) {
        if (!fieldSession || !ready || state == ReportSessionState.active || fieldStarting) return
        if (!ReportRadioOwner.acquire(this)) {
            coordinator.pause(ReportSessionState.interrupted)
            message = "Another Nearby session is running. Stop it first."
            return
        }
        pendingFieldPlan = plan
        fieldStarting = true
        try {
            startForegroundService(Intent(this, javaClass).setAction(ACTION_START_FIELD))
        } catch (_: IllegalStateException) {
            cancelQueuedStart(ReportSessionState.interrupted, "Open TrailMesh to start sharing.")
        } catch (_: SecurityException) {
            cancelQueuedStart(ReportSessionState.permissionDenied, "Nearby permission is required.")
        }
    }

    private fun cancelQueuedStart(state: ReportSessionState, explanation: String) {
        pendingFieldPlan = null
        fieldStarting = false
        coordinator.pause(state)
        message = explanation
        leaveForeground()
    }

    private fun launchRequestedSession(action: String, consent: Boolean) {
        val plan = pendingFieldPlan
        pendingFieldPlan = null
        fieldStarting = false
        try {
            // Fulfill Android's foreground obligation even if Stop canceled the plan or
            // the radio changed after the request. Discovery starts only after validation.
            if (!promoted) promote()
            if (fieldSession && action == ACTION_START_FIELD && plan != null) {
                fieldPlan = plan
                activate(plan.context, true)
            } else if (!fieldSession && action != ACTION_START_FIELD) {
                activate(TEST_CONTEXT, consent)
            }
        } catch (_: SecurityException) {
            if (::coordinator.isInitialized) coordinator.pause(ReportSessionState.permissionDenied)
            message = "Nearby or foreground permission denied."
        } catch (_: Exception) {
            if (::coordinator.isInitialized) coordinator.pause(ReportSessionState.radioUnavailable)
            message = "Radio session could not start. Check settings, then Resume."
        } finally {
            if (state != ReportSessionState.active) {
                leaveForeground()
                stopSelf()
            }
        }
    }

    private fun activate(context: RelevanceContext, consent: Boolean) {
        if (state == ReportSessionState.active) return
        if (!ready) {
            message = "Storage is still opening. Tap Start again when ready."
            return
        }
        if (!consent) {
            coordinator.start(context, false)
            message = "Public sharing consent is required."
            return
        }
        if (neededPermissions().isNotEmpty()) {
            coordinator.pause(ReportSessionState.permissionDenied)
            message = "Nearby permissions denied. Allow them, then Resume."
            return
        }
        if (!bluetoothEnabled()) {
            coordinator.pause(ReportSessionState.radioUnavailable)
            message = "Bluetooth is off. Enable it, then Resume."
            return
        }
        if (!ReportRadioOwner.acquire(this)) {
            coordinator.pause(ReportSessionState.interrupted)
            message = "Another Nearby session is running. Stop it first."
            return
        }
        if (!preferences.edit().putBoolean("open_intent", true).commit()) {
            coordinator.pause(ReportSessionState.storageFailure)
            message = "Could not save session intent."
            return
        }
        coordinator.start(context, true)
        if (state != ReportSessionState.active) {
            message = "Public sharing paused (${state.name}). Check permissions/radio and Resume."
            return
        }
        message =
            if (fieldSession) "Public report exchange is running."
            else "Public session active. Reports/inventories are visible to nearby unverified participants; signatures protect report integrity, not a person's identity."
    }

    private fun promote() {
        val notification =
            Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_upload_done)
                .setContentTitle(if (fieldSession) "TrailMesh Nearby" else "TrailMesh report diagnostics")
                .setContentText("Stop the public report session at any time.")
                .setContentIntent(
                    PendingIntent.getActivity(
                        this,
                        0,
                        Intent(this, org.trailmesh.app.MainActivity::class.java).apply {
                            if (fieldSession) {
                                action = OPEN_NEARBY
                                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                            }
                        },
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
                                Intent(this, javaClass).setAction(ACTION_STOP),
                                PendingIntent.FLAG_UPDATE_CURRENT or
                                    PendingIntent.FLAG_IMMUTABLE,
                            ),
                        )
                        .build(),
                )
                .build()
        val notificationId = if (fieldSession) 43 else 42
        if (Build.VERSION.SDK_INT >= 29)
            startForeground(
                notificationId,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        else startForeground(notificationId, notification)
        promoted = true
    }

    fun stopSharing() {
        stopRevision += 1
        pendingFieldPlan = null
        fieldPlan = null
        if (::coordinator.isInitialized) coordinator.stop()
        preferences.edit().putBoolean("open_intent", false).commit()
        leaveForeground()
        message = "Stopped. Committed reports remain saved locally."
        if (!fieldStarting) stopSelf()
    }

    fun createSyntheticReport() {
        if (fieldSession || !ready) return
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
        if (fieldSession || !ready) return
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
        check(!fieldSession)
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
        pendingFieldPlan = null
        fieldPlan = null
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

    internal fun bluetoothEnabled() =
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
        ReportRadioOwner.release(this)
    }

    override fun onDestroy() {
        if (::coordinator.isInitialized) coordinator.stop()
        handler.removeCallbacks(ticker)
        unregisterReceiver(bluetoothReceiver)
        leaveForeground()
        val initialLoad = opening
        scope.cancel()
        CoroutineScope(Dispatchers.IO).launch {
            initialLoad?.join()
            repository?.close()
        }
        super.onDestroy()
    }

    companion object {
        const val ACTION_START = "org.trailmesh.app.START_REPORT_SESSION"
        const val ACTION_RESUME = "org.trailmesh.app.RESUME_REPORT_SESSION"
        const val ACTION_STOP = "org.trailmesh.app.STOP_REPORT_SESSION"
        const val OPEN_NEARBY = "org.trailmesh.app.OPEN_FIELD_NEARBY"
        private const val ACTION_START_FIELD = "org.trailmesh.app.START_FIELD_REPORT_SESSION"
        private const val CHANNEL = "public_report_session"
        val TEST_CONTEXT = RelevanceContext(manualArea = Area(GeoPoint(426977000, 233219000), 5000))

        fun requiredPermissions(): List<String> =
            ReportNearbyPermissions.required(Build.VERSION.SDK_INT)
    }
}

class FieldReportSessionService : ReportSessionService() {
    override val fieldSession = true
}

/** Both modes share one underlying Nearby client per app. */
private object ReportRadioOwner {
    private var owner: ReportSessionService? = null

    @Synchronized
    fun acquire(service: ReportSessionService): Boolean {
        if (owner != null && owner !== service) return false
        owner = service
        return true
    }

    @Synchronized
    fun isOwnedBy(service: ReportSessionService) = owner === service

    @Synchronized
    fun release(service: ReportSessionService) {
        if (owner === service) owner = null
    }
}
