//! `fsp upgrade --app` (since 0.23.0): moves the `ref:` of `fespalier` and of every companion
//! package in the app's `pubspec.yaml` to one release, this `fsp`'s own unless `--version` names
//! another, then runs `flutter pub get` and `fsp gen`, and prints what changed in between: the
//! migration notes of `docs/migration.md`, which this binary carries as it was when it was built.
//!
//! The decisions are pure and tested in `upgrade_app_tests.rs`: [`plan`] (the pubspec in, the
//! moves and the new text out) and [`notes`] (the sections of the notes between two releases).
//! The pubspec is edited by `pubspec_edit`, so only the `ref:` values change.

use std::path::Path;
use std::{env, fs};

use anyhow::{Context, Result, anyhow, bail};
use serde_json::json;
use serde_yaml_ng::Value;

use crate::Exit;
use crate::create::plan::REPO_URL;
use crate::pins::{self, Origin};
use crate::pubspec_edit::{self, Edit};
use crate::upgrade::{UpgradeCmd, Version};

/// `docs/migration.md` as it was when this `fsp` was built: the notes it prints.
pub const MIGRATION: &str = include_str!("../../docs/migration.md");

/// One `ref:` that moves.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Move {
    pub name: String,
    pub section: &'static str,
    pub from: String,
    pub to: String,
    /// The move goes to an older release than the ref is at now.
    pub down: bool,
}

/// What `fsp upgrade --app` does to a pubspec.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AppPlan {
    /// `fespalier` comes from a checkout's folder (`path:`), so there is no ref to move.
    Checkout { root: String },
    /// The refs to move (none when every one is at the target already).
    Refs {
        target: Version,
        /// The oldest release the app pins: the notes start after it.
        oldest: Version,
        /// The newest release the app pins: what a move to an older `fsp` would leave behind.
        newest: Version,
        moves: Vec<Move>,
        /// Pins that are left as they are, and why (an override to a folder).
        kept: Vec<String>,
        /// The pubspec with the moves made; the same text when there are none.
        pubspec: String,
    },
}

/// The release a `ref:` names, when it is a tag `vX.Y.Z`.
fn release(reference: &str) -> Option<Version> {
    reference
        .starts_with('v')
        .then(|| Version::parse(reference))
        .flatten()
}

/// Decides the moves. `overrides` is `pubspec_overrides.yaml`, when the app has one: pub reads it
/// after the pubspec, and this reads it only to say what it overrides.
pub fn plan(pubspec: &str, overrides: Option<&str>, target: Version) -> Result<AppPlan, String> {
    let value: Value =
        serde_yaml_ng::from_str(pubspec).map_err(|e| format!("pubspec.yaml: {e}"))?;
    let pins = pins::read(&value)?;
    let listed = || {
        pins.all
            .iter()
            .filter(|p| p.section != "dependency_overrides")
    };
    let url = match &pins.fespalier {
        Origin::Path { root } => {
            let git: Vec<String> = listed()
                .filter(|p| matches!(p.origin, Origin::Git { .. }))
                .map(|p| format!("{} ({})", p.name, p.section))
                .collect();
            if !git.is_empty() {
                return Err(format!(
                    "fespalier comes from a checkout ({root}/fespalier) and {} from git: pin them one way, by hand",
                    git.join(", ")
                ));
            }
            return Ok(AppPlan::Checkout { root: root.clone() });
        }
        Origin::Git { url, .. } => url.clone(),
        Origin::Other(_) => unreachable!("pins::read refuses it"),
    };
    let mut problems = vec![];
    let mut kept = vec![];
    let mut pinned: Vec<(&pins::Pin, Version)> = vec![];
    for pin in &pins.all {
        let overriding = pin.section == "dependency_overrides";
        match &pin.origin {
            Origin::Git {
                url: other,
                reference,
            } if pins::same_url(other, &url) => match release(reference) {
                Some(version) => pinned.push((pin, version)),
                None => problems.push(format!(
                    "{} ({}) is at `{reference}`, not a release tag like {}",
                    pin.name,
                    pin.section,
                    target.tag()
                )),
            },
            origin if overriding => kept.push(format!(
                "dependency_overrides: {} is {}; left as it is",
                pin.name,
                origin.describe(&pin.name)
            )),
            origin => problems.push(format!(
                "{} ({}) comes from {}, not from {url}",
                pin.name,
                pin.section,
                origin.describe(&pin.name)
            )),
        }
    }
    if !problems.is_empty() {
        return Err(format!(
            "fespalier and its companions are pinned together, at one url and one release tag, and these are not:\n  {}\nPin them as fespalier is, then run `fsp upgrade --app` again",
            problems.join("\n  ")
        ));
    }
    if let Some(text) = overrides {
        let file: Value =
            serde_yaml_ng::from_str(text).map_err(|e| format!("pubspec_overrides.yaml: {e}"))?;
        if let Some(Value::Mapping(map)) = file.get("dependency_overrides") {
            for name in map.keys().filter_map(Value::as_str) {
                if pins::is_package(name) {
                    kept.push(format!(
                        "pubspec_overrides.yaml overrides {name}; left as it is"
                    ));
                }
            }
        }
    }
    let oldest = pinned.iter().map(|(_, v)| *v).min().unwrap_or(target);
    let newest = pinned.iter().map(|(_, v)| *v).max().unwrap_or(target);
    let moves: Vec<Move> = pinned
        .iter()
        .filter(|(_, v)| *v != target)
        .map(|(pin, version)| Move {
            name: pin.name.clone(),
            section: pin.section,
            from: match &pin.origin {
                Origin::Git { reference, .. } => reference.clone(),
                _ => String::new(),
            },
            to: target.tag(),
            down: *version > target,
        })
        .collect();
    let edits: Vec<Edit> = moves
        .iter()
        .map(|m| Edit::set(&[m.section, &m.name, "git", "ref"], &m.to))
        .collect();
    let pubspec = pubspec_edit::apply(pubspec, &edits).map_err(|e| {
        format!(
            "could not move the refs in pubspec.yaml safely ({e}); nothing was written. By hand: {}",
            e.edit.by_hand()
        )
    })?;
    Ok(AppPlan::Refs {
        target,
        oldest,
        newest,
        moves,
        kept,
        pubspec,
    })
}

// --- The migration notes -----------------------------------------------------------------------

/// One release's section of `docs/migration.md`, "Upgrading".
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Section {
    /// The heading as written: `0.22.0`, `0.9.x`.
    pub heading: String,
    /// The release it sorts as (`0.9.x` is `0.9.0`).
    pub version: Version,
    /// What to print: the first paragraph, the subheadings and the lead of each bullet, plain.
    pub summary: Vec<String>,
}

impl Section {
    /// Where the section is on GitHub, at `tag`.
    #[must_use]
    pub fn url(&self, tag: &str) -> String {
        let anchor: String = self
            .heading
            .to_lowercase()
            .chars()
            .filter(|c| c.is_alphanumeric() || *c == '-' || *c == '_')
            .collect();
        format!("{REPO_URL}/blob/{tag}/docs/migration.md#{anchor}")
    }
}

/// `text` without its bold marks (`**`), except inside a code span (`` `build/**` ``).
fn without_bold(text: &str) -> String {
    let mut out = String::new();
    let mut in_code = false;
    let mut rest = text;
    while let Some(c) = rest.chars().next() {
        if c == '`' {
            in_code = !in_code;
        } else if !in_code && let Some(after) = rest.strip_prefix("**") {
            rest = after;
            continue;
        }
        out.push(c);
        rest = &rest[c.len_utf8()..];
    }
    out
}

/// Markdown as plain text: links are their text, and bold marks go.
fn plain(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(open) = rest.find('[') {
        let Some(close) = rest[open..].find("](").map(|i| open + i) else {
            break;
        };
        let Some(end) = rest[close..].find(')').map(|i| close + i) else {
            break;
        };
        out.push_str(&rest[..open]);
        out.push_str(&rest[open + 1..close]);
        rest = &rest[end + 1..];
    }
    out.push_str(rest);
    without_bold(&out)
}

/// The lead of a bullet: its bold first words, else its first sentence.
fn lead(bullet: &str) -> String {
    if let Some(bold) = bullet.strip_prefix("**")
        && let Some(end) = bold.find("**")
    {
        return plain(&bold[..end]);
    }
    let text = plain(bullet);
    let sentence = text.find(". ").map_or(text.as_str(), |i| &text[..=i]);
    if sentence.chars().count() > 160 {
        let cut: String = sentence.chars().take(157).collect();
        format!("{cut}...")
    } else {
        sentence.to_string()
    }
}

fn section_version(heading: &str) -> Option<Version> {
    Version::parse(heading).or_else(|| {
        let minor = heading.strip_suffix(".x")?;
        Version::parse(&format!("{minor}.0"))
    })
}

/// The release sections of `markdown` ("### X.Y.Z" under "## Upgrading"), newest first as written.
#[must_use]
pub fn sections(markdown: &str) -> Vec<Section> {
    let mut out: Vec<Section> = vec![];
    let mut inside = false;
    let mut paragraph: Vec<String> = vec![];
    let mut first_done = false;
    // Inside a `###` heading that is no release: its text belongs to nobody.
    let mut skipping = false;
    // The paragraph or bullet being read, and whether it is a bullet.
    let flush = |out: &mut Vec<Section>, paragraph: &mut Vec<String>, first: &mut bool| {
        if paragraph.is_empty() {
            return;
        }
        let text = paragraph.join(" ");
        paragraph.clear();
        let Some(section) = out.last_mut() else {
            return;
        };
        if let Some(bullet) = text.strip_prefix("- ") {
            section.summary.push(format!("- {}", lead(bullet.trim())));
        } else if !*first {
            section.summary.push(plain(text.trim()));
        }
        *first = true;
    };
    for line in markdown.lines() {
        if let Some(title) = line.strip_prefix("## ") {
            flush(&mut out, &mut paragraph, &mut first_done);
            inside = title.trim() == "Upgrading";
            skipping = false;
            continue;
        }
        if !inside {
            continue;
        }
        if let Some(heading) = line.strip_prefix("### ") {
            flush(&mut out, &mut paragraph, &mut first_done);
            let heading = heading.trim().to_string();
            skipping = true;
            if let Some(version) = section_version(&heading) {
                out.push(Section {
                    heading,
                    version,
                    summary: vec![],
                });
                first_done = false;
                skipping = false;
            }
            continue;
        }
        if skipping {
            continue;
        }
        if let Some(sub) = line.strip_prefix("#### ") {
            flush(&mut out, &mut paragraph, &mut first_done);
            first_done = true;
            if let Some(section) = out.last_mut() {
                section.summary.push(format!("{}:", plain(sub.trim())));
            }
            continue;
        }
        if line.trim().is_empty() || line.starts_with("- ") {
            flush(&mut out, &mut paragraph, &mut first_done);
        }
        if !line.trim().is_empty() {
            paragraph.push(line.trim().to_string());
        }
    }
    flush(&mut out, &mut paragraph, &mut first_done);
    out
}

/// The sections of the releases after `from` up to `to`, oldest first (the order to read them).
#[must_use]
pub fn notes(markdown: &str, from: Version, to: Version) -> Vec<Section> {
    let mut picked: Vec<Section> = sections(markdown)
        .into_iter()
        .filter(|s| s.version > from && s.version <= to)
        .collect();
    picked.sort_by_key(|s| s.version);
    picked
}

/// The notes as printed, for a move from `from` to `to` by an `fsp` of version `own`.
#[must_use]
pub fn notes_text(markdown: &str, from: Version, to: Version, own: Version) -> String {
    let tag = to.tag();
    let page = format!("{REPO_URL}/blob/{tag}/docs/migration.md#upgrading");
    if to < from {
        return format!(
            "{} -> {tag} is a downgrade: {page} says what each release in between changed.\n",
            from.tag()
        );
    }
    let picked = notes(markdown, from, to.min(own));
    let mut out = String::new();
    if !picked.is_empty() {
        out.push_str(&format!(
            "What changed from {} to {tag} (docs/migration.md, \"Upgrading\"; read each before you run the app):\n",
            from.tag()
        ));
        for section in &picked {
            out.push_str(&format!("\n{}: {}\n", section.heading, section.url(&tag)));
            for line in &section.summary {
                out.push_str(&format!("  {line}\n"));
            }
        }
    }
    if to > own {
        out.push_str(&format!(
            "\nfsp {own} was built before {tag}, so it does not carry the notes of the releases after {}: {page}\n",
            own.tag()
        ));
    } else if picked.is_empty() && from < to {
        out.push_str(&format!(
            "No release from {} to {tag} has migration notes.\n",
            from.tag()
        ));
    }
    out
}

// --- Running -----------------------------------------------------------------------------------

/// The refusal when no `--version` is given and a pin is above this `fsp`: the target would be this
/// `fsp`'s own release, which moves the app back.
fn older_than_the_pins(own: Version, newest: Version) -> String {
    format!(
        "this app pins fespalier {newest_tag} and fsp {own} is older, so `fsp upgrade --app` would move the refs back to {own_tag}; nothing was written. Upgrade fsp (`fsp upgrade`), or use the fsp of the pin with `dart run fespalier`, or go back on purpose with `--version {own_tag}`",
        newest_tag = newest.tag(),
        own_tag = own.tag(),
    )
}

/// `fsp upgrade --app` in `project`.
pub fn run(cmd: &UpgradeCmd, project: &Path) -> Result<()> {
    let own =
        Version::parse(env!("CARGO_PKG_VERSION")).context("this fsp's own version is not X.Y.Z")?;
    let target = match &cmd.version {
        Some(text) => Version::parse(text)
            .ok_or_else(|| anyhow!("--version wants a release tag like v1.2.3, not `{text}`"))?,
        None => own,
    };
    let path = project.join("pubspec.yaml");
    let text = fs::read_to_string(&path).with_context(|| format!("reading {}", path.display()))?;
    let overrides = fs::read_to_string(project.join("pubspec_overrides.yaml")).ok();
    let plan = plan(&text, overrides.as_deref(), target).map_err(|e| anyhow!(e))?;
    // With --json, stdout is the one object; what people read goes to stderr.
    let say = |line: &str| {
        if cmd.json {
            errln!("{line}");
        } else {
            outln!("{line}");
        }
    };
    let (oldest, newest, moves, kept, pubspec) = match plan {
        AppPlan::Refs {
            oldest,
            newest,
            moves,
            kept,
            pubspec,
            ..
        } => (oldest, newest, moves, kept, pubspec),
        AppPlan::Checkout { root } => {
            checkout(cmd, &root, target);
            return Ok(());
        }
    };
    // Going back to an older release is something a person asks for with `--version`; an `fsp`
    // older than the app is not that, and neither `--check` nor a run may treat it as an update.
    if cmd.version.is_none() && newest > own {
        bail!(older_than_the_pins(own, newest));
    }
    let up_to_date = moves.is_empty();
    // Where the move starts: the oldest pin, or, when everything goes down, the newest.
    let from = if target < oldest { newest } else { oldest };
    if cmd.json {
        let packages: Vec<serde_json::Value> = moves
            .iter()
            .map(|m| {
                json!({"name": m.name, "section": m.section, "from": m.from, "to": m.to, "downgrade": m.down})
            })
            .collect();
        let sections: Vec<String> = notes(MIGRATION, from, target.min(own))
            .into_iter()
            .map(|s| s.heading)
            .collect();
        outln!(
            "{}",
            json!({
                "from": from.to_string(),
                "target": target.to_string(),
                "upToDate": up_to_date,
                "packages": packages,
                "notes": sections,
            })
        );
    }
    if up_to_date {
        say(&format!(
            "fespalier and every companion in pubspec.yaml are at {}; nothing to move.",
            target.tag()
        ));
    } else {
        say(&format!(
            "pubspec.yaml: {} -> {}{}",
            from.tag(),
            target.tag(),
            if target < from { " (a downgrade)" } else { "" }
        ));
        let width = moves.iter().map(|m| m.name.len()).max().unwrap_or(0);
        for m in &moves {
            let section = if m.section == "dependencies" {
                String::new()
            } else {
                format!(" ({})", m.section)
            };
            let down = if m.down { " (a downgrade)" } else { "" };
            say(&format!(
                "  {:<width$} {} -> {}{section}{down}",
                m.name, m.from, m.to
            ));
        }
    }
    for line in &kept {
        say(&format!("note: {line}"));
    }
    if cmd.check {
        if !up_to_date {
            return Err(Exit(3).into());
        }
        return Ok(());
    }
    let notes = notes_text(MIGRATION, from, target, own);
    if cmd.dry_run || up_to_date {
        if cmd.dry_run && !up_to_date {
            say("Would write pubspec.yaml, then run flutter pub get and fsp gen.");
        }
        if !notes.is_empty() && !up_to_date {
            say(&format!("\n{}", notes.trim_end()));
        }
        return Ok(());
    }
    fs::write(&path, &pubspec).with_context(|| format!("writing {}", path.display()))?;
    say("  edit  pubspec.yaml");
    // The notes come before the commands that can fail: the refs are moved by now, so a second
    // run finds nothing to move and prints no notes, and `pub get` failing is the very case the
    // notes of a release (its Flutter floor, say) explain.
    if !notes.is_empty() {
        say(&format!("\n{}", notes.trim_end()));
    }
    let own_gen = target == own;
    if cmd.no_pub_get {
        say("pubspec.lock still names the commits of the old refs: run `flutter pub get`.");
    } else {
        crate::create::run_flutter(&["pub", "get"], project, "fsp upgrade --app", cmd.json)
            .map_err(|e| {
                Exit::after(&e, |why| {
                    format!(
                        "pubspec.yaml now pins {}, and `flutter pub get` {why}\n{}Fix that and run `flutter pub get`{} (or put the old refs back).",
                        target.tag(),
                        if notes.is_empty() {
                            ""
                        } else {
                            "The migration notes are printed above.\n"
                        },
                        if own_gen { " and `fsp gen`" } else { "" },
                    )
                })
            })?;
    }
    if own_gen {
        let regenerate = || -> Result<()> {
            let cfg = crate::config::Config::load(project)?;
            let outcome = crate::gen_with(project, &cfg, true)?;
            errln!("{}", outcome.line());
            Ok(())
        };
        regenerate().map_err(|e| {
            anyhow!(
                "pubspec.yaml now pins {}, and `fsp gen` failed: {e:#}\n{}Fix that and run `fsp gen`.",
                target.tag(),
                if notes.is_empty() {
                    ""
                } else {
                    "The migration notes are printed above.\n"
                },
            )
        })?;
    } else {
        say(&format!(
            "fsp {own} writes the code of {}: regenerate with the fsp of {} (`dart run fespalier gen`, or `fsp upgrade --version {}` first).",
            own.tag(),
            target.tag(),
            target.tag()
        ));
    }
    Ok(())
}

/// An app whose fespalier is a checkout's folder: nothing to move, and a line that says why.
fn checkout(cmd: &UpgradeCmd, root: &str, target: Version) {
    let line = format!(
        "fespalier comes from a checkout ({root}/fespalier): its version is the checkout's, and pubspec.yaml has no ref to move."
    );
    if cmd.json {
        outln!(
            "{}",
            json!({"checkout": format!("{root}/fespalier"), "target": target.to_string(), "upToDate": true, "packages": [], "notes": []})
        );
        errln!("{line}");
    } else {
        outln!("{line}");
    }
}
