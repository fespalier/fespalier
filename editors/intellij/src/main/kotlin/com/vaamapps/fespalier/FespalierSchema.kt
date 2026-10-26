package com.vaamapps.fespalier

import com.intellij.openapi.project.DumbAware
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.VirtualFile
import com.jetbrains.jsonSchema.extension.JsonSchemaFileProvider
import com.jetbrains.jsonSchema.extension.JsonSchemaProviderFactory
import com.jetbrains.jsonSchema.extension.SchemaType
import com.jetbrains.jsonSchema.impl.JsonSchemaVersion
import com.vaamapps.fespalier.core.isPubspecPath

/**
 * The schema of `pubspec.yaml` with its `fespalier:` section (since fespalier 0.23.0): completion,
 * quick documentation and checks of the section's keys, wherever the IDE applies JSON schemas to
 * YAML (the bundled YAML plugin, in IntelliJ IDEA and Android Studio).
 *
 * The IDE applies one schema to a file, and a plugin's outranks the JSON Schema Store catalog's (the
 * one `pubspec.yaml` gets without this plugin), so this schema brings the store's with it: it is
 * what `fsp schema --pubspec` prints, the store's pubspec schema through a `$ref` (downloaded as the
 * catalog's is) with the section added, shipped in the plugin. A schema mapped to `pubspec.yaml` by
 * hand (Settings | Languages & Frameworks | Schemas and DTDs | JSON Schema Mappings) still wins.
 *
 * Registered in `fespalier-json.xml`, only when the JSON plugin is there.
 */
class FespalierSchemaProviderFactory : JsonSchemaProviderFactory, DumbAware {
    override fun getProviders(project: Project): List<JsonSchemaFileProvider> = listOf(PubspecSchemaProvider)
}

/** `schemas/pubspec.schema.json`, for every `pubspec.yaml` (see [isPubspecPath]). */
object PubspecSchemaProvider : JsonSchemaFileProvider {
    const val NAME = "pubspec.yaml with fespalier"
    const val RESOURCE = "/schemas/pubspec.schema.json"

    override fun isAvailable(file: VirtualFile): Boolean = isPubspecPath(file.path)

    override fun getName(): String = NAME

    override fun getSchemaFile(): VirtualFile? = JsonSchemaProviderFactory.getResourceFile(PubspecSchemaProvider::class.java, RESOURCE)

    override fun getSchemaType(): SchemaType = SchemaType.embeddedSchema

    override fun getSchemaVersion(): JsonSchemaVersion = JsonSchemaVersion.SCHEMA_7
}
