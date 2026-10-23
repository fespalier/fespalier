//! `schema/fespalier.schema.json` against the code that reads the section (since 0.23.0). The schema
//! is written by hand; these tests are what keeps it in step:
//!
//! - every struct `config.rs` deserializes a section into has exactly the schema's keys, read from
//!   serde's own list of fields ([`fields_of`]), and so has every task form (`tasks::TASK_KEYS`);
//! - every enum has exactly serde's variants, and every `default` reads as the default;
//! - every pubspec of the repository validates, and a table of mistakes `fsp` refuses is refused.
//!
//! A key added to `config.rs` fails the first test until the schema has it; a new nested section
//! (a struct with `deny_unknown_fields`) also needs a row in [`OBJECTS`], which the same test asks
//! for: every object of the schema with `properties` must be in it.

use std::cell::Cell;
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::Value;

use crate::config::{
    Config, DataRetry, FlavorConfig, Guideline, LinksConfig, LintLevel, LintsConfig, MaestroConfig,
    MainMode, Pubspec, RawConfig, Remount, SizeConfig, TestConfig,
};
use crate::scan::FileStyle;
use crate::schema;
use crate::tasks::{TASK_KEYS, Tasks};

// --- serde's own lists --------------------------------------------------------

/// What [`Probe`] stops with.
#[derive(Debug)]
struct Stop;

impl std::fmt::Display for Stop {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("probed")
    }
}

impl std::error::Error for Stop {}

impl serde::de::Error for Stop {
    fn custom<T: std::fmt::Display>(_: T) -> Self {
        Stop
    }
}

/// A deserializer that reads nothing: it keeps the names serde's derive hands to
/// `deserialize_struct` (the fields) or `deserialize_enum` (the variants, as renamed), and stops.
struct Probe<'a>(&'a Cell<Option<&'static [&'static str]>>);

impl<'de> serde::Deserializer<'de> for Probe<'_> {
    type Error = Stop;

    fn deserialize_any<V: serde::de::Visitor<'de>>(self, _: V) -> Result<V::Value, Stop> {
        Err(Stop)
    }

    fn deserialize_struct<V: serde::de::Visitor<'de>>(
        self,
        _: &'static str,
        fields: &'static [&'static str],
        _: V,
    ) -> Result<V::Value, Stop> {
        self.0.set(Some(fields));
        Err(Stop)
    }

    fn deserialize_enum<V: serde::de::Visitor<'de>>(
        self,
        _: &'static str,
        variants: &'static [&'static str],
        _: V,
    ) -> Result<V::Value, Stop> {
        self.0.set(Some(variants));
        Err(Stop)
    }

    serde::forward_to_deserialize_any! {
        bool i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64 char str string bytes byte_buf
        option unit unit_struct newtype_struct seq tuple tuple_struct map identifier ignored_any
    }
}

/// The keys `T` accepts (its fields) or the values it takes (its variants), as serde has them.
fn names_of<T: for<'de> Deserialize<'de>>() -> BTreeSet<String> {
    let cell = Cell::new(None);
    let _ = T::deserialize(Probe(&cell));
    cell.get()
        .expect("a derived struct or enum")
        .iter()
        .map(|s| (*s).to_string())
        .collect()
}

fn fields_of<T: for<'de> Deserialize<'de>>() -> BTreeSet<String> {
    names_of::<T>()
}

fn set(names: &[&str]) -> BTreeSet<String> {
    names.iter().map(|s| (*s).to_string()).collect()
}

// --- the schema ---------------------------------------------------------------

fn section() -> Value {
    schema::section()
}

/// The schema node at a JSON pointer of the section (`/definitions/links`).
fn at<'a>(root: &'a Value, pointer: &str) -> &'a Value {
    root.pointer(pointer)
        .unwrap_or_else(|| panic!("no {pointer} in the schema"))
}

fn keys(node: &Value) -> BTreeSet<String> {
    node["properties"]
        .as_object()
        .map(|m| m.keys().cloned().collect())
        .unwrap_or_default()
}

fn enum_of(node: &Value) -> BTreeSet<String> {
    node["enum"]
        .as_array()
        .unwrap_or_else(|| panic!("no enum in {node}"))
        .iter()
        .map(|v| v.as_str().map_or_else(|| v.to_string(), str::to_string))
        .collect()
}

/// Every object of the schema that lists `properties`, and what it must list.
fn objects() -> Vec<(&'static str, BTreeSet<String>)> {
    let named: BTreeSet<String> = TASK_KEYS
        .iter()
        .filter(|k| **k != "hot_reload")
        .map(|k| (*k).to_string())
        .collect();
    vec![
        ("", fields_of::<RawConfig>()),
        ("/properties/lints", fields_of::<LintsConfig>()),
        ("/definitions/links", fields_of::<LinksConfig>()),
        ("/definitions/flavor", fields_of::<FlavorConfig>()),
        ("/definitions/maestro", fields_of::<MaestroConfig>()),
        ("/definitions/size", fields_of::<SizeConfig>()),
        ("/definitions/test", fields_of::<TestConfig>()),
        // `tasks:` is read by hand (`tasks.rs`): `dev` and `build` have a default command,
        // and only `dev` takes `hot_reload`.
        ("/definitions/tasks", set(&["dev", "build"])),
        ("/definitions/devTask", set(&TASK_KEYS)),
        ("/definitions/buildTask", named.clone()),
        ("/definitions/namedTask", named),
    ]
}

/// Every node of `v` with its JSON pointer.
fn walk<'a>(v: &'a Value, pointer: String, out: &mut Vec<(String, &'a Value)>) {
    match v {
        Value::Object(m) => {
            out.push((pointer.clone(), v));
            for (k, child) in m {
                walk(child, format!("{pointer}/{k}"), out);
            }
        }
        Value::Array(items) => {
            for (i, child) in items.iter().enumerate() {
                walk(child, format!("{pointer}/{i}"), out);
            }
        }
        _ => {}
    }
}

#[test]
fn the_schema_is_draft_07_json() {
    let s = section();
    assert_eq!(s["$schema"], "http://json-schema.org/draft-07/schema#");
    assert_eq!(s["type"], "object");
    assert_eq!(s["additionalProperties"], false);
    // `fsp schema --pubspec` hoists the definitions beside the section, which is `fespalier`.
    assert!(s["definitions"].get("fespalier").is_none());
}

#[test]
fn every_key_config_rs_accepts_is_in_the_schema_and_no_other() {
    let s = section();
    for (pointer, expected) in objects() {
        let node = at(&s, pointer);
        assert_eq!(keys(node), expected, "the keys of {pointer}");
        // A struct with `deny_unknown_fields` refuses any other key; the task maps take any name.
        if !pointer.ends_with("tasks") {
            assert_eq!(node["additionalProperties"], false, "{pointer}");
        }
    }
    // Every object with `properties` is in the table, so a new section cannot be left out of it.
    let covered: BTreeSet<&str> = objects().iter().map(|(p, _)| *p).collect();
    let mut nodes = vec![];
    walk(&s, String::new(), &mut nodes);
    for (pointer, node) in nodes {
        if node.get("properties").is_some_and(Value::is_object) {
            assert!(
                covered.contains(pointer.as_str()),
                "{pointer} lists properties: add it to objects() in schema_tests.rs, with the struct or list it must match"
            );
        }
    }
}

#[test]
fn every_enum_is_what_serde_takes() {
    let s = section();
    for (pointer, expected) in [
        ("/properties/remount", names_of::<Remount>()),
        ("/properties/data_retry", names_of::<DataRetry>()),
        ("/properties/main", names_of::<MainMode>()),
        ("/properties/file_style", names_of::<FileStyle>()),
        (
            "/properties/lints/properties/unknown_path",
            names_of::<LintLevel>(),
        ),
        (
            "/definitions/test/properties/a11y/anyOf/1/items",
            Guideline::ALL.iter().map(|g| g.key().to_string()).collect(),
        ),
        // Read by hand in `config.rs`.
        ("/properties/meta", set(&["optional", "required"])),
        ("/properties/adapters/anyOf/0", set(&["auto"])),
    ] {
        assert_eq!(enum_of(at(&s, pointer)), expected, "{pointer}");
    }
    // Each value reads, and a value off the list does not.
    for (key, values) in [
        ("remount", names_of::<Remount>()),
        ("data_retry", names_of::<DataRetry>()),
        ("main", names_of::<MainMode>()),
        ("file_style", names_of::<FileStyle>()),
        ("meta", set(&["optional", "required"])),
    ] {
        for v in &values {
            assert!(
                parse(&format!("fespalier:\n  {key}: {v}\n")).is_ok(),
                "{key}: {v}"
            );
        }
        assert!(parse(&format!("fespalier:\n  {key}: sometimes\n")).is_err());
    }
}

fn parse(yaml: &str) -> anyhow::Result<Config> {
    Ok(Pubspec::parse(&format!("name: demo\n{yaml}"))?.config)
}

/// A JSON value as YAML text for one line: `lib/app`, `false`, `[]`.
fn yaml_text(v: &Value) -> String {
    match v {
        Value::String(s) => format!("\"{s}\""),
        other => other.to_string(),
    }
}

#[test]
fn every_default_reads_as_the_default() {
    let s = section();
    let none = parse("fespalier: {}\n").unwrap();
    for (key, node) in s["properties"].as_object().unwrap() {
        if let Some(default) = node.get("default") {
            let c = parse(&format!("fespalier:\n  {key}: {}\n", yaml_text(default))).unwrap();
            assert_eq!(c, none, "the default of `{key}`");
        }
    }
    // Inside the sections, through the code that checks each.
    let lints = parse("fespalier:\n  lints: {unknown_path: warning}\n").unwrap();
    assert_eq!(lints, parse("fespalier:\n  lints: {}\n").unwrap());
    let d = |p: &str| at(&s, p)["default"].clone();
    assert_eq!(d("/properties/lints/properties/unknown_path"), "warning");
    let links = |extra: &str| {
        serde_yaml_ng::from_str::<LinksConfig>(&format!("domains: [shop.example.com]\n{extra}"))
            .unwrap()
            .validate()
            .unwrap()
    };
    assert_eq!(
        links(&format!(
            "out: {}\nscheme: myshop\nios_app_id: ABCDE12345.com.example.shop\nscheme_host: {}\n",
            yaml_text(&d("/definitions/links/properties/out")),
            d("/definitions/links/properties/scheme_host")
        )),
        links("scheme: myshop\nios_app_id: ABCDE12345.com.example.shop\n")
    );
    let maestro = |extra: &str| {
        serde_yaml_ng::from_str::<MaestroConfig>(&format!("url: http://localhost:8080\n{extra}"))
            .unwrap()
            .validate(None)
            .unwrap()
    };
    assert_eq!(
        maestro(&format!(
            "out: {}\ntimeout: {}\n",
            yaml_text(&d("/definitions/maestro/properties/out")),
            d("/definitions/maestro/properties/timeout")
        )),
        maestro("")
    );
    let size = |yaml: &str| {
        serde_yaml_ng::from_str::<SizeConfig>(yaml)
            .unwrap()
            .validate()
            .unwrap()
    };
    assert_eq!(
        size(&format!(
            "build: {}\n",
            yaml_text(&d("/definitions/size/properties/build"))
        )),
        size("{}")
    );
    let test = |yaml: &str| {
        serde_yaml_ng::from_str::<TestConfig>(yaml)
            .unwrap()
            .validate()
            .unwrap()
    };
    assert_eq!(
        test(&format!(
            "out: {}\ntimeout: {}\na11y: {}\n",
            yaml_text(&d("/definitions/test/properties/out")),
            d("/definitions/test/properties/timeout"),
            d("/definitions/test/properties/a11y"),
        )),
        test("{}")
    );
    let dev = |yaml: &str| {
        Tasks::from_value(Some(&serde_yaml_ng::from_str(yaml).unwrap()))
            .unwrap()
            .dev()
    };
    assert_eq!(
        dev(&format!(
            "dev: {{hot_reload: {}}}",
            d("/definitions/devTask/properties/hot_reload")
        )),
        dev("dev: {}")
    );
}

// --- a validator for the keywords the schema uses -------------------------------

/// The keywords the schema may use: the ones [`validate`] checks, and annotations.
const KEYWORDS: [&str; 21] = [
    "$schema",
    "title",
    "description",
    "default",
    "definitions",
    "$ref",
    "type",
    "enum",
    "properties",
    "additionalProperties",
    "propertyNames",
    "required",
    "items",
    "minItems",
    "uniqueItems",
    "minimum",
    "maximum",
    "pattern",
    "anyOf",
    "allOf",
    "not",
];

/// The schema nodes of `v` (each value of a keyword that holds a schema, recursively).
fn schema_nodes<'a>(v: &'a Value, pointer: String, out: &mut Vec<(String, &'a Value)>) {
    let Value::Object(m) = v else { return };
    out.push((pointer.clone(), v));
    for (k, child) in m {
        let p = format!("{pointer}/{k}");
        match k.as_str() {
            "properties" | "definitions" => {
                for (name, s) in child.as_object().into_iter().flatten() {
                    schema_nodes(s, format!("{p}/{name}"), out);
                }
            }
            "anyOf" | "allOf" => {
                for (i, s) in child.as_array().into_iter().flatten().enumerate() {
                    schema_nodes(s, format!("{p}/{i}"), out);
                }
            }
            "items" | "additionalProperties" | "propertyNames" | "not" => {
                schema_nodes(child, p, out);
            }
            _ => {}
        }
    }
}

#[test]
fn the_schema_uses_only_keywords_the_test_validator_checks() {
    let s = section();
    let mut nodes = vec![];
    schema_nodes(&s, String::new(), &mut nodes);
    for (pointer, node) in nodes {
        for k in node.as_object().unwrap().keys() {
            assert!(
                KEYWORDS.contains(&k.as_str()),
                "{pointer}: `{k}` is not a keyword schema_tests.rs validates; teach `validate` it"
            );
        }
        if let Some(r) = node.get("$ref") {
            let r = r.as_str().unwrap();
            assert!(r.starts_with("#/definitions/"), "{pointer}: {r}");
            at(&s, r.trim_start_matches('#'));
        }
        if let Some(p) = node.get("pattern") {
            regex::Regex::new(p.as_str().unwrap()).unwrap();
        }
    }
}

fn type_ok(t: &str, v: &Value) -> bool {
    match t {
        "string" => v.is_string(),
        "boolean" => v.is_boolean(),
        "object" => v.is_object(),
        "array" => v.is_array(),
        "null" => v.is_null(),
        "number" => v.is_number(),
        "integer" => v.is_i64() || v.is_u64(),
        other => panic!("type {other}"),
    }
}

/// What is wrong with `v` against `schema` (`root` resolves `$ref`), one line per mistake.
fn validate(root: &Value, schema: &Value, v: &Value, at: &str, out: &mut Vec<String>) {
    if let Some(r) = schema.get("$ref").and_then(Value::as_str) {
        validate(root, self::at(root, r.trim_start_matches('#')), v, at, out);
        return;
    }
    if let Some(t) = schema.get("type") {
        let ok = match t {
            Value::String(t) => type_ok(t, v),
            Value::Array(ts) => ts.iter().any(|t| type_ok(t.as_str().unwrap(), v)),
            _ => panic!("type {t}"),
        };
        if !ok {
            out.push(format!("{at}: not {t}"));
            return;
        }
    }
    if let Some(values) = schema.get("enum").and_then(Value::as_array)
        && !values.contains(v)
    {
        out.push(format!("{at}: {v} is not one of {values:?}"));
    }
    if let Some(m) = v.as_object() {
        let props = schema.get("properties").and_then(Value::as_object);
        for (k, child) in m {
            let at = format!("{at}/{k}");
            if let Some(s) = props.and_then(|p| p.get(k)) {
                validate(root, s, child, &at, out);
            } else {
                match schema.get("additionalProperties") {
                    Some(Value::Bool(false)) => out.push(format!("{at}: not allowed")),
                    Some(s @ Value::Object(_)) => validate(root, s, child, &at, out),
                    _ => {}
                }
            }
            if let Some(names) = schema.get("propertyNames") {
                validate(root, names, &Value::String(k.clone()), &at, out);
            }
        }
        for r in schema
            .get("required")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if !m.contains_key(r.as_str().unwrap()) {
                out.push(format!("{at}: {r} is required"));
            }
        }
    }
    if let Some(items) = v.as_array() {
        if let Some(s) = schema.get("items") {
            for (i, item) in items.iter().enumerate() {
                validate(root, s, item, &format!("{at}/{i}"), out);
            }
        }
        if let Some(n) = schema.get("minItems").and_then(Value::as_u64)
            && (items.len() as u64) < n
        {
            out.push(format!("{at}: fewer than {n} items"));
        }
        if schema.get("uniqueItems") == Some(&Value::Bool(true))
            && items
                .iter()
                .enumerate()
                .any(|(i, a)| items[..i].contains(a))
        {
            out.push(format!("{at}: an item twice"));
        }
    }
    if let Some(n) = v.as_f64() {
        if let Some(min) = schema.get("minimum").and_then(Value::as_f64)
            && n < min
        {
            out.push(format!("{at}: below {min}"));
        }
        if let Some(max) = schema.get("maximum").and_then(Value::as_f64)
            && n > max
        {
            out.push(format!("{at}: above {max}"));
        }
    }
    if let (Some(text), Some(p)) = (v.as_str(), schema.get("pattern").and_then(Value::as_str))
        && !regex::Regex::new(p).unwrap().is_match(text)
    {
        out.push(format!("{at}: `{text}` does not match {p}"));
    }
    if let Some(all) = schema.get("allOf").and_then(Value::as_array) {
        for s in all {
            validate(root, s, v, at, out);
        }
    }
    if let Some(any) = schema.get("anyOf").and_then(Value::as_array) {
        let fits = any.iter().any(|s| {
            let mut e = vec![];
            validate(root, s, v, at, &mut e);
            e.is_empty()
        });
        if !fits {
            out.push(format!("{at}: matches none of anyOf"));
        }
    }
    if let Some(not) = schema.get("not") {
        let mut e = vec![];
        validate(root, not, v, at, &mut e);
        if e.is_empty() {
            out.push(format!("{at}: matches `not`"));
        }
    }
}

/// The mistakes in the `fespalier:` section of a pubspec's text, by the schema.
fn schema_errors(pubspec: &str) -> Vec<String> {
    let yaml: serde_yaml_ng::Value = serde_yaml_ng::from_str(pubspec).unwrap();
    let Some(section) = yaml.get("fespalier") else {
        return vec![];
    };
    let json: Value = serde_json::to_value(section).unwrap();
    if json.is_null() {
        return vec![];
    }
    let root = self::section();
    let mut out = vec![];
    validate(&root, &root, &json, "fespalier", &mut out);
    out
}

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..")
}

/// Every `pubspec.yaml` under `dir`, but in build output and dependencies.
fn pubspecs(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in fs::read_dir(dir).unwrap().filter_map(Result::ok) {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        if path.is_dir() {
            if !matches!(
                name.as_str(),
                "build" | ".dart_tool" | "node_modules" | "target" | ".git"
            ) {
                pubspecs(&path, out);
            }
        } else if name == "pubspec.yaml" {
            out.push(path);
        }
    }
}

/// The YAML of the first block of a `//!` comment that holds `fespalier:`.
fn doc_block(src: &str) -> String {
    let lines: Vec<&str> = src
        .lines()
        .take_while(|l| l.starts_with("//!"))
        .map(|l| l.trim_start_matches("//!").strip_prefix(' ').unwrap_or(""))
        .collect();
    let start = lines.iter().position(|l| *l == "```yaml").unwrap() + 1;
    let end = start + lines[start..].iter().position(|l| *l == "```").unwrap();
    lines[start..end].join("\n")
}

#[test]
fn the_schema_accepts_every_pubspec_of_the_repository() {
    let mut files = vec![];
    for dir in ["examples", "packages"] {
        pubspecs(&repo().join(dir), &mut files);
    }
    let mut texts: Vec<(String, String)> = files
        .iter()
        .map(|f| (f.display().to_string(), fs::read_to_string(f).unwrap()))
        .collect();
    // The examples the code documents itself with.
    for file in ["src/config.rs", "src/tasks.rs"] {
        let src = fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join(file)).unwrap();
        // Their `adapters:` lists a package, which must be a dependency.
        let deps = "dependencies:\n  fespalier_push: any\n";
        texts.push((
            file.to_string(),
            format!("name: demo\n{deps}{}", doc_block(&src)),
        ));
    }
    let mut sections = 0;
    for (name, text) in &texts {
        if !text.contains("\nfespalier:") {
            continue;
        }
        sections += 1;
        // `fsp` reads it, and so does the schema.
        let pubspec = Pubspec::parse(text).unwrap_or_else(|e| panic!("{name}: {e:#}"));
        if let Some(tasks) = &pubspec.config.tasks {
            Tasks::from_value(Some(tasks)).unwrap_or_else(|e| panic!("{name}: {e:#}"));
        }
        assert_eq!(schema_errors(text), Vec::<String>::new(), "{name}");
    }
    assert!(
        sections >= 10,
        "only {sections} pubspecs with a fespalier: section"
    );
}

#[test]
fn the_schema_refuses_what_fsp_refuses_by_its_shape() {
    // Each is refused by `fsp`: by `Pubspec::parse`, or by the command that reads the section.
    let cases = [
        "app_dirr: lib/app",
        "format: yes please",
        "remount: sometimes",
        "lints: {unknown: off}",
        "lints: {unknown_path: loud}",
        "links: {domain: [shop.example.com]}",
        "links: {flavors: {prod: {android_packages: x}}}",
        "links: {domains: [shop.example.com], out: true}",
        "maestro: {url: http://localhost:8080, timeout: 10}",
        "maestro: {url: http://localhost:8080, retries: 2}",
        "size: {main: 3 GB}",
        "size: {routes: {/a: 0}}",
        "test: {a11y: [colour]}",
        "test: {timeout: 999999}",
        "tasks: {Codegen: x}",
        "tasks: {codegen: {run: x, hot_reload: true}}",
        "tasks: {lint: {before: dart analyze}}",
        "tasks: {dev: {with: {flutter: x}}}",
        "tasks: {dev: {env: {1X: y}}}",
        "tasks: {dev: {colour: red}}",
        "tasks: {dev: {run: []}}",
        "tasks: {dev: {before: ''}}",
        "adapters: fespalier_push",
        "adapters: [auto]",
        "adapters: [fespalier]",
        "adapters: [Fespalier_push]",
        "main: always",
        "meta: sometimes",
        "meta_unique: [a-b]",
        "output: lib/app.g.txt",
    ];
    for case in cases {
        let text =
            format!("name: demo\ndependencies:\n  fespalier_push: any\nfespalier:\n  {case}\n");
        assert!(refused_by_fsp(&text), "fsp takes `{case}`");
        assert!(
            !schema_errors(&text).is_empty(),
            "the schema takes `{case}`"
        );
    }
}

/// Whether `fsp` refuses the pubspec: when it parses, or in the command that checks a section.
fn refused_by_fsp(text: &str) -> bool {
    let Ok(p) = Pubspec::parse(text) else {
        return true;
    };
    let c = p.config;
    c.links.as_ref().is_some_and(|l| l.validate().is_err())
        || c.maestro
            .as_ref()
            .is_some_and(|m| m.validate(None).is_err())
        || c.size.as_ref().is_some_and(|s| s.validate().is_err())
        || c.test.as_ref().is_some_and(|t| t.validate().is_err())
        || Tasks::from_config(&c).is_err()
}

// --- what the editors ship ------------------------------------------------------

#[test]
fn the_pubspec_schema_wraps_schemastore_and_the_section() {
    let p = schema::pubspec();
    assert_eq!(p["allOf"][0]["$ref"], schema::SCHEMASTORE_PUBSPEC);
    let s = section();
    assert_eq!(p["definitions"]["fespalier"]["properties"], s["properties"]);
    for (name, def) in s["definitions"].as_object().unwrap() {
        assert_eq!(&p["definitions"][name], def, "{name}");
    }
    // `fespalier:` alone is no section.
    let root = &p;
    let mut errors = vec![];
    validate(
        root,
        &p["properties"]["fespalier"],
        &Value::Null,
        "fespalier",
        &mut errors,
    );
    assert!(errors.is_empty(), "{errors:?}");
    validate(
        root,
        &p["properties"]["fespalier"],
        &serde_json::json!({"app_dirr": "x"}),
        "fespalier",
        &mut errors,
    );
    assert!(!errors.is_empty());
}

/// The copies the editor plugins ship are what `fsp schema --pubspec` prints. `FSP_UPDATE_GOLDEN=1`
/// writes them.
#[test]
fn the_editor_plugins_ship_what_fsp_schema_pubspec_prints() {
    let text = schema::text(true);
    for copy in [
        "editors/vscode/schemas/pubspec.schema.json",
        "editors/intellij/src/main/resources/schemas/pubspec.schema.json",
    ] {
        let path = repo().join(copy);
        if std::env::var_os("FSP_UPDATE_GOLDEN").is_some() {
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, &text).unwrap();
        }
        let on_disk = fs::read_to_string(&path).unwrap_or_default();
        assert!(
            on_disk == text,
            "{copy} is not what `fsp schema --pubspec` prints: run `FSP_UPDATE_GOLDEN=1 cargo test schema_tests::` in cli/"
        );
    }
}
