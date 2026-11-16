package org.trailmesh.app.relevance

import org.json.*
import org.junit.Assert.*
import org.junit.Test

abstract class RelevanceVectorContract {
    protected abstract fun resource(name: String): ByteArray
    private fun local(value: Any?): Any? = when(value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence().associateWith { local(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { local(value.get(it)) }
        else -> value
    }
    private fun report(o: JSONObject) = RelevantReport(o.getString("id"),o.getLong("observed_at_ms"),o.getLong("expires_at_ms"),GeoPoint(o.getLong("lat_e7"),o.getLong("lon_e7")))
    @Test fun sharedLiteralDecisionsAndOrderingMatchLocalPolicy() {
        val root = JSONObject(String(resource("relevance-v1-vectors.json"),Charsets.UTF_8))
        val cases = root.getJSONArray("cases")
        assertTrue(cases.length() >= 53)
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            assertEquals(c.getString("name"),c.getString("expected"),RelevancePolicy.evaluateLocal(report(c.getJSONObject("report")),local(c.get("context")),c.getLong("now_ms")).name)
        }
        val selections = root.getJSONArray("selection_cases")
        for (i in 0 until selections.length()) {
            val c = selections.getJSONObject(i)
            val reports = c.getJSONArray("reports")
            val expected = c.getJSONArray("expected_ids")
            assertEquals(c.getString("name"),(0 until expected.length()).map { expected.getString(it) },RelevancePolicy.select((0 until reports.length()).map { report(reports.getJSONObject(it)) },RelevancePolicy.parseLocal(local(c.get("context"))),c.getLong("now_ms")).map { it.id })
        }
    }
}
