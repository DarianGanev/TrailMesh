package org.trailmesh.app.session

import android.Manifest.permission.ACCESS_FINE_LOCATION
import android.app.Activity
import android.app.AlertDialog
import android.app.Dialog
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.trailmesh.app.relevance.RelevanceContext
import kotlin.math.roundToInt

internal const val FIELD_NEARBY_PERMISSION_REQUEST = 22

/** Held only in process. The summary and geometry are never sent to the radio. */
internal data class FieldSessionPlan(val context: RelevanceContext, val summary: String)

internal object FieldReportUpdates {
    private val changes = MutableSharedFlow<Unit>(extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val committed = changes.asSharedFlow()
    fun publish() { changes.tryEmit(Unit) }
}

/** Opening the panel binds for status. Only an explicit consent action starts the service. */
internal class FieldSessionPanel(
    private val activity: Activity,
    private val scope: CoroutineScope,
    private val options: () -> List<FieldSessionPlan>,
    private val closed: () -> Unit,
) {
    private var dialog: Dialog? = null
    private var prompt: AlertDialog? = null
    private var watching: Job? = null
    private var service: FieldReportSessionService? = null
    private var binding = false
    private var connectionFailed = false
    private var approved: FieldSessionPlan? = null
    private var awaitingPermission = false
    private var stateView: TextView? = null
    private var detailView: TextView? = null
    private var primary: Button? = null
    private var secondary: Button? = null
    private var rendered: Screen? = null
    private val availablePlans by lazy(options)
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            service = (binder as? ReportSessionService.LocalBinder)?.session as? FieldReportSessionService
            connectionFailed = service == null
            refresh()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
            connectionFailed = true
            refresh()
        }
    }

    fun show() {
        if (dialog?.isShowing == true) return
        val page = Dialog(activity, android.R.style.Theme_Material_Light_NoActionBar)
        dialog = page
        val body = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(12), dp(20), dp(24))
            setBackgroundColor(PAPER)
            addView(action("‹  Explore") { page.dismiss() }, LinearLayout.LayoutParams(-2, -2))
            addView(text("Nearby", 30f, bold = true))
            stateView = text("", 22f, bold = true).also {
                it.accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
                addView(it, margin(top = 28))
            }
            detailView = text("", 16f).also { addView(it, margin(top = 8)) }
            primary = action("", prominent = true) {}.also { addView(it, margin(top = 22)) }
            secondary = action("") {}.also { addView(it, margin(top = 6)) }
        }
        page.setContentView(ScrollView(activity).apply {
            setBackgroundColor(PAPER)
            isFillViewport = true
            addView(body, -1, -2)
        })
        page.setOnDismissListener { detach(); closed() }
        page.show()
        page.window?.let { window ->
            window.setLayout(-1, -1)
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
        }
        connect()
        watching = scope.launch {
            while (isActive) {
                refresh()
                delay(300L)
            }
        }
    }

    fun permissionsResult() {
        if (!awaitingPermission || dialog?.isShowing != true) return
        awaitingPermission = false
        // A canceled or denied system prompt never starts a radio session.
        if (service?.neededPermissions()?.isEmpty() == true) startApproved()
        refresh()
    }

    fun close() {
        dialog?.dismiss()
        detach()
    }

    private fun detach() {
        watching?.cancel()
        watching = null
        prompt?.dismiss()
        prompt = null
        if (binding) activity.unbindService(connection)
        binding = false
        service = null
        dialog = null
        approved = null
        awaitingPermission = false
        rendered = null
    }

    private fun connect() {
        if (binding) activity.unbindService(connection)
        service = null
        binding = activity.bindService(
            Intent(activity, FieldReportSessionService::class.java), connection, Context.BIND_AUTO_CREATE,
        )
        connectionFailed = !binding
        refresh()
    }

    private fun choosePlan() {
        val choices = availablePlans
        if (choices.isEmpty()) return
        prompt = AlertDialog.Builder(activity)
            .setTitle("Choose which reports to share")
            .setItems(choices.map { it.summary }.toTypedArray()) { _, index -> confirm(choices[index]) }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun confirm(plan: FieldSessionPlan) {
        prompt = AlertDialog.Builder(activity)
            .setTitle("Start Nearby sharing?")
            .setMessage("${plan.summary}\n\nNearby TrailMesh users can receive eligible public reports, including report locations and notes. Your route and selected area stay on this phone. The session runs until you stop it or Android interrupts it.")
            .setPositiveButton("Start sharing") { _, _ ->
                approved = plan
                startApproved()
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun startApproved() {
        val owner = service ?: return
        val plan = approved ?: owner.fieldPlan ?: return
        if (dialog?.isShowing != true || awaitingPermission) return
        val missing = owner.neededPermissions()
        if (missing.isNotEmpty()) {
            awaitingPermission = true
            val permissions = ReportNearbyPermissions.forRequest(Build.VERSION.SDK_INT, missing)
            activity.requestPermissions(permissions.toTypedArray(), FIELD_NEARBY_PERMISSION_REQUEST)
        } else if (owner.bluetoothEnabled()) {
            owner.startFieldSharing(plan)
        }
        refresh()
    }

    private fun settings(action: String) {
        val intent = if (action == Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            Intent(action, Uri.fromParts("package", activity.packageName, null))
            else Intent(action)
        try { activity.startActivity(intent) } catch (_: ActivityNotFoundException) { Unit }
    }

    private fun confirmClockRecovery() {
        prompt = AlertDialog.Builder(activity)
            .setTitle("Confirm the device clock")
            .setMessage("Check the date and time before continuing. Existing reports will become history and will no longer be shared as current.")
            .setPositiveButton("Clock is correct") { _, _ ->
                approved = null
                service?.recoverClockAfterConfirmation()
                refresh()
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun refresh() {
        val owner = service
        val consented = approved != null || owner?.fieldPlan != null
        val missingPermissions = owner?.neededPermissions().orEmpty()
        val screen = when {
            connectionFailed -> Screen("Nearby unavailable", "Open Nearby again to retry.", "Retry", Command.Connect)
            owner == null -> Screen("Opening Nearby", "Connecting to the report store.")
            !owner.ready -> Screen(
                if (owner.message.startsWith("Opening")) "Opening Nearby" else "Report storage unavailable",
                owner.message,
            )
            owner.state == ReportSessionState.active -> Screen(
                "Nearby session active",
                "${owner.fieldPlan?.summary.orEmpty()}\n\nKeep TrailMesh open for Nearby exchange. Background and screen-off exchange depend on your device and have not been verified.",
                "Stop sharing", Command.Stop,
            )
            owner.fieldStarting || awaitingPermission -> Screen("Starting Nearby", "Waiting for Android.")
            owner.state == ReportSessionState.clockFailure -> Screen(
                "Sharing paused", "The device clock moved backward. Check the date and time before recovering.",
                "Check clock", Command.Clock, if (consented) "Stop sharing" else null,
            )
            owner.state == ReportSessionState.storageFailure -> Screen(
                "Sharing paused", "The report store couldn't verify or save data.",
                "Stop sharing", Command.Stop,
            )
            missingPermissions.isNotEmpty() && consented -> Screen(
                "Nearby permission needed",
                if (ACCESS_FINE_LOCATION in missingPermissions)
                    "Android Nearby requires precise Location access on this device. Your live location stays on this phone."
                else "Allow the requested access in Settings or try the permission prompt again.",
                "Try again", Command.Resume, "Settings",
            )
            missingPermissions.isEmpty() && !owner.bluetoothEnabled() -> Screen(
                "Bluetooth is off or unavailable", "Turn on Bluetooth before starting or resuming sharing.",
                "Bluetooth settings", Command.Bluetooth, if (consented || owner.canResume) "Stop sharing" else null,
            )
            consented || owner.canResume -> Screen(
                if (owner.canResume && owner.fieldPlan == null && !consented) "Session interrupted" else "Sharing paused",
                if (owner.fieldPlan == null && !consented) "Choose an area or route to start sharing again."
                else if (owner.state == ReportSessionState.radioUnavailable) "Nearby couldn't start or continue. Check the connection and try again."
                else if (owner.state == ReportSessionState.interrupted) owner.message
                else "Open TrailMesh when starting or resuming a session.",
                if (consented) "Resume sharing" else "Set up sharing",
                if (consented) Command.Resume else Command.Choose,
                "Stop sharing",
            )
            availablePlans.isEmpty() -> Screen(
                "Choose a map area", "Open a downloaded map before starting a Nearby session.",
            )
            else -> Screen(
                if (owner.message.startsWith("Stopped")) "Sharing stopped" else "Ready to share",
                "Share trail reports with nearby hikers. You can stop at any time.",
                "Set up sharing", Command.Choose,
            )
        }
        if (rendered == screen) return
        rendered = screen
        stateView?.text = screen.title
        detailView?.text = screen.detail
        primary?.let { button ->
            button.visibility = if (screen.primary == null) View.GONE else View.VISIBLE
            button.text = screen.primary.orEmpty()
            button.setOnClickListener {
                when (screen.command) {
                    Command.Choose -> choosePlan()
                    Command.Resume -> startApproved()
                    Command.Stop -> stop()
                    Command.Clock -> confirmClockRecovery()
                    Command.Bluetooth -> settings(Settings.ACTION_BLUETOOTH_SETTINGS)
                    Command.Connect -> connect()
                    null -> Unit
                }
            }
        }
        secondary?.let { button ->
            button.visibility = if (screen.secondary == null) View.GONE else View.VISIBLE
            button.text = screen.secondary.orEmpty()
            button.setOnClickListener {
                if (screen.secondary == "Settings") settings(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                else stop()
            }
        }
    }

    private fun stop() {
        approved = null
        awaitingPermission = false
        service?.stopSharing()
        refresh()
    }

    private fun text(value: String, size: Float, bold: Boolean = false) = TextView(activity).apply {
        text = value
        textSize = size
        setTextColor(INK)
        if (bold) typeface = Typeface.DEFAULT_BOLD
        if (size == 30f && Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
    }

    private fun action(value: String, prominent: Boolean = false, click: () -> Unit) = Button(activity).apply {
        text = value
        isAllCaps = false
        minimumHeight = dp(48)
        stateListAnimator = null
        setPadding(dp(14), dp(8), dp(14), dp(8))
        setTextColor(if (prominent) Color.WHITE else ACCENT)
        background = RippleDrawable(ColorStateList.valueOf(if (prominent) 0x33FFFFFF else 0x190E4185),
            GradientDrawable().apply {
                setColor(if (prominent) ACCENT else PAPER)
                cornerRadius = dp(10).toFloat()
            }, null)
        setOnClickListener { click() }
    }

    private fun margin(top: Int) = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(top) }
    private fun dp(value: Int) = (value * activity.resources.displayMetrics.density).roundToInt()

    private data class Screen(
        val title: String,
        val detail: String,
        val primary: String? = null,
        val command: Command? = null,
        val secondary: String? = null,
    )

    private enum class Command { Choose, Resume, Stop, Clock, Bluetooth, Connect }

    private companion object {
        val PAPER = Color.rgb(250, 251, 255)
        val INK = Color.rgb(24, 34, 51)
        val ACCENT = Color.rgb(31, 80, 158)
    }
}
