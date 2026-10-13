//! `fsp upgrade`: find the latest release, work out how this `fsp` was installed, and hand the
//! upgrade to whatever owns the install (Homebrew runs, Scoop and cargo print their command).
//!
//! Everything that decides something is pure and tested in `upgrade_tests.rs`: the install method
//! from a path, the tag from a redirect URL, the version order, and the action for a method and
//! the flags. The I/O (the `curl` lookup, `brew`) is at the bottom and small.

use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::{env, fs};

use anyhow::{Context, Result, anyhow, bail};
use clap::Args;
use serde_json::json;

use crate::Exit;
use crate::upgrade_replace as replace;

/// Where releases are found (the redirect of `/releases/latest`).
const RELEASES_URL: &str = "https://github.com/fespalier/fespalier/releases/latest";
/// Where release archives are downloaded from (`FSP_BASE_URL` replaces it).
const BASE_URL: &str = "https://github.com/fespalier/fespalier/releases/download";
const INSTALL_SH: &str = "https://raw.githubusercontent.com/fespalier/fespalier/main/install.sh";
const INSTALL_PS1: &str = "https://raw.githubusercontent.com/fespalier/fespalier/main/install.ps1";
const BREW: &str = "brew upgrade fespalier/tap/fsp";

#[derive(Args)]
pub struct UpgradeCmd {
    /// Write nothing; print the installed and the latest version and exit 0 (up to date), 3 (an update is available) or 1 (error)
    #[arg(long)]
    pub check: bool,
    /// Print what would run or be replaced, and do nothing
    #[arg(long, conflicts_with = "check")]
    pub dry_run: bool,
    /// Print one JSON object (current, latest, target, method, command, upToDate) with --check or --dry-run
    #[arg(long)]
    pub json: bool,
    /// Install this release instead of the latest (vX.Y.Z or X.Y.Z); script installs only
    #[arg(long, value_name = "TAG")]
    pub version: Option<String>,
}

// --- Versions ----------------------------------------------------------------------------------

/// A release version, `major.minor.patch` and nothing else (a pre-release suffix is refused).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version(pub u64, pub u64, pub u64);

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}.{}", self.0, self.1, self.2)
    }
}

impl Version {
    /// `v0.15.0` or `0.15.0`.
    pub fn parse(text: &str) -> Option<Self> {
        let text = text.trim();
        let text = text.strip_prefix('v').unwrap_or(text);
        let mut parts = text.split('.');
        let mut next = || {
            let part = parts.next()?;
            if part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            part.parse::<u64>().ok()
        };
        let version = Self(next()?, next()?, next()?);
        parts.next().is_none().then_some(version)
    }

    pub fn tag(self) -> String {
        format!("v{self}")
    }
}

/// The version out of the URL `/releases/latest` redirects to (`.../releases/tag/v0.15.0`).
pub fn version_from_release_url(url: &str) -> Result<Version> {
    let url = url.trim();
    let (_, rest) = url
        .split_once("/releases/tag/")
        .ok_or_else(|| anyhow!("no release was found at {url}"))?;
    let tag = rest.split(['/', '?', '#']).next().unwrap_or_default();
    Version::parse(tag).ok_or_else(|| anyhow!("the latest release is tagged `{tag}`, not vX.Y.Z"))
}

// --- Install methods ---------------------------------------------------------------------------

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Method {
    /// The copy `dart run fespalier` keeps in its cache, for this version.
    DartRun(String),
    /// A `cargo build` of this repository.
    Source,
    Homebrew,
    Scoop,
    Cargo,
    /// `install.sh`, `install.ps1` or a hand-placed binary.
    Script,
}

impl Method {
    pub fn name(&self) -> &'static str {
        match self {
            Self::DartRun(_) => "dart-run",
            Self::Source => "source",
            Self::Homebrew => "homebrew",
            Self::Scoop => "scoop",
            Self::Cargo => "cargo",
            Self::Script => "script",
        }
    }
}

/// What detection reads besides the path.
#[derive(Clone, Debug, Default)]
pub struct Env {
    pub home: Option<String>,
    pub cargo_home: Option<String>,
    pub scoop: Option<String>,
}

fn components(path: &str) -> Vec<String> {
    path.trim_start_matches(r"\\?\")
        .split(['/', '\\'])
        .filter(|c| !c.is_empty())
        .map(str::to_string)
        .collect()
}

fn same(a: &str, b: &str, ignore_case: bool) -> bool {
    if ignore_case {
        a.eq_ignore_ascii_case(b)
    } else {
        a == b
    }
}

fn has_run(parts: &[String], run: &[&str], ignore_case: bool) -> bool {
    parts
        .windows(run.len())
        .any(|w| w.iter().zip(run).all(|(a, b)| same(a, b, ignore_case)))
}

fn starts_with(parts: &[String], prefix: &[String], ignore_case: bool) -> bool {
    !prefix.is_empty()
        && parts.len() > prefix.len()
        && parts
            .iter()
            .zip(prefix)
            .all(|(a, b)| same(a, b, ignore_case))
}

/// How this `fsp` was installed, from where it runs (the canonical path). Both path separators
/// are read, so a Windows path is understood on any host. The first match wins.
pub fn detect(exe: &str, env: &Env) -> Method {
    let parts = components(exe);
    // Windows paths are case-insensitive.
    let ci = exe.contains('\\');
    // `<cache>/fespalier/<version>-<target>/fsp`, what `dart run fespalier` keeps.
    if parts.len() >= 3 {
        let (grand, dir) = (&parts[parts.len() - 3], &parts[parts.len() - 2]);
        if grand == "fespalier"
            && let Some((version, target)) = dir.split_once('-')
            && Version::parse(version).is_some()
            && !version.starts_with('v')
            && !target.is_empty()
        {
            return Method::DartRun(version.to_string());
        }
    }
    if has_run(&parts, &["target", "debug"], false)
        || has_run(&parts, &["target", "release"], false)
    {
        return Method::Source;
    }
    if has_run(&parts, &["Cellar", "fsp"], false) {
        return Method::Homebrew;
    }
    if has_run(&parts, &["scoop", "apps", "fsp"], true) {
        return Method::Scoop;
    }
    if let Some(scoop) = &env.scoop {
        let mut prefix = components(scoop);
        prefix.extend(["apps".to_string(), "fsp".to_string()]);
        if starts_with(&parts, &prefix, ci) {
            return Method::Scoop;
        }
    }
    let cargo_home = env.cargo_home.clone().or_else(|| {
        env.home
            .as_ref()
            .map(|h| format!("{}/.cargo", h.trim_end_matches(['/', '\\'])))
    });
    if let Some(cargo_home) = cargo_home {
        let mut prefix = components(&cargo_home);
        prefix.push("bin".to_string());
        if starts_with(&parts, &prefix, ci) {
            return Method::Cargo;
        }
    }
    Method::Script
}

// --- The decision ------------------------------------------------------------------------------

/// What `fsp upgrade` does for a method and a target.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    /// Nothing to do: this is the release asked for (or newer than the latest).
    UpToDate,
    /// Stop with this message and exit 1.
    Refuse(String),
    /// Run `brew upgrade fespalier/tap/fsp`.
    Brew,
    /// Print these commands for the person to run.
    Print(Vec<String>),
    /// A script install: the binary is replaced in place, after the archive is checked.
    Script,
}

pub struct Plan {
    pub action: Action,
    /// The one-line command for `--json`; none when the method cannot be upgraded from here.
    pub command: Option<String>,
}

pub fn cargo_command(target: Version) -> String {
    format!(
        "cargo install --git https://github.com/fespalier/fespalier --tag {} --locked fespalier",
        target.tag()
    )
}

/// The install script's command for a release, writing over `dir`.
pub fn script_command(target: Version, dir: &str, windows: bool) -> String {
    if windows {
        format!(
            "$env:FSP_VERSION='{}'; $env:FSP_INSTALL_DIR='{dir}'; irm {INSTALL_PS1} | iex",
            target.tag()
        )
    } else {
        format!(
            "curl -fsSL {INSTALL_SH} | FSP_VERSION={} FSP_INSTALL_DIR='{dir}' sh",
            target.tag()
        )
    }
}

fn dart_run_refusal(cached: &str) -> String {
    format!(
        "this fsp is the one `dart run fespalier` keeps for fespalier {cached}; it follows the \
         ref: in pubspec.yaml. Change the ref of fespalier and every companion to the release \
         you want, then flutter pub get."
    )
}

/// What to do for `method`, with `current` installed and `target` wanted. `explicit` is
/// `--version`; `dir` is the folder of the binary and `windows` the host, for the script command.
pub fn plan(
    method: &Method,
    current: Version,
    target: Version,
    explicit: bool,
    dir: &str,
    windows: bool,
) -> Plan {
    let refuse = |message: String| Plan {
        action: Action::Refuse(message),
        command: None,
    };
    match method {
        Method::DartRun(cached) => return refuse(dart_run_refusal(cached)),
        Method::Source => {
            return refuse(
                "this fsp is a build of the source tree; update it with git pull and cargo \
                 build, or install a release (see docs/getting-started.md)."
                    .to_string(),
            );
        }
        _ => {}
    }
    let command = match method {
        Method::Homebrew => BREW.to_string(),
        Method::Scoop => "scoop update && scoop update fsp".to_string(),
        Method::Cargo => cargo_command(target),
        _ => script_command(target, dir, windows),
    };
    let up_to_date = if explicit {
        current == target
    } else {
        current >= target
    };
    if up_to_date {
        return Plan {
            action: Action::UpToDate,
            command: Some(command),
        };
    }
    let action = match method {
        Method::Homebrew | Method::Scoop if explicit => {
            let who = if matches!(method, Method::Homebrew) {
                "Homebrew"
            } else {
                "Scoop"
            };
            return refuse(format!(
                "{who} installs only the release it has; to install {tag} run the install \
                 script with FSP_VERSION={tag} set (see docs/getting-started.md).",
                tag = target.tag()
            ));
        }
        Method::Homebrew => Action::Brew,
        Method::Scoop => Action::Print(vec!["scoop update".into(), "scoop update fsp".into()]),
        Method::Cargo => Action::Print(vec![command.clone()]),
        _ => Action::Script,
    };
    Plan {
        action,
        command: Some(command),
    }
}

// --- Running -----------------------------------------------------------------------------------

pub fn env_nonempty(name: &str) -> Option<String> {
    env::var(name).ok().filter(|v| !v.is_empty())
}

/// The null device for `curl -o`.
const NULL: &str = if cfg!(windows) { "NUL" } else { "/dev/null" };

/// The version `FSP_RELEASES_URL` (default: GitHub's `/releases/latest`) redirects to, by the
/// system `curl`, as `install.sh` does: it honours `HTTPS_PROXY` and the OS trust store.
fn latest_version() -> Result<Version> {
    let override_url = env_nonempty("FSP_RELEASES_URL");
    let url = override_url.as_deref().unwrap_or(RELEASES_URL);
    // https only, unless the person pointed us at a mirror or a test server.
    let proto = if override_url.is_some() || env_nonempty("FSP_BASE_URL").is_some() {
        "=http,https"
    } else {
        "=https"
    };
    let out = Command::new("curl")
        .args([
            "-fsSL",
            "-I",
            "--proto",
            proto,
            "--proto-redir",
            proto,
            "-o",
            NULL,
        ])
        .args(["-w", "%{url_effective}", url])
        .stdin(Stdio::null())
        .output()
        .map_err(|e| {
            if e.kind() == ErrorKind::NotFound {
                anyhow!(
                    "fsp upgrade needs `curl` on PATH to look up the latest release; install it, \
                     or run the install script: {INSTALL_SH}"
                )
            } else {
                anyhow!("could not run curl: {e}")
            }
        })?;
    if !out.status.success() {
        let why = String::from_utf8_lossy(&out.stderr);
        bail!(
            "could not look up the latest release at {url}: {}",
            why.trim()
        );
    }
    version_from_release_url(&String::from_utf8_lossy(&out.stdout))
}

/// `\\?\C:\dir` as `C:\dir`, and `\\?\UNC\host\share` as `\\host\share`: what
/// `fs::canonicalize` returns on Windows, which is no path to show a person or to put in a
/// command. Any other path is returned as it is.
pub fn strip_verbatim(path: &Path) -> PathBuf {
    let text = path.to_string_lossy();
    if let Some(unc) = text.strip_prefix(r"\\?\UNC\") {
        PathBuf::from(format!(r"\\{unc}"))
    } else if let Some(rest) = text.strip_prefix(r"\\?\") {
        PathBuf::from(rest)
    } else {
        path.to_path_buf()
    }
}

/// A folder named by the environment, resolved the way `current_exe` is (long names, no
/// 8.3 `RUNNER~1`), so that the two can be compared; as given when it does not exist.
fn resolved(value: String) -> String {
    fs::canonicalize(&value)
        .map(|p| strip_verbatim(&p).to_string_lossy().into_owned())
        .unwrap_or(value)
}

fn current_env() -> Env {
    Env {
        home: env_nonempty("HOME")
            .or_else(|| env_nonempty("USERPROFILE"))
            .map(resolved),
        cargo_home: env_nonempty("CARGO_HOME").map(resolved),
        scoop: env_nonempty("SCOOP").map(resolved),
    }
}

/// The note after an upgrade when the app pins another fespalier than the `fsp` now installed.
/// `pinned` is the pubspec's `ref:` of `fespalier`; a ref that is not a release tag (a branch, a
/// commit) cannot be compared and says nothing.
pub fn ref_note(pinned: Option<&str>, installed: Version) -> Option<String> {
    let pinned = pinned?;
    let version = Version::parse(pinned)?;
    (version != installed).then(|| {
        format!(
            "this app pins fespalier {pin}; fsp {installed} writes code for {tag}. Update the refs \
             (fespalier and every companion, the same url and ref), or run `dart run fespalier` \
             to use the fsp that matches the pin.",
            pin = version.tag(),
            tag = installed.tag(),
        )
    })
}

/// Prints [`ref_note`] for the project at `project`, if there is one.
fn print_ref_note(project: Option<&Path>, installed: Version) {
    let pinned = project
        .and_then(|p| crate::config::Pubspec::load(p).ok())
        .and_then(|p| p.pinned_ref);
    if let Some(note) = ref_note(pinned.as_deref(), installed) {
        println!("{note}");
    }
}

pub fn run(cmd: &UpgradeCmd, project: Option<&Path>) -> Result<()> {
    let current =
        Version::parse(env!("CARGO_PKG_VERSION")).context("this fsp's own version is not X.Y.Z")?;
    let exe = env::current_exe()
        .and_then(fs::canonicalize)
        .map(|path| strip_verbatim(&path))
        .context("could not find where fsp is installed")?;
    let dir = exe
        .parent()
        .map(Path::to_string_lossy)
        .map(String::from)
        .unwrap_or_default();
    let method = detect(&exe.to_string_lossy(), &current_env());
    let explicit = cmd.version.is_some();

    // A method that cannot be upgraded from here says so before any network call.
    if !cmd.check && !cmd.json {
        let probe = plan(&method, current, current, explicit, &dir, cfg!(windows));
        if let Action::Refuse(message) = probe.action
            && matches!(method, Method::DartRun(_) | Method::Source)
        {
            bail!("{message}");
        }
    }

    let target = match &cmd.version {
        Some(text) => Version::parse(text)
            .ok_or_else(|| anyhow!("--version wants a release tag like v1.2.3, not `{text}`"))?,
        None => latest_version()?,
    };
    let plan = plan(&method, current, target, explicit, &dir, cfg!(windows));
    let up_to_date = if explicit {
        current == target
    } else {
        current >= target
    };

    if cmd.check || cmd.json {
        if cmd.json {
            println!(
                "{}",
                json!({
                    "current": current.to_string(),
                    "latest": target.to_string(),
                    "target": target.to_string(),
                    "method": method.name(),
                    "command": plan.command,
                    "upToDate": up_to_date,
                })
            );
        } else if up_to_date {
            println!("fsp {current} is the latest ({}).", method.name());
        } else {
            println!("fsp {current} ({}); {target} is available.", method.name());
            if let Some(command) = &plan.command {
                println!("  {command}");
            }
        }
        if cmd.check && !up_to_date {
            return Err(Exit(3).into());
        }
        return Ok(());
    }

    match &plan.action {
        Action::UpToDate => {
            if current > target && !explicit {
                println!("fsp {current} is newer than the latest release ({target}).");
            } else {
                println!("fsp {current} is the latest.");
            }
        }
        Action::Refuse(message) => bail!("{message}"),
        Action::Brew => {
            println!("fsp {current} -> {target}: {BREW}");
            println!("(if Homebrew finds nothing newer, run `brew update` first)");
            if cmd.dry_run {
                return Ok(());
            }
            let status = Command::new("brew")
                .args(["upgrade", "fespalier/tap/fsp"])
                .status()
                .context("could not run brew")?;
            if !status.success() {
                return Err(Exit(status.code().unwrap_or(1)).into());
            }
            print_ref_note(project, target);
        }
        Action::Print(lines) => {
            println!("fsp {current} -> {target}. Run:");
            for line in lines {
                println!("  {line}");
            }
        }
        Action::Script => {
            let note = if current > target {
                " (a downgrade)"
            } else {
                ""
            };
            let base = env_nonempty("FSP_BASE_URL").unwrap_or_else(|| BASE_URL.to_string());
            if cmd.dry_run {
                println!("fsp {current} -> {target}{note}, a script install in {dir}.");
                let archive = replace::host_target()
                    .map(replace::archive_name)
                    .unwrap_or_default();
                println!(
                    "Would download {base}/{}/{archive} and replace {} after checking the archive \
                     against the release's .sha256 and the checksums pinned at the tag. The \
                     install script does the same:",
                    target.tag(),
                    exe.display()
                );
                if let Some(command) = &plan.command {
                    println!("  {command}");
                }
                return Ok(());
            }
            if current > target {
                println!("fsp {current} -> {target}: a downgrade, as asked.");
            }
            replace::remove_stale_old(&exe);
            replace::replace(&exe, target, &base)?;
            println!(
                "\u{2713} fsp {current} \u{2192} {target} ({})",
                exe.display()
            );
            print_ref_note(project, target);
        }
    }
    Ok(())
}
