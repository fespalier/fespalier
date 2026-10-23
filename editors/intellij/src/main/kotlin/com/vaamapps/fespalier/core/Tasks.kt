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
    /** The main command, as `fsp run <name> --dry-run` shows it. */
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
        out.exitCode != 0 ->
            if (out.stderr.contains("unexpected argument '--json'")) {
                OLD_FSP_TASKS
            } else {
                out.stderr.lines().lastOrNull { it.isNotBlank() }?.trim() ?: "${inv.command} exited with code ${out.exitCode}"
            }
        else -> null
    }
    val tasks = if (failure == null) out.stdout.lines().mapNotNull { if (it.isBlank()) null else parseTaskEntry(it) } else emptyList()
    return TaskList(inv, tasks, failure)
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

/** What a run configuration lacks before it can run, or null. */
fun taskProblem(projectDir: String, task: String, target: String): String? = when {
    projectDir.isBlank() -> "Set the project folder: the folder with the pubspec.yaml"
    task.isBlank() -> "Set the task: a name from `fespalier: tasks:` in pubspec.yaml, or dev or build"
    task == "build" && target.isBlank() -> "The build task needs a target: what flutter build builds (apk, web, ios, ...)"
    else -> null
}

/** `codegen (shop)`: the task and the project's folder name. */
fun configurationName(task: String, root: String): String = "$task (${root.trimEnd('/').substringAfterLast('/')})"
