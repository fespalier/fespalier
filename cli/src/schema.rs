//! `fsp schema` (since 0.23.0): the JSON Schema (draft-07) of the `fespalier:` section of
//! pubspec.yaml, for editors: completion, hover and validation of the keys `config.rs` reads.
//!
//! The schema is written by hand, in `schema/fespalier.schema.json`, and embedded here, so it is the
//! schema of the `fsp` that prints it. `schema_tests.rs` keeps it in step with the code: every key a
//! struct of `config.rs` accepts (serde's own list of fields), every task key of `tasks.rs`, every
//! enum's values and every default, and every pubspec of the repository must validate. A key added to
//! `config.rs` or `tasks.rs` fails those tests until the schema has it.
//!
//! An editor applies one schema to a file: a second schema for `pubspec.yaml` would replace the
//! one the JSON Schema Store gives it, in VS Code's YAML extension (its associations outrank the
//! store's) and in IntelliJ (a plugin's schema outranks the catalog). So `fsp schema --pubspec`
//! prints a schema for the whole file: the store's pubspec schema, through a `$ref`, with the
//! `fespalier:` section added.
//! The editor plugins ship that file (`editors/vscode/schemas/pubspec.schema.json`,
//! `editors/intellij/src/main/resources/schemas/pubspec.schema.json`), and a test compares both with
//! what this prints (`FSP_UPDATE_GOLDEN=1` writes them).

use anyhow::Result;
use clap::Args;
use serde_json::{Map, Value, json};

/// The schema of the `fespalier:` section, as written.
pub const SECTION: &str = include_str!("../schema/fespalier.schema.json");

/// The JSON Schema Store's schema of pubspec.yaml, the URL its catalog gives (so an editor that already
/// downloaded it for the catalog reuses that copy).
pub const SCHEMASTORE_PUBSPEC: &str = "https://www.schemastore.org/pubspec.json";

#[derive(Args, Debug)]
pub struct SchemaCmd {
    /// Print a schema for the whole pubspec.yaml: the JSON Schema Store's pubspec schema with the `fespalier:` section added (what the editor plugins ship)
    #[arg(long)]
    pub pubspec: bool,
}

/// The schema of the `fespalier:` section.
///
/// # Panics
///
/// Never: the embedded file is JSON, which `schema_tests.rs` checks.
#[must_use]
pub fn section() -> Value {
    #[allow(clippy::expect_used, reason = "the embedded file is checked by a test")]
    serde_json::from_str(SECTION).expect("schema/fespalier.schema.json is JSON")
}

/// The schema of a whole pubspec.yaml: the JSON Schema Store's, and the `fespalier:` section (which may also
/// be empty: `fespalier:` alone reads as no section). The section's definitions move to the root,
/// beside the section itself, so its `#/definitions/...` references still resolve.
#[must_use]
pub fn pubspec() -> Value {
    let mut section = section();
    let mut definitions = Map::new();
    if let Some(Value::Object(defs)) = section
        .as_object_mut()
        .and_then(|s| s.shift_remove("definitions"))
    {
        definitions = defs;
    }
    let description = section.get("description").cloned().unwrap_or(Value::Null);
    if let Some(s) = section.as_object_mut() {
        s.shift_remove("$schema");
    }
    let mut all = Map::new();
    all.insert("fespalier".into(), section);
    all.extend(definitions);
    json!({
        "$schema": "http://json-schema.org/draft-07/schema#",
        "title": "pubspec.yaml with fespalier",
        "description": "The JSON Schema Store's schema of pubspec.yaml (www.schemastore.org), and the fespalier: section that fsp reads. Written by `fsp schema --pubspec`.",
        "allOf": [{ "$ref": SCHEMASTORE_PUBSPEC }],
        "properties": {
            "fespalier": {
                "description": description,
                "anyOf": [{ "$ref": "#/definitions/fespalier" }, { "type": "null" }]
            }
        },
        "definitions": all,
    })
}

/// The text `fsp schema` prints: pretty JSON with a final newline.
#[must_use]
pub fn text(pubspec: bool) -> String {
    let value = if pubspec { self::pubspec() } else { section() };
    let mut out = serde_json::to_string_pretty(&value).unwrap_or_default();
    out.push('\n');
    out
}

pub fn run(cmd: &SchemaCmd) -> Result<()> {
    out!("{}", text(cmd.pubspec));
    Ok(())
}
