package com.vaamapps.fespalier

import com.intellij.execution.actions.ConfigurationContext
import com.intellij.execution.configurations.RuntimeConfigurationError
import com.intellij.testFramework.fixtures.BasePlatformTestCase
import com.intellij.testFramework.fixtures.IdeaTestFixtureFactory
import com.intellij.testFramework.fixtures.TempDirTestFixture
import com.vaamapps.fespalier.core.RunnerSetting

class TasksSmokeTest : BasePlatformTestCase() {
    override fun createTempDirTestFixture(): TempDirTestFixture =
        IdeaTestFixtureFactory.getFixtureFactory().createTempDirTestFixture()

    private val pubspec = listOf(
        "name: shop",
        "fespalier:",
        "  tasks:",
        "    codegen: dart run build_runner build",
        "    build:",
        "      before: echo hi",
        "",
    ).joinToString("\n")

    private var saved = RunnerSetting.AUTO to "fsp"

    override fun setUp() {
        super.setUp()
        saved = FespalierSettings.getInstance().state.let { it.runner to it.fspPath }
    }

    override fun tearDown() {
        try {
            FespalierSettings.getInstance().state.let {
                it.runner = saved.first
                it.fspPath = saved.second
            }
        } finally {
            super.tearDown()
        }
    }

    private fun open() = myFixture.addFileToProject("pubspec.yaml", pubspec).also {
        myFixture.configureFromExistingVirtualFile(it.virtualFile)
    }

    /** The gutter of a task key has a run icon; other lines have none. */
    fun testEachTaskKeyHasARunIcon() {
        open()
        val doc = myFixture.editor.document
        fun guttersOn(line: Int) = myFixture.editor.caretModel.moveToOffset(doc.getLineStartOffset(line)).let { myFixture.findGuttersAtCaret() }
        assertFalse(guttersOn(3).isEmpty()) // codegen:
        assertFalse(guttersOn(4).isEmpty()) // build:
        assertTrue(guttersOn(5).isEmpty()) // before: (inside build)
        assertTrue(guttersOn(1).isEmpty()) // fespalier:
    }

    /** Run from the context of a task key makes a fespalier task configuration for it. */
    fun testTheContextOfATaskMakesItsConfiguration() {
        val file = open()
        val doc = myFixture.editor.document
        val element = file.findElementAt(doc.getLineStartOffset(3) + 4)!!
        val configs = ConfigurationContext(element).configurationsFromContext.orEmpty()
            .map { it.configuration }
            .filterIsInstance<FespalierTaskConfiguration>()
        assertEquals(1, configs.size)
        val c = configs[0]
        assertEquals("codegen", c.task)
        assertEquals(file.virtualFile.parent.path, c.projectDir)
        assertEquals("codegen (${file.virtualFile.parent.name})", c.name)

        val s = FespalierSettings.getInstance().state
        s.runner = RunnerSetting.FSP
        s.fspPath = "/opt/fsp"
        c.arguments = "--x 'a b'"
        val line = c.commandLine()
        assertEquals("/opt/fsp", line.exePath)
        assertEquals(listOf("run", "codegen", "--", "--x", "a b"), line.parametersList.list)
        assertEquals(c.projectDir, line.workDirectory?.path?.replace('\\', '/'))

        c.task = "build"
        assertThrows(RuntimeConfigurationError::class.java) { c.checkConfiguration() }
        c.target = "web"
        c.checkConfiguration()
    }
}
