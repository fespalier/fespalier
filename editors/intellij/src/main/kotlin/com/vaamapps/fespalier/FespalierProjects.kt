package com.vaamapps.fespalier

import com.intellij.openapi.application.ReadAction
import com.intellij.openapi.project.Project
import com.intellij.openapi.roots.ProjectFileIndex
import com.intellij.openapi.vfs.VfsUtilCore
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.psi.search.FilenameIndex
import com.intellij.psi.search.GlobalSearchScope
import com.vaamapps.fespalier.core.FespalierProject
import java.io.IOException
import java.util.concurrent.Callable

/** Finds the fespalier projects (a pubspec.yaml that lists fespalier or has a `fespalier:` section). */
object FespalierProjects {
    private const val PUBSPEC = "pubspec.yaml"

    /** Folders that hold copies or build output of pubspecs, never a project of their own. */
    private val SKIPPED = listOf("/.dart_tool/", "/build/", "/ephemeral/", "/node_modules/", "/.symlinks/")

    /**
     * The fespalier project [file] belongs to: the nearest folder above it (within its content
     * root) that has a pubspec.yaml, if that pubspec uses fespalier. Call it in a read action.
     */
    fun of(ide: Project, file: VirtualFile): FespalierProject? {
        val bound = ProjectFileIndex.getInstance(ide).getContentRootForFile(file)
        var dir: VirtualFile? = if (file.isDirectory) file else file.parent
        var depth = 0
        while (dir != null && depth++ < 64) {
            val pubspec = dir.findChild(PUBSPEC)
            if (pubspec != null && !pubspec.isDirectory) return read(dir, pubspec)
            if (dir == bound) return null
            dir = dir.parent
        }
        return null
    }

    /** Every fespalier project in the IDE project. Waits for indexing to finish. */
    fun all(ide: Project): List<FespalierProject> =
        ReadAction.nonBlocking(
            Callable {
                FilenameIndex.getVirtualFilesByName(PUBSPEC, GlobalSearchScope.projectScope(ide))
                    .filter { vf -> SKIPPED.none { vf.path.contains(it) } }
                    .mapNotNull { vf -> vf.parent?.let { read(it, vf) } }
                    .sortedBy { it.root }
            },
        ).inSmartMode(ide).executeSynchronously()

    /** [of] for use outside a read action. */
    fun ofInReadAction(ide: Project, file: VirtualFile): FespalierProject? = ReadAction.compute<FespalierProject?, RuntimeException> { of(ide, file) }

    private fun read(dir: VirtualFile, pubspec: VirtualFile): FespalierProject? =
        try {
            FespalierProject.fromPubspec(dir.path, VfsUtilCore.loadText(pubspec))
        } catch (_: IOException) {
            null
        }
}
