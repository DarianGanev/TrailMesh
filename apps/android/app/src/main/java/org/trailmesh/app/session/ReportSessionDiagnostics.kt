package org.trailmesh.app.session

import org.json.JSONArray
import org.json.JSONObject
import org.trailmesh.app.persistence.SavedTestReportEvidence

/** In-memory bounded redacted events. Export is explicit and hashes come from verified storage. */
class ReportSessionDiagnostics {
    private val events = java.util.ArrayDeque<ReportSessionEvent>()

    @Synchronized
    fun record(event: ReportSessionEvent) {
        if (events.size == ReportSessionLimits.EXPORT_EVENTS) events.removeFirst()
        events.addLast(event)
    }

    @Synchronized
    fun export(
        deviceModel: String,
        osVersion: String,
        appBuild: String,
        sourceCommit: String?,
        sessionID: String?,
        state: ReportSessionState,
        saved: List<SavedTestReportEvidence>,
    ): String {
        val records = JSONArray()
        for (e in events) {
            val r = JSONObject().put("code", e.code).put("timestamp_ms", e.timestamp)
            e.peer?.let { r.put("peer_session_id", it) }
            e.bundleID?.let { r.put("bundle_id", it) }
            records.put(r)
        }
        val reports = JSONArray()
        for (r in saved.take(ReportSessionLimits.EXPORT_REPORTS)) reports.put(
            JSONObject()
                .put("bundle_id", r.bundleID)
                .put("canonical_core_sha256", r.canonicalCoreSHA256)
                .put("original_wire_sha256", r.originalWireSHA256)
                .put("observed_at_ms", r.observedAt)
                .put("is_expired", r.isExpired)
                .put("is_quarantined", r.isQuarantined)
                .put("remaining_hops", r.remainingHops),
        )
        return JSONObject()
            .put("schema", "trailmesh.report-session-log")
            .put("version", 1)
            .put("platform", "android")
            .put("deviceModel", deviceModel)
            .put("osVersion", osVersion)
            .put("appBuild", appBuild)
            .put("sourceCommit", sourceCommit ?: JSONObject.NULL)
            .put("exportID", ReportAdvertisement.randomID())
            .put("sessionID", sessionID?.takeIf { it.isNotEmpty() } ?: JSONObject.NULL)
            .put("state", state.name)
            .put("events", records)
            .put("saved_test_reports", reports)
            .toString(2)
    }
}
