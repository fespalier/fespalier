package com.vaamapps.fespalier

import com.intellij.execution.Executor
import com.intellij.execution.configurations.CommandLineState
import com.intellij.execution.configurations.ConfigurationFactory
import com.intellij.execution.configurations.ConfigurationTypeUtil
import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.execution.configurations.LocatableConfigurationBase
import com.intellij.execution.configurations.LocatableRunConfigurationOptions
import com.intellij.execution.configurations.RunConfiguration
import com.intellij.execution.configurations.RunProfileState
import com.intellij.execution.configurations.RuntimeConfigurationError
import com.intellij.execution.configurations.SimpleConfigurationType
import com.intellij.execution.process.KillableColoredProcessHandler
import com.intellij.execution.process.ProcessHandler
import com.intellij.execution.process.ProcessTerminatedListener
import com.intellij.execution.runners.ExecutionEnvironment
import com.intellij.icons.AllIcons
import com.intellij.openapi.components.BaseState
import com.intellij.openapi.options.SettingsEditor
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.NotNullLazyValue
import com.intellij.ui.components.JBTextField
import com.intellij.util.execution.ParametersListUtil
import com.intellij.util.ui.FormBuilder
import com.vaamapps.fespalier.core.configurationName
import com.vaamapps.fespalier.core.taskArgs
import com.vaamapps.fespalier.core.taskProblem
import javax.swing.JComponent

/** Run | Edit Configurations | + | fespalier task: one task of `fespalier: tasks:` in a pubspec.yaml. */
class FespalierTaskConfigurationType : SimpleConfigurationType(
    "FespalierTask",
    "fespalier task",
    "A task of fespalier: tasks: in pubspec.yaml, run with fsp",
    NotNullLazyValue.lazy { AllIcons.Actions.Execute },
) {
    override fun createTemplateConfiguration(project: Project): RunConfiguration =
        FespalierTaskConfiguration(project, this, "fespalier task")

    override fun getOptionsClass(): Class<out BaseState> = FespalierTaskOptions::class.java
}

/** The one instance the platform made. */
fun fespalierTaskType(): FespalierTaskConfigurationType =
    ConfigurationTypeUtil.findConfigurationType(FespalierTaskConfigurationType::class.java)

class FespalierTaskOptions : LocatableRunConfigurationOptions() {
    var projectDir by string("")
    var task by string("")
    var target by string("")
    var arguments by string("")
}

class FespalierTaskConfiguration(project: Project, factory: ConfigurationFactory, name: String) :
    LocatableConfigurationBase<FespalierTaskOptions>(project, factory, name) {

    override fun getOptions(): FespalierTaskOptions = super.getOptions() as FespalierTaskOptions

    /** The folder with the pubspec.yaml (absolute, `/` separators). */
    var projectDir: String
        get() = options.projectDir ?: ""
        set(value) { options.projectDir = value }

    /** A name of `fespalier: tasks:`, or `dev` or `build`. */
    var task: String
        get() = options.task ?: ""
        set(value) { options.task = value }

    /** For `build`: what `flutter build` builds. */
    var target: String
        get() = options.target ?: ""
        set(value) { options.target = value }

    /** Passed on after `--`, split like a command line. */
    var arguments: String
        get() = options.arguments ?: ""
        set(value) { options.arguments = value }

    override fun suggestedName(): String? = if (task.isBlank() || projectDir.isBlank()) null else configurationName(task, projectDir)

    override fun getConfigurationEditor(): SettingsEditor<out RunConfiguration> = FespalierTaskEditor()

    override fun checkConfiguration() {
        taskProblem(projectDir, task, target)?.let { throw RuntimeConfigurationError(it) }
    }

    /** The command line the run starts: `fsp ...` or `dart run fespalier ...` in [projectDir]. */
    fun commandLine(): GeneralCommandLine {
        val args = taskArgs(task, target.trim(), ParametersListUtil.parse(arguments, false, true))
        return FespalierService.commandLine(FespalierService.getInstance(project).taskInvocation(args), projectDir)
    }

    override fun getState(executor: Executor, environment: ExecutionEnvironment): RunProfileState =
        object : CommandLineState(environment) {
            override fun startProcess(): ProcessHandler {
                // SIGINT first on Stop (soft kill), so `fsp dev` stops flutter and its `with` commands.
                val handler = KillableColoredProcessHandler(commandLine())
                ProcessTerminatedListener.attach(handler)
                return handler
            }
        }
}

class FespalierTaskEditor : SettingsEditor<FespalierTaskConfiguration>() {
    private val projectDir = JBTextField()
    private val task = JBTextField()
    private val target = JBTextField()
    private val arguments = JBTextField()

    override fun resetEditorFrom(s: FespalierTaskConfiguration) {
        projectDir.text = s.projectDir
        task.text = s.task
        target.text = s.target
        arguments.text = s.arguments
    }

    override fun applyEditorTo(s: FespalierTaskConfiguration) {
        s.projectDir = projectDir.text.trim()
        s.task = task.text.trim()
        s.target = target.text.trim()
        s.arguments = arguments.text
    }

    override fun createEditor(): JComponent =
        FormBuilder.createFormBuilder()
            .addLabeledComponent("Project folder (with pubspec.yaml):", projectDir)
            .addLabeledComponent("Task:", task)
            .addLabeledComponent("Target (build only):", target)
            .addLabeledComponent("Arguments (after --):", arguments)
            .panel
}
