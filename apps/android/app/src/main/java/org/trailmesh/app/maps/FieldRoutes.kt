package org.trailmesh.app.maps

import android.app.Activity
import android.app.AlertDialog
import android.location.Location
import android.widget.LinearLayout
import android.widget.TextView
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import java.util.concurrent.ExecutionException
import kotlin.math.roundToInt

/** Main-thread route selection retained independently of any Activity, map or worker. */
internal class FieldRouteSession {
    var origin: MountainPlace? = null
    var destination: MountainPlace? = null
    var route: HikingRoute? = null
    var maximumGrade = RouteParser.DEFAULT_HIKING_DIFFICULTY
    var following = false

    fun clear() {
        origin = null
        destination = null
        route = null
        maximumGrade = RouteParser.DEFAULT_HIKING_DIFFICULTY
        following = false
    }
}

internal class FieldRoutes(
    private val activity: Activity,
    private val scope: CoroutineScope,
    private val router: RegionRouter,
    private val session: FieldRouteSession,
    private val selectPlace: ((MountainPlace) -> Unit) -> Unit,
    private val updateMap: (HikingRoute?, Boolean) -> Unit,
    private val updateGuidance: (String?) -> Unit,
    private val startLocation: () -> Unit,
    private val stopLocation: () -> Unit,
    private val openLocationSettings: () -> Unit,
) {
    private var computing = false
    private var guidanceJob: Job? = null
    private var routeJob: Job? = null
    private var planner: AlertDialog? = null
    private var waitingForLocation = false
    val following: Boolean get() = session.following

    fun restoreMap() {
        val route = session.route ?: return
        updateMap(route, false)
        if (following) locationPaused()
        else updateGuidance("Route ready · Start guidance from Route")
    }

    fun open() {
        if (computing) {
            AlertDialog.Builder(activity).setMessage("Finding a hiking route...").setPositiveButton("Close", null).show()
            return
        }
        if (following) {
            val controls = AlertDialog.Builder(activity)
                .setTitle("Hike to ${session.destination?.name}")
                .setMessage(if (waitingForLocation) "Allow location in Settings or follow the highlighted trail."
                    else "The route stays on this phone.")
                .setPositiveButton("End guidance") { _, _ -> end() }
                .setNegativeButton("Keep hiking", null)
            if (waitingForLocation) controls.setNeutralButton("Location settings") { _, _ -> openLocationSettings() }
            controls.show()
            return
        }
        val options = arrayOf(
            "From · ${session.origin?.name ?: "Choose a start"}",
            "To · ${session.destination?.name ?: "Choose a destination"}",
            "Maximum trail grade · ${session.maximumGrade}",
        )
        val current = session.route
        val builder = AlertDialog.Builder(activity)
            .setTitle("Plan a hike")
            .setItems(options) { _, choice ->
                if (choice == 2) {
                    val grades = Array(7) { "Grade $it" }
                    AlertDialog.Builder(activity).setTitle("Maximum trail grade")
                        .setSingleChoiceItems(grades, session.maximumGrade) { dialog, grade ->
                            session.maximumGrade = grade
                            dialog.dismiss()
                            resetPreview()
                        }.setNegativeButton("Back") { _, _ -> open() }.show()
                } else selectPlace { place ->
                    if (choice == 0) session.origin = place else session.destination = place
                    resetPreview()
                }
            }
            .setNegativeButton("Close", null)
        if (current != null) {
            val minutes = (current.seconds / 60).roundToInt().coerceAtLeast(1)
            val distance = java.text.NumberFormat.getNumberInstance().apply { maximumFractionDigits = 1 }
            val summary = TextView(activity).apply {
                text = "${distance.format(current.distanceKm)} km · About $minutes min"
                textSize = 16f
                val padding = (24 * resources.displayMetrics.density).roundToInt()
                setPadding(padding, padding / 2, padding, padding / 2)
            }
            val header = LinearLayout(activity).apply { addView(summary) }
            builder.setCustomTitle(header)
                .setPositiveButton("Start guidance") { _, _ ->
                    session.following = true
                    waitingForLocation = false
                    updateGuidance("Waiting for GPS · Follow the highlighted trail")
                    startLocation()
                }
                .setNeutralButton("Clear route") { _, _ -> end() }
        } else if (session.origin != null && session.destination != null) {
            builder.setPositiveButton("Find route") { _, _ -> compute() }
        }
        planner = builder.show()
    }

    private fun resetPreview() {
        session.route = null
        updateMap(null, false)
        updateGuidance(null)
        open()
    }

    private fun compute() {
        val from = session.origin ?: return
        val to = session.destination ?: return
        if (from.id == to.id || from.point == to.point) {
            AlertDialog.Builder(activity).setMessage("Choose a different start and destination.")
                .setPositiveButton("OK") { _, _ -> open() }.show()
            return
        }
        computing = true
        updateGuidance("Finding a hiking route...")
        routeJob = scope.launch {
            try {
                val pending = router.route(from.point, to.point, session.maximumGrade)
                val result = try {
                    runInterruptible(Dispatchers.IO) { pending.get() }
                } finally {
                    if (!isActive) pending.cancel(true)
                }
                session.route = result
                updateMap(result, true)
                updateGuidance("Route ready · Start guidance from Route")
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                val cause = (error as? ExecutionException)?.cause ?: error
                val reason = (cause as? MapFailure)?.reason
                updateGuidance(when (reason) {
                    MapError.NO_ROUTE -> "No route at grade ${session.maximumGrade}. Check the endpoints and trail grade."
                    MapError.OUTSIDE_COVERAGE -> "Both places need to be inside the offline map."
                    else -> "Could not calculate an offline route. Try again."
                })
            } finally {
                computing = false
            }
        }
    }

    fun locationUnavailable() {
        guidanceJob?.cancel()
        if (following) {
            waitingForLocation = true
            updateGuidance("Location unavailable · Follow the highlighted trail")
        }
    }

    fun locationPaused() {
        guidanceJob?.cancel()
        if (following) updateGuidance("Waiting for GPS · Follow the highlighted trail")
    }

    fun onLocation(fix: Location) {
        val current = session.route ?: return
        if (!following || guidanceJob?.isActive == true) return
        waitingForLocation = false
        if (fix.accuracy > 60f) {
            updateGuidance("GPS is imprecise · Follow the highlighted trail")
            return
        }
        guidanceJob = scope.launch {
            val point = fix.mapPoint()
            val match = withContext(Dispatchers.Default) { current.matchPosition(point) }
            if (session.route !== current || !following) return@launch
            val lastPoint = current.points.last()
            when {
                match.distanceM > maxOf(35.0, fix.accuracy * 2.0) ->
                    updateGuidance("Off the highlighted trail · Check the map")
                RouteParser.distance(point, lastPoint) <= maxOf(15.0, fix.accuracy.toDouble()) &&
                    match.shapePosition >= current.points.lastIndex - 1 ->
                    updateGuidance("Near your destination")
                else -> {
                    val instruction = current.instructionsAt(match.shapePosition)
                    updateGuidance(instruction ?: "Follow the highlighted trail")
                }
            }
        }
    }

    fun end() {
        guidanceJob?.cancel()
        session.following = false
        waitingForLocation = false
        stopLocation()
        session.route = null
        updateMap(null, false)
        updateGuidance(null)
    }

    fun close(): java.util.concurrent.Future<*> {
        planner?.dismiss()
        routeJob?.cancel()
        guidanceJob?.cancel()
        return router.closeAsync()
    }
}
