package com.vaamapps.fespalier.core

// The tasks of `fespalier: tasks:` as `fsp run --json` lists them (since fespalier 0.22.0), one JSON
// object per line: {"name","args","needs_target","run","declared"}; `dev` and `build` first. See
// `json_lines` in cli/src/tasks.rs. No IDE class here (plain JUnit tests).

/** One task of the listing. */
data class TaskEntry(
    val name: String,
    /** What to give fsp to run it: `[dev]`, `[build]`, `[run, codegen]`. */
    val args: List<String>,
    /** `build`: a target (apk, web, ...) goes right after [args]. */
    val needsTarget: Boolean,
    /** The main command, as the listing of `fsp run` shows it (`flutter run` for an undeclared `dev`). */
    val run: String,
    /** Whether pubspec.yaml has the task (false for the default `dev` and `build`). */
    val declared: Boolean,
)

/** The outcome of one `fsp run --json`. */
data class TaskList(val invocation: Invocation, val tasks: List<TaskEntry>, val failure: String?)

const val OLD_FSP_TASKS = "this fsp cannot list tasks: `fsp run --json` needs fespalier 0.22.0 or later"

/** One line of `fsp run --json`, or null when it is not a task. */
fun parseTaskEntry(line: String): TaskEntry? {
    val o = try {
        MiniJson.parse(line)
    } catch (_: MiniJson.JsonException) {
        return null
    } as? Map<*, *> ?: return null
    val name = o["name"] as? String ?: return null
    val run = o["run"] as? String ?: return null
    val args = (o["args"] as? List<*>)?.map { it as? String ?: return null } ?: return null
    if (name.isEmpty() || args.isEmpty()) return null
    return TaskEntry(name, args, o["needs_target"] == true, run, o["declared"] == true)
}

/** Reads a run of `fsp run --json`: the tasks, or why there are none. */
fun interpretTaskList(inv: Invocation, out: RawOutput): TaskList {
    val failure = when {
        out.startError != null -> out.startError
        out.exitCode != 0 -> taskListFailure(inv, out)
        else -> null
    }
    val tasks = if (failure == null) out.stdout.lines().mapNotNull { if (it.isBlank()) null else parseTaskEntry(it) } else emptyList()
    return TaskList(inv, tasks, failure)
}

// `unexpected argument '--json'`: fsp 0.9 to 0.21; `unrecognized subcommand 'run'`: before 0.9.
private val OLD_FSP = Regex("""unexpected argument '--json'|unrecognized subcommand 'run'""")

/**
 * Why a failed `fsp run --json` gave no list, in one line: the old-fsp sentence, the `error:` line of a
 * clap message (its last line is only `For more information, try '--help'.`), else the last line (fsp's
 * own errors are one line).
 */
internal fun taskListFailure(inv: Invocation, out: RawOutput): String {
    if (OLD_FSP.containsMatchIn(out.stderr)) return OLD_FSP_TASKS
    val lines = out.stderr.lines().map { it.trim() }.filter { it.isNotEmpty() }
    return lines.firstOrNull { it.startsWith("error:") } ?: lines.lastOrNull() ?: "${inv.command} exited with code ${out.exitCode}"
}

/** The fsp arguments of a task: `dev`, `build <target>`, or `run <task>`; [extra] goes after `--`. */
fun taskArgs(task: String, target: String, extra: List<String>): List<String> {
    val head = when (task) {
        "dev" -> listOf("dev")
        "build" -> listOf("build", target)
        else -> listOf("run", task)
    }
    return if (extra.isEmpty()) head else head + "--" + extra
}

/** What a run configuration lacks before it can run, or null. [hasPubspec]: the folder has a pubspec.yaml. */
fun taskProblem(projectDir: String, task: String, target: String, hasPubspec: Boolean = true): String? = when {
    projectDir.isBlank() -> "Set the project folder: the folder with the pubspec.yaml"
    !hasPubspec -> "There is no pubspec.yaml in $projectDir: set the project folder to the folder with it"
    task.isBlank() -> "Set the task: a name from `fespalier: tasks:` in pubspec.yaml, or dev or build"
    task == "build" && target.isBlank() -> "The build task needs a target: what flutter build builds (apk, web, ios, ...)"
    else -> null
}

/** Whether two folder paths name the same folder: `/` or `\\`, with or without a last separator. */
fun sameFolder(a: String, b: String): Boolean =
    a.replace('\\', '/').trimEnd('/') == b.replace('\\', '/').trimEnd('/')

/**
 * How a run configuration and the pick list name a project: its folder name when it is the IDE project's
 * own folder, its path below [base] (`apps/shop`) when it is inside it, else the whole path. So two
 * projects that share a folder name (`apps/shop`, `examples/shop`) get two names.
 */
fun projectLabel(root: String, base: String?): String {
    val r = root.replace('\\', '/').trimEnd('/')
    val b = base?.replace('\\', '/')?.trimEnd('/').orEmpty()
    return when {
        b.isEmpty() || r == b -> r.substringAfterLast('/')
        r.startsWith("$b/") -> r.substring(b.length + 1)
        else -> r
    }
}

/** `codegen (shop)`: the task and the project's [projectLabel]. */
fun configurationName(task: String, root: String, base: String? = null): String = "$task (${projectLabel(root, base)})"
