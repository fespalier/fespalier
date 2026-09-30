package com.vaamapps.fespalier.core

/**
 * A small JSON reader for the one-object-per-line output of `fsp ... --json`. It exists so the
 * mapping code has no dependency (the IDE's own JSON libraries are not on a plain test
 * classpath, and bundling one into the plugin is not worth it for five fields).
 *
 * Objects become [Map], arrays [List], numbers [Long] (when integral) or [Double], strings
 * [String], and `true`/`false`/`null` their Kotlin counterparts.
 */
internal object MiniJson {
    class JsonException(message: String) : Exception(message)

    /** Parses one complete JSON value; anything after it (but whitespace) is an error. */
    fun parse(text: String): Any? {
        val p = Parser(text)
        p.skipWhitespace()
        val value = p.value()
        p.skipWhitespace()
        if (!p.atEnd()) p.fail("unexpected trailing text")
        return value
    }

    private class Parser(private val s: String) {
        private var i = 0

        fun atEnd() = i >= s.length

        fun fail(what: String): Nothing = throw JsonException("$what at offset $i")

        fun skipWhitespace() {
            while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++
        }

        fun value(): Any? {
            if (atEnd()) fail("unexpected end")
            return when (val c = s[i]) {
                '{' -> obj()
                '[' -> array()
                '"' -> string()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", null)
                else -> if (c == '-' || c in '0'..'9') number() else fail("unexpected '$c'")
            }
        }

        private fun literal(word: String, result: Any?): Any? {
            if (!s.startsWith(word, i)) fail("invalid literal")
            i += word.length
            return result
        }

        private fun obj(): Map<String, Any?> {
            i++ // {
            val out = LinkedHashMap<String, Any?>()
            skipWhitespace()
            if (peek() == '}') {
                i++
                return out
            }
            while (true) {
                skipWhitespace()
                if (peek() != '"') fail("expected a string key")
                val key = string()
                skipWhitespace()
                if (peek() != ':') fail("expected ':'")
                i++
                skipWhitespace()
                out[key] = value()
                skipWhitespace()
                when (peek()) {
                    ',' -> i++
                    '}' -> {
                        i++
                        return out
                    }
                    else -> fail("expected ',' or '}'")
                }
            }
        }

        private fun array(): List<Any?> {
            i++ // [
            val out = ArrayList<Any?>()
            skipWhitespace()
            if (peek() == ']') {
                i++
                return out
            }
            while (true) {
                skipWhitespace()
                out.add(value())
                skipWhitespace()
                when (peek()) {
                    ',' -> i++
                    ']' -> {
                        i++
                        return out
                    }
                    else -> fail("expected ',' or ']'")
                }
            }
        }

        private fun peek(): Char = if (atEnd()) fail("unexpected end") else s[i]

        private fun string(): String {
            i++ // opening quote
            val sb = StringBuilder()
            while (true) {
                if (atEnd()) fail("unterminated string")
                val c = s[i++]
                when {
                    c == '"' -> return sb.toString()
                    c == '\\' -> {
                        if (atEnd()) fail("unterminated escape")
                        when (val e = s[i++]) {
                            '"', '\\', '/' -> sb.append(e)
                            'b' -> sb.append('\b')
                            'f' -> sb.append('\u000C')
                            'n' -> sb.append('\n')
                            'r' -> sb.append('\r')
                            't' -> sb.append('\t')
                            'u' -> {
                                if (i + 4 > s.length) fail("short \\u escape")
                                val code = s.substring(i, i + 4).toIntOrNull(16) ?: fail("bad \\u escape")
                                sb.append(code.toChar()) // surrogate pairs arrive as two escapes
                                i += 4
                            }
                            else -> fail("bad escape '\\$e'")
                        }
                    }
                    c < ' ' -> fail("control character in string")
                    else -> sb.append(c)
                }
            }
        }

        private fun number(): Any {
            val start = i
            if (s[i] == '-') i++
            while (i < s.length && (s[i] in '0'..'9' || s[i] in ".eE+-")) i++
            val text = s.substring(start, i)
            return text.toLongOrNull() ?: text.toDoubleOrNull() ?: fail("bad number '$text'")
        }
    }
}
