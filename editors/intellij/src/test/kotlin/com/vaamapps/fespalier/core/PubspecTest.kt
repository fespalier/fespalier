package com.vaamapps.fespalier.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PubspecTest {
    private val withDependency = """
        name: shop
        dependencies:
          flutter:
            sdk: flutter
          fespalier:
            git:
              url: https://github.com/vaam-apps/fespalier.git
              path: packages/fespalier
    """.trimIndent()

    @Test
    fun detectsTheDependency() {
        assertTrue(isFespalierPubspec(withDependency))
        assertTrue(isFespalierPubspec("name: a\ndev_dependencies:\n  fespalier: ^0.2.0\n"))
        assertTrue(isFespalierPubspec("name: a\ndependency_overrides:\n    fespalier:\n        path: ../x\n"))
    }

    @Test
    fun detectsTheSectionEvenWithoutTheDependency() {
        assertTrue(isFespalierPubspec("name: a\nfespalier:\n  app_dir: lib/routes\n"))
        assertTrue(isFespalierPubspec("name: a\nfespalier: # settings\n"))
        assertTrue(isFespalierPubspec("name: a\r\nfespalier:\r\n  format: true\r\n"))
    }

    @Test
    fun otherPubspecsAreNotFespalierProjects() {
        assertFalse(isFespalierPubspec("name: fespalier\nversion: 0.2.0\n")) // the package itself
        assertFalse(isFespalierPubspec("name: a\ndependencies:\n  fespalier_extras: ^1.0.0\n"))
        assertFalse(isFespalierPubspec("name: a\ndependencies:\n  flutter:\n    sdk: flutter\n"))
        assertFalse(isFespalierPubspec("name: a\n# fespalier: later\ndependencies:\n  # fespalier: ^1\n  go_router: ^14.0.0\n"))
        assertFalse(isFespalierPubspec("name: a\nflutter:\n  fespalier:\n    x: 1\n")) // not a dependency section
        assertFalse(isFespalierPubspec(""))
    }

    @Test
    fun aNestedKeyNamedFespalierIsNotTheDependency() {
        // `fespalier:` as a key inside another dependency's own mapping.
        val text = "name: a\ndependencies:\n  other:\n    path: ../o\n    fespalier: yes\n"
        assertFalse(isFespalierPubspec(text))
    }

    @Test
    fun appDirDefaultsToLibApp() {
        assertEquals("lib/app", appDirFromPubspec(withDependency))
        assertEquals("lib/app", appDirFromPubspec("name: a\nfespalier:\n  format: true\n"))
        assertEquals("lib/app", appDirFromPubspec("name: a\nfespalier:\n  app_dir:\n"))
        assertEquals("lib/app", appDirFromPubspec(""))
    }

    @Test
    fun readsAppDirFromTheFespalierSection() {
        assertEquals("lib/routes", appDirFromPubspec("name: a\nfespalier:\n  app_dir: lib/routes\n"))
        assertEquals("lib/routes", appDirFromPubspec("name: a\nfespalier:\n  format: true\n  app_dir: ./lib\\routes/  # here\n"))
        assertEquals("lib/my routes", appDirFromPubspec("name: a\nfespalier:\n  app_dir: \"lib/my routes\" # quoted\n"))
        assertEquals("lib/x", appDirFromPubspec("name: a\r\nfespalier:\r\n  app_dir: 'lib/x'\r\n"))
    }

    @Test
    fun appDirOfAnotherSectionIsIgnored() {
        assertEquals("lib/app", appDirFromPubspec("name: a\nother:\n  app_dir: nope\nfespalier:\n  format: true\n"))
        assertEquals("lib/app", appDirFromPubspec("name: a\nfespalier:\n  format: true\nother:\n  app_dir: nope\n"))
    }

    @Test
    fun underAppDir() {
        assertTrue(isUnderAppDir("lib/app/products/page.dart", "lib/app"))
        assertTrue(isUnderAppDir("lib/app", "lib/app"))
        assertTrue(isUnderAppDir("lib\\app\\a.dart", "./lib/app/"))
        assertFalse(isUnderAppDir("lib/application/page.dart", "lib/app"))
        assertFalse(isUnderAppDir("lib/main.dart", "lib/app"))
        assertFalse(isUnderAppDir("test/app/a_test.dart", "lib/app"))
    }

    @Test
    fun projectFromPubspec() {
        val p = FespalierProject.fromPubspec("C:\\work\\shop\\", "name: a\nfespalier:\n  app_dir: lib/routes\n")!!
        assertEquals(FespalierProject("C:/work/shop", "lib/routes"), p)
        assertNull(FespalierProject.fromPubspec("/x", "name: a\n"))
    }

    @Test
    fun relativePathsAndAffectedFiles() {
        val p = FespalierProject("/work/shop", "lib/app")
        assertEquals("lib/app/a/page.dart", p.relativePath("/work/shop/lib/app/a/page.dart"))
        assertEquals("lib/app/a/page.dart", p.relativePath("\\work\\shop\\lib\\app\\a\\page.dart"))
        assertNull(p.relativePath("/work/shop2/lib/app/a.dart"))
        assertNull(p.relativePath("/elsewhere/lib/app/a.dart"))
        assertTrue(p.affectedBy("/work/shop/lib/app/a/page.dart"))
        assertTrue(p.affectedBy("/work/shop/pubspec.yaml"))
        assertFalse(p.affectedBy("/work/shop/lib/main.dart"))
        assertFalse(p.affectedBy("/work/shop/lib/app.g.dart"))
        assertFalse(p.affectedBy("/work/other/lib/app/a.dart"))
    }
}
