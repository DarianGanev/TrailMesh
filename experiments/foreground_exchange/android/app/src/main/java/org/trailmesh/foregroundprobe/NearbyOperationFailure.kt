package org.trailmesh.foregroundprobe

internal data class NearbyOperationFailure(
    val operation: String,
    val statusCode: Int?,
    val statusName: String?,
    val exceptionType: String,
) {
    fun userMessage(): String {
        val details = statusCode?.let { code ->
            val name = statusName?.takeIf(String::isNotBlank)?.let { ": $it" }.orEmpty()
            " ($code$name)"
        } ?: " (${exceptionType.ifBlank { "unknown error" }})"
        return "$operation failed$details. See test log."
    }
}
