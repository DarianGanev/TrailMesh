package org.trailmesh.app

import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.os.*
import android.widget.*
import kotlinx.coroutines.*
import org.trailmesh.app.session.*

/** Temporary development panel. Hiking workflows and operational maps remain deferred. */
class MainActivity : Activity() {
    private var session: ReportSessionService? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var status: TextView
    private lateinit var saved: TextView
    private lateinit var consent: CheckBox
    private lateinit var start: Button
    private lateinit var resume: Button
    private lateinit var create: Button
    private var pendingExport: String? = null
    private val connection =
        object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                session = (binder as ReportSessionService.LocalBinder).session
                render()
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                session = null
                render()
            }
        }
    private val updater =
        object : Runnable {
            override fun run() {
                render()
                handler.postDelayed(this, 500)
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE == 0) {
            setContentView(
                TextView(this).apply {
                    text =
                        "TrailMesh development product. Public test controls are unavailable in release builds."
                },
            )
            return
        }
        val container =
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(20), dp(24), dp(20), dp(24))
            }
        fun text(value: String, size: Float = 16f) =
            TextView(this).apply {
                text = value
                textSize = size
                setPadding(0, dp(6), 0, dp(6))
                container.addView(this)
            }
        text("TrailMesh | Signed report test", 24f)
        text(
            "DEVELOPMENT ONLY | Synthetic Sofia area (5 km). This panel does not show an operational map. Start never creates a report.",
        )
        status = text("Opening...")
        consent =
            CheckBox(this).apply {
                text =
                    "I agree to public sharing: reports and inventories are visible to nearby unverified participants. Signatures protect report integrity, not a person's identity. Routes, interests and private content are never sent."
                minHeight = dp(48)
                container.addView(this)
            }
        fun button(label: String, action: () -> Unit) =
            Button(this).apply {
                text = label
                minHeight = dp(48)
                setOnClickListener { action() }
                container.addView(this, LinearLayout.LayoutParams(-1, -2))
            }
        start = button("Start public test session") { requestStart(false) }
        resume = button("Resume interrupted session") { requestStart(true) }
        button("Stop sharing") {
            session?.stopSharing()
            render()
        }
        create = button("Create signed synthetic test report") { session?.createSyntheticReport() }
        button("Refresh saved test reports") { session?.refresh() }
        saved = text("No saved test reports loaded.")
        button("Export redacted diagnostics") {
            scope.launch {
                try {
                    pendingExport = session?.exportedLog() ?: return@launch
                    startActivityForResult(
                        Intent(Intent.ACTION_CREATE_DOCUMENT)
                            .addCategory(Intent.CATEGORY_OPENABLE)
                            .setType("application/json")
                            .putExtra(
                                Intent.EXTRA_TITLE,
                                "trailmesh-report-session-${System.currentTimeMillis()}.json",
                            ),
                        EXPORT,
                    )
                } catch (_: Exception) {
                    Toast.makeText(
                            this@MainActivity,
                            "Verified diagnostic export failed. No export was created.",
                            Toast.LENGTH_LONG,
                        )
                        .show()
                }
            }
        }
        button("Confirm clock recovery...") {
            AlertDialog.Builder(this)
                .setTitle("Confirm corrected clock")
                .setMessage(
                    "Only continue after confirming the device clock is correct. Existing reports become quarantined history and cannot be forwarded.",
                )
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Clock is correct; recover") { _, _ ->
                    session?.recoverClockAfterConfirmation()
                }
                .show()
        }
        button("Delete expired history...") {
            AlertDialog.Builder(this)
                .setTitle("Confirm clock and cleanup")
                .setMessage(
                    "Confirm the device clock is accurate and delete expired stored history. This cannot be undone.",
                )
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Clock is correct; delete") { _, _ ->
                    session?.cleanupAfterConfirmation()
                }
                .show()
        }
        text(
            "Android uses a user-started connected-device foreground service. Actual screen-off behavior depends on device, OS and permissions and has not been established for signed reports. SDK send completion and peer RECEIVED claims never prove final delivery.",
        )
        setContentView(
            ScrollView(this).apply {
                addView(container)
                fitsSystemWindows = true
            },
        )
        window.decorView.setOnApplyWindowInsetsListener { view, insets ->
            view.setPadding(
                insets.systemWindowInsetLeft,
                insets.systemWindowInsetTop,
                insets.systemWindowInsetRight,
                insets.systemWindowInsetBottom,
            )
            insets
        }
        bindService(Intent(this, ReportSessionService::class.java), connection, BIND_AUTO_CREATE)
        handler.post(updater)
    }

    private fun dp(n: Int) = (resources.displayMetrics.density * n).toInt()

    private fun render() {
        if (!::status.isInitialized) return
        val s = session
        val statusText =
            "${s?.state?.name ?: "connecting"} | ${s?.links ?: 0}/4 links | ${s?.waiting ?: 0} waiting\n${s?.message ?: "Opening protected storage..."}"
        if (status.text.toString() != statusText) status.text = statusText
        start.isEnabled = s?.ready == true && s.state != ReportSessionState.active
        resume.isEnabled = s?.ready == true && s.canResume
        create.isEnabled = s?.ready == true
        val savedText =
            s?.saved?.joinToString("\n", prefix = "Saved synthetic test reports (bounded):\n") {
                "${it.bundleID.take(16)} | saved locally | hops ${it.remainingHops}" +
                    (if (it.isQuarantined) " | quarantined"
                    else if (it.isExpired) " | expired" else " | current")
            } ?: "No saved test reports loaded."
        if (saved.text.toString() != savedText) saved.text = savedText
    }

    private fun requestStart(resume: Boolean) {
        if (!consent.isChecked) {
            Toast.makeText(this, "Public-sharing consent is required.", Toast.LENGTH_LONG).show()
            return
        }
        val needed =
            (session?.neededPermissions()
                    ?: ReportSessionService.requiredPermissions().filter {
                        checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
                    })
                .toMutableList()
        if (
            Build.VERSION.SDK_INT >= 33 &&
                checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                    PackageManager.PERMISSION_GRANTED
        )
            needed.add(android.Manifest.permission.POST_NOTIFICATIONS)
        if (needed.isNotEmpty()) {
            requestPermissions(
                needed.toTypedArray(),
                if (resume) RESUME_PERMISSION else START_PERMISSION,
            )
            return
        }
        startForegroundService(
            Intent(this, ReportSessionService::class.java)
                .setAction(
                    if (resume) ReportSessionService.ACTION_RESUME
                    else ReportSessionService.ACTION_START,
                )
                .putExtra("consent", true),
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != START_PERMISSION && requestCode != RESUME_PERMISSION) return
        if (
            (session?.neededPermissions()
                    ?: ReportSessionService.requiredPermissions().filter {
                        checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
                    })
                .isNotEmpty()
        ) {
            Toast.makeText(
                    this,
                    "Nearby permission denied. Allow it in Settings, then Resume or Start.",
                    Toast.LENGTH_LONG,
                )
                .show()
            return
        }
        // Notification denial alone does not authorize recreating a permission dialog repeatedly.
        if (consent.isChecked)
            startForegroundService(
                Intent(this, ReportSessionService::class.java)
                    .setAction(
                        if (requestCode == RESUME_PERMISSION) ReportSessionService.ACTION_RESUME
                        else ReportSessionService.ACTION_START,
                    )
                    .putExtra("consent", true),
            )
    }

    @Deprecated("Legacy document picker result")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != EXPORT) return
        val text = pendingExport
        pendingExport = null
        val uri = data?.data
        if (resultCode != RESULT_OK || text == null || uri == null) return
        scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    contentResolver.openOutputStream(uri)?.use {
                        it.write(text.toByteArray(Charsets.UTF_8))
                    } ?: error("document unavailable")
                }
                Toast.makeText(
                        this@MainActivity,
                        "Redacted verified diagnostics exported.",
                        Toast.LENGTH_LONG,
                    )
                    .show()
            } catch (_: Exception) {
                Toast.makeText(
                        this@MainActivity,
                        "Diagnostic export could not be saved.",
                        Toast.LENGTH_LONG,
                    )
                    .show()
            }
        }
    }

    override fun onDestroy() {
        handler.removeCallbacks(updater)
        if (::status.isInitialized)
            try {
                unbindService(connection)
            } catch (_: IllegalArgumentException) {}
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        private const val EXPORT = 11
        private const val START_PERMISSION = 12
        private const val RESUME_PERMISSION = 13
    }
}
