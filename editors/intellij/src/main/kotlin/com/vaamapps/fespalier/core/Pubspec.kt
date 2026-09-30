package com.vaamapps.fespalier.core

// What the plugin needs from a project's pubspec.yaml: whether it uses fespalier, where its app
// folder is, and whether a file is inside that folder. A small line reader, not a YAML parser.

const val DEFAULT_APP_DIR = "lib/app"

private val DEPENDENCY_SECTIONS = setOf("dependencies", "dev_dependencies", "dependency_overrides")

private val TOP_LEVEL_KEY = Regex("""^([A-Za-z_][\w-]*)\s*:(.*)$""")
private val CHILD_KEY = Regex("""^(\s+)([A-Za-z_][\w-]*)\s*:""")

/** `./lib\app/` -> `lib/app`. */
fun normalizeDir(dir: String): String {
    var d = dir.trim().replace('\\', '/')
    while (d.startsWith("./")) d = d.substring(2)
    return d.trimEnd('/')
}

private fun stripComment(value: String): String {
    val v = value.trim()
    if (v.startsWith("\"") || v.startsWith("'")) {
        val end = v.indexOf(v[0], 1)
        return if (end == -1) v.substring(1) else v.substring(1, end)
    }
    val hash = Regex("""\s#""").find(v)?.range?.first
    return (if (hash == null) v else v.substring(0, hash)).trim()
}

/**
 * Whether the pubspec belongs to a project that uses fespalier: it has a `fespalier:` section
 * (the generator's settings) or lists the `fespalier` package under `dependencies`,
 * `dev_dependencies` or `dependency_overrides`.
 */
fun isFespalierPubspec(pubspec: String): Boolean {
    var section: String? = null
    var childIndent: Int? = null
    for (line in pubspec.lineSequence()) {
        if (line.isBlank() || line.trimStart().startsWith("#")) continue
        if (!line[0].isWhitespace()) {
            val m = TOP_LEVEL_KEY.matchEntire(line.trimEnd())
            section = m?.groupValues?.get(1)
            childIndent = null
            if (section == "fespalier") return true
            continue
        }
        if (section !in DEPENDENCY_SECTIONS) continue
        val m = CHILD_KEY.find(line) ?: continue
        val indent = m.groupValues[1].length
        // Only direct children: `fespalier:` under another package's path or version is not it.
        if (childIndent == null) childIndent = indent
        if (indent == childIndent && m.groupValues[2] == "fespalier") return true
    }
    return false
}

/**
 * `fespalier: app_dir:` from the text of a pubspec.yaml, or `lib/app`. It only looks inside the
 * top-level `fespalier:` mapping.
 */
fun appDirFromPubspec(pubspec: String): String {
    var inSection = false
    for (line in pubspec.lineSequence()) {
        if (Regex("""^fespalier:\s*(#.*)?$""").matches(line)) {
            inSection = true
            continue
        }
        if (!inSection) continue
        if (line.isNotEmpty() && !line[0].isWhitespace() && !line.startsWith("#")) break // next top-level key
        val m = Regex("""^\s+app_dir:\s*(.*)$""").find(line)
        if (m != null) {
            val dir = normalizeDir(stripComment(m.groupValues[1]))
            return dir.ifEmpty { DEFAULT_APP_DIR }
        }
    }
    return DEFAULT_APP_DIR
}

/** Whether [relPath] (relative to the project root) is the app folder or below it. */
fun isUnderAppDir(relPath: String, appDir: String): Boolean {
    val p = normalizeDir(relPath)
    val dir = normalizeDir(appDir)
    return p == dir || p.startsWith("$dir/")
}

/** A project that uses fespalier: the folder with its pubspec.yaml, and its app folder. */
data class FespalierProject(
    /** Absolute path of the folder with the pubspec.yaml, with `/` separators. */
    val root: String,
    /** Relative to [root], normalised (`lib/app` by default). */
    val appDir: String,
) {
    /** Whether a file at [absolutePath] is one that changes the route table (or where it lives). */
    fun affectedBy(absolutePath: String): Boolean {
        val rel = relativePath(absolutePath) ?: return false
        return rel == "pubspec.yaml" || isUnderAppDir(rel, appDir)
    }

    /** [absolutePath] relative to [root] with `/` separators, or null when it is outside it. */
    fun relativePath(absolutePath: String): String? {
        val p = absolutePath.replace('\\', '/')
        val prefix = root.trimEnd('/') + "/"
        return if (p.startsWith(prefix)) p.substring(prefix.length) else null
    }

    companion object {
        /** The project described by [pubspec] at [root], or null when it doesn't use fespalier. */
        fun fromPubspec(root: String, pubspec: String): FespalierProject? =
            if (isFespalierPubspec(pubspec)) {
                FespalierProject(root.replace('\\', '/').trimEnd('/'), appDirFromPubspec(pubspec))
            } else {
                null
            }
    }
}
