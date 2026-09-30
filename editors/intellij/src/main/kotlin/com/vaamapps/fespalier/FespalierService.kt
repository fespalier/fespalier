package com.vaamapps.fespalier

import com.intellij.codeInsight.daemon.DaemonCodeAnalyzer
import com.intellij.execution.ExecutionException
import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.execution.process.CapturingProcessHandler
import com.intellij.openapi.Disposable
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.serviceIfCreated
import com.intellij.openapi.progress.ProcessCanceledException
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.project.Project
import com.intellij.openapi.project.ProjectManager
import com.intellij.openapi.util.SystemInfo
import com.intellij.openapi.vfs.VirtualFileManager
import com.intellij.openapi.vfs.newvfs.BulkFileListener
import com.intellij.openapi.vfs.newvfs.events.VFileEvent
import com.vaamapps.fespalier.core.FespalierProject
import com.vaamapps.fespalier.core.Invocation
import com.vaamapps.fespalier.core.RawOutput
import com.vaamapps.fespalier.core.RunResult
import com.vaamapps.fespalier.core.RunnerSetting
import com.vaamapps.fespalier.core.Subcommand
import com.vaamapps.fespalier.core.interpret
import com.vaamapps.fespalier.core.invocation
import java.nio.charset.StandardCharsets
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock

/**
 * Runs `fsp check` / `fsp gen` and remembers the last `check` per fespalier project, so the
 * annotator of every open file in it shares one run instead of starting one each.
 *
 * A result is dropped when a file that can change it (see [FespalierProject.affectedBy]) is
 * written, and the editors are asked to highlight again, which runs the next check.
 */
@Service(Service.Level.PROJECT)
class FespalierService(private val ide: Project) : Disposable {
    private class Entry(@Volatile var project: FespalierProject) {
        @Volatile var result: RunResult? = null
        @Volatile var stale = true
        val lock = ReentrantLock()
    }

    private val entries = ConcurrentHashMap<String, Entry>()
    private val fspFound = ConcurrentHashMap<String, Boolean>()

    init {
        ide.messageBus.connect(this).subscribe(
            VirtualFileManager.VFS_CHANGES,
            object : BulkFileListener {
                override fun after(events: List<VFileEvent>) {
                    if (entries.isEmpty()) return
                    val paths = events.flatMap { listOfNotNull(it.path, it.file?.path) }
                    var any = false
                    for (e in entries.values) {
                        if (paths.any { e.project.affectedBy(it) }) {
                            e.stale = true
                            any = true
                        }
                    }
                    if (any && FespalierSettings.getInstance().state.checkOnSave) {
                        DaemonCodeAnalyzer.getInstance(ide).restart()
                    }
                }
            },
        )
    }

    /**
     * The result of the last check of [project]. When there is none, or files changed since, and
     * [allowRun] is true, runs a check first (blocking; call it from a background thread). With
     * [allowRun] false a stale result is returned as it is, or null when there never was one.
     */
    fun resultFor(project: FespalierProject, allowRun: Boolean): RunResult? {
        val e = entries.computeIfAbsent(project.root) { Entry(project) }
        e.project = project
        fresh(e)?.let { return it }
        if (!allowRun) return e.result
        // One run per project; the others wait for it (and stay cancellable while they do).
        while (!e.lock.tryLock(50, TimeUnit.MILLISECONDS)) {
            ProgressManager.checkCanceled()
        }
        try {
            fresh(e)?.let { return it }
            val result = storing(e) { run(project, Subcommand.CHECK, ProgressManager.getInstance().progressIndicator, forceDetect = false) }
            if (result.failure != null) FespalierNotifier.failure(ide, result)
            return result
        } finally {
            e.lock.unlock()
        }
    }

    private fun fresh(e: Entry): RunResult? = e.result?.takeIf { !e.stale }

    /** Runs `check` or `gen` for [project], remembers the outcome as its current result, and returns it. */
    fun runAndStore(project: FespalierProject, sub: Subcommand, indicator: ProgressIndicator?): RunResult {
        val e = entries.computeIfAbsent(project.root) { Entry(project) }
        e.project = project
        return storing(e) { run(project, sub, indicator, forceDetect = true) }
    }

    /** Runs [block] and keeps its result in [e]. A cancelled or failed run leaves the entry stale. */
    private fun storing(e: Entry, block: () -> RunResult): RunResult {
        e.stale = false // a write while the run is going sets it again
        try {
            return block().also { e.result = it }
        } catch (t: Throwable) {
            e.stale = true
            throw t
        }
    }

    fun invalidateAll() {
        fspFound.clear()
        for (e in entries.values) e.stale = true
        DaemonCodeAnalyzer.getInstance(ide).restart()
    }

    /** Asks the open editors to highlight again, which shows the result just stored. */
    fun refreshHighlighting() = DaemonCodeAnalyzer.getInstance(ide).restart()

    private fun run(project: FespalierProject, sub: Subcommand, indicator: ProgressIndicator?, forceDetect: Boolean): RunResult {
        val s = FespalierSettings.getInstance().state
        val available = s.runner == RunnerSetting.AUTO && fspAvailable(s.fspPath, forceDetect)
        val inv = invocation(s.runner, s.fspPath, available, sub, project.root)
        return interpret(inv, sub, execute(inv, project.root, indicator))
    }

    private fun fspAvailable(fspPath: String, force: Boolean): Boolean {
        if (!force) fspFound[fspPath]?.let { return it }
        val found = try {
            val cmd = commandLine(Invocation(fspPath.trim().ifEmpty { "fsp" }, listOf("--version")), null)
            val out = CapturingProcessHandler(cmd).runProcess(10_000, true)
            !out.isTimeout && out.exitCode == 0
        } catch (_: ExecutionException) {
            false
        }
        fspFound[fspPath] = found
        return found
    }

    override fun dispose() {}

    companion object {
        private const val TIMEOUT_MS = 5 * 60 * 1000 // `dart run` may download fsp the first time

        fun getInstance(ide: Project): FespalierService = ide.getService(FespalierService::class.java)

        /** After a settings change: every open project forgets its results. */
        fun invalidateEverywhere() {
            for (p in ProjectManager.getInstance().openProjects) p.serviceIfCreated<FespalierService>()?.invalidateAll()
        }

        private fun commandLine(inv: Invocation, cwd: String?): GeneralCommandLine {
            // On Windows `dart` is often dart.bat (Flutter's copy), which only a shell can start.
            val cmd = if (SystemInfo.isWindows && inv.command == "dart") {
                GeneralCommandLine(listOf("cmd", "/c", inv.command) + inv.args)
            } else {
                GeneralCommandLine(inv.command).withParameters(inv.args)
            }
            if (cwd != null) cmd.withWorkDirectory(cwd)
            // CONSOLE: the environment of a shell, so a PATH set in .zshrc is seen when the IDE
            // was started from the Dock.
            return cmd.withCharset(StandardCharsets.UTF_8).withParentEnvironmentType(GeneralCommandLine.ParentEnvironmentType.CONSOLE)
        }

        private fun execute(inv: Invocation, cwd: String, indicator: ProgressIndicator?): RawOutput =
            try {
                val handler = CapturingProcessHandler(commandLine(inv, cwd))
                val out = if (indicator != null) {
                    handler.runProcessWithProgressIndicator(indicator, TIMEOUT_MS, true)
                } else {
                    handler.runProcess(TIMEOUT_MS, true)
                }
                when {
                    out.isCancelled -> throw ProcessCanceledException()
                    out.isTimeout -> RawOutput(null, out.stdout, out.stderr, "`${inv.display}` did not finish within ${TIMEOUT_MS / 60000} minutes")
                    else -> RawOutput(out.exitCode, out.stdout, out.stderr)
                }
            } catch (e: ExecutionException) {
                RawOutput(null, "", "", e.message ?: "could not start ${inv.command}")
            }
    }
}
