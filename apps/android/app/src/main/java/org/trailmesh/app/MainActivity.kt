package org.trailmesh.app

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
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
import org.trailmesh.app.maps.RegionInstallProgress
import org.trailmesh.app.maps.RilaRegion

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
        mapView?.onStart()
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        mapView?.onResume()
    }

    override fun onPause() {
        resumed = false
        mapView?.onPause()
        super.onPause()
    }

    override fun onStop() {
        started = false
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
            it.progressTintList = ColorStateList.valueOf(GREEN)
            it.indeterminateTintList = ColorStateList.valueOf(GREEN)
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
        val name = column().apply {
            background = mapSurface(12)
            setPadding(dp(12), dp(8), dp(16), dp(8))
        }
        name.addView(label("Rila", 18f, bold = true).apply {
            if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
        })
        val status = label("Opening map…", 12f, MUTED).apply {
            setLineSpacing(0f, 1f)
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        name.addView(status)
        controls.addView(name, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.START).apply {
            marginStart = dp(12)
            topMargin = dp(12)
            marginEnd = dp(72)
        })
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            controls.addView(button("⋮") { showDiagnostics() }.apply {
                contentDescription = "Developer tools"
                textSize = 22f
                background = mapSurface(12)
            }, FrameLayout.LayoutParams(dp(48), dp(48), Gravity.TOP or Gravity.END).apply {
                topMargin = dp(12)
                marginEnd = dp(12)
            })
        }

        val credits = button("© OpenStreetMap") {
            AlertDialog.Builder(this)
                .setTitle("Map credits")
                .setMessage(state.region.manifest.attribution)
                .setPositiveButton("Close", null)
                .show()
        }.apply {
            textSize = 11f
            setTextColor(INK)
            setPadding(dp(10), 0, dp(10), 0)
            // Keep the attribution compact without reducing its accessible touch area.
            background = android.graphics.drawable.InsetDrawable(mapSurface(8), 0, dp(12), 0, dp(12))
        }
        controls.addView(credits, FrameLayout.LayoutParams(-2, -2, Gravity.START or Gravity.BOTTOM).apply {
            marginStart = dp(12)
            bottomMargin = dp(4)
            marginEnd = dp(72)
        })
        val mapButtons = addMapControls(controls, state)
        updateInsets()

        val initial = restoredCamera ?: CameraPosition.Builder()
            .target(LatLng(42.181, 23.369))
            .zoom(11.6)
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
                        status.text = "Saved offline"
                        mapButtons.forEach { it.isEnabled = true }
                    }
                }
            })
            view.getMapAsync { map ->
                if (mapView === view) {
                    nativeMap = map
                    map.setLatLngBoundsForCameraTarget(bounds(state))
                    map.setStyle(Style.Builder().fromJson(state.style))
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
        val rail = column().apply { background = mapSurface(14) }
        val overview = android.widget.ImageButton(this, null, android.R.attr.borderlessButtonStyle).apply {
            setImageResource(R.drawable.ic_region_overview)
            setColorFilter(GREEN)
            contentDescription = "Show Rila overview"
            isEnabled = false
            setOnClickListener {
                nativeMap?.moveCamera(CameraUpdateFactory.newLatLngBounds(bounds(state), dp(20)))
            }
            rail.addView(this, LinearLayout.LayoutParams(dp(48), dp(48)))
        }
        val actions = listOf(
            Triple("+", "Zoom in", CameraUpdateFactory.zoomBy(1.0)),
            Triple("−", "Zoom out", CameraUpdateFactory.zoomBy(-1.0)),
        )
        val zoom = actions.map { (symbol, description, update) ->
            rail.addView(rule(), LinearLayout.LayoutParams(-1, dp(1)))
            button(symbol) { nativeMap?.moveCamera(update) }.apply {
                textSize = 22f
                contentDescription = description
                setPadding(0, 0, 0, 0)
                isEnabled = false
                rail.addView(this, LinearLayout.LayoutParams(dp(48), dp(48)))
            }
        }
        overlay.addView(rail, FrameLayout.LayoutParams(-2, -2, Gravity.END or Gravity.BOTTOM).apply {
            marginEnd = dp(12)
            bottomMargin = dp(16)
        })
        return listOf(overview) + zoom
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

    private fun rule() = View(this).apply { setBackgroundColor(LINE) }

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
            setTextColor(if (primary) Color.WHITE else GREEN)
            minimumWidth = 0
            minWidth = 0
            minimumHeight = dp(48)
            setPadding(dp(12), dp(8), dp(12), dp(8))
            if (primary) {
                background = RippleDrawable(
                    ColorStateList.valueOf(0x33FFFFFF), shape(GREEN, 10), null,
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
        val PAPER = Color.rgb(252, 251, 246)
        val MAP_PAPER = Color.rgb(244, 241, 230)
        val INK = Color.rgb(30, 40, 31)
        val MUTED = Color.rgb(72, 84, 72)
        val GREEN = Color.rgb(36, 70, 47)
        val LINE = Color.rgb(221, 225, 213)
    }
}
