package org.trailmesh.foregroundprobe

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.provider.Settings
import android.view.ViewGroup
import android.widget.*

/** UI observes a service-owned session; leaving this Activity does not stop that session. */
class MainActivity : Activity() {
    private lateinit var statusView: TextView
    private lateinit var progressView: TextView
    private lateinit var logView: TextView
    private lateinit var sizePicker: Spinner
    private lateinit var startButton: Button
    private lateinit var resumeButton: Button
    private lateinit var stopButton: Button
    private var service: ProbeSessionService? = null
    private var bound = false
    private var resumed = false
    private var pendingAction: String? = null
    private var pendingSize = 2048
    private var permissionInFlight = false
    private var compatibilityTicket = -1L
    private var notificationAsked = false
    private var pendingPermissionResult: Pair<Long, Boolean>? = null
    private var latest: ProbeSnapshot? = null
    private val observer: (ProbeSnapshot) -> Unit = { render(it) }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            service = (binder as ProbeSessionService.LocalBinder).session
            pendingPermissionResult?.let { (ticket, granted) ->
                pendingPermissionResult = null
                service!!.permissionResult(ticket, granted)
            }
            service!!.observe(observer)
        }
        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
            statusView.text = "Session process ended. Open this screen again to Resume saved progress."
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingAction = savedInstanceState?.getString("pending_action")
        pendingSize = savedInstanceState?.getInt("pending_size", 2048) ?: 2048
        permissionInFlight = savedInstanceState?.getBoolean("permission_in_flight") ?: false
        compatibilityTicket = savedInstanceState?.getLong("permission_ticket", -1L) ?: -1L
        notificationAsked = savedInstanceState?.getBoolean("notification_asked") ?: false
        savedInstanceState?.getLong("result_ticket", -1L)?.takeIf { it >= 0 }?.let {
            pendingPermissionResult = it to savedInstanceState.getBoolean("result_granted")
        }
        buildScreen()
    }

    override fun onStart() {
        super.onStart()
        bound = bindService(Intent(this, ProbeSessionService::class.java), connection, BIND_AUTO_CREATE)
    }
    override fun onResume() {
        super.onResume()
        resumed = true
        executePendingAction()
        latest?.let(::render)
    }
    override fun onPause() { resumed = false; super.onPause() }
    override fun onStop() {
        service?.removeObserver(observer)
        if (bound) unbindService(connection)
        bound = false
        service = null
        super.onStop()
    }
    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString("pending_action", pendingAction)
        outState.putInt("pending_size", pendingSize)
        outState.putBoolean("permission_in_flight", permissionInFlight)
        outState.putLong("permission_ticket", compatibilityTicket)
        outState.putBoolean("notification_asked", notificationAsked)
        pendingPermissionResult?.let { (ticket, granted) ->
            outState.putLong("result_ticket", ticket)
            outState.putBoolean("result_granted", granted)
        }
        super.onSaveInstanceState(outState)
    }

    private fun buildScreen() {
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 24, 24, 24)
            layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        }
        setContentView(ScrollView(this).apply { addView(content) })
        content.addView(TextView(this).apply { text = "TrailMesh transport test"; textSize = 22f })
        content.addView(TextView(this).apply {
            text = "Generated test bytes only. A started session automatically accepts compatible probes without verifying Nearby's code. Do not send reports, messages, or private data."
            setPadding(0, 12, 0, 12)
        })
        content.addView(TextView(this).apply {
            text = "Start on both phones with the same size. Each pair sends 20 payloads in both directions. Android can exchange with Android or iPhone; iPhone pairs with Android. Internet access is not required. Keep Bluetooth enabled; Nearby selects the underlying link."
            setPadding(0, 0, 0, 12)
        })
        sizePicker = Spinner(this).apply {
            adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item,
                listOf("256 bytes", "2 KiB (required gate)", "8 KiB"))
            setSelection(1)
        }
        content.addView(sizePicker)
        startButton = Button(this).apply {
            text = "Start new test session"
            setOnClickListener { requestSession(ProbeSessionService.ACTION_START) }
        }
        content.addView(startButton)
        resumeButton = Button(this).apply {
            text = "Resume saved session"; isEnabled = false
            setOnClickListener { requestSession(ProbeSessionService.ACTION_RESUME) }
        }
        content.addView(resumeButton)
        stopButton = Button(this).apply {
            text = "Stop session"
            setOnClickListener { pendingAction = null; service?.stopByUser() }
        }
        content.addView(stopButton)
        content.addView(Button(this).apply {
            text = "Bluetooth settings"
            setOnClickListener { startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS)) }
        })
        content.addView(Button(this).apply {
            text = "App permissions and battery settings"
            setOnClickListener { startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.parse("package:$packageName"))) }
        })
        content.addView(Button(this).apply {
            text = "Share redacted test log"
            setOnClickListener {
                val text = service?.exportedLog() ?: return@setOnClickListener
                startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"; putExtra(Intent.EXTRA_TEXT, text)
                }, "Share transport test log"))
            }
        })
        content.addView(TextView(this).apply {
            text = "The active session has a Stop notification and continues when you switch apps. Screen-off behavior depends on the phone and must be measured. After process termination, return here and choose Resume. If Nearby asks for Location, this probe does not read coordinates."
            setPadding(0, 12, 0, 12)
        })
        statusView = TextView(this).apply { text = "Loading saved session…"; textSize = 18f }
        progressView = TextView(this).apply { setPadding(0, 12, 0, 12) }
        logView = TextView(this).apply { textSize = 12f; setTextIsSelectable(true) }
        content.addView(statusView); content.addView(progressView); content.addView(logView)
    }

    private fun requestSession(action: String) {
        if (permissionInFlight) return
        pendingAction = action
        pendingSize = when (sizePicker.selectedItemPosition) { 0 -> 256; 2 -> 8192; else -> 2048 }
        val granted = NearbyPermissionPolicy.requiredPermissions(Build.VERSION.SDK_INT).filter {
            checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }.toSet()
        val missing = NearbyPermissionPolicy.permissionsToRequest(Build.VERSION.SDK_INT, granted)
        if (missing.isNotEmpty()) {
            permissionInFlight = true
            requestPermissions(missing.toTypedArray(), REQUEST_NEARBY)
            statusView.text = "Allow Nearby device permissions to start the test."
        } else executePendingAction()
    }

    private fun executePendingAction() {
        if (!resumed || permissionInFlight) return
        val action = pendingAction ?: return
        pendingAction = null
        try {
            startForegroundService(Intent(this, ProbeSessionService::class.java).setAction(action)
                .putExtra(ProbeSessionService.EXTRA_SIZE, pendingSize))
            if (Build.VERSION.SDK_INT >= 33 && !notificationAsked &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                notificationAsked = true
                permissionInFlight = true
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATION)
            }
        } catch (_: Exception) {
            statusView.text = "Session could not start. Check permissions, then try while this screen is open."
        }
    }

    private fun render(snapshot: ProbeSnapshot) {
        latest = snapshot
        statusView.text = snapshot.status
        startButton.isEnabled = !snapshot.active && !permissionInFlight
        resumeButton.isEnabled = snapshot.canResume && !permissionInFlight
        stopButton.isEnabled = snapshot.active || snapshot.canResume || pendingAction != null
        sizePicker.isEnabled = !snapshot.active
        progressView.text = snapshot.checkpoint?.let { checkpoint ->
            "${checkpoint.payloadSize} bytes; ${checkpoint.peers.size}/8 peers recorded\n" +
                checkpoint.peers.mapIndexed { index, peer ->
                    "Peer ${index + 1} (${peer.platform}): sent ${peer.successfulOutgoing} matched, ${peer.failedOutgoing} failed; " +
                        "received ${peer.receivedAccepted} unique matches" +
                        when { peer.complete -> "; both directions finished"; peer.exhausted -> "; recovery exhausted"; else -> "" }
                }.joinToString("\n")
        } ?: "No saved session"
        logView.text = snapshot.checkpoint?.events?.takeLast(40)?.joinToString("\n") {
            "${it.time} ${it.name} ${it.fields.entries.joinToString(" ") { field -> "${field.key}=${field.value}" }}"
        }.orEmpty()
        if (resumed && !permissionInFlight && snapshot.active && snapshot.permissionsNeeded.isNotEmpty()) {
            compatibilityTicket = snapshot.permissionTicket
            permissionInFlight = true
            requestPermissions(snapshot.permissionsNeeded.toTypedArray(), REQUEST_COMPATIBILITY)
        }
    }

    @Deprecated("Platform permission callback retained for the small probe UI.")
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            REQUEST_NEARBY -> {
                permissionInFlight = false
                val granted = NearbyPermissionPolicy.requiredPermissions(Build.VERSION.SDK_INT).all {
                    checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
                }
                if (granted) executePendingAction()
                else { pendingAction = null; statusView.text = "Required device permission denied. Allow it in App settings and retry." }
            }
            REQUEST_COMPATIBILITY -> {
                permissionInFlight = false
                val ticket = compatibilityTicket
                compatibilityTicket = -1L
                val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
                if (service != null) service!!.permissionResult(ticket, granted)
                else pendingPermissionResult = ticket to granted
            }
            REQUEST_NOTIFICATION -> { permissionInFlight = false; latest?.let(::render) }
        }
    }

    companion object {
        private const val REQUEST_NEARBY = 41
        private const val REQUEST_COMPATIBILITY = 42
        private const val REQUEST_NOTIFICATION = 43
    }
}
