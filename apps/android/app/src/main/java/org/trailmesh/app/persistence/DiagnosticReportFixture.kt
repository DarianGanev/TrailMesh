package org.trailmesh.app.persistence

/** Recognizes the legacy fixture in verified rows of the pre-separation product database. */
internal object DiagnosticReportFixture {
    const val NOTE_PREFIX = "SYNTHETIC TrailMesh test "
    private val suffix = Regex("[A-Za-z0-9_-]{8}")

    fun matches(report: StoredReport) =
        report.category == "trail" && report.status == "muddy" &&
            report.latE7 == 426977000L && report.lonE7 == 233219000L &&
            (report.accuracyM == 1L || report.accuracyM == 10L) &&
            report.expiresAt - report.observedAt == 3_600_000L &&
            report.supersedes == null && report.maxHops == 3 &&
            report.note.startsWith(NOTE_PREFIX) && suffix.matches(report.note.removePrefix(NOTE_PREFIX))
}
