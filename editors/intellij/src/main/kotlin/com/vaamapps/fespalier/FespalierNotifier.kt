package com.vaamapps.fespalier

import com.intellij.notification.Notification
import com.intellij.notification.NotificationAction
import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.fileEditor.OpenFileDescriptor
import com.intellij.openapi.options.ShowSettingsUtil
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.text.StringUtil
import com.intellij.openapi.vfs.LocalFileSystem
import com.vaamapps.fespalier.core.FespalierProject
import com.vaamapps.fespalier.core.Finding
import com.vaamapps.fespalier.core.RunResult
import com.vaamapps.fespalier.core.Severity
import com.vaamapps.fespalier.core.Subcommand
import com.vaamapps.fespalier.core.startFailureHint
import java.io.File

/** The balloons: "could not run fsp", and what a Check or Generate found. */
object FespalierNotifier {
    private const val GROUP = "fespalier"
    private const val MAX_LISTED = 8

    private fun notification(title: String, lines: List<String>, type: NotificationType): Notification =
        NotificationGroupManager.getInstance().getNotificationGroup(GROUP)
            .createNotification(title, lines.joinToString("<br>") { StringUtil.escapeXmlEntities(it) }, type)

    /** fsp did not run, or failed before it could report on the routes. */
    fun failure(ide: Project, r: RunResult) {
        val lines = buildList {
            add(if (r.couldNotStart) "Could not run `${r.invocation.display}`." else "`${r.invocation.display}` failed.")
            add(r.failure ?: "")
            if (r.couldNotStart) add(startFailureHint(r.invocation))
            addAll(r.log.filter { it != r.failure }.takeLast(4))
        }
        notification("fespalier: ${r.subcommand.cli} failed", lines, NotificationType.ERROR)
            .addAction(
                NotificationAction.createSimple("Settings") {
                    ShowSettingsUtil.getInstance().showSettingsDialog(ide, FespalierConfigurable::class.java)
                },
            )
            .notify(ide)
    }

    /** The outcome of an explicit Check or Generate: counts, the first problems, and a way to open one. */
    fun outcome(ide: Project, project: FespalierProject, r: RunResult) {
        if (r.failure != null) {
            failure(ide, r)
            return
        }
        val name = File(project.root).name
        val c = r.counts
        val type = when {
            c.errors > 0 -> NotificationType.ERROR
            c.warnings > 0 -> NotificationType.WARNING
            else -> NotificationType.INFORMATION
        }
        val lines = buildList {
            if (r.summary.isNotEmpty()) add(r.summary)
            for (f in r.findings.take(MAX_LISTED)) add(describe(f))
            if (r.findings.size > MAX_LISTED) add("... and ${r.findings.size - MAX_LISTED} more")
        }.ifEmpty { listOf("No problems.") }
        val n = notification("fespalier ($name): ${r.subcommand.cli}${if (c.total == 0) "" else ", ${plural(c.errors, "error")} ${plural(c.warnings, "warning")}"}", lines, type)
        val first = r.findings.firstOrNull()
        if (first != null) {
            n.addAction(NotificationAction.createSimple("Open first problem") { open(ide, project, first) })
        }
        n.notify(ide)
    }

    fun noProject(ide: Project, sub: Subcommand) {
        notification(
            "fespalier: ${sub.cli}",
            listOf("No project with a `fespalier:` section or a fespalier dependency in its pubspec.yaml was found."),
            NotificationType.INFORMATION,
        ).notify(ide)
    }

    private fun plural(n: Int, word: String) = "$n $word${if (n == 1) "" else "s"}"

    private fun describe(f: Finding): String {
        val where = buildString {
            append(f.file)
            if (f.line != null) append(':').append(f.line)
            if (f.line != null && f.column != null) append(':').append(f.column)
        }
        return "${if (f.severity == Severity.ERROR) "error" else "warning"}  $where  ${f.message}"
    }

    private fun open(ide: Project, project: FespalierProject, f: Finding) {
        val vf = LocalFileSystem.getInstance().refreshAndFindFileByPath("${project.root}/${f.file}") ?: return
        OpenFileDescriptor(ide, vf, ((f.line ?: 1) - 1).coerceAtLeast(0), ((f.column ?: 1) - 1).coerceAtLeast(0)).navigate(true)
    }
}
