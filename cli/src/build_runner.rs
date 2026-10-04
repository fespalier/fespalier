//! The one way `build_runner` undoes what `fsp` writes (since 0.9.0).
//!
//! `fsp gen` writes `lib/app.g.dart`. `build_runner` declares the outputs of the builders that
//! write `.g.dart` files (`json_serializable`, `riverpod_generator`, ...) through `source_gen`'s
//! combining builder: `{".dart": [".g.dart"]}`, every `X.dart` in the package getting an
//! `X.g.dart`. With a `lib/app.dart` in the app, `lib/app.g.dart` is therefore one of its outputs,
//! and `dart run build_runner build` deletes the file `fsp` wrote, whatever its flags, with
//! nothing logged (it has deleted conflicting outputs without being asked since 2.7).
//!
//! `lib/app.dart` is a common name in a Flutter app, and the default output is a `.g.dart`, so
//! [`check`] warns when both are there and `build_runner` is a dependency: syntax and file names
//! only, it never runs `build_runner`. The warning is about the file the user can rename
//! (`lib/app.dart`), and names the way out: another `output:`. A third way, which the warning
//! does not offer but respects, is a `build.yaml` that keeps the `.dart` file out of the
//! combining builder (`generate_for: exclude: [lib/app.dart]`): then nothing claims the output.

use std::path::Path;

use serde_yaml_ng::Value;

use crate::config::Config;
use crate::diag::{Base, Diags, Level};

/// The warning for each generated file that has an `X.dart` beside it, when `build_runner` is a
/// dependency. `outputs` are the files `gen` writes, as the user spells them (`lib/app.g.dart`).
/// Nothing is read but whether those `.dart` files exist, so it is cheap enough for every run.
pub fn check(project: &Path, cfg: &Config, outputs: &[String]) -> Diags {
    let mut diags = Diags::default();
    if !cfg.build_runner {
        return diags;
    }
    for out in outputs {
        let Some(stem) = out.strip_suffix(".g.dart") else {
            continue;
        };
        let source = format!("{stem}.dart");
        if project.join(&source).is_file() && !kept_out(project, &source) {
            let msg = message(project, cfg, out, &source);
            diags.add(Level::Warning, Base::Project, &source, None, msg);
        }
    }
    diags
}

/// The warning for `out`, a file `build_runner` would claim for `source`. Quoted in
/// `skills/fespalier-troubleshooting/references/diagnostics-config-and-meta.md`.
fn message(project: &Path, cfg: &Config, out: &str, source: &str) -> String {
    let (key, example) = if cfg.output_manifest.as_deref() == Some(out) {
        (
            "output_manifest",
            elsewhere(project, out, &["app.routes", "app.manifest"]),
        )
    } else {
        // The generated main() follows `output`, so moving `output` moves it too.
        (
            "output",
            elsewhere(
                project,
                &cfg.output,
                &["routes", "app_routes", "fsp_routes"],
            ),
        )
    };
    format!(
        "`build_runner` can delete `{out}`: `{source}` exists, so the builders that write `.g.dart` files (json_serializable, riverpod_generator, ...) claim that path as an output of theirs, and `dart run build_runner build` removes the file `fsp` wrote; set `fespalier: {key}:` in pubspec.yaml to another file (for example `{example}`), or rename `{source}`"
    )
}

/// Where the file of `path` could go instead: the first of `names` (`routes.g.dart`, in the
/// folder of `path`) that has no `.dart` file beside it for `build_runner` to claim it for.
fn elsewhere(project: &Path, path: &str, names: &[&str]) -> String {
    let dir = crate::config::parent(path);
    let at = |name: &str, ext: &str| {
        if dir.is_empty() {
            format!("{name}{ext}")
        } else {
            format!("{dir}/{name}{ext}")
        }
    };
    let name = names
        .iter()
        .find(|n| !project.join(at(n, ".dart")).exists())
        .unwrap_or(&names[0]);
    at(name, ".g.dart")
}

/// The builder whose outputs are every `X.g.dart`.
const COMBINING: &str = "source_gen:combining_builder";

/// Whether the project's `build.yaml` keeps `source` out of the combining builder, by naming it
/// in `generate_for: exclude:` of that builder in any target: `build_runner` then has no output
/// for it, and nothing claims `X.g.dart`. Only the file itself counts, spelled as it is here
/// (`lib/app.dart`); a glob, an `include:` list or a file that does not parse is not read as
/// one, so the warning stays.
fn kept_out(project: &Path, source: &str) -> bool {
    let Ok(text) = std::fs::read_to_string(project.join("build.yaml")) else {
        return false;
    };
    let Ok(yaml) = serde_yaml_ng::from_str::<Value>(&text) else {
        return false;
    };
    let Some(targets) = yaml.get("targets").and_then(Value::as_mapping) else {
        return false;
    };
    targets.values().any(|target| {
        target
            .get("builders")
            .and_then(|b| b.get(COMBINING))
            .and_then(|b| b.get("generate_for"))
            .and_then(|g| g.get("exclude"))
            .and_then(Value::as_sequence)
            .is_some_and(|files| files.iter().any(|f| f.as_str() == Some(source)))
    })
}
