package com.vaamapps.fespalier.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RunnerTest {
    private val root = "/work/shop"

    @Test
    fun autoPrefersFspWhenItIsOnPath() {
        val inv = invocation(RunnerSetting.AUTO, "fsp", true, Subcommand.CHECK, root)
        assertEquals(Invocation("fsp", listOf("check", "--json", "--project", root)), inv)
    }

    @Test
    fun autoFallsBackToDartRun() {
        val inv = invocation(RunnerSetting.AUTO, "fsp", false, Subcommand.GEN, root)
        assertEquals(Invocation("dart", listOf("run", "fespalier", "gen", "--json", "--project", root)), inv)
        assertEquals("dart run fespalier gen --json --project /work/shop", inv.display)
    }

    @Test
    fun explicitRunnersIgnoreAvailability() {
        assertEquals("fsp", invocation(RunnerSetting.FSP, "fsp", false, Subcommand.CHECK, root).command)
        assertEquals("dart", invocation(RunnerSetting.DART, "fsp", true, Subcommand.CHECK, root).command)
    }

    @Test
    fun usesTheConfiguredFspPathOrTheDefault() {
        assertEquals("/opt/fsp/bin/fsp", invocation(RunnerSetting.FSP, " /opt/fsp/bin/fsp ", true, Subcommand.CHECK, root).command)
        assertEquals("fsp", invocation(RunnerSetting.FSP, "  ", true, Subcommand.CHECK, root).command)
    }

    private val inv = Invocation("fsp", listOf("check", "--json"))
    private val error = """{"file":"lib/app/a/page.dart","line":2,"column":1,"severity":"error","message":"bad"}"""
    private val warning = """{"file":"lib/app/a/page.dart","line":null,"column":null,"severity":"warning","message":"careful"}"""

    @Test
    fun aCleanRunHasNoFailure() {
        val r = interpret(inv, Subcommand.CHECK, RawOutput(0, "", "✓ 12 routes, no errors\n"))
        assertTrue(r.findings.isEmpty())
        assertNull(r.failure)
        assertEquals("✓ 12 routes, no errors", r.summary)
    }

    @Test
    fun errorsInTheRoutesAreNotAFailureToRun() {
        val r = interpret(inv, Subcommand.CHECK, RawOutput(1, "$error\n$warning\n", "1 error\n"))
        assertEquals(2, r.findings.size)
        assertEquals(Counts(1, 1), r.counts)
        assertNull(r.failure)
    }

    @Test
    fun warningsWithAnExitCodeAreNotAFailureEither() {
        val r = interpret(inv, Subcommand.GEN, RawOutput(0, "$warning\n", ""))
        assertNull(r.failure)
        assertEquals(Counts(0, 1), r.counts)
    }

    @Test
    fun aNonZeroExitWithoutErrorDiagnosticsIsAFailure() {
        val r = interpret(inv, Subcommand.CHECK, RawOutput(2, "", "error: no lib/app folder in /work/shop\n"))
        assertEquals("error: no lib/app folder in /work/shop", r.failure)
        val silent = interpret(inv, Subcommand.CHECK, RawOutput(3, "", ""))
        assertEquals("fsp exited with code 3", silent.failure)
        val onlyWarnings = interpret(inv, Subcommand.CHECK, RawOutput(2, "$warning\n", "boom\n"))
        assertEquals("boom", onlyWarnings.failure)
    }

    @Test
    fun aProcessThatCouldNotStartIsAFailure() {
        val r = interpret(inv, Subcommand.CHECK, RawOutput(null, "", "", "Cannot run program \"fsp\""))
        assertEquals("Cannot run program \"fsp\"", r.failure)
        assertTrue(r.couldNotStart)
        assertFalse(interpret(inv, Subcommand.CHECK, RawOutput(2, "", "boom\n")).couldNotStart)
    }

    @Test
    fun keepsTheGeneratorsOwnWordsForTheLog() {
        val r = interpret(inv, Subcommand.GEN, RawOutput(0, "hello\n$error\n", "warn: a\n\n✓ 3 routes → lib/app.g.dart\n"))
        assertEquals(listOf("hello", "warn: a", "✓ 3 routes → lib/app.g.dart"), r.log)
        assertEquals("✓ 3 routes → lib/app.g.dart", r.summary)
    }

    @Test
    fun hintsNameTheRightFix() {
        assertTrue(startFailureHint(Invocation("dart", emptyList())).contains("Dart SDK"))
        assertTrue(startFailureHint(Invocation("fsp", emptyList())).contains("Settings"))
    }
}
