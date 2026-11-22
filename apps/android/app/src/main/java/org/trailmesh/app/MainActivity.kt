package org.trailmesh.app

import android.app.Activity
import android.app.AlertDialog
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.location.Location
import android.net.Uri
import android.provider.Settings
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.inputmethod.EditorInfo
import android.view.WindowManager
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.widget.Button
import android.widget.EditText
import android.widget.PopupMenu
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapLibreMapOptions
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import org.trailmesh.app.maps.ExploreRegionState
import org.trailmesh.app.maps.MapError
import org.trailmesh.app.maps.MapFailure
import org.trailmesh.app.maps.MountainPlace
import org.trailmesh.app.maps.RegionInstallProgress
import org.trailmesh.app.maps.RilaRegion
import org.trailmesh.app.maps.FIELD_LOCATION_REQUEST
import org.trailmesh.app.maps.FieldLocation
import org.trailmesh.app.maps.FieldMapLayers
import org.trailmesh.app.maps.FieldReports
import org.trailmesh.app.maps.FieldRoutes
import org.trailmesh.app.maps.HikingRoute
import org.trailmesh.app.maps.MapPoint
import org.trailmesh.app.maps.NativeValhallaFactory
import org.trailmesh.app.maps.RegionRouter
import org.trailmesh.app.maps.RegionStore
import org.trailmesh.app.maps.ReportPoint
import org.trailmesh.app.maps.latLng
import org.trailmesh.app.maps.mapPoint
import org.trailmesh.app.maps.reportAccuracy
import org.trailmesh.app.maps.remainingFreshMillis
import org.trailmesh.app.persistence.ReportBounds
import org.trailmesh.app.persistence.StoredReport

class MainActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var region: RilaRegion
    private lateinit var root: LinearLayout
    private lateinit var header: LinearLayout
    private lateinit var content: FrameLayout
    private val systemInsets = Rect()
    private var mapControls: FrameLayout? = null
    private var mapView: MapView? = null
    private var nativeMap: MapLibreMap? = null
    private var restoredCamera: CameraPosition? = null
    private var started = false
    private var resumed = false
    private var fieldLayers: FieldMapLayers? = null
    private var fieldRoutes: FieldRoutes? = null
    private var fieldReports: FieldReports? = null
    private val location by lazy { FieldLocation(this, ::showLocation) }
    private var locationRequested = false
    private var locationOneShot: ((ReportPoint?) -> Unit)? = null
    private var locationTimeout: Job? = null
    private var fixExpiry: Job? = null
    private var locationPermissionPending = false
    private var reportRefresh: Job? = null
    private var reportExpiry: Job? = null
    private var fieldActionButtons = emptyList<View>()
    private val wantsContinuousLocation: Boolean
        get() = locationRequested || fieldRoutes?.following == true
    private var mapReports: List<StoredReport> = emptyList()
    private var chooseReportPoint: ((ReportPoint) -> Unit)? = null
    private var guidance: TextView? = null
    private val reportClockChanged = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_TIME_CHANGED) refreshFieldReports()
        }
    }
    private var pickLocation: LinearLayout? = null
    private var progressBar: ProgressBar? = null
    private var progressText: TextView? = null

    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        restoredCamera = savedInstanceState?.getParcelable(CAMERA_STATE)
        region = lastNonConfigurationInstance as? RilaRegion
            ?: RilaRegion(File(filesDir, "offline-regions"))

        root = column().apply { setBackgroundColor(PAPER) }
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
        } else {
            window.decorView.systemUiVisibility =
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or
                    View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        }
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        root.setOnApplyWindowInsetsListener { _, insets ->
            if (Build.VERSION.SDK_INT >= 30) {
                val bars = insets.getInsets(
                    WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout(),
                )
                systemInsets.set(bars.left, bars.top, bars.right, bars.bottom)
            } else {
                systemInsets.set(
                    insets.systemWindowInsetLeft, insets.systemWindowInsetTop,
                    insets.systemWindowInsetRight, insets.systemWindowInsetBottom,
                )
            }
            updateInsets()
            insets
        }

        header = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(52)
            setPadding(dp(24), 0, dp(8), 0)
        }
        header.addView(label("Explore", 24f, bold = true), LinearLayout.LayoutParams(0, -2, 1f))
        if (Build.VERSION.SDK_INT >= 28) {
            header.getChildAt(0).isAccessibilityHeading = true
        }
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            header.addView(button("⋮") { showDiagnostics() }.apply {
                contentDescription = "Developer tools"
                textSize = 24f
            }, LinearLayout.LayoutParams(dp(48), -2))
        }
        root.addView(header, LinearLayout.LayoutParams(-1, -2))
        content = FrameLayout(this)
        root.addView(content, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(root)
        if (Build.VERSION.SDK_INT >= 30) {
            val lightBars = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
            window.insetsController?.setSystemBarsAppearance(lightBars, lightBars)
        }

        scope.launch { region.state.collect(::render) }
    }

    override fun onRetainNonConfigurationInstance(): Any = region

    @Deprecated("Debug map diagnostic result")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == MAP_DIAGNOSTICS) region.refreshAfterDiagnostics()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        (nativeMap?.cameraPosition ?: restoredCamera)?.let { outState.putParcelable(CAMERA_STATE, it) }
    }

    override fun onStart() {
        super.onStart()
        started = true
        val clockChanges = IntentFilter(Intent.ACTION_TIME_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(reportClockChanged, clockChanges, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(reportClockChanged, clockChanges)
        }
        mapView?.onStart()
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        mapView?.onResume()
        if (fieldLayers != null && (wantsContinuousLocation || locationOneShot != null)) {
            if (location.hasPermission()) startFieldLocation()
            else if (!locationPermissionPending) fieldRoutes?.locationUnavailable()
        }
        refreshFieldReports()
    }

    override fun onPause() {
        resumed = false
        location.stop()
        locationTimeout?.cancel()
        fixExpiry?.cancel()
        fieldLayers?.showLocation(null)
        fieldRoutes?.locationPaused()
        reportRefresh?.cancel()
        reportExpiry?.cancel()
        mapView?.onPause()
        super.onPause()
    }

    override fun onStop() {
        started = false
        unregisterReceiver(reportClockChanged)
        mapView?.onStop()
        super.onStop()
    }

    override fun onLowMemory() {
        super.onLowMemory()
        mapView?.onLowMemory()
    }

    override fun onDestroy() {
        scope.cancel()
        destroyMap()
        if (!isChangingConfigurations) region.close()
        super.onDestroy()
    }

    private fun destroyMap() {
        fieldRoutes?.close()
        fieldRoutes = null
        fieldLayers = null
        fieldReports?.close()
        fieldReports = null
        reportRefresh?.cancel()
        reportExpiry?.cancel()
        fieldActionButtons = emptyList()
        mapReports = emptyList()
        location.stop()
        locationTimeout?.cancel()
        fixExpiry?.cancel()
        locationRequested = false
        locationOneShot = null
        chooseReportPoint = null
        guidance = null
        pickLocation = null
        mapControls = null
        val view = mapView ?: return
        mapView = null
        nativeMap = null
        if (resumed) view.onPause()
        if (started) view.onStop()
        view.onDestroy()
    }

    private fun render(state: ExploreRegionState) {
        if (state is ExploreRegionState.Installing && progressBar != null) {
            updateProgress(state.progress)
            return
        }
        progressBar = null
        progressText = null
        destroyMap()
        content.removeAllViews()
        val showingMap = state is ExploreRegionState.Ready
        header.visibility = if (showingMap) View.GONE else View.VISIBLE
        updateInsets()
        when (state) {
            ExploreRegionState.Checking -> showPanel(
                "Checking for a saved map", "The map will open here when it’s ready.",
            )
            ExploreRegionState.Available -> showPanel(
                "Rila · Рила",
                "Hiking trails, huts and peaks on a map you can use offline.",
                "Download Rila",
                "64 MB · Internet required",
            ) { region.download() }
            ExploreRegionState.Damaged -> showPanel(
                "The saved map couldn’t be opened",
                "Download a fresh copy of Rila to use the map offline.",
                "Replace download",
                "64 MB · Internet required",
            ) { region.download() }
            is ExploreRegionState.Installing -> showDownload(state.progress)
            ExploreRegionState.Cancelling -> showPanel(
                "Cancelling download", "Your download will stop as soon as the current request finishes.",
            )
            is ExploreRegionState.Failed -> showFailure(state)
            is ExploreRegionState.Ready -> showMap(state)
        }
    }

    private fun updateInsets() {
        val mapIsVisible = header.visibility == View.GONE
        root.setPadding(
            systemInsets.left, if (mapIsVisible) 0 else systemInsets.top,
            systemInsets.right, if (mapIsVisible) 0 else systemInsets.bottom,
        )
        mapControls?.setPadding(0, systemInsets.top, 0, systemInsets.bottom)
    }

    private fun showFailure(state: ExploreRegionState.Failed) {
        val (title, detail) = when (state.reason) {
            MapError.CANCELLED -> "Download cancelled" to "You can download Rila when you’re ready."
            MapError.SPACE -> "Not enough storage" to
                "Free some space on this phone, then try again. Rila uses about 64 MB."
            MapError.CORRUPT -> "The download couldn’t be verified" to
                "Try downloading Rila again before you go offline."
            MapError.BUSY -> "The map is in use" to
                "Close map diagnostics and try again."
            else -> "Rila couldn’t be downloaded" to
                "Check your internet connection and try again."
        }
        showPanel(
            title, detail,
            if (state.reason == MapError.CANCELLED) "Download Rila" else "Try again",
            action = region::download,
        )
    }

    private fun showDownload(progress: RegionInstallProgress?) {
        val panel = emptyPanel("Downloading Rila")
        progressText = label("", 16f, MUTED).also {
            it.accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            panel.addView(it, itemParams(top = 12))
        }
        progressBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).also {
            it.max = 100
            it.progressTintList = ColorStateList.valueOf(ACCENT)
            it.indeterminateTintList = ColorStateList.valueOf(ACCENT)
            it.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            panel.addView(it, itemParams(top = 18))
        }
        panel.addView(button("Cancel download", action = region::cancelDownload), itemParams(top = 14))
        updateProgress(progress)
    }

    private fun updateProgress(progress: RegionInstallProgress?) {
        val percent = (progress as? RegionInstallProgress.Downloading)?.let {
            (it.bytes * 100L / it.total).toInt()
        }
        progressBar?.isIndeterminate = percent == null
        progressBar?.progress = percent ?: 0
        val message = when (progress) {
            RegionInstallProgress.Verifying -> "Checking downloaded files…"
            is RegionInstallProgress.Downloading -> "Download ${percent}% complete"
            null -> "Connecting…"
        }
        if (progressText?.text != message) progressText?.text = message
    }

    private fun showPanel(
        title: String,
        detail: String,
        buttonText: String? = null,
        sizeLabel: String? = null,
        action: () -> Unit = {},
    ) {
        val panel = emptyPanel(title)
        panel.addView(label(detail, 17f, MUTED), itemParams(top = 10))
        if (buttonText != null) {
            panel.addView(button(buttonText, primary = true, action), itemParams(top = 26))
        }
        if (sizeLabel != null) {
            panel.addView(label(sizeLabel, 14f, MUTED).apply {
                gravity = Gravity.CENTER
            }, itemParams(top = 12))
        }
    }

    private fun emptyPanel(title: String): LinearLayout {
        val scroll = ScrollView(this).apply { isFillViewport = true }
        val alignment = FrameLayout(this).apply { setPadding(dp(24), dp(44), dp(24), dp(44)) }
        val panel = column()
        panel.addView(label(title, 34f, bold = true).apply {
            if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
        })
        alignment.addView(panel, FrameLayout.LayoutParams(-1, -2, Gravity.CENTER).apply {
            val width = resources.displayMetrics.widthPixels - dp(48)
            if (width > dp(380)) this.width = dp(380)
        })
        scroll.addView(alignment)
        content.addView(scroll, FrameLayout.LayoutParams(-1, -1))
        return panel
    }

    private fun showMap(state: ExploreRegionState.Ready) {
        val canvas = FrameLayout(this).apply { setBackgroundColor(MAP_PAPER) }
        content.addView(canvas, FrameLayout.LayoutParams(-1, -1))
        val controls = FrameLayout(this)
        mapControls = controls
        val regionTitle = column().apply {
            addView(label("Rila", 44f).apply {
                typeface = Typeface.create("serif", Typeface.NORMAL)
                setShadowLayer(dp(4).toFloat(), 0f, dp(1).toFloat(), Color.WHITE)
                if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
            })
            addView(label("Malyovitsa Valley", 14f, bold = true).apply {
                setShadowLayer(dp(3).toFloat(), 0f, dp(1).toFloat(), Color.WHITE)
            })
        }
        val status = label("Opening map…", 14f, MUTED).apply {
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        regionTitle.addView(status)
        controls.addView(regionTitle, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.START).apply {
            marginStart = dp(20)
            topMargin = dp(12)
            marginEnd = dp(72)
        })
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            controls.addView(button("⋮") { showDiagnostics() }.apply {
                contentDescription = "Developer tools"
                textSize = 22f
                background = mapSurface(24)
            }, FrameLayout.LayoutParams(dp(48), dp(48), Gravity.TOP or Gravity.END).apply {
                topMargin = dp(12)
                marginEnd = dp(12)
            })
        }

        val credits = button("© OpenStreetMap") {
            val dialog = AlertDialog.Builder(this)
                .setTitle("Map credits")
                .setMessage(state.region.manifest.attribution + "\n\nhttps://www.openstreetmap.org/copyright")
                .setPositiveButton("Close", null)
                .show()
            dialog.findViewById<TextView>(android.R.id.message)?.let {
                android.text.util.Linkify.addLinks(it, android.text.util.Linkify.WEB_URLS)
            }
        }.apply {
            textSize = 12f
            minimumWidth = dp(48)
            setTextColor(INK)
            setPadding(dp(10), 0, dp(10), 0)
            // Keep the attribution compact without reducing its accessible touch area.
            background = InsetDrawable(mapSurface(8), 0, dp(12), 0, dp(12))
        }
        controls.addView(credits, FrameLayout.LayoutParams(-2, -2, Gravity.START or Gravity.BOTTOM).apply {
            marginStart = dp(12)
            bottomMargin = dp(4)
            marginEnd = dp(72)
        })
        fieldActionButtons = addMapControls(controls, state)
        updateInsets()

        val initial = restoredCamera ?: CameraPosition.Builder()
            .target(LatLng(42.181, 23.369))
            .zoom(12.3)
            .build()
        restoredCamera = null
        try {
            MapLibre.getInstance(applicationContext)
            val view = MapView(
                this,
                MapLibreMapOptions.createFromAttributes(this)
                    .camera(initial)
                    .attributionEnabled(false)
                    .logoEnabled(false)
                    .compassEnabled(false)
                    .rotateGesturesEnabled(false)
                    .tiltGesturesEnabled(false)
                    .maxZoomPreference(17.0)
                    .textureMode(true)
                    .asyncRendererCleanup(false)
                    .foregroundLoadColor(MAP_PAPER),
            )
            mapView = view
            canvas.addView(view, FrameLayout.LayoutParams(-1, -1))
            canvas.addView(controls, FrameLayout.LayoutParams(-1, -1))
            view.onCreate(null)
            if (started) view.onStart()
            if (resumed) view.onResume()
            view.addOnDidFailLoadingMapListener {
                view.post {
                    if (mapView === view) showMapError(state)
                }
            }
            view.addOnDidFinishRenderingMapListener(object : MapView.OnDidFinishRenderingMapListener {
                override fun onDidFinishRenderingMap(fullyRendered: Boolean) {
                    if (fullyRendered && mapView === view) {
                        view.removeOnDidFinishRenderingMapListener(this)
                        status.visibility = View.GONE
                        fieldActionButtons.forEach { it.isEnabled = true }
                        credits.postDelayed({
                            if (mapView === view) {
                                credits.text = "ⓘ"
                                credits.textSize = 18f
                                credits.contentDescription = "Map credits"
                            }
                        }, 5000)
                    }
                }
            })
            view.getMapAsync { map ->
                if (mapView === view) {
                    nativeMap = map
                    map.setLatLngBoundsForCameraTarget(bounds(state))
                    map.setStyle(
                        Style.Builder().fromJson(state.style)
                            .withImage("trailmesh-hut", requireNotNull(getDrawable(R.drawable.ic_map_hut)))
                            .withImage("trailmesh-peak", requireNotNull(getDrawable(R.drawable.ic_map_peak))),
                    ) { style ->
                        if (mapView === view) prepareFieldMap(state, map, style)
                    }
                }
            }
        } catch (_: RuntimeException) {
            showMapError(state)
        }
    }

    private fun showMapError(state: ExploreRegionState.Ready) {
        destroyMap()
        content.removeAllViews()
        header.visibility = View.VISIBLE
        updateInsets()
        showPanel("The map didn’t open", "Rila is saved on this phone.", "Try again") { render(state) }
    }

    private fun addMapControls(overlay: FrameLayout, state: ExploreRegionState.Ready): List<View> {
        val controls = column()
        val placeName = label("", 20f, bold = true).apply {
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
        }
        val kind = label("", 14f, MUTED)
        val placeDetails = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(8), dp(8), dp(8))
            background = mapSurface(22)
            visibility = View.GONE
            val summary = column().apply {
                addView(placeName)
                addView(kind)
            }
            addView(summary, LinearLayout.LayoutParams(0, -2, 1f))
        }
        val dismiss = mapIcon(R.drawable.ic_map_close, "Dismiss place") {
            placeDetails.visibility = View.GONE
        }
        placeDetails.addView(dismiss, LinearLayout.LayoutParams(dp(48), dp(48)))
        controls.addView(placeDetails, itemParams(top = 0))
        guidance = label("", 14f).apply {
            setPadding(dp(12), dp(8), dp(12), dp(8))
            background = mapSurface(10)
            visibility = View.GONE
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }.also { controls.addView(it, itemParams(top = 4)) }
        pickLocation = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            background = mapSurface(10)
            visibility = View.GONE
            addView(label("Tap the report location", 14f).apply {
                setPadding(dp(12), 0, 0, 0)
            }, LinearLayout.LayoutParams(0, -2, 1f))
            addView(button("Cancel") { finishMapPointSelection() })
        }.also { controls.addView(it, itemParams(top = 4)) }

        val row = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL }
        val search = button("Search Rila") {
            showPlaceSearch(state) { place ->
                val position = LatLng(place.point.latE7 / 1e7, place.point.lonE7 / 1e7)
                nativeMap?.let { map ->
                    map.moveCamera(CameraUpdateFactory.newLatLngZoom(position, maxOf(map.cameraPosition.zoom, 13.5)))
                }
                placeName.text = place.name
                kind.text = placeKind(place)
                placeDetails.visibility = View.VISIBLE
            }
        }.apply {
            gravity = Gravity.START or Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(8), dp(16), dp(8))
            textSize = 16f
            typeface = Typeface.DEFAULT_BOLD
            setCompoundDrawablesRelativeWithIntrinsicBounds(R.drawable.ic_map_search, 0, 0, 0)
            compoundDrawablePadding = dp(10)
            background = RippleDrawable(ColorStateList.valueOf(0x18001D42), mapSurface(28), null)
            isEnabled = false
        }
        row.addView(search, LinearLayout.LayoutParams(0, -2, 1f))
        val options = mapIcon(R.drawable.ic_map_controls, "Map controls") { anchor ->
            PopupMenu(this, anchor).apply {
                menu.add(0, 1, 0, "Rila overview")
                menu.add(0, 2, 1, "Zoom in")
                menu.add(0, 3, 2, "Zoom out")
                menu.add(0, 4, 3, "Offline maps")
                setOnMenuItemClickListener { item ->
                    if (item.itemId == 4) {
                        showOfflineMaps(state)
                        return@setOnMenuItemClickListener true
                    }
                    val update = when (item.itemId) {
                        1 -> {
                            placeDetails.visibility = View.GONE
                            CameraUpdateFactory.newLatLngBounds(bounds(state), dp(20))
                        }
                        2 -> CameraUpdateFactory.zoomBy(1.0)
                        3 -> CameraUpdateFactory.zoomBy(-1.0)
                        else -> return@setOnMenuItemClickListener false
                    }
                    nativeMap?.moveCamera(update)
                    true
                }
                show()
            }
        }.apply { isEnabled = false }
        row.addView(options, LinearLayout.LayoutParams(dp(48), dp(48)).apply { marginStart = dp(8) })
        controls.addView(row, itemParams(top = 8))
        val fieldActions = LinearLayout(this).apply { background = mapSurface(12) }
        val actions = listOf(
            button("Route") { fieldRoutes?.open() },
            button("Reports") { fieldReports?.show(reportBounds(state)) },
            button("Locate") { locateOnMap() },
        )
        for (action in actions) {
            action.isEnabled = false
            action.setPadding(dp(4), 0, dp(4), 0)
            fieldActions.addView(action, LinearLayout.LayoutParams(0, -2, 1f))
        }
        controls.addView(fieldActions, itemParams(top = 6))
        overlay.addView(controls, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM).apply {
            marginStart = dp(16)
            marginEnd = dp(16)
            bottomMargin = dp(54)
        })
        return listOf(search, options) + actions
    }

    private fun showOfflineMaps(state: ExploreRegionState.Ready) {
        val bytes = state.region.manifest.files.sumOf { it.bytes }
        val size = (bytes + 999_999L) / 1_000_000L
        AlertDialog.Builder(this)
            .setTitle("Offline maps")
            .setMessage("Rila · $size MB\nDownloaded and verified")
            .setPositiveButton("Remove map") { _, _ ->
                AlertDialog.Builder(this)
                    .setTitle("Remove the Rila map?")
                    .setMessage("Download the map again before your next offline hike.")
                    .setNegativeButton("Cancel", null)
                    .setPositiveButton("Remove") { _, _ ->
                        val routeClosed = fieldRoutes?.close()
                        fieldRoutes = null
                        destroyMap()
                        region.removeMap(routeClosed) { removed ->
                            if (!removed && resumed && !isFinishing) AlertDialog.Builder(this)
                                .setMessage("Rila could not be removed. Try again.")
                                .setPositiveButton("Close", null).show()
                        }
                    }.show()
            }.setNegativeButton("Close", null).show()
    }

    private fun prepareFieldMap(state: ExploreRegionState.Ready, map: MapLibreMap, style: Style) {
        fieldLayers = FieldMapLayers(style)
        val manifest = state.region.manifest
        fieldRoutes = FieldRoutes(this, scope, RegionRouter(
            RegionStore(File(filesDir, "offline-regions")), manifest.id, manifest.revision,
            NativeValhallaFactory(cacheDir),
        ), region.fieldRouteSession, { select -> showPlaceSearch(state, select) }, ::showHikingRoute, ::showGuidance,
            ::startFieldLocation, ::releaseUnusedLocation, ::openLocationSettings,
        )
        fieldReports = FieldReports(this, scope, ::startMapPointSelection, { result ->
            requestReportLocation { point -> result(point?.takeIf { manifest.bounds.contains(it.point) }) }
        }, { centerOn(it) }, {
            scheduleReports(state)
        })
        map.addOnMapClickListener { coordinate ->
            val select = chooseReportPoint
            if (select != null) {
                val point = coordinate.mapPoint()
                if (manifest.bounds.contains(point)) {
                    finishMapPointSelection()
                    select(ReportPoint(point, 0))
                }
                return@addOnMapClickListener true
            }
            val ids = FieldMapLayers.tappedReports(map, coordinate, dp(18).toFloat())
            val now = System.currentTimeMillis()
            val matches = mapReports.filter { it.bundleID in ids && it.isCurrentAt(now) }
            when (matches.size) {
                0 -> false
                1 -> {
                    fieldReports?.details(matches.single())
                    true
                }
                else -> {
                    AlertDialog.Builder(this).setTitle("Reports at this spot")
                        .setItems(matches.map { fieldReports?.reportTitle(it).orEmpty() }.toTypedArray()) { _, index ->
                            fieldReports?.details(matches[index])
                        }.setNegativeButton("Close", null).show()
                    true
                }
            }
        }
        fieldRoutes?.restoreMap()
        if (resumed) {
            if (wantsContinuousLocation && location.hasPermission()) startFieldLocation()
            else if (wantsContinuousLocation) fieldRoutes?.locationUnavailable()
            scheduleReports(state)
        }
    }

    private fun refreshFieldReports() {
        if (!resumed) return
        fieldReports?.refreshOpenReports()
        val ready = region.state.value as? ExploreRegionState.Ready
        if (ready != null && fieldLayers != null) scheduleReports(ready)
    }

    private fun reportBounds(state: ExploreRegionState.Ready) =
        state.region.manifest.bounds.let { ReportBounds(it.south, it.north, it.west, it.east) }

    private fun scheduleReports(state: ExploreRegionState.Ready) {
        val reports = fieldReports ?: return
        reportRefresh?.cancel()
        reportRefresh = scope.launch {
            publishMapReports(mapReports)
            while (isActive && resumed) {
                val refresh = try {
                    reports.mapRows(reportBounds(state))
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    emptyList()
                }
                publishMapReports(refresh)
                delay(30_000L)
            }
        }
    }

    private fun publishMapReports(reports: List<StoredReport>) {
        val now = System.currentTimeMillis()
        mapReports = reports.filter { it.isCurrentAt(now) }
        fieldLayers?.showReports(mapReports)
        reportExpiry?.cancel()
        val expiry = mapReports.minOfOrNull { it.effectiveExpiresAt } ?: return
        reportExpiry = scope.launch {
            delay((expiry - now).coerceAtLeast(1L))
            publishMapReports(mapReports)
        }
    }

    private fun startMapPointSelection(select: (ReportPoint) -> Unit) {
        // A delayed Locate fix must not move the map under the user's next tap.
        locationTimeout?.cancel()
        locationOneShot = null
        releaseUnusedLocation()
        chooseReportPoint = select
        fieldActionButtons.forEach { it.isEnabled = false }
        pickLocation?.visibility = View.VISIBLE
    }

    private fun finishMapPointSelection() {
        chooseReportPoint = null
        fieldActionButtons.forEach { it.isEnabled = true }
        pickLocation?.visibility = View.GONE
    }

    @Deprecated("Used for back navigation on the current View-based Explore screen")
    override fun onBackPressed() {
        if (chooseReportPoint != null) finishMapPointSelection() else super.onBackPressed()
    }

    private fun showHikingRoute(route: HikingRoute?, fit: Boolean) {
        fieldLayers?.showRoute(route)
        if (fit && route != null && chooseReportPoint == null) {
            val positions = route.points.map { it.latLng() }
            val bounds = LatLngBounds.Builder().includes(positions).build()
            val viewport = mapView?.height ?: 0
            nativeMap?.moveCamera(CameraUpdateFactory.newLatLngBounds(
                bounds, dp(20), minOf(dp(140), viewport / 5), dp(20), minOf(dp(210), viewport / 3),
            ))
        }
    }

    private fun showGuidance(text: String?) {
        guidance?.apply {
            this.text = text.orEmpty()
            visibility = if (text == null) View.GONE else View.VISIBLE
        }
    }

    private fun locateOnMap() {
        locationRequested = true
        requestReportLocation { point ->
            if (point != null) centerOn(point.point)
            else AlertDialog.Builder(this).setMessage("A recent location is unavailable.")
                .setPositiveButton("Close", null).show()
        }
    }

    private fun requestReportLocation(result: (ReportPoint?) -> Unit) {
        val fix = location.current()
        if (fix != null) {
            result(ReportPoint(fix.mapPoint(), fix.reportAccuracy()))
            return
        }
        locationOneShot = result
        startFieldLocation()
    }

    private fun startFieldLocation() {
        if (!resumed || fieldLayers == null || (!wantsContinuousLocation && locationOneShot == null)) return
        if (!location.hasPermission()) {
            if (!locationPermissionPending) {
                locationPermissionPending = true
                requestPermissions(FieldLocation.PERMISSIONS, FIELD_LOCATION_REQUEST)
            }
            return
        }
        if (!location.start()) {
            fieldRoutes?.locationUnavailable()
            finishLocationRequest(null)
        } else if (locationOneShot != null && locationTimeout?.isActive != true) {
            locationTimeout = scope.launch {
                delay(7000L)
                finishLocationRequest(null)
            }
        }
    }

    override fun onRequestPermissionsResult(request: Int, permissions: Array<out String>, grants: IntArray) {
        super.onRequestPermissionsResult(request, permissions, grants)
        if (request != FIELD_LOCATION_REQUEST) return
        locationPermissionPending = false
        if (grants.any { it == PackageManager.PERMISSION_GRANTED }) {
            if (wantsContinuousLocation || locationOneShot != null) startFieldLocation()
        } else {
            locationRequested = false
            fieldRoutes?.locationUnavailable()
            finishLocationRequest(null)
        }
    }

    private fun showLocation(fix: Location) {
        val remainingMillis = fix.remainingFreshMillis()
        if (remainingMillis <= 0L) return
        val point = fix.mapPoint()
        if (wantsContinuousLocation) {
            fieldLayers?.showLocation(point)
            fieldRoutes?.onLocation(fix)
            fixExpiry?.cancel()
            fixExpiry = scope.launch {
                delay(remainingMillis)
                fieldLayers?.showLocation(null)
                fieldRoutes?.locationUnavailable()
            }
        }
        finishLocationRequest(ReportPoint(point, fix.reportAccuracy()))
    }

    private fun finishLocationRequest(value: ReportPoint?) {
        locationTimeout?.cancel()
        val pending = locationOneShot
        locationOneShot = null
        if (pending != null) releaseUnusedLocation()
        pending?.invoke(value)
    }

    private fun releaseUnusedLocation() {
        if (wantsContinuousLocation || locationOneShot != null) return
        location.stop()
        fixExpiry?.cancel()
        fieldLayers?.showLocation(null)
    }

    private fun openLocationSettings() {
        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
    }

    private fun centerOn(point: MapPoint) {
        if (chooseReportPoint != null) return
        nativeMap?.let { map ->
            map.moveCamera(CameraUpdateFactory.newLatLngZoom(point.latLng(), maxOf(map.cameraPosition.zoom, 13.5)))
        }
    }

    private fun mapIcon(icon: Int, description: String, action: (View) -> Unit) =
        android.widget.ImageButton(this, null, android.R.attr.borderlessButtonStyle).apply {
            setImageResource(icon)
            setColorFilter(INK)
            contentDescription = description
            background = RippleDrawable(ColorStateList.valueOf(0x18001D42), mapSurface(24), null)
            setOnClickListener(action)
        }

    private fun showPlaceSearch(state: ExploreRegionState.Ready, select: (MountainPlace) -> Unit) {
        val panel = column().apply { setPadding(dp(20), dp(8), dp(20), 0) }
        val field = EditText(this).apply {
            hint = "Hut, summit or trailhead"
            inputType = InputType.TYPE_CLASS_TEXT
            imeOptions = EditorInfo.IME_ACTION_SEARCH
            setSingleLine()
            minHeight = dp(48)
        }
        panel.addView(field)
        val results = column()
        panel.addView(ScrollView(this).apply { addView(results) }, itemParams(top = 8))
        var request: Job? = null
        val dialog = AlertDialog.Builder(this)
            .setTitle("Find a place")
            .setView(panel)
            .setNegativeButton("Close", null)
            .setPositiveButton("Search", null)
            .create()
        dialog.show()
        dialog.window?.setGravity(Gravity.BOTTOM)
        dialog.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        val index = scope.async(Dispatchers.IO) {
            try {
                state.region.places()
            } catch (_: java.io.IOException) {
                null
            } catch (_: MapFailure) {
                null
            }
        }
        dialog.setOnDismissListener {
            request?.cancel()
            index.cancel()
        }
        fun search() {
            request?.cancel()
            val term = field.text.toString().trim()
            results.removeAllViews()
            if (term.isEmpty()) return
            results.addView(label("Searching…", 16f, MUTED))
            request = scope.launch {
                val matches = withContext(Dispatchers.IO) { index.await()?.search(term) }
                results.removeAllViews()
                if (matches.isNullOrEmpty()) {
                    results.addView(label(
                        if (matches == null) "Place search couldn’t open." else "No matching places",
                        16f, MUTED,
                    ))
                } else {
                    for (place in matches) {
                        results.addView(button("${place.name} · ${placeKind(place)}") {
                            dialog.dismiss()
                            select(place)
                        }.apply { gravity = Gravity.START or Gravity.CENTER_VERTICAL })
                    }
                }
            }
        }
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener { search() }
        field.setOnEditorActionListener { _, action, _ ->
            if (action != EditorInfo.IME_ACTION_SEARCH) false
            else {
                search()
                true
            }
        }
    }

    private fun placeKind(place: MountainPlace) = when (place.kind) {
        "hut" -> "Hut"
        "peak" -> "Summit"
        "shelter" -> "Shelter"
        "water" -> "Water"
        "trailhead" -> "Trailhead"
        else -> "Place"
    }

    private fun mapSurface(radius: Int) = shape(PAPER, radius).apply { setStroke(dp(1), LINE) }

    private fun bounds(state: ExploreRegionState.Ready) = state.region.manifest.bounds.let {
        LatLngBounds.from(it.north / 1e7, it.east / 1e7, it.south / 1e7, it.west / 1e7)
    }

    @Suppress("DEPRECATION")
    private fun showDiagnostics() {
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) return
        val options = arrayOf("Report session diagnostics", "Map diagnostics")
        val activities = arrayOf("session.ReportDiagnosticsActivity", "maps.MapsDiagnosticsActivity")
        AlertDialog.Builder(this)
            .setTitle("Developer tools")
            .setItems(options) { _, which ->
                val intent = Intent().setClassName(this, "$packageName.${activities[which]}")
                if (which == 1) startActivityForResult(intent, MAP_DIAGNOSTICS)
                else startActivity(intent)
            }
            .setNegativeButton("Close", null)
            .show()
    }

    private fun column() = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }

    private fun label(value: String, size: Float, color: Int = INK, bold: Boolean = false) =
        TextView(this).apply {
            text = value
            textSize = size
            setTextColor(color)
            typeface = if (bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
            setLineSpacing(dp(3).toFloat(), 1f)
        }

    private fun button(value: String, primary: Boolean = false, action: () -> Unit) =
        Button(this, null, android.R.attr.borderlessButtonStyle).apply {
            text = value
            isAllCaps = false
            textSize = 15f
            setTextColor(if (primary) Color.WHITE else ACCENT)
            minimumWidth = 0
            minWidth = 0
            minimumHeight = dp(48)
            setPadding(dp(12), dp(8), dp(12), dp(8))
            if (primary) {
                background = RippleDrawable(
                    ColorStateList.valueOf(0x33FFFFFF), shape(ACCENT, 10), null,
                )
            }
            setOnClickListener { action() }
        }

    private fun shape(color: Int, radius: Int) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radius).toFloat()
    }

    private fun itemParams(top: Int) = LinearLayout.LayoutParams(-1, -2).apply {
        topMargin = dp(top)
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density + 0.5f).toInt()

    private companion object {
        const val CAMERA_STATE = "explore.camera"
        const val MAP_DIAGNOSTICS = 1
        val PAPER = Color.rgb(250, 251, 255)
        val MAP_PAPER = Color.rgb(244, 241, 230)
        val INK = Color.rgb(24, 34, 51)
        val MUTED = Color.rgb(69, 80, 98)
        val ACCENT = Color.rgb(31, 80, 158)
        val LINE = Color.rgb(210, 218, 229)
    }
}
