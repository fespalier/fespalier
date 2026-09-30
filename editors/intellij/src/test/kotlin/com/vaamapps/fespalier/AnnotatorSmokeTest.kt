package com.vaamapps.fespalier

import com.intellij.lang.annotation.HighlightSeverity
import com.intellij.openapi.util.SystemInfo
import com.intellij.testFramework.fixtures.BasePlatformTestCase
import com.intellij.testFramework.fixtures.IdeaTestFixtureFactory
import com.intellij.testFramework.fixtures.TempDirTestFixture
import com.vaamapps.fespalier.core.RunnerSetting
import java.io.File

class AnnotatorSmokeTest : BasePlatformTestCase() {
    override fun createTempDirTestFixture(): TempDirTestFixture =
        IdeaTestFixtureFactory.getFixtureFactory().createTempDirTestFixture()

    private var saved = Triple(RunnerSetting.AUTO, "fsp", true)

    override fun setUp() {
        super.setUp()
        saved = FespalierSettings.getInstance().state.let { Triple(it.runner, it.fspPath, it.checkOnSave) }
    }

    override fun tearDown() {
        try {
            FespalierSettings.getInstance().state.let {
                it.runner = saved.first
                it.fspPath = saved.second
                it.checkOnSave = saved.third
            }
        } finally {
            super.tearDown()
        }
    }

    /**
     * The whole path in a headless IDE: a stand-in for fsp that prints two diagnostics, the
     * service that runs it, and the annotator that highlights the file. It uses a YAML file
     * because the Dart plugin is not part of the test platform (the annotator is registered for
     * both languages).
     */
    fun testShowsWhatFspReports() {
        if (SystemInfo.isWindows) return // the stand-in for fsp is a shell script
        val dir = File(myFixture.tempDirPath)
        val fsp = File(dir, "fake-fsp")
        fsp.writeText(
            """
            #!/bin/sh
            echo '{"file":"cfg/a.yaml","line":2,"column":3,"severity":"error","message":"bad thing"}'
            echo '{"file":"cfg/a.yaml","line":null,"column":null,"severity":"warning","message":"careful"}'
            echo 'x' >&2
            exit 1
            """.trimIndent(),
        )
        fsp.setExecutable(true)
        val s = FespalierSettings.getInstance().state
        s.runner = RunnerSetting.FSP
        s.fspPath = fsp.path

        myFixture.addFileToProject("pubspec.yaml", "name: x\nfespalier:\n  app_dir: cfg\n")
        val file = myFixture.addFileToProject("cfg/a.yaml", "first: 1\n  second: 2\n")
        myFixture.configureFromExistingVirtualFile(file.virtualFile)
        val infos = myFixture.doHighlighting().filter { it.description?.startsWith("fespalier:") == true }
        assertEquals(setOf("fespalier: bad thing", "fespalier: careful"), infos.map { it.description }.toSet())
        assertEquals(HighlightSeverity.ERROR, infos.first { it.description!!.contains("bad") }.severity)
        assertEquals(HighlightSeverity.WARNING, infos.first { it.description!!.contains("careful") }.severity)
        assertEquals("second", myFixture.file.text.substring(infos.first { it.description!!.contains("bad") }.startOffset).substringBefore(":"))
    }
}
