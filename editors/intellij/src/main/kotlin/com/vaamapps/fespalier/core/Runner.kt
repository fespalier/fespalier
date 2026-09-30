package com.vaamapps.fespalier.core

/** How to run the generator. */
enum class RunnerSetting(val label: String) {
    AUTO("Auto (fsp on PATH, else dart run fespalier)"),
    FSP("fsp"),
    DART("dart run fespalier"),
    ;

    override fun toString() = label
}

enum class Subcommand(val cli: String) {
    CHECK("check"),
    GEN("gen"),
}

data class Invocation(val command: String, val args: List<String>) {
    /** For logs and notifications. */
    val display get() = (listOf(command) + args).joinToString(" ")
}

/**
 * `fsp <sub> --json --project <dir>`, or `dart run fespalier <sub> --json --project <dir>`.
 * With [RunnerSetting.AUTO] fsp is preferred when it is on PATH ([fspAvailable]).
 */
fun invocation(
    runner: RunnerSetting,
    fspPath: String,
    fspAvailable: Boolean,
    subcommand: Subcommand,
    projectDir: String,
): Invocation {
    val tail = listOf(subcommand.cli, "--json", "--project", projectDir)
    val useFsp = runner == RunnerSetting.FSP || (runner == RunnerSetting.AUTO && fspAvailable)
    return if (useFsp) {
        Invocation(fspPath.trim().ifEmpty { "fsp" }, tail)
    } else {
        Invocation("dart", listOf("run", "fespalier") + tail)
    }
}

/** What running a process gave back. */
data class RawOutput(
    /** Exit code; null when the process could not start, timed out or was killed. */
    val exitCode: Int?,
    val stdout: String,
    val stderr: String,
    /** Set when the process could not be started (not installed) or did not finish. */
    val startError: String? = null,
)

/** The outcome of one `check` or `gen` run, ready to show. */
data class RunResult(
    val invocation: Invocation,
    val subcommand: Subcommand,
    val findings: List<Finding>,
    /** stdout lines that were not diagnostics, then stderr: the generator's own words. */
    val log: List<String>,
    /** The last line of stderr, e.g. `✓ 12 routes → lib/app.g.dart`. */
    val summary: String,
    /** Why fsp did not run or did not report properly; null when the run itself worked. */
    val failure: String?,
    /** True when the process never ran (fsp or dart not installed) or was killed after a timeout. */
    val couldNotStart: Boolean = false,
) {
    val counts get() = countBySeverity(findings)
}

/**
 * Reads the output of a run. A non-zero exit with no error diagnostics means fsp itself failed
 * (no app folder, unreadable pubspec, ...), which is not the same as "the routes have errors".
 */
fun interpret(inv: Invocation, sub: Subcommand, out: RawOutput): RunResult {
    val parsed = parseFindings(out.stdout)
    val stderrLines = out.stderr.lines().filter { it.isNotBlank() }
    val counts = countBySeverity(parsed.findings)
    val failure = when {
        out.startError != null -> out.startError
        out.exitCode != 0 && counts.errors == 0 ->
            stderrLines.lastOrNull()?.trim() ?: "${inv.command} exited with code ${out.exitCode}"
        else -> null
    }
    return RunResult(inv, sub, parsed.findings, parsed.ignored + stderrLines, stderrLines.lastOrNull()?.trim() ?: "", failure, out.startError != null)
}

/** The advice shown with a "could not run" notification. */
fun startFailureHint(inv: Invocation): String =
    if (inv.command == "dart") {
        "Install the Dart SDK, or install fsp (see the fespalier README)."
    } else {
        "Install fsp, set its path in Settings | Tools | fespalier, or choose the dart runner."
    }
