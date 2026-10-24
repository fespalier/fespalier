//! `fsp add <feature>`: an optional feature of `fsp create`, added to an app that exists (since
//! 0.23.0).
//!
//! The decisions are in `add/plan.rs` (pure: the app's pubspec and files in, a plan out); the
//! features are `create/recipes.rs`'s, the one table. This file reads the app, and does what the
//! plan says, in this order:
//!
//! 1. writes `pubspec.yaml` (only the lines the plan adds or changes), the feature's files (never
//!    over one that is there), and the shared files that are still what `fsp create` wrote;
//! 2. raises the Android `minSdk` when a feature's plugin needs it and the line is Flutter's;
//! 3. `flutter pub get`, `dart format` on the Dart files it wrote (the app's language version and
//!    page width), `fsp gen`, and `fsp test` when the app has its route smoke tests;
//! 4. prints the changes to make by hand, to the files that are the app's own.

use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::Write as _;
use std::path::Path;

use anyhow::{Context, Result, bail};
use clap::Args;
use serde_yaml_ng::Value;

use crate::Exit;
use crate::config::Config;
use crate::create::{self, recipes};

pub mod plan;

use plan::{Request, Write};

#[derive(Args)]
pub struct AddCmd {
    /// The features to add: the optional features of `fsp create` (`fsp create --list-features`)
    #[arg(value_name = "FEATURE")]
    pub features: Vec<String>,
    /// Print what would change (the pubspec's lines, every file, the changes to make by hand); write and run nothing
    #[arg(long)]
    pub dry_run: bool,
    /// Write the files, but leave `flutter pub get` to you
    #[arg(long)]
    pub no_pub_get: bool,
    /// Pass --offline to `flutter pub get`
    #[arg(long, conflicts_with = "no_pub_get")]
    pub offline: bool,
}

/// The file `fsp test` writes: when the app has it, `fsp add` writes it again.
const ROUTES_TEST: &str = "test/routes/routes_test.dart";

pub fn run(project: &Path, cmd: &AddCmd) -> Result<()> {
    let path = project.join("pubspec.yaml");
    let text = fs::read_to_string(&path).with_context(|| {
        format!(
            "no pubspec.yaml in {}; fsp add adds a feature to an app (`fsp create` makes one)",
            project.display()
        )
    })?;
    let mut files = BTreeMap::new();
    for rel in plan::paths(recipes::RECIPES) {
        match fs::read_to_string(project.join(&rel)) {
            Ok(content) => {
                files.insert(rel, content);
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            // A file that is there but is not text is not "absent": the plan would write over it.
            Err(e) => bail!("reading {rel}: {e}; fsp add reads the files it may write to"),
        }
    }
    let overrides_path = project.join(plan::OVERRIDES);
    let overrides = match fs::read_to_string(&overrides_path) {
        Ok(content) => Some(content),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => bail!(
            "reading {}: {e}; fsp add reads the files it may write to",
            plan::OVERRIDES
        ),
    };
    let workspace = workspace_overrides(project, &text);
    let plan = plan::build(
        &Request {
            features: &cmd.features,
            pubspec: &text,
            files: &files,
            overrides: overrides.as_deref(),
            workspace_overrides: &workspace,
        },
        recipes::RECIPES,
    )?;
    for note in &plan.notes {
        errln!("note: {note}");
    }
    if plan.is_empty() {
        errln!("nothing to add");
        return Ok(());
    }
    let mut commands = vec![];
    if !cmd.no_pub_get {
        commands.push(if cmd.offline {
            "flutter pub get --offline".to_string()
        } else {
            "flutter pub get".to_string()
        });
    }
    commands.push("fsp gen".to_string());
    let smoke = project.join(ROUTES_TEST).is_file();
    if smoke {
        commands.push("fsp test".to_string());
    }
    if cmd.dry_run {
        err!("{}", plan.describe(&text, &commands));
        return Ok(());
    }

    // Nothing is written over: a feature's file that appeared since the plan was made stops here.
    for file in plan.files.iter().filter(|f| f.write == Write::New) {
        if project.join(&file.path).exists() {
            bail!(
                "{} is there now; fsp add never writes over a file, and wrote nothing",
                file.path
            );
        }
    }
    if let Some(new) = &plan.pubspec {
        fs::write(&path, new).with_context(|| format!("writing {}", path.display()))?;
        errln!("  edit   pubspec.yaml");
        for change in &plan.changes {
            errln!("           {change}");
        }
    }
    if let Some(edited) = &plan.overrides {
        fs::write(&overrides_path, &edited.after)
            .with_context(|| format!("writing {}", overrides_path.display()))?;
        errln!("  edit   {}", plan::OVERRIDES);
        for change in &edited.changes {
            errln!("           {change}");
        }
    }
    for file in &plan.files {
        let target = project.join(&file.path);
        if let Some(dir) = target.parent() {
            fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        }
        match file.write {
            Write::New => {
                let mut out = OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(&target)
                    .with_context(|| format!("writing {}", target.display()))?;
                out.write_all(file.content.as_bytes())
                    .with_context(|| format!("writing {}", target.display()))?;
            }
            Write::Update => fs::write(&target, &file.content)
                .with_context(|| format!("writing {}", target.display()))?,
        }
        errln!("  {:<6} {}", file.write.word(), file.path);
    }
    if let Some(min) = plan.android_min_sdk {
        create::raise_android_min_sdk(project, min)?;
    }

    // What a person has to do is printed before any command runs: one of them can fail, and
    // the feature then reads as present, so a later `fsp add` would say nothing about it.
    for hand in &plan.by_hand {
        errln!(
            "\nBy hand: {} ({}). Make this change:\n{}",
            hand.path,
            hand.why,
            hand.change.trim_end()
        );
    }

    let left = |step: &str, rest: &[String], e: &anyhow::Error| {
        Exit::after(e, |why| {
            format!(
                "{step} {why}\n\nThe files are written; {}fix that and finish with:\n  {}",
                if plan.by_hand.is_empty() {
                    ""
                } else {
                    "the changes to make by hand are printed above; "
                },
                rest.join(" && ")
            )
        })
    };
    let mut rest = commands.clone();
    if !cmd.no_pub_get {
        let mut args = vec!["pub", "get"];
        if cmd.offline {
            args.push("--offline");
        }
        create::run_flutter(&args, project, "fsp add", false)
            .map_err(|e| left(&rest[0], &rest, &e))?;
        rest.remove(0);
    }
    let written: Vec<&str> = plan
        .files
        .iter()
        .map(|f| f.path.as_str())
        .filter(|p| p.ends_with(".dart"))
        .collect();
    if let Some(why) = dart_format(project, &written) {
        errln!("note: {why}; the files are as `fsp create` writes them");
    }
    let generate = || -> Result<()> {
        let cfg = Config::load(project)?.for_scaffolding();
        let outcome = crate::gen_with(project, &cfg, true)?;
        errln!("{}", outcome.line());
        Ok(())
    };
    generate().map_err(|e| left("fsp gen", &rest, &e))?;
    rest.remove(0);
    if smoke {
        crate::smoke::run(project, false).map_err(|e| left("fsp test", &rest, &e))?;
    }
    if !plan.by_hand.is_empty() {
        errln!(
            "\nUntil the changes above are made, the feature is not wired in, and its test fails."
        );
    }
    errln!("\n✓ added {}", plan.features.join(", "));
    Ok(())
}

/// The packages the root of the app's pub workspace overrides, when the app says `resolution:
/// workspace` (pub reads them with the app's own): those of the root's `pubspec_overrides.yaml`
/// when it has the key, else of its pubspec. Those of the other members are not read, as `fsp check`
/// does not look for the members.
pub(crate) fn workspace_overrides(project: &Path, pubspec: &str) -> Vec<String> {
    let Ok(value) = serde_yaml_ng::from_str::<Value>(pubspec) else {
        return vec![];
    };
    let Some((root, root_pubspec)) = crate::packages::workspace_root(project, &value) else {
        return vec![];
    };
    let file: Option<Value> = fs::read_to_string(root.join(plan::OVERRIDES))
        .ok()
        .and_then(|text| serde_yaml_ng::from_str(&text).ok());
    file.as_ref()
        .and_then(|f| f.get("dependency_overrides"))
        .or_else(|| root_pubspec.get("dependency_overrides"))
        .and_then(Value::as_mapping)
        .map(|m| {
            m.keys()
                .filter_map(|k| k.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

/// `dart format` on the Dart files `fsp add` wrote, in the app, so they follow the app's own
/// language version and page width (`fsp create`'s are formatted for `sdk: ^3.9.0` and 80
/// columns). Why it did not, when it did not: no `dart`, or `dart format` refused.
fn dart_format(project: &Path, files: &[&str]) -> Option<String> {
    if files.is_empty() {
        return None;
    }
    let out = std::process::Command::new(crate::format::dart_program())
        .arg("format")
        .args(files)
        .current_dir(project)
        .stdin(std::process::Stdio::null())
        .output();
    match out {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            Some("`dart` is not on PATH, so dart format did not run".to_string())
        }
        Err(e) => Some(format!("could not run `dart format`: {e}")),
        Ok(out) if !out.status.success() => Some(format!(
            "`dart format` failed: {}",
            String::from_utf8_lossy(&out.stderr)
                .lines()
                .next()
                .unwrap_or_default()
                .trim()
        )),
        Ok(_) => None,
    }
}
