package com.vaamapps.fespalier.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FindingsTest {
    @Test
    fun parsesAnErrorWithAPosition() {
        val f = parseFinding("""{"file":"lib/app/products/${'$'}id/page.dart","line":4,"column":7,"severity":"error","message":"bad"}""")
        assertEquals(Finding("lib/app/products/\$id/page.dart", 4, 7, Severity.ERROR, "bad"), f)
    }

    @Test
    fun parsesAWarningWithoutAPosition() {
        val f = parseFinding("""{"file":"lib/app/a/page.dart","line":null,"column":null,"severity":"warning","message":"w"}""")
        assertEquals(Finding("lib/app/a/page.dart", null, null, Severity.WARNING, "w"), f)
    }

    @Test
    fun missingOrInvalidPositionsBecomeNull() {
        val f = parseFinding("""{"file":"a.dart","line":0,"column":-3,"severity":"error","message":"m"}""")!!
        assertNull(f.line)
        assertNull(f.column)
        val g = parseFinding("""{"file":"a.dart","line":"4","column":1.5,"severity":"error","message":"m"}""")!!
        assertNull(g.line)
        assertNull(g.column)
        assertNull(parseFinding("""{"file":"a.dart","severity":"error","message":"m"}""")!!.line)
    }

    @Test
    fun windowsSeparatorsInFileAreNormalised() {
        val f = parseFinding("""{"file":"lib\\app\\a\\page.dart","line":1,"column":1,"severity":"error","message":"m"}""")!!
        assertEquals("lib/app/a/page.dart", f.file)
    }

    @Test
    fun decodesEscapesInTheMessage() {
        val f = parseFinding(
            """{"file":"a.dart","line":1,"column":1,"severity":"error","message":"a \"quoted\" name\nnext é 😀 \\ /"}""",
        )!!
        assertEquals("a \"quoted\" name\nnext é 😀 \\ /", f.message)
    }

    @Test
    fun ignoresExtraFields() {
        val f = parseFinding("""{"file":"a.dart","extra":{"x":[1,2,{"y":null}],"z":true},"line":2,"column":3,"severity":"error","message":"m"}""")
        assertEquals(Finding("a.dart", 2, 3, Severity.ERROR, "m"), f)
    }

    @Test
    fun rejectsWhatIsNotADiagnostic() {
        assertNull(parseFinding("✓ 12 routes, no errors"))
        assertNull(parseFinding("[]"))
        assertNull(parseFinding("42"))
        assertNull(parseFinding("{"))
        assertNull(parseFinding("""{"file":"a.dart","line":1,"column":1,"severity":"info","message":"m"}"""))
        assertNull(parseFinding("""{"file":"a.dart","line":1,"column":1,"severity":"error"}"""))
        assertNull(parseFinding("""{"file":1,"line":1,"column":1,"severity":"error","message":"m"}"""))
        assertNull(parseFinding("""{"file":"a.dart","severity":"error","message":"m"} trailing"""))
        assertNull(parseFinding("""{"file":"a.dart","severity":"error","message":"unterminated}"""))
    }

    @Test
    fun parsesLinesAndKeepsWhatItIgnored() {
        val out = """
            {"file":"a.dart","line":1,"column":1,"severity":"error","message":"one"}

            not json
            {"file":"b.dart","line":null,"column":null,"severity":"warning","message":"two"}
        """.trimIndent().replace("\n", "\r\n")
        val parsed = parseFindings(out)
        assertEquals(listOf("one", "two"), parsed.findings.map { it.message })
        assertEquals(listOf("not json"), parsed.ignored)
    }

    @Test
    fun groupsByFileInFirstSeenOrderAndCountsSeverities() {
        val a1 = Finding("a.dart", 1, 1, Severity.ERROR, "a1")
        val b = Finding("b.dart", 1, 1, Severity.WARNING, "b")
        val a2 = Finding("a.dart", 2, 1, Severity.WARNING, "a2")
        val grouped = groupByFile(listOf(a1, b, a2))
        assertEquals(listOf("a.dart", "b.dart"), grouped.keys.toList())
        assertEquals(listOf(a1, a2), grouped["a.dart"])
        assertEquals(Counts(1, 2), countBySeverity(listOf(a1, b, a2)))
        assertEquals(3, countBySeverity(listOf(a1, b, a2)).total)
    }

    @Test
    fun readsWhatFspActuallyPrints() {
        // Copied from `fsp check --json` on a page whose constructor asks for a `slug` the path lacks,
        // and on a folder with a bad name (a folder is a "file" here, and has no position).
        val out = """
            {"file":"lib/app/products/${'$'}id/page.dart","line":4,"column":42,"severity":"error","message":"can't fill `slug`: it isn't a segment of this path (${'$'}id) or a query parameter (optional and nullable)"}
            {"file":"lib/app/products/[id]","line":null,"column":null,"severity":"error","message":"`[id]` is not a valid URL segment (use a-z, 0-9, - _ . ~; `${'$'}name` for params, `(name)` for groups, `_name` for private folders)"}
            1 error(s); lib/app.g.dart left unchanged
        """.trimIndent()
        val parsed = parseFindings(out)
        assertEquals(2, parsed.findings.size)
        assertEquals(listOf("1 error(s); lib/app.g.dart left unchanged"), parsed.ignored)
        val f = parsed.findings[0]
        assertEquals("lib/app/products/\$id/page.dart", f.file)
        val page = "import 'package:flutter/widgets.dart';\n\nclass ProductPage extends StatelessWidget {\n  const ProductPage({super.key, required this.slug});\n"
        assertEquals("this", toSpan(f, page).of(page))
        assertEquals(Counts(2, 0), countBySeverity(parsed.findings))
    }

    // --- toSpan ---

    private fun span(text: String, line: Int?, column: Int?) =
        toSpan(Finding("a.dart", line, column, Severity.ERROR, "m"), text)

    private fun Span.of(text: String) = text.substring(start, end)

    private val source = "import 'x.dart';\n\n  final \$id = 1;\nclass Page {}\n"

    @Test
    fun underlinesTheWordAtTheColumn() {
        // Line 4 is `class Page {}`; column 7 is the P of Page.
        assertEquals("Page", span(source, 4, 7).of(source))
        // Column 1 is the start of `class`.
        assertEquals("class", span(source, 4, 1).of(source))
        // `$` is part of an identifier in Dart.
        assertEquals("\$id", span(source, 3, 9).of(source))
    }

    @Test
    fun underlinesOneCharacterWhenThereIsNoWord() {
        assertEquals("{", span(source, 4, 12).of(source))
        assertEquals("'", span(source, 1, 8).of(source))
    }

    @Test
    fun lineOnlyUnderlinesTheLineWithoutItsIndentation() {
        assertEquals("final \$id = 1;", span(source, 3, null).of(source))
    }

    @Test
    fun noPositionUnderlinesTheFirstLine() {
        assertEquals("import 'x.dart';", span(source, null, null).of(source))
        // A file that starts with blank lines has nothing on line 1: take the newline.
        val blank = "\nclass A {}"
        assertEquals("\n", span(blank, null, null).of(blank))
    }

    @Test
    fun columnsCountCodePointsNotUtf16Units() {
        // The emoji is one character for fsp and two UTF-16 units for the IDE.
        val text = "// 😀 name\nx"
        assertEquals("name", span(text, 1, 6).of(text))
    }

    @Test
    fun clampsPositionsPastTheEndOfTheText() {
        // Column past the end of the line: its last character.
        assertEquals(";", span(source, 1, 99).of(source))
        // Line past the end of the text (an edit removed lines since the check): the last line.
        val text = "a\nbcd"
        assertEquals("bcd", span(text, 9, 2).of(text))
        assertEquals("bcd", span(text, 9, null).of(text))
    }

    @Test
    fun handlesCrLfAndEmptyText() {
        val text = "one\r\ntwo\r\n"
        assertEquals("two", span(text, 2, 1).of(text))
        assertEquals("o", span(text, 2, 3).of(text)) // 'o' is the last character of `two`
        assertEquals("o", span(text, 2, 99).of(text))
        assertTrue(span("", 1, 1).isEmpty)
        assertTrue(span("", null, null).isEmpty)
    }
}
