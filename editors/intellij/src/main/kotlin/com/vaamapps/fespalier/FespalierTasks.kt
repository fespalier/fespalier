package com.vaamapps.fespalier

import com.intellij.execution.ProgramRunnerUtil
import com.intellij.execution.RunManager
import com.intellij.execution.RunnerAndConfigurationSettings
import com.intellij.execution.actions.ConfigurationContext
import com.intellij.execution.actions.LazyRunConfigurationProducer
import com.intellij.execution.configurations.ConfigurationFactory
import com.intellij.execution.configurations.ConfigurationType
import com.intellij.execution.executors.DefaultRunExecutor
import com.intellij.execution.lineMarker.RunLineMarkerContributor
import com.intellij.icons.AllIcons
import com.intellij.openapi.editor.Document
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.Ref
import com.intellij.psi.PsiDocumentManager
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiFile
import com.intellij.psi.util.CachedValueProvider
import com.intellij.psi.util.CachedValuesManager
import com.vaamapps.fespalier.core.FespalierProject
import com.vaamapps.fespalier.core.PubspecTask
import com.vaamapps.fespalier.core.configurationName
import com.vaamapps.fespalier.core.pubspecTasks
import com.vaamapps.fespalier.core.sameFolder

/** What a pubspec.yaml says about fespalier: the project, and its task keys. Read once per change of the file. */
private class PubspecParse(val project: FespalierProject?, val tasks: List<PubspecTask>)

private fun parsedPubspec(file: PsiFile, dir: String): PubspecParse = CachedValuesManager.getCachedValue(file) {
    PubspecTaskAt.parses++
    val text = file.text
    val project = FespalierProject.fromPubspec(dir, text)
    CachedValueProvider.Result.create(PubspecParse(project, if (project == null) emptyList() else pubspecTasks(text)), file)
}

/** The task whose key is at [element], in a pubspec.yaml of a fespalier project. */
data class PubspecTaskAt(val root: String, val task: String, val keyOffset: Int) {
    companion object {
        /** How many times a pubspec.yaml was read for its tasks: a highlighting pass reads it once (a test checks). */
        @Volatile
        internal var parses = 0

        /** The task on the line [element] starts on (any leaf of it: right-click anywhere on the line). */
        fun of(element: PsiElement): PubspecTaskAt? {
            val where = locate(element) ?: return null
            return at(where.file, where.dir, where.doc, where.line)
        }

        /**
         * The task whose key is the leaf [element], for the gutter, which asks about every leaf of the file:
         * a leaf that does not start its line is turned away before anything is read.
         */
        fun ofKey(element: PsiElement): PubspecTaskAt? {
            val where = locate(element) ?: return null
            val start = where.doc.getLineStartOffset(where.line)
            if (!where.doc.charsSequence.subSequence(start, where.offset).isBlank()) return null
            val found = at(where.file, where.dir, where.doc, where.line) ?: return null
            return found.takeIf { it.keyOffset == where.offset }
        }

        private class Where(val file: PsiFile, val dir: String, val doc: Document, val offset: Int, val line: Int)

        private fun locate(element: PsiElement): Where? {
            val file = element.containingFile ?: return null
            if (file.name != "pubspec.yaml") return null
            val dir = file.originalFile.virtualFile?.parent ?: return null
            val doc = PsiDocumentManager.getInstance(element.project).getDocument(file) ?: return null
            val offset = element.textRange.startOffset
            if (offset > doc.textLength) return null
            return Where(file, dir.path, doc, offset, doc.getLineNumber(offset))
        }

        private fun at(file: PsiFile, dir: String, doc: Document, line: Int): PubspecTaskAt? {
            val parsed = parsedPubspec(file, dir)
            val project = parsed.project ?: return null
            val key = parsed.tasks.firstOrNull { it.line == line } ?: return null
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
        return sameFolder(configuration.projectDir, at.root) && configuration.task == at.task
    }
}

/** A run icon in the gutter of each task key of `fespalier: tasks:` (pubspec.yaml is YAML). */
class FespalierTaskLineMarker : RunLineMarkerContributor() {
    override fun getInfo(element: PsiElement): Info? {
        if (element.firstChild != null) return null // leaves only: one icon per key
        if (PubspecTaskAt.ofKey(element) == null) return null
        return withExecutorActions(AllIcons.RunConfigurations.TestState.Run)
    }

    override fun isDumbAware(): Boolean = true
}

/**
 * The run configuration of [task] in the project at [root]: the one with that folder and that task (found
 * by them, not by name: two projects can share a folder name, and a user may rename or edit a
 * configuration), else a new temporary one with a name nobody has.
 */
fun taskConfiguration(ide: Project, root: String, task: String): RunnerAndConfigurationSettings {
    val type = fespalierTaskType()
    val runManager = RunManager.getInstance(ide)
    val existing = runManager.getConfigurationSettingsList(type).firstOrNull {
        val c = it.configuration as? FespalierTaskConfiguration
        c != null && sameFolder(c.projectDir, root) && c.task == task
    }
    if (existing != null) return existing
    return runManager.createConfiguration(unusedName(runManager, type, configurationName(task, root, ide.basePath)), type).also {
        val c = it.configuration as FespalierTaskConfiguration
        c.projectDir = root
        c.task = task
        runManager.setTemporaryConfiguration(it)
    }
}

private fun unusedName(runManager: RunManager, type: ConfigurationType, name: String): String {
    var candidate = name
    var n = 2
    while (runManager.findConfigurationByTypeAndName(type, candidate) != null) candidate = "$name (${n++})"
    return candidate
}

/** Runs [task] of the project at [root] through its run configuration. */
fun runTask(ide: Project, root: String, task: String) {
    val settings = taskConfiguration(ide, root, task)
    RunManager.getInstance(ide).selectedConfiguration = settings
    ProgramRunnerUtil.executeConfiguration(settings, DefaultRunExecutor.getRunExecutorInstance())
}
