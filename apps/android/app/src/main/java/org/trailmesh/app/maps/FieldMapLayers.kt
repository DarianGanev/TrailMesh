package org.trailmesh.app.maps

import android.graphics.Color
import android.graphics.RectF
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.Style
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory.*
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.LineString
import org.maplibre.geojson.Point
import org.trailmesh.app.persistence.StoredReport
import kotlin.math.roundToLong

internal fun LatLng.mapPoint() = MapPoint(
    (latitude * 1e7).roundToLong(),
    (longitude * 1e7).roundToLong(),
)

internal fun MapPoint.latLng() = LatLng(latE7 / 1e7, lonE7 / 1e7)
private fun MapPoint.geometry() = Point.fromLngLat(lonE7 / 1e7, latE7 / 1e7)

internal class FieldMapLayers(style: Style) {
    private val route = GeoJsonSource("field-route")
    private val reports = GeoJsonSource("field-reports")
    private val location = GeoJsonSource("field-location")

    init {
        listOf(route, reports, location).forEach(style::addSource)
        style.addLayer(LineLayer("field-route-edge", route.id).withProperties(
            lineColor(Color.WHITE), lineWidth(7f), lineCap(Property.LINE_CAP_ROUND), lineJoin(Property.LINE_JOIN_ROUND),
        ))
        style.addLayer(LineLayer("field-route-line", route.id).withProperties(
            lineColor(Color.rgb(44, 69, 176)), lineWidth(4f), lineCap(Property.LINE_CAP_ROUND), lineJoin(Property.LINE_JOIN_ROUND),
        ))
        style.addLayer(CircleLayer(REPORT_LAYER, reports.id).withProperties(
            circleColor(Color.rgb(102, 62, 23)), circleRadius(7f), circleStrokeColor(Color.WHITE), circleStrokeWidth(2f),
        ))
        style.addLayer(CircleLayer("field-location-dot", location.id).withProperties(
            circleColor(Color.rgb(28, 101, 201)), circleRadius(8f), circleStrokeColor(Color.WHITE), circleStrokeWidth(2f),
        ))
    }

    fun showRoute(geometry: HikingRoute?) =
        route.setGeoJson(if (geometry == null) emptyFeatures() else FeatureCollection.fromFeature(
            Feature.fromGeometry(LineString.fromLngLats(geometry.points.map { it.geometry() })),
        ))

    fun showReports(rows: List<StoredReport>) = reports.setGeoJson(FeatureCollection.fromFeatures(
        rows.map { report ->
            Feature.fromGeometry(MapPoint(report.latE7, report.lonE7).geometry()).apply {
                addStringProperty("report", report.bundleID)
            }
        },
    ))

    fun showLocation(point: MapPoint?) = location.setGeoJson(
        if (point == null) emptyFeatures() else FeatureCollection.fromFeature(Feature.fromGeometry(point.geometry())),
    )

    private fun emptyFeatures() = FeatureCollection.fromFeatures(emptyList<Feature>())

    companion object {
        private const val REPORT_LAYER = "field-report-points"

        fun tappedReports(map: MapLibreMap, coordinate: LatLng, tolerance: Float): Set<String> {
            val pixel = map.projection.toScreenLocation(coordinate)
            val box = RectF(pixel.x-tolerance, pixel.y-tolerance, pixel.x+tolerance, pixel.y+tolerance)
            return map.queryRenderedFeatures(box, REPORT_LAYER).mapNotNull {
                it.getStringProperty("report")
            }.toSet()
        }
    }
}
