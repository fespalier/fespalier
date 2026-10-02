package com.vaamapps.fespalier

import com.intellij.lang.annotation.AnnotationHolder
import com.intellij.lang.annotation.ExternalAnnotator
import com.intellij.lang.annotation.HighlightSeverity
import com.intellij.openapi.editor.Editor
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.TextRange
import com.intellij.psi.PsiFile
import com.vaamapps.fespalier.core.FespalierProject
import com.vaamapps.fespalier.core.Finding
import com.vaamapps.fespalier.core.Severity
import com.vaamapps.fespalier.core.Span
import com.vaamapps.fespalier.core.toSpan

/**
 * Shows what `fsp check --json` reports inline, in the files under the project's app folder
 * (and in its pubspec.yaml), and in any other Dart file under `lib/` (string paths that match no
 * route, since fespalier 0.7.0). The check itself is shared by all open files of the project, see
 * [FespalierService].
 *
 * Like the generator, it reads the files as they are on disk. Highlights in a file with unsaved
 * edits can therefore sit a few lines off until the next save.
 */
class FespalierAnnotator : ExternalAnnotator<FespalierAnnotator.Info, List<FespalierAnnotator.Problem>>() {
    class Info(val ide: Project, val project: FespalierProject, val relPath: String, val text: String)

    class Problem(val span: Span, val finding: Finding)

    override fun collectInformation(file: PsiFile, editor: Editor, hasErrors: Boolean): Info? {
        val vf = file.virtualFile ?: return null
        if (!vf.isInLocalFileSystem) return null
        val project = FespalierProjects.of(file.project, vf) ?: return null
        if (!project.affectedBy(vf.path)) return null
        val rel = project.relativePath(vf.path) ?: return null
        return Info(file.project, project, rel, file.text)
    }

    override fun doAnnotate(info: Info): List<Problem>? {
        val allowRun = FespalierSettings.getInstance().state.checkOnSave
        val result = FespalierService.getInstance(info.ide).resultFor(info.project, allowRun) ?: return null
        if (result.failure != null) return emptyList() // the notification has said why
        return result.findings
            .filter { it.file == info.relPath }
            .map { Problem(toSpan(it, info.text), it) }
    }

    override fun apply(file: PsiFile, problems: List<Problem>?, holder: AnnotationHolder) {
        if (problems == null) return
        val length = file.textLength
        for (p in problems) {
            val severity = if (p.finding.severity == Severity.ERROR) HighlightSeverity.ERROR else HighlightSeverity.WARNING
            val builder = holder.newAnnotation(severity, "fespalier: ${p.finding.message}")
            val start = p.span.start.coerceIn(0, length)
            val end = p.span.end.coerceIn(start, length)
            if (end > start) {
                builder.range(TextRange(start, end)).create()
            } else {
                builder.fileLevel().create()
            }
        }
    }
}
