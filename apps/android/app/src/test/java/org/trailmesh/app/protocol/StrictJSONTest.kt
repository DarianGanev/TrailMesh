package org.trailmesh.app.protocol

import org.junit.Assert.*
import org.junit.Test

class StrictJSONTest {
    @Test
    fun sortsByUtf16AndPreservesUnicodeWithoutNormalization() {
        val wire = "{\"\\ufb33\":0,\"\\ud83d\\ude00\":1,\"\\u0080\":2,\"e\\u0301\":3,\"e\":4}"
        assertEquals(
            "{\"e\":4,\"e\u0301\":3,\"\u0080\":2,\"\ud83d\ude00\":1,\"\ufb33\":0}",
            StrictJSON.parse(wire.toByteArray()).canonical(),
        )
    }

    @Test
    fun canonicalEscapingUsesLowercaseControlEscapesAndLiteralSlash() {
        assertEquals(
            "\"\\u0000\\b\\t\\n\\f\\r\\\"\\\\/\"",
            StrictJSON.parse("\"\\u0000\\b\\t\\n\\f\\r\\\"\\\\\\/\"".toByteArray()).canonical(),
        )
    }

    @Test
    fun rejectsLossyTypesDuplicateKeysAndMalformedSyntax() {
        val inputs =
            listOf(
                "true",
                "false",
                "1.0",
                "1e0",
                "9007199254740992",
                "-9007199254740992",
                "01",
                "+1",
                "--1",
                "[1,]",
                "{\"x\":0,}",
                "{\"x\":1,\"\\u0078\":2}",
                "\"\\ud800\"",
                "\"\\udc00\"",
                "\"\\ud800x\"",
                "\"a\n\"",
                "{}{}",
                "null x",
                "\"\\x20\"",
            )
        for (input in inputs) assertThrows(input, IllegalArgumentException::class.java) {
            StrictJSON.parse(input.toByteArray())
        }
    }

    @Test
    fun rejectsInvalidUtf8BomAndBoundsBeforeParsing() {
        for (bytes in
            listOf(
                byteArrayOf(0xc0.toByte(), 0xaf.toByte()),
                byteArrayOf(0xed.toByte(), 0xa0.toByte(), 0x80.toByte()),
                byteArrayOf(0xef.toByte(), 0xbb.toByte(), 0xbf.toByte(), 0x30),
            )) {
            assertThrows(IllegalArgumentException::class.java) { StrictJSON.parse(bytes) }
        }
        assertEquals("0", StrictJSON.parse((" ".repeat(8191) + "0").toByteArray()).canonical())
        assertThrows(IllegalArgumentException::class.java) {
            StrictJSON.parse((" ".repeat(8192) + "0").toByteArray())
        }
        assertEquals(
            "[".repeat(8) + "0" + "]".repeat(8),
            StrictJSON.parse(("[".repeat(8) + "0" + "]".repeat(8)).toByteArray()).canonical(),
        )
        assertThrows(IllegalArgumentException::class.java) {
            StrictJSON.parse(("[".repeat(9) + "0" + "]".repeat(9)).toByteArray())
        }
    }

    @Test
    fun acceptsSafeIntegerBoundariesAndCanonicalizesNegativeZero() {
        assertEquals(
            "[-9007199254740991,0,9007199254740991]",
            StrictJSON.parse("[-9007199254740991,-0,9007199254740991]".toByteArray()).canonical(),
        )
    }
}
