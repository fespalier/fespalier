package com.vaamapps.fespalier.core

// `fsp check --json` / `fsp gen --json` print one JSON object per line on stdout:
//   {"file": "lib/app/products/$id/page.dart", "line": 4, "column": 7,
//    "severity": "error" | "warning", "message": "..."}
// `file` is relative to the project root; `line` and `column` are 1-based (the column counts
// characters, i.e. Unicode code points) and null when the problem isn't about a place in the
// file. See json_line in cli/src/diag.rs.
//
// Nothing in this package imports the IntelliJ Platform, so it is unit-tested with plain JUnit.

enum class Severity { ERROR, WARNING }

data class Finding(
    /** Relative to the project root, with `/` separators. */
    val file: String,
    /** 1-based, or null when the problem isn't at a place in the file. */
    val line: Int?,
    /** 1-based code points from the start of the line, or null. */
    val column: Int?,
    val severity: Severity,
    val message: String,
)

data class Parsed(
    val findings: List<Finding>,
    /** Non-empty lines that were not a diagnostic object (kept so the caller can log them). */
    val ignored: List<String>,
)

private fun positive(v: Any?): Int? = (v as? Long)?.takeIf { it in 1..Int.MAX_VALUE }?.toInt()

/** One line of `--json` output, or null when it isn't a diagnostic. */
fun parseFinding(line: String): Finding? {
    val raw = try {
        MiniJson.parse(line)
    } catch (_: MiniJson.JsonException) {
        return null
    }
    val o = raw as? Map<*, *> ?: return null
    val file = o["file"] as? String ?: return null
    val message = o["message"] as? String ?: return null
    val severity = when (o["severity"]) {
        "error" -> Severity.ERROR
        "warning" -> Severity.WARNING
        else -> return null
    }
    return Finding(file.replace('\\', '/'), positive(o["line"]), positive(o["column"]), severity, message)
}

fun parseFindings(stdout: String): Parsed {
    val findings = ArrayList<Finding>()
    val ignored = ArrayList<String>()
    for (line in stdout.lineSequence()) {
        if (line.isBlank()) continue
        val f = parseFinding(line)
        if (f != null) findings.add(f) else ignored.add(line)
    }
    return Parsed(findings, ignored)
}

/** Findings grouped by their (project-relative) file, in first-seen order. */
fun groupByFile(findings: List<Finding>): Map<String, List<Finding>> =
    findings.groupByTo(LinkedHashMap()) { it.file }

data class Counts(val errors: Int, val warnings: Int) {
    val total get() = errors + warnings
}

fun countBySeverity(findings: List<Finding>): Counts {
    val errors = findings.count { it.severity == Severity.ERROR }
    return Counts(errors, findings.size - errors)
}

/**
 * A half-open range of UTF-16 offsets in a document. An empty range means "no room to underline
 * anything" (an empty file), for which the caller shows a file-level problem instead.
 */
data class Span(val start: Int, val end: Int) {
    val isEmpty get() = end <= start
}

private fun isIdentifierChar(c: Char) = c == '_' || c == '$' || c.isLetterOrDigit()

/**
 * The text to underline for [f] in a document with [text]:
 *
 * - at a line and column: the word (identifier) that starts there, else the one character there;
 * - at a line only: that line without its indentation;
 * - at neither: the first line.
 *
 * Positions past the end of the text are clamped to it, because the results of a check can be
 * older than the edits in an open editor.
 */
fun toSpan(f: Finding, text: CharSequence): Span {
    // Line starts: offset 0 and after every '\n'.
    val lineStarts = ArrayList<Int>()
    lineStarts.add(0)
    for (i in text.indices) if (text[i] == '\n') lineStarts.add(i + 1)

    val lineIndex = if (f.line == null) 0 else (f.line - 1).coerceAtMost(lineStarts.size - 1)
    val lineStart = lineStarts[lineIndex]
    var lineEnd = if (lineIndex + 1 < lineStarts.size) lineStarts[lineIndex + 1] - 1 else text.length
    if (lineEnd > lineStart && text[lineEnd - 1] == '\r') lineEnd--

    val pastEnd = f.line != null && f.line > lineStarts.size
    if (f.line == null || f.column == null || pastEnd) {
        // Whole line, minus the indentation.
        var s = lineStart
        while (s < lineEnd && (text[s] == ' ' || text[s] == '\t')) s++
        return if (s < lineEnd) Span(s, lineEnd) else Span(lineStart, lineEnd).ifEmptyWiden(text)
    }

    // The column counts code points; offsets count UTF-16 units.
    var pos = lineStart
    var remaining = f.column - 1
    while (remaining > 0 && pos < lineEnd) {
        pos += if (Character.isHighSurrogate(text[pos]) && pos + 1 < lineEnd && Character.isLowSurrogate(text[pos + 1])) 2 else 1
        remaining--
    }
    if (pos >= lineEnd) {
        // At or past the end of the line: underline its last character.
        if (lineEnd == lineStart) return Span(lineStart, lineEnd).ifEmptyWiden(text)
        val lastStart = if (lineEnd - 2 >= lineStart && Character.isLowSurrogate(text[lineEnd - 1]) &&
            Character.isHighSurrogate(text[lineEnd - 2])
        ) lineEnd - 2 else lineEnd - 1
        return Span(lastStart, lineEnd)
    }
    var end = pos
    if (isIdentifierChar(text[pos])) {
        while (end < lineEnd && isIdentifierChar(text[end])) end++
    } else {
        end += if (Character.isHighSurrogate(text[pos]) && pos + 1 < lineEnd && Character.isLowSurrogate(text[pos + 1])) 2 else 1
    }
    return Span(pos, end)
}

/** An empty line has nothing to underline: take the line break after it, when there is one. */
private fun Span.ifEmptyWiden(text: CharSequence): Span =
    if (isEmpty && end < text.length) Span(start, end + 1) else this
