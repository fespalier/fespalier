package com.vaamapps.fespalier.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TasksTest {
    // Real `fsp run --json` output (stdout), fsp 0.22.0.
    private val sample = listOf(
        """{"name":"dev","args":["dev"],"needs_target":false,"run":"flutter run","declared":true}""",
        """{"name":"build","args":["build"],"needs_target":true,"run":"flutter build","declared":false}""",
        """{"name":"codegen","args":["run","codegen"],"needs_target":false,"run":"dart run build_runner build","declared":true}""",
    ).joinToString("\n", postfix = "\n")
    private val inv = Invocation("fsp", listOf("run", "--json"))

    @Test
    fun readsTheListing() {
        val r = interpretTaskList(inv, RawOutput(0, sample, ""))
        assertNull(r.failure)
        assertEquals(
            listOf(
                TaskEntry("dev", listOf("dev"), false, "flutter run", true),
                TaskEntry("build", listOf("build"), true, "flutter build", false),
                TaskEntry("codegen", listOf("run", "codegen"), false, "dart run build_runner build", true),
            ),
            r.tasks,
        )
    }

    @Test
    fun aLineThatIsNotATaskIsSkipped() {
        assertNull(parseTaskEntry("hello"))
        assertNull(parseTaskEntry("""{"name":"x","args":[],"run":"y"}"""))
        assertNull(parseTaskEntry("""{"name":"x","args":["run",1],"run":"y"}"""))
        assertNull(parseTaskEntry("[1]"))
        assertEquals("ok", parseTaskEntry("""{"name":"ok","args":["run","ok"],"run":"r"}""")?.name)
    }

    @Test
    fun failuresSayWhy() {
        val old = RawOutput(2, "", "error: unexpected argument '--json' found\n\nUsage: fsp run [OPTIONS] [TASK] [-- <ARGS>...]\n")
        assertEquals(OLD_FSP_TASKS, interpretTaskList(inv, old).failure)
        val bad = RawOutput(1, "", "`fespalier.tasks.codegen` must be a command ...\n")
        assertEquals("`fespalier.tasks.codegen` must be a command ...", interpretTaskList(inv, bad).failure)
        assertEquals("fsp exited with code 3", interpretTaskList(inv, RawOutput(3, "", "")).failure)
        val missing = interpretTaskList(inv, RawOutput(null, "", "", "Cannot run program \"fsp\""))
        assertEquals("Cannot run program \"fsp\"", missing.failure)
        assertTrue(missing.tasks.isEmpty())
    }

    @Test
    fun taskArgsPickTheCommand() {
        assertEquals(listOf("dev"), taskArgs("dev", "", emptyList()))
        assertEquals(listOf("dev", "--", "-d", "chrome"), taskArgs("dev", "", listOf("-d", "chrome")))
        assertEquals(listOf("build", "web", "--", "--release"), taskArgs("build", "web", listOf("--release")))
        assertEquals(listOf("run", "codegen"), taskArgs("codegen", "ignored", emptyList()))
    }

    @Test
    fun aConfigurationSaysWhatItLacks() {
        assertEquals("Set the project folder: the folder with the pubspec.yaml", taskProblem("", "codegen", ""))
        assertEquals("Set the task: a name from `fespalier: tasks:` in pubspec.yaml, or dev or build", taskProblem("/p", " ", ""))
        assertEquals("The build task needs a target: what flutter build builds (apk, web, ios, ...)", taskProblem("/p", "build", ""))
        assertNull(taskProblem("/p", "build", "web"))
        assertNull(taskProblem("/p", "dev", ""))
    }

    @Test
    fun configurationNamesNameTheFolder() {
        assertEquals("codegen (shop)", configurationName("codegen", "/work/examples/shop"))
        assertEquals("dev (shop)", configurationName("dev", "/work/examples/shop/"))
    }

    @Test
    fun findsTheTaskKeysOfThePubspec() {
        val pubspec = listOf(
            "name: shop",
            "tasks:", // not fespalier's
            "  nope: x",
            "fespalier:",
            "  app_dir: lib/app",
            "  tasks: # the commands",
            "    dev:",
            "      before: dart run build_runner build",
            "      with:",
            "        build_runner: dart run build_runner watch",
            "",
            "    # a comment",
            "    codegen: dart run build_runner build",
            "    \"web-release\": fsp build web",
            "  output: lib/app.g.dart",
            "    later: x",
            "dependencies:",
        ).joinToString("\r\n")
        assertEquals(
            listOf(PubspecTask("dev", 6, 4), PubspecTask("codegen", 12, 4), PubspecTask("web-release", 13, 4)),
            pubspecTasks(pubspec),
        )
        assertEquals(emptyList<PubspecTask>(), pubspecTasks("name: a\nfespalier:\n  tasks: {codegen: x}\n"))
        assertEquals(emptyList<PubspecTask>(), pubspecTasks("name: a\n"))
    }
}
