package com.vaamapps.fespalier

import com.intellij.execution.ProgramRunnerUtil
import com.intellij.execution.RunManager
import com.intellij.execution.actions.ConfigurationContext
import com.intellij.execution.actions.LazyRunConfigurationProducer
import com.intellij.execution.configurations.ConfigurationFactory
import com.intellij.execution.executors.DefaultRunExecutor
import com.intellij.execution.lineMarker.RunLineMarkerContributor
import com.intellij.icons.AllIcons
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.Ref
import com.intellij.psi.PsiDocumentManager
import com.intellij.psi.PsiElement
import com.vaamapps.fespalier.core.FespalierProject
import com.vaamapps.fespalier.core.configurationName
import com.vaamapps.fespalier.core.pubspecTasks

/** The task whose key is at [element], in a pubspec.yaml of a fespalier project. */
data class PubspecTaskAt(val root: String, val task: String, val keyOffset: Int) {
    companion object {
        fun of(element: PsiElement): PubspecTaskAt? {
            val file = element.containingFile ?: return null
            val vf = file.originalFile.virtualFile ?: return null
            if (vf.name != "pubspec.yaml") return null
            val dir = vf.parent ?: return null
            val doc = PsiDocumentManager.getInstance(element.project).getDocument(file) ?: return null
            val text = doc.text
            val project = FespalierProject.fromPubspec(dir.path, text) ?: return null
            val line = doc.getLineNumber(element.textRange.startOffset)
            val key = pubspecTasks(text).firstOrNull { it.line == line } ?: return null
            return PubspecTaskAt(project.root, key.name, doc.getLineStartOffset(line) + key.column)
        }
    }
}

/** Run 'codegen (shop)' from the context menu or the gutter of a task in pubspec.yaml. */
class FespalierTaskProducer : LazyRunConfigurationProducer<FespalierTaskConfiguration>() {
    override fun getConfigurationFactory(): ConfigurationFactory = fespalierTaskType()

    override fun setupConfigurationFromContext(
        configuration: FespalierTaskConfiguration,
        context: ConfigurationContext,
        sourceElement: Ref<PsiElement>,
    ): Boolean {
        val at = PubspecTaskAt.of(context.psiLocation ?: return false) ?: return false
        configuration.projectDir = at.root
        configuration.task = at.task
        configuration.setGeneratedName()
        return true
    }

    override fun isConfigurationFromContext(configuration: FespalierTaskConfiguration, context: ConfigurationContext): Boolean {
        val at = PubspecTaskAt.of(context.psiLocation ?: return false) ?: return false
        return configuration.projectDir == at.root && configuration.task == at.task
    }
}

/** A run icon in the gutter of each task key of `fespalier: tasks:` (pubspec.yaml is YAML). */
class FespalierTaskLineMarker : RunLineMarkerContributor() {
    override fun getInfo(element: PsiElement): Info? {
        if (element.firstChild != null) return null // leaves only: one icon per key
        val at = PubspecTaskAt.of(element) ?: return null
        if (element.textRange.startOffset != at.keyOffset) return null
        return withExecutorActions(AllIcons.RunConfigurations.TestState.Run)
    }

    override fun isDumbAware(): Boolean = true
}

/** Runs [task] of the project at [root]: its run configuration, made (temporary) when there is none. */
fun runTask(ide: Project, root: String, task: String) {
    val type = fespalierTaskType()
    val runManager = RunManager.getInstance(ide)
    val name = configurationName(task, root)
    val settings = runManager.findConfigurationByTypeAndName(type, name)
        ?: runManager.createConfiguration(name, type).also {
            val c = it.configuration as FespalierTaskConfiguration
            c.projectDir = root
            c.task = task
            runManager.setTemporaryConfiguration(it)
        }
    runManager.selectedConfiguration = settings
    ProgramRunnerUtil.executeConfiguration(settings, DefaultRunExecutor.getRunExecutorInstance())
}
