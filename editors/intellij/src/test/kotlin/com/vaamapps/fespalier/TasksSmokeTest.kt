package com.vaamapps.fespalier

import com.intellij.execution.RunManager
import com.intellij.execution.RunnerAndConfigurationSettings
import com.intellij.execution.actions.ConfigurationContext
import com.intellij.execution.configurations.RuntimeConfigurationError
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiRecursiveElementVisitor
import com.intellij.testFramework.fixtures.BasePlatformTestCase
import com.intellij.testFramework.fixtures.IdeaTestFixtureFactory
import com.intellij.testFramework.fixtures.TempDirTestFixture
import com.vaamapps.fespalier.core.RunnerSetting
import com.vaamapps.fespalier.core.configurationName
import java.io.File

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
            val runManager = RunManager.getInstance(project)
            runManager.getConfigurationSettingsList(fespalierTaskType()).forEach { runManager.removeConfiguration(it) }
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
        assertEquals(configurationName("codegen", c.projectDir, project.basePath), c.name)

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

    /** Every leaf of the file asks the gutter; the file is read once, and only the keys answer. */
    fun testOneHighlightingPassReadsThePubspecOnce() {
        val file = open()
        val leaves = mutableListOf<PsiElement>()
        file.accept(object : PsiRecursiveElementVisitor() {
            override fun visitElement(element: PsiElement) {
                if (element.firstChild == null) leaves += element
                super.visitElement(element)
            }
        })
        assertTrue(leaves.size > 10)
        val before = PubspecTaskAt.parses
        val keys = leaves.mapNotNull { PubspecTaskAt.ofKey(it) }
        assertEquals(listOf("codegen", "build"), keys.map { it.task })
        assertEquals(1, PubspecTaskAt.parses - before)
        // The context menu works from anywhere on the line, not only from the key.
        val onValue = file.findElementAt(myFixture.editor.document.getLineStartOffset(3) + 20)!!
        assertEquals("codegen", PubspecTaskAt.of(onValue)?.task)
        assertNull(PubspecTaskAt.ofKey(onValue))
    }

    private fun addPubspec(dir: String): String =
        myFixture.addFileToProject("$dir/pubspec.yaml", pubspec).virtualFile.parent.path

    private fun settingsOf(c: RunnerAndConfigurationSettings) = c.configuration as FespalierTaskConfiguration

    /** Two projects named alike (apps/shop, examples/shop) each run their own task. */
    fun testProjectsThatShareAFolderNameKeepTheirOwnConfigurations() {
        val a = addPubspec("apps/shop")
        val b = addPubspec("examples/shop")
        val first = taskConfiguration(project, a, "codegen")
        val second = taskConfiguration(project, b, "codegen")
        assertNotSame(first, second)
        assertFalse(first.name == second.name)
        assertEquals(a, settingsOf(first).projectDir)
        assertEquals(b, settingsOf(second).projectDir)
        // Found again by folder and task, not made again.
        assertSame(first, taskConfiguration(project, a, "codegen"))
        assertSame(second, taskConfiguration(project, b, "codegen"))
        assertNotSame(first, taskConfiguration(project, a, "dev"))
        // One the user edited is still the one for its folder and task.
        settingsOf(first).arguments = "--verbose"
        assertSame(first, taskConfiguration(project, a, "codegen"))
    }

    /** A configuration that has the generated name but belongs to another folder does not win. */
    fun testAConfigurationWithTheNameButAnotherFolderDoesNotWin() {
        val a = addPubspec("apps/shop")
        val b = addPubspec("examples/shop")
        val runManager = RunManager.getInstance(project)
        val name = configurationName("codegen", a, project.basePath)
        val other = runManager.createConfiguration(name, fespalierTaskType())
        settingsOf(other).projectDir = b
        settingsOf(other).task = "codegen"
        runManager.addConfiguration(other)

        val mine = taskConfiguration(project, a, "codegen")
        assertNotSame(other, mine)
        assertEquals(a, settingsOf(mine).projectDir)
        assertEquals("$name (2)", mine.name)
        assertEquals(b, settingsOf(other).projectDir) // untouched
    }

    /** A run starts on the UI thread (this test is on it): it must not wait for `fsp --version`. */
    fun testARunOnTheUiThreadDoesNotWaitForFsp() {
        val dir = addPubspec("shop")
        // A file that is no program: running `--version` on it fails, so it would read as "not installed".
        val fake = File(dir, "fake-fsp").apply {
            writeText("not a program")
            setExecutable(true)
        }
        val s = FespalierSettings.getInstance().state
        s.runner = RunnerSetting.AUTO
        s.fspPath = fake.path
        val c = settingsOf(taskConfiguration(project, dir, "codegen"))
        assertEquals(fake.path, c.commandLine().exePath)
    }

    fun testAFolderWithoutAPubspecIsRefused() {
        val file = open()
        val c = FespalierTaskConfiguration(project, fespalierTaskType(), "t")
        c.task = "codegen"
        c.projectDir = myFixture.tempDirFixture.findOrCreateDir("empty").path
        val message = try {
            c.checkConfiguration()
            null
        } catch (e: RuntimeConfigurationError) {
            e.message
        }
        assertEquals("There is no pubspec.yaml in ${c.projectDir}: set the project folder to the folder with it", message)
        c.projectDir = file.virtualFile.parent.path
        c.checkConfiguration()
    }
}
