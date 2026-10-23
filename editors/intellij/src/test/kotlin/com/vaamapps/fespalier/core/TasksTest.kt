package com.vaamapps.fespalier.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
    fun aClapErrorIsToldByItsErrorLineNotTheLineThatEndsIt() {
        val help = "\nFor more information, try '--help'.\n"
        // fsp before 0.9.0 has no `run` at all: the old-fsp sentence, as for an fsp that has no --json.
        val noRun = RawOutput(2, "", "error: unrecognized subcommand 'run'\n\n  tip: a similar subcommand exists: 'gen'\n\nUsage: fsp [OPTIONS] <COMMAND>\n$help")
        assertEquals(OLD_FSP_TASKS, interpretTaskList(inv, noRun).failure)
        val other = RawOutput(2, "", "error: unexpected argument '--project' found\n\nUsage: fsp run [OPTIONS] [TASK] [-- <ARGS>...]\n$help")
        assertEquals("error: unexpected argument '--project' found", interpretTaskList(inv, other).failure)
        // fsp's own errors have no prefix and are one line; a warning above them does not hide them.
        val own = RawOutput(1, "", "warning: x\n`fespalier.tasks.codegen` must be ...\n")
        assertEquals("`fespalier.tasks.codegen` must be ...", interpretTaskList(inv, own).failure)
        assertEquals("error: y", interpretTaskList(inv, RawOutput(1, "", "warning: x\nerror: y\nmore\n")).failure)
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
        assertEquals(
            "There is no pubspec.yaml in /p: set the project folder to the folder with it",
            taskProblem("/p", "codegen", "", hasPubspec = false),
        )
        assertNull(taskProblem("/p", "build", "web"))
        assertNull(taskProblem("/p", "dev", ""))
    }

    @Test
    fun configurationNamesNameTheFolder() {
        assertEquals("codegen (shop)", configurationName("codegen", "/work/examples/shop"))
        assertEquals("dev (shop)", configurationName("dev", "/work/examples/shop/"))
        assertEquals("dev (shop)", configurationName("dev", "/work/shop", "/work/shop/"))
    }

    @Test
    fun projectsThatShareAFolderNameGetTwoNames() {
        val base = "/work/repo"
        assertEquals("apps/shop", projectLabel("/work/repo/apps/shop", base))
        assertEquals("examples/shop", projectLabel("/work/repo/examples/shop/", base))
        assertEquals("repo", projectLabel("/work/repo", base)) // the IDE project's own folder
        assertEquals("/elsewhere/shop", projectLabel("/elsewhere/shop", base)) // outside it: the whole path
        assertEquals("shop", projectLabel("/work/repo/shop", null))
        assertEquals("codegen (apps/shop)", configurationName("codegen", "/work/repo/apps/shop", base))
        assertEquals("apps/shop", projectLabel("C:\\w\\repo\\apps\\shop", "C:/w/repo"))
        assertFalse(configurationName("codegen", "/work/repo/apps/shop", base) == configurationName("codegen", "/work/repo/examples/shop", base))
    }

    @Test
    fun foldersAreTheSameWhateverTheSeparators() {
        assertTrue(sameFolder("/work/shop", "/work/shop/"))
        assertTrue(sameFolder("C:\\work\\shop", "C:/work/shop"))
        assertFalse(sameFolder("/work/shop", "/work/shop2"))
        assertFalse(sameFolder("/a/shop", "/b/shop"))
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
