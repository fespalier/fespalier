package com.vaamapps.fespalier

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys
import com.intellij.openapi.fileEditor.FileDocumentManager
import com.intellij.openapi.progress.ProcessCanceledException
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.progress.Task
import com.intellij.openapi.project.DumbAwareAction
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.LocalFileSystem
import com.intellij.openapi.vfs.VfsUtil
import com.intellij.openapi.vfs.VirtualFile
import com.vaamapps.fespalier.core.FespalierProject
import com.vaamapps.fespalier.core.Subcommand

/**
 * Tools | fespalier: Check and fespalier: Generate. They run for the project of the file in the
 * editor, or for every fespalier project in the IDE project when there is none, on a background
 * thread with a progress indicator, then show what came out in a notification.
 */
abstract class FespalierAction(private val sub: Subcommand) : DumbAwareAction() {
    override fun getActionUpdateThread() = ActionUpdateThread.BGT

    override fun update(e: AnActionEvent) {
        e.presentation.isEnabledAndVisible = e.project != null
    }

    override fun actionPerformed(e: AnActionEvent) {
        val ide = e.project ?: return
        val context = e.getData(CommonDataKeys.VIRTUAL_FILE)
        // fsp reads the files on disk.
        FileDocumentManager.getInstance().saveAllDocuments()
        object : Task.Backgroundable(ide, "fespalier: ${sub.cli}", true) {
            override fun run(indicator: ProgressIndicator) {
                indicator.isIndeterminate = true
                runFor(ide, context, indicator)
            }
        }.queue()
    }

    private fun runFor(ide: Project, context: VirtualFile?, indicator: ProgressIndicator) {
        val projects: List<FespalierProject> =
            (context?.let { FespalierProjects.ofInReadAction(ide, it) })?.let { listOf(it) } ?: FespalierProjects.all(ide)
        if (projects.isEmpty()) {
            FespalierNotifier.noProject(ide, sub)
            return
        }
        val service = FespalierService.getInstance(ide)
        try {
            for (project in projects) {
                indicator.text = "fespalier ${sub.cli}: ${project.root}"
                val result = service.runAndStore(project, sub, indicator)
                if (sub == Subcommand.GEN && result.failure == null) refresh(project)
                FespalierNotifier.outcome(ide, project, result)
            }
        } catch (_: ProcessCanceledException) {
            // The user cancelled the task: nothing to report.
        } finally {
            service.refreshHighlighting()
        }
    }

    /** `gen` wrote a file the IDE has not looked at yet. */
    private fun refresh(project: FespalierProject) {
        val fs = LocalFileSystem.getInstance()
        fs.refreshAndFindFileByPath(project.root)?.let { VfsUtil.markDirtyAndRefresh(true, false, false, it) }
        fs.refreshAndFindFileByPath("${project.root}/lib")?.let { VfsUtil.markDirtyAndRefresh(true, true, false, it) }
    }
}

class FespalierCheckAction : FespalierAction(Subcommand.CHECK)

class FespalierGenerateAction : FespalierAction(Subcommand.GEN)
