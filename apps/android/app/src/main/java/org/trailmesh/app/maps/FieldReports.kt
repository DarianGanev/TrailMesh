package org.trailmesh.app.maps

import android.app.Activity
import android.app.AlertDialog
import android.app.Dialog
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Build
import android.view.Gravity
import android.text.InputFilter
import android.view.View
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.trailmesh.app.persistence.DiagnosticReportFixture
import org.trailmesh.app.persistence.ReportBounds
import org.trailmesh.app.persistence.ReportDraft
import org.trailmesh.app.persistence.ReportPage
import org.trailmesh.app.persistence.ReportPageCursor
import org.trailmesh.app.persistence.ReportRepository
import org.trailmesh.app.persistence.ReportStoreException
import org.trailmesh.app.persistence.StoreFailure
import org.trailmesh.app.persistence.StoreOutcome
import org.trailmesh.app.persistence.StoredReport
import org.trailmesh.app.session.ProductReportAccess
import org.trailmesh.app.session.ReportSessionCoordinator
import java.text.DateFormat
import java.util.Date

internal data class ReportPoint(val point: MapPoint, val accuracyM: Long)

internal class FieldReports(
    private val activity: Activity,
    private val scope: CoroutineScope,
    private val chooseMapPoint: ((ReportPoint) -> Unit) -> Unit,
    private val currentLocation: ((ReportPoint?) -> Unit) -> Unit,
    private val centerOn: (MapPoint) -> Unit,
    private val saved: () -> Unit,
) {
    private val application = activity.applicationContext
    private var saving = false
    private val activeReports = mutableMapOf<Dialog, () -> Unit>()

    fun refreshOpenReports() {
        activeReports.toMap().forEach { (dialog, refresh) ->
            if (dialog.isShowing) refresh()
        }
    }

    fun close() {
        activeReports.keys.toList().forEach { it.dismiss() }
        activeReports.clear()
    }

    private suspend fun <T> withRepository(block: suspend (ReportRepository) -> T): T =
        withContext(Dispatchers.IO) {
            // Open and close before returning across the dispatcher boundary, where an already
            // opened repository could otherwise be lost to prompt cancellation.
            val repository = ProductReportAccess.open(application)
            try { block(repository) } finally { repository.close() }
        }

    private fun registerRefresh(dialog: Dialog, refresh: () -> Unit, cleanup: () -> Unit) {
        activeReports[dialog] = refresh
        dialog.setOnDismissListener {
            activeReports.remove(dialog)
            cleanup()
        }
    }

    suspend fun page(bounds: ReportBounds, history: Boolean = false, cursor: ReportPageCursor? = null): ReportPage =
        withRepository { it.reportPage(System::currentTimeMillis, bounds, history, cursor, limit = 32) }

    fun fieldRows(rows: List<StoredReport>): List<StoredReport> = rows.filterNot {
        DiagnosticReportFixture.matches(it)
    }

    suspend fun mapRows(bounds: ReportBounds): List<StoredReport> =
        withRepository { repository ->
            collectCurrentMapReports { cursor ->
                repository.reportPage(System::currentTimeMillis, bounds, after = cursor, limit = 32)
            }
        }

    fun show(bounds: ReportBounds) {
        val panel = column()
        val filters = LinearLayout(activity)
        val rows = column()
        var history = false
        var next: ReportPageCursor? = null
        var currentPage: ReportPageCursor? = null
        var loading: Job? = null
        var displayGeneration = 0
        val dialog = Dialog(activity, android.R.style.Theme_Material_Light_NoActionBar)
        val back = action("‹  Explore") { dialog.dismiss() }.apply { setTextColor(ACCENT) }
        val header = LinearLayout(activity).apply { gravity = Gravity.CENTER_VERTICAL }
        header.addView(text("Trail reports").apply {
            textSize = 24f
            typeface = Typeface.DEFAULT_BOLD
            if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
        }, LinearLayout.LayoutParams(0, -2, 1f))
        header.addView(action("New report") {
            dialog.dismiss()
            newReport()
        }.apply {
            background = controlBackground(TINT, 9)
            setTextColor(ACCENT)
        })
        val screen = column().apply {
            setBackgroundColor(PAPER)
            setPadding(dp(14), dp(8), dp(14), dp(8))
            addView(back, LinearLayout.LayoutParams(-2, -2))
            addView(header)
            addView(scroll(panel, horizontalPadding = 0), LinearLayout.LayoutParams(-1, 0, 1f))
        }
        dialog.setContentView(screen)

        fun load(cursor: ReportPageCursor? = null) {
            currentPage = cursor
            val generation = ++displayGeneration
            loading?.cancel()
            next = null
            rows.removeAllViews()
            rows.addView(text("Loading reports..."))
            loading = scope.launch {
                try {
                    val result = page(bounds, history, cursor)
                    if (!dialog.isShowing || generation != displayGeneration) return@launch
                    val candidates = fieldRows(result.reports)
                    next = result.nextCursor.takeIf { result.hasMore }
                    do {
                        val now = System.currentTimeMillis()
                        val reports = candidates.filter { it.isCurrentAt(now) != history }
                        rows.removeAllViews()
                        if (reports.isEmpty()) {
                            rows.addView(text(if (result.hasMore) "No matching reports on this page."
                                else if (history) "No older reports in this area." else "No recent reports in this area."))
                        }
                        for (item in reports) {
                            rows.addView(action("${reportTitle(item)}\n${age(item.observedAt)}") {
                                details(item) { dialog.dismiss() }
                            }.apply {
                                gravity = Gravity.START or Gravity.CENTER_VERTICAL
                                minimumHeight = dp(66)
                            }, LinearLayout.LayoutParams(-1, -2))
                            rows.addView(View(activity).apply { setBackgroundColor(LINE) },
                                LinearLayout.LayoutParams(-1, dp(1)))
                        }
                        if (next != null) rows.addView(action("More reports") { load(next) })
                        val expiry = candidates.filter { it.isCurrentAt(now) }
                            .minOfOrNull { it.effectiveExpiresAt } ?: break
                        delay((expiry - now).coerceAtLeast(1L))
                    } while (dialog.isShowing && generation == displayGeneration)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    if (!dialog.isShowing || generation != displayGeneration) return@launch
                    rows.removeAllViews()
                    rows.addView(text(readError(error)))
                    rows.addView(action("Try again") { load(cursor) })
                }
            }
        }

        val recent = action("Recent") {}
        val older = action("History") {}
        fun selectHistory(showHistory: Boolean) {
            history = showHistory
            filterAppearance(recent, !showHistory)
            filterAppearance(older, showHistory)
            load()
        }
        recent.setOnClickListener { selectHistory(false) }
        older.setOnClickListener { selectHistory(true) }
        filters.addView(recent, LinearLayout.LayoutParams(0, -2, 1f))
        filters.addView(older, LinearLayout.LayoutParams(0, -2, 1f))
        panel.addView(filters)
        panel.addView(rows)
        registerRefresh(dialog, { load(currentPage) }, { loading?.cancel() })
        dialog.show()
        dialog.window?.let { window ->
            window.setLayout(-1, -1)
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
        }
        selectHistory(false)
    }

    fun details(report: StoredReport, beforeShowOnMap: () -> Unit = {}) {
        val time = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
        val location = if (report.accuracyM == 0L) "Accuracy unavailable" else "About ${report.accuracyM} m accuracy"
        val source = if (report.isLocal) "Created on this phone" else "Received on this phone"
        val status = text("")
        fun updateStatus(now: Long = System.currentTimeMillis()) {
            val state = when {
                report.isQuarantined -> "Held after a clock change"
                report.isCurrentAt(now) -> "Current"
                else -> "Expired"
            }
            status.text = "$state · $location"
        }
        updateStatus()
        val panel = column().apply {
            if (report.note.isNotBlank()) addView(text(report.note))
            addView(status)
            addView(text(
                "Observed ${time.format(Date(report.observedAt))}\n" +
                    "Saved on this phone ${time.format(Date(report.admittedAt))}\n" +
                    "Effective expiry ${time.format(Date(report.effectiveExpiresAt))}" +
                    (if (report.expiresAt != report.effectiveExpiresAt)
                        "\nPublished expiry ${time.format(Date(report.expiresAt))}" else "") +
                    "\n\n$source. Signature verified. Author identity and observation unverified.",
            ))
        }
        val dialog = AlertDialog.Builder(activity)
            .setTitle(reportTitle(report))
            .setView(scroll(panel))
            .setPositiveButton("Show on map") { _, _ ->
                beforeShowOnMap()
                centerOn(MapPoint(report.latE7, report.lonE7))
            }
            .setNegativeButton("Close", null)
            .show()
        var expiry: Job? = null
        fun refresh() {
            expiry?.cancel()
            val now = System.currentTimeMillis()
            updateStatus(now)
            expiry = if (report.isCurrentAt(now)) scope.launch {
                delay((report.effectiveExpiresAt - now).coerceAtLeast(1L))
                updateStatus()
            } else null
        }
        registerRefresh(dialog, ::refresh) { expiry?.cancel() }
        refresh()
    }

    fun newReport(locationMessage: String = "Choose where you saw the condition.") {
        if (saving) return
        val panel = column()
        panel.addView(text(locationMessage))
        val prompt = AlertDialog.Builder(activity)
            .setTitle("Report location")
            .setView(scroll(panel))
            .setNegativeButton("Cancel", null)
            .create()
        panel.addView(action("Use my location") {
            prompt.dismiss()
            currentLocation { point ->
                if (point != null) compose(point)
                else newReport("A recent location is unavailable. You can choose a point on the map.")
            }
        })
        panel.addView(action("Choose on map") {
            prompt.dismiss()
            chooseMapPoint(::compose)
        })
        prompt.show()
    }

    private fun compose(location: ReportPoint) {
        val panel = column()
        val categories = Spinner(activity).apply { contentDescription = "Report type" }
        val conditions = Spinner(activity).apply { contentDescription = "Condition" }
        fun choices(labels: List<String>) =
            ArrayAdapter(activity, android.R.layout.simple_spinner_dropdown_item, labels)
        categories.adapter = choices(TYPES.map { it.label })
        conditions.adapter = choices(TYPES.first().statuses.map(::display))
        categories.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, index: Int, id: Long) {
                conditions.adapter = choices(TYPES[index].statuses.map(::display))
            }
        }
        val notes = EditText(activity).apply {
            hint = "Optional note"
            filters = arrayOf(InputFilter.LengthFilter(480))
            minLines = 2
            maxLines = 4
        }
        panel.addView(text("Report type"))
        panel.addView(categories)
        panel.addView(text("Condition"))
        panel.addView(conditions)
        panel.addView(notes)
        panel.addView(text("This public report includes the chosen location and your note. Nearby hikers may receive it."))
        val status = text("")
        panel.addView(status)
        val dialog = AlertDialog.Builder(activity)
            .setTitle("New report")
            .setView(scroll(panel))
            .setPositiveButton("Save public report", null)
            .setNegativeButton("Cancel", null)
            .create()
        dialog.show()
        val submit = dialog.getButton(AlertDialog.BUTTON_POSITIVE)
        val cancel = dialog.getButton(AlertDialog.BUTTON_NEGATIVE)
        submit.setOnClickListener {
            if (saving) return@setOnClickListener
            val type = TYPES[categories.selectedItemPosition.coerceAtLeast(0)]
            val condition = type.statuses.getOrElse(conditions.selectedItemPosition) { type.statuses.first() }
            val note = notes.text.toString().trim()
            if (isDiagnosticReportNote(note)) {
                status.text = "This note starts with a reserved test label. Change the note and try again."
                return@setOnClickListener
            }
            val now = System.currentTimeMillis()
            val draft = ReportDraft(type.key, condition, now, location.point.latE7, location.point.lonE7,
                location.accuracyM, note, now + 86_400_000L)
            saving = true
            submit.isEnabled = false
            cancel.isEnabled = false
            dialog.setCancelable(false)
            status.text = "Saving..."
            scope.launch {
                try {
                    val signer = ProductReportAccess.signer(application)
                    val outcome = withRepository { it.author(draft, signer, System::currentTimeMillis) }
                    if (outcome is StoreOutcome.Stored) {
                        dialog.dismiss()
                        AlertDialog.Builder(activity).setMessage("Report saved on this phone.")
                            .setPositiveButton("Done", null).show()
                        saved()
                    } else status.text = "Report could not be saved. Check the note and try again."
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    status.text = readError(error)
                } finally {
                    saving = false
                    if (dialog.isShowing) {
                        submit.isEnabled = true
                        cancel.isEnabled = true
                        dialog.setCancelable(true)
                    }
                }
            }
        }
    }

    private fun text(value: String) = TextView(activity).apply {
        text = value
        textSize = 16f
        setTextColor(INK)
        setPadding(dp(4), dp(8), dp(4), dp(8))
    }

    private fun action(value: String, click: () -> Unit) = Button(activity).apply {
        text = value
        isAllCaps = false
        minimumHeight = dp(48)
        stateListAnimator = null
        setPadding(dp(10), dp(6), dp(10), dp(6))
        background = controlBackground(Color.TRANSPARENT, 8)
        setTextColor(INK)
        setOnClickListener { click() }
    }

    private fun column() = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    private fun filterAppearance(button: Button, selected: Boolean) {
        button.isSelected = selected
        button.setTextColor(if (selected) ACCENT else INK)
        button.background = controlBackground(if (selected) TINT else Color.TRANSPARENT, 8)
    }

    private fun controlBackground(color: Int, radius: Int) = RippleDrawable(
        ColorStateList.valueOf(0x18001D42), GradientDrawable().apply {
            setColor(color)
            cornerRadius = dp(radius).toFloat()
        }, null,
    )

    private fun scroll(content: View, horizontalPadding: Int = 20) = ScrollView(activity).apply {
        setPadding(dp(horizontalPadding), 0, dp(horizontalPadding), dp(8))
        addView(content, -1, -2)
    }
    private fun dp(value: Int) = (value * activity.resources.displayMetrics.density + 0.5f).toInt()

    fun reportTitle(item: StoredReport): String = "${display(item.category)} · ${display(item.status)}"

    private fun display(value: String) = value.replaceFirstChar { it.uppercase() }

    private fun age(time: Long): String {
        val minutes = ((System.currentTimeMillis() - time) / 60_000L).coerceAtLeast(0L)
        return when {
            minutes == 0L -> "Just now"
            minutes < 60 -> "${minutes}m ago"
            minutes < 1440 -> "${minutes / 60}h ago"
            else -> DateFormat.getDateInstance().format(Date(time))
        }
    }

    private fun readError(error: Exception): String =
        if ((error as? ReportStoreException)?.reason == StoreFailure.CLOCK)
            "Check the device clock before continuing."
        else "Could not open or save reports. Try again."

    private data class ReportType(val key: String, val label: String, val statuses: List<String>)
    private companion object {
        val PAPER = Color.rgb(250, 251, 255)
        val INK = Color.rgb(24, 34, 51)
        val ACCENT = Color.rgb(31, 80, 158)
        val TINT = Color.rgb(229, 237, 249)
        val LINE = Color.rgb(210, 218, 229)
        val TYPES = listOf(
            ReportType("trail", "Trail condition", listOf("muddy", "icy", "damaged", "blocked", "good", "unknown")),
            ReportType("obstruction", "Obstruction", listOf("partial", "blocked", "clear", "unknown")),
            ReportType("water", "Water source", listOf("flowing", "low", "dry", "unknown")),
            ReportType("weather", "Weather", listOf("rain", "snow", "storm", "fog", "clear", "unknown")),
            ReportType("campsite", "Campsite", listOf("available", "occupied", "closed", "unknown")),
            ReportType("hut", "Hut", listOf("open", "closed", "unknown")),
            ReportType("crowding", "Crowding", listOf("quiet", "moderate", "busy", "unknown")),
            ReportType("note", "Other", listOf("observed", "unknown")),
        )
    }
}

private fun isDiagnosticReportNote(note: String) = note.startsWith(ReportSessionCoordinator.TEST_NOTE_PREFIX)

// One bounded verified transaction at a time. Filtering can leave a page empty
// while its raw cursor still reaches older, relevant reports.
internal suspend fun collectCurrentMapReports(
    clock: () -> Long = System::currentTimeMillis,
    load: suspend (ReportPageCursor?) -> ReportPage,
): List<StoredReport> {
    val reports = mutableListOf<StoredReport>()
    var cursor: ReportPageCursor? = null
    do {
        val page = load(cursor)
        val now = clock()
        reports += page.reports.asSequence()
            .filter { it.isCurrentAt(now) && !DiagnosticReportFixture.matches(it) }
            .take(96 - reports.size)
            .toList()
        cursor = page.nextCursor.takeIf { page.hasMore }
        if (cursor != null && reports.size < 96) {
            // Let queued exchange work run before verifying another page.
            delay(16)
        }
    } while (cursor != null && reports.size < 96)
    return reports
}
