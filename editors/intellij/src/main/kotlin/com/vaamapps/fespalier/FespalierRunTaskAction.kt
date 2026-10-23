package com.vaamapps.fespalier

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.progress.Task
import com.intellij.openapi.project.DumbAwareAction
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.popup.JBPopupFactory
import com.vaamapps.fespalier.core.FespalierProject
import com.vaamapps.fespalier.core.TaskEntry
import com.vaamapps.fespalier.core.configurationName

/**
 * Tools | fespalier: Run Task...: lists the tasks `fsp run --json` reports for the project of the file
 * in the editor (every fespalier project when there is none), and runs the one picked.
 */
class FespalierRunTaskAction : DumbAwareAction() {
    private class Choice(val project: FespalierProject, val entry: TaskEntry, val label: String) {
        override fun toString() = "$label    ${entry.run}"
    }

    override fun getActionUpdateThread() = ActionUpdateThread.BGT

    override fun update(e: AnActionEvent) {
        e.presentation.isEnabledAndVisible = e.project != null
    }

    override fun actionPerformed(e: AnActionEvent) {
        val ide = e.project ?: return
        val context = e.getData(CommonDataKeys.VIRTUAL_FILE)
        object : Task.Backgroundable(ide, "fespalier: listing the tasks", true) {
            override fun run(indicator: ProgressIndicator) {
                indicator.isIndeterminate = true
                val projects = context?.let { FespalierProjects.ofInReadAction(ide, it) }?.let { listOf(it) } ?: FespalierProjects.all(ide)
                if (projects.isEmpty()) {
                    FespalierNotifier.noProject(ide, "fespalier: run task")
                    return
                }
                val service = FespalierService.getInstance(ide)
                val choices = mutableListOf<Choice>()
                for (p in projects) {
                    val listed = service.listTasks(p, indicator)
                    if (listed.failure != null) {
                        FespalierNotifier.taskListFailure(ide, p, listed)
                        continue
                    }
                    for (t in listed.tasks) {
                        choices += Choice(p, t, if (projects.size > 1) configurationName(t.name, p.root, ide.basePath) else t.name)
                    }
                }
                if (choices.isEmpty()) return
                ApplicationManager.getApplication().invokeLater {
                    if (!ide.isDisposed) choose(ide, choices)
                }
            }
        }.queue()
    }

    private fun choose(ide: Project, choices: List<Choice>) {
        JBPopupFactory.getInstance()
            .createPopupChooserBuilder(choices)
            .setTitle("fespalier: Run Task")
            .setItemChosenCallback { runTask(ide, it.project.root, it.entry.name) }
            .createPopup()
            .showCenteredInCurrentWindow(ide)
    }
}
