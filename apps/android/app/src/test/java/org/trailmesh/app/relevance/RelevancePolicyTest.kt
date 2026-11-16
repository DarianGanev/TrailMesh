package org.trailmesh.app.relevance

import org.junit.Assert.*
import org.junit.Test

class RelevancePolicyTest {
    private val report = RelevantReport("b", 100, 200, GeoPoint(0, 0))
    @Test fun missingConfigurationNeverFallsBackToGlobal() {
        assertEquals(RelevanceDecision.configurationRequired, RelevancePolicy.evaluate(report, null, 100))
    }
    @Test fun routeUsesShortArcAndExpiryAndRejectsAntipodes() {
        val route = RelevanceContext(route = Route(listOf(GeoPoint(0, 1_790_000_000), GeoPoint(0, -1_790_000_000))))
        assertEquals(RelevanceDecision.eligible, RelevancePolicy.evaluate(report.copy(point = GeoPoint(0, 1_800_000_000)), route, 100))
        assertEquals(RelevanceDecision.notRelevant, RelevancePolicy.evaluate(report, route, 100))
        assertEquals(RelevanceDecision.expired, RelevancePolicy.evaluate(report, route, 200))
        val invalid = RelevanceContext(route = Route(listOf(GeoPoint(0,0), GeoPoint(0,1_800_000_000))))
        assertEquals(RelevanceDecision.invalidConfiguration, RelevancePolicy.evaluate(report, invalid, 100))
    }
    @Test fun gpsNeedsRecentAccurateFixButManualAreaRemainsAvailable() {
        val manual = Area(GeoPoint(0,0),100)
        val gps = GPSArea(manual, 1001.0, 100)
        assertEquals(RelevanceDecision.configurationRequired, RelevancePolicy.evaluate(report, RelevanceContext(gpsArea=gps),100))
        assertEquals(RelevanceDecision.eligible, RelevancePolicy.evaluate(report, RelevanceContext(manualArea=manual,gpsArea=gps),100))
        assertEquals(RelevanceDecision.invalidConfiguration, RelevancePolicy.evaluate(report, RelevanceContext(gpsArea=gps.copy(accuracyM=Double.NaN)),100))
    }
    @Test fun selectionDeduplicatesAndSortsByObservationThenID() {
        val context = RelevanceContext(manualArea=Area(GeoPoint(0,0),100))
        assertEquals(listOf("a","b","c"), RelevancePolicy.select(listOf(report,report.copy(id="c",observedAt=99),report.copy(id="a"),report),context,100).map { it.id })
    }
    @Test fun localBoundaryRejectsFloatIntegerFieldsAndUnknownAndNullMembers() {
        val point = mapOf("lat_e7" to 0L,"lon_e7" to 0L)
        for (radius in listOf<Any?>(1000.0,true,null)) {
            assertEquals(RelevanceDecision.invalidConfiguration,RelevancePolicy.evaluateLocal(report,mapOf("manual_area" to mapOf("center" to point,"radius_m" to radius)),100))
        }
        assertEquals(RelevanceDecision.invalidConfiguration,RelevancePolicy.evaluateLocal(report,mapOf("unknown" to 1),100))
        assertEquals(RelevanceDecision.invalidConfiguration,RelevancePolicy.evaluateLocal(report,mapOf("manual_area" to null),100))
        assertEquals(RelevanceDecision.invalidConfiguration,RelevancePolicy.evaluate(report,RelevanceContext(route=Route(List(2049) { GeoPoint(0,0) })),100))
    }
    @Test fun diagnosticsExposeCountsAndReasonsWithDeduplicatedSelection() {
        val context = RelevanceContext(manualArea = Area(GeoPoint(0, 0), 100))
        val candidates = listOf(report, report, report.copy(id = "far", point = GeoPoint(10_000_000, 0)), report.copy(id = "old", expiresAt = 100))
        val summary = RelevancePolicy.diagnostics(candidates, context, 100)
        assertEquals(4, summary.candidateCount)
        assertEquals(1, summary.selectedCount)
        assertEquals(2, summary.decisionCounts[RelevanceDecision.eligible])
        assertEquals(1, summary.decisionCounts[RelevanceDecision.notRelevant])
        assertEquals(1, summary.decisionCounts[RelevanceDecision.expired])
        assertEquals(4, summary.decisionCounts.values.sum())
        assertEquals(3, RelevancePolicy.diagnostics(candidates, null, 100).decisionCounts[RelevanceDecision.configurationRequired])
        val invalid = RelevanceContext(manualArea = Area(GeoPoint(0, 0), 99))
        assertEquals(4, RelevancePolicy.diagnostics(candidates, invalid, 100).decisionCounts[RelevanceDecision.invalidConfiguration])
    }
    @Test fun routeSnapshotsCallerOwnedMutablePoints() {
        val points = mutableListOf(GeoPoint(0,0))
        val context = RelevanceContext(route=Route(points,100))
        points[0] = GeoPoint(100000000,0)
        assertEquals(RelevanceDecision.eligible,RelevancePolicy.evaluate(report,context,100))
    }
}

