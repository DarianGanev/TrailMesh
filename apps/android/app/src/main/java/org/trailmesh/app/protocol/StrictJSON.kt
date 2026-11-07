package org.trailmesh.app.protocol

/** Integer-only RFC 8785 data model for the frozen report profile. */
sealed class ReportJSON {
    class ObjectValue(val members: Map<String, ReportJSON>) : ReportJSON()

    class ArrayValue(val values: List<ReportJSON>) : ReportJSON()

    class StringValue(val value: String) : ReportJSON()

    class IntegerValue(val value: Long) : ReportJSON()

    data object NullValue : ReportJSON()

    operator fun get(key: String): ReportJSON? = (this as? ObjectValue)?.members?.get(key)

    val text: String?
        get() = (this as? StringValue)?.value

    val number: Long?
        get() = (this as? IntegerValue)?.value

    fun canonical(): String =
        when (this) {
            is ObjectValue ->
                members.toSortedMap().entries.joinToString(",", "{", "}") {
                    quote(it.key) + ":" + it.value.canonical()
                }
            is ArrayValue -> values.joinToString(",", "[", "]") { it.canonical() }
            is StringValue -> quote(value)
            is IntegerValue -> {
                require(value in -SAFE_INTEGER..SAFE_INTEGER)
                value.toString()
            }
            NullValue -> "null"
        }

    fun canonicalBytes(): ByteArray = canonical().toByteArray(Charsets.UTF_8)

    companion object {
        const val SAFE_INTEGER = 9_007_199_254_740_991L

        private fun quote(value: String): String = buildString {
            append('"')
            var i = 0
            while (i < value.length) {
                val c = value[i++]
                when (c) {
                    '"' -> append("\\\"")
                    '\\' -> append("\\\\")
                    '\b' -> append("\\b")
                    '\u000c' -> append("\\f")
                    '\n' -> append("\\n")
                    '\r' -> append("\\r")
                    '\t' -> append("\\t")
                    else ->
                        when {
                            c.code < 32 -> append("\\u" + c.code.toString(16).padStart(4, '0'))
                            c.isHighSurrogate() -> {
                                require(i < value.length && value[i].isLowSurrogate())
                                append(c)
                                append(value[i++])
                            }
                            c.isLowSurrogate() -> error("Invalid Unicode")
                            else -> append(c)
                        }
                }
            }
            append('"')
        }
    }
}

object StrictJSON {
    fun parse(input: ByteArray, maxBytes: Int = 8192, maxDepth: Int = 8): ReportJSON {
        require(input.size <= maxBytes && maxDepth > 0)
        val decoder =
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
        val text =
            try {
                decoder.decode(java.nio.ByteBuffer.wrap(input)).toString()
            } catch (_: java.nio.charset.CharacterCodingException) {
                throw IllegalArgumentException("Invalid UTF-8")
            }
        require(!text.startsWith('\uFEFF'))
        return Parser(text, maxDepth).parse()
    }

    private class Parser(val source: String, val maxDepth: Int) {
        var index = 0

        fun space() {
            while (index < source.length && source[index] in " \t\r\n") index++
        }

        fun take(c: Char): Boolean {
            space()
            return if (index < source.length && source[index] == c) {
                index++
                true
            } else false
        }

        fun parse(): ReportJSON {
            val value = value(0)
            space()
            require(index == source.length)
            return value
        }

        fun value(depth: Int): ReportJSON {
            space()
            require(index < source.length)
            return when (source[index]) {
                '{' -> {
                    require(depth < maxDepth)
                    index++
                    val members = linkedMapOf<String, ReportJSON>()
                    if (!take('}')) {
                        do {
                            space()
                            val key = string()
                            require(!members.containsKey(key))
                            require(take(':'))
                            members[key] = value(depth + 1)
                        } while (take(','))
                        require(take('}'))
                    }
                    ReportJSON.ObjectValue(members)
                }
                '[' -> {
                    require(depth < maxDepth)
                    index++
                    val values = mutableListOf<ReportJSON>()
                    if (!take(']')) {
                        do {
                            values.add(value(depth + 1))
                        } while (take(','))
                        require(take(']'))
                    }
                    ReportJSON.ArrayValue(values)
                }
                '"' -> ReportJSON.StringValue(string())
                'n' -> {
                    require(source.startsWith("null", index))
                    index += 4
                    ReportJSON.NullValue
                }
                else -> number()
            }
        }

        fun string(): String {
            require(index < source.length && source[index++] == '"')
            val result = StringBuilder()
            while (index < source.length) {
                var c = source[index++]
                if (c == '"') {
                    val text = result.toString()
                    var i = 0
                    while (i < text.length) {
                        val ch = text[i++]
                        if (ch.isHighSurrogate()) {
                            require(i < text.length && text[i++].isLowSurrogate())
                        } else require(!ch.isLowSurrogate())
                    }
                    return text
                }
                require(c.code >= 32)
                if (c == '\\') {
                    require(index < source.length)
                    c =
                        when (val escaped = source[index++]) {
                            '"',
                            '\\',
                            '/' -> escaped
                            'b' -> '\b'
                            'f' -> '\u000c'
                            'n' -> '\n'
                            'r' -> '\r'
                            't' -> '\t'
                            'u' -> {
                                require(index + 4 <= source.length)
                                val hex = source.substring(index, index + 4)
                                require(hex.all { it in "0123456789abcdefABCDEF" })
                                index += 4
                                hex.toInt(16).toChar()
                            }
                            else -> throw IllegalArgumentException("Invalid escape")
                        }
                }
                result.append(c)
            }
            throw IllegalArgumentException("Unterminated string")
        }

        fun number(): ReportJSON {
            val start = index
            if (source[index] == '-') {
                index++
                require(index < source.length)
            }
            if (source[index] == '0') index++
            else {
                require(source[index] in '1'..'9')
                while (index < source.length && source[index] in '0'..'9') index++
            }
            require(index == source.length || source[index] in " \t\r\n,]}")
            val number = source.substring(start, index).toLong()
            require(number in -ReportJSON.SAFE_INTEGER..ReportJSON.SAFE_INTEGER)
            return ReportJSON.IntegerValue(number)
        }
    }
}
