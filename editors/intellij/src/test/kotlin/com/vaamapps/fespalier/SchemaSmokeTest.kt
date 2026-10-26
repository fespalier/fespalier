package com.vaamapps.fespalier

import com.intellij.codeInspection.LocalInspectionEP
import com.intellij.lang.annotation.HighlightSeverity
import com.intellij.testFramework.fixtures.BasePlatformTestCase
import com.jetbrains.jsonSchema.ide.JsonSchemaService

/**
 * The schema of pubspec.yaml (since fespalier 0.23.0) in a headless IDE: which files get it, and
 * what the YAML plugin makes of it. No network: the JSON Schema Store's part (a remote `$ref`) is not
 * downloaded in a test, so only the `fespalier:` section is checked here.
 */
class SchemaSmokeTest : BasePlatformTestCase() {
    private fun schemasOf(name: String, text: String = "name: shop\n"): List<String> {
        val file = myFixture.addFileToProject(name, text).virtualFile
        return JsonSchemaService.Impl.get(project).getSchemaFilesForFile(file).map { it.name }
    }

    fun testEveryPubspecGetsTheSchemaAndNothingElseDoes() {
        assertEquals(listOf("pubspec.schema.json"), schemasOf("pubspec.yaml"))
        assertEquals(listOf("pubspec.schema.json"), schemasOf("packages/a/pubspec.yaml"))
        assertFalse(schemasOf("analysis_options.yaml").contains("pubspec.schema.json"))
        assertFalse(schemasOf("build/web/pubspec.yaml").contains("pubspec.schema.json"))
    }

    fun testTheKeysOfTheSectionComplete() {
        myFixture.configureByText("pubspec.yaml", "name: shop\nfespalier:\n  main: auto\n  <caret>\n")
        myFixture.completeBasic()
        val keys = myFixture.lookupElementStrings.orEmpty()
        for (key in listOf("app_dir", "adapters", "tasks", "telemetry")) assertTrue(keys.toString(), key in keys)
        assertFalse("a key already there is not offered again", "main" in keys)
    }

    fun testAMistakeInTheSectionIsHighlighted() {
        // The YAML plugin's schema inspection, found by its class name: the plugin has no compile-time YAML dependency.
        val inspection = LocalInspectionEP.LOCAL_INSPECTION.extensionList
            .first { it.implementationClass == "org.jetbrains.yaml.schema.YamlJsonSchemaHighlightingInspection" }
            .instantiateTool()
        myFixture.enableInspections(inspection)
        myFixture.configureByText("pubspec.yaml", "name: shop\nfespalier:\n  app_dirr: lib/app\n  remount: sometimes\n")
        val problems = myFixture.doHighlighting()
            .filter { it.severity.myVal >= HighlightSeverity.WEAK_WARNING.myVal }
            .map { "${myFixture.editor.document.getLineNumber(it.startOffset) + 1}: ${it.description}" }
        assertTrue(problems.toString(), problems.any { it.startsWith("3: ") && "app_dirr" in it })
        assertTrue(problems.toString(), problems.any { it.startsWith("4: ") })
        myFixture.configureByText("pubspec.yaml", "name: shop\nfespalier:\n  app_dir: lib/app\n  remount: on_segments\n")
        val none = myFixture.doHighlighting().filter { it.severity.myVal >= HighlightSeverity.WEAK_WARNING.myVal }
        assertEquals(none.map { it.description }.toString(), 0, none.size)
    }
}
