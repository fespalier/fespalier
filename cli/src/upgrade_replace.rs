//! The in-place replacement of a script-installed `fsp` (`fsp upgrade`): download the release
//! archive next to the binary, check it against the release's own `.sha256` **and** the checksums
//! the release tag pins in `release_checksums.dart` (what `dart run fespalier` trusts), unpack it
//! with the system `tar`, prove the new binary runs, and put it in place.
//!
//! The decisions (names, parsing the pins, whether the hashes agree) are pure and tested in
//! `upgrade_tests.rs`; the I/O is `replace` and the small helpers under it. Nothing is ever run
//! with `sudo`, and every temporary file is removed on every path out (`Scratch` on drop).

use std::fs::{self, File, OpenOptions};
use std::io::{self, ErrorKind, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{Context, Result, anyhow, bail};
use sha2::{Digest, Sha256};

use crate::upgrade::{Version, env_nonempty};

const PINS_URL: &str = "https://raw.githubusercontent.com/fespalier/fespalier";
const PINS_PATH: &str = "packages/fespalier/lib/src/release_checksums.dart";
const INSTALL_SH: &str = "https://raw.githubusercontent.com/fespalier/fespalier/main/install.sh";
const INSTALL_PS1: &str = "https://raw.githubusercontent.com/fespalier/fespalier/main/install.ps1";

// --- Pure: names -------------------------------------------------------------------------------

/// The release target for an OS and an architecture (`std::env::consts` spellings), the names
/// `install.sh` and the launcher use; none when no binary is published for it.
pub fn target_for(os: &str, arch: &str) -> Option<&'static str> {
    match (os, arch) {
        ("linux", "x86_64") => Some("x86_64-unknown-linux-gnu"),
        ("linux", "aarch64") => Some("aarch64-unknown-linux-gnu"),
        ("macos", "x86_64") => Some("x86_64-apple-darwin"),
        ("macos", "aarch64") => Some("aarch64-apple-darwin"),
        // Windows on ARM runs the x64 build under emulation.
        ("windows", "x86_64" | "aarch64") => Some("x86_64-pc-windows-msvc"),
        _ => None,
    }
}

/// The target of the host this `fsp` runs on.
pub fn host_target() -> Option<&'static str> {
    target_for(std::env::consts::OS, std::env::consts::ARCH)
}

pub fn is_windows_target(target: &str) -> bool {
    target.contains("windows")
}

/// `fsp-<target>.tar.gz`, or `.zip` for Windows.
pub fn archive_name(target: &str) -> String {
    let ext = if is_windows_target(target) {
        "zip"
    } else {
        "tar.gz"
    };
    format!("fsp-{target}.{ext}")
}

/// `fsp`, or `fsp.exe` for Windows.
pub fn binary_name(target: &str) -> &'static str {
    if is_windows_target(target) {
        "fsp.exe"
    } else {
        "fsp"
    }
}

// --- Pure: pins and verification ---------------------------------------------------------------

/// What `release_checksums.dart` pins: the version and target -> SHA-256 of that target's archive.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pins {
    pub version: String,
    pub checksums: Vec<(String, String)>,
}

impl Pins {
    pub fn get(&self, target: &str) -> Option<&str> {
        self.checksums
            .iter()
            .find(|(t, _)| t == target)
            .map(|(_, h)| h.as_str())
    }
}

/// The single-quoted strings of `text`, in order.
fn quoted(text: &str) -> Vec<&str> {
    text.split('\'').skip(1).step_by(2).collect()
}

/// Reads the generated Dart file: `const pinnedVersion = '0.14.0';` and the
/// `pinnedChecksums = <String, String>{ 'target': 'hash', ... }` map. Comment lines are skipped
/// (the header quotes `''`). None when the file has no `pinnedVersion` at all.
pub fn parse_pins(text: &str) -> Option<Pins> {
    let code: String = text
        .lines()
        .filter(|l| !l.trim_start().starts_with("//"))
        .collect::<Vec<_>>()
        .join("\n");
    let (_, after) = code.split_once("pinnedVersion")?;
    let version = (*quoted(after.split_once(';')?.0).first()?).to_string();
    let checksums = code
        .split_once("pinnedChecksums")
        .and_then(|(_, rest)| rest.split_once('{'))
        .map(|(_, body)| body.split('}').next().unwrap_or_default())
        .map(|body| {
            quoted(body)
                .as_chunks::<2>()
                .0
                .iter()
                .map(|[target, hash]| ((*target).to_string(), hash.to_ascii_lowercase()))
                .collect()
        })
        .unwrap_or_default();
    Some(Pins { version, checksums })
}

/// The hash in a `.sha256` file (`<hex>  <name>`): its first word, as `install.sh` reads it.
pub fn parse_sidecar(text: &str) -> Option<String> {
    let word = text.split_whitespace().next()?.to_ascii_lowercase();
    (word.len() == 64 && word.bytes().all(|b| b.is_ascii_hexdigit())).then_some(word)
}

/// Whether the archive may be installed. `actual` is its SHA-256. It must equal the release's
/// `.sha256` and, from the tag's pins, the pin of `target` (the pins must be those of
/// `version`). Without usable pins the answer is no, unless `allow_unpinned` (a release staged
/// for development, `FSP_UPGRADE_ALLOW_UNPINNED=1`). The error names both values of a mismatch.
pub fn verify(
    actual: &str,
    sidecar: &str,
    pins: Option<&Pins>,
    target: &str,
    version: Version,
    allow_unpinned: bool,
) -> Result<(), String> {
    let expected = parse_sidecar(sidecar)
        .ok_or_else(|| "the release's .sha256 file does not hold a SHA-256".to_string())?;
    if actual != expected {
        return Err(format!(
            "the download does not match the release's .sha256 (downloaded {actual}, the .sha256 \
             says {expected}); nothing was changed"
        ));
    }
    let unpinned = |why: String| {
        if allow_unpinned {
            Ok(())
        } else {
            Err(format!(
                "{why}; refusing to install an archive nothing but the release itself vouches \
                 for. Install with the script instead (curl -fsSL {INSTALL_SH} | sh), or set \
                 FSP_UPGRADE_ALLOW_UNPINNED=1 for a release staged for development"
            ))
        }
    };
    let Some(pins) = pins.filter(|p| !p.version.is_empty()) else {
        return unpinned(format!(
            "{} pins no checksums for the archives of fsp {version}",
            version.tag()
        ));
    };
    if pins.version != version.to_string() {
        return unpinned(format!(
            "the checksums pinned at {} are for fsp {}, not {version}",
            version.tag(),
            pins.version
        ));
    }
    let Some(pin) = pins.get(target) else {
        return Err(format!(
            "the checksums pinned at {} have none for {target}",
            version.tag()
        ));
    };
    if actual != pin {
        return Err(format!(
            "the download does not match the checksum pinned at {} (downloaded {actual}, pinned \
             {pin}); nothing was changed",
            version.tag()
        ));
    }
    Ok(())
}

/// `fsp --version`'s answer for a good binary of `version`.
pub fn version_banner_ok(output: &str, version: Version) -> bool {
    output.trim() == format!("fsp {version}")
}

/// The refusal for a folder fsp cannot write to; the install script is the way out.
pub fn not_writable_message(dir: &str, windows: bool) -> String {
    let alternative = if windows {
        format!("$env:FSP_INSTALL_DIR='{dir}'; irm {INSTALL_PS1} | iex")
    } else {
        format!("curl -fsSL {INSTALL_SH} | FSP_INSTALL_DIR=<a folder you own> sh")
    };
    format!(
        "cannot write to {dir}, where fsp is installed, so it cannot replace itself (fsp never \
         uses sudo). Install into a folder you own and put it first on PATH: {alternative}"
    )
}

// --- I/O ---------------------------------------------------------------------------------------

/// https only, unless the person pointed fsp at a mirror or a test server.
fn proto() -> &'static str {
    let overridden = ["FSP_BASE_URL", "FSP_PINS_URL", "FSP_RELEASES_URL"]
        .iter()
        .any(|name| env_nonempty(name).is_some());
    if overridden { "=http,https" } else { "=https" }
}

fn curl_missing(e: &io::Error) -> anyhow::Error {
    if e.kind() == ErrorKind::NotFound {
        anyhow!(
            "fsp upgrade needs `curl` on PATH to download the release; install it, or run the \
             install script: {INSTALL_SH}"
        )
    } else {
        anyhow!("could not run curl: {e}")
    }
}

/// `curl -fsSL` of `url`, into `dest` when given, else captured.
fn curl(url: &str, dest: Option<&Path>) -> Result<Vec<u8>> {
    let mut command = Command::new("curl");
    command.args(["-fsSL", "--proto", proto(), "--proto-redir", proto()]);
    if let Some(dest) = dest {
        command.arg("-o").arg(dest);
    }
    let out = command
        .arg(url)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| curl_missing(&e))?;
    if !out.status.success() {
        bail!(
            "could not download {url}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(out.stdout)
}

fn sha256_hex(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 8 * 1024];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}

/// Temporary files next to the binary, removed when this goes out of scope, however it does.
struct Scratch {
    archive: PathBuf,
    unpacked: PathBuf,
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.archive);
        let _ = fs::remove_dir_all(&self.unpacked);
    }
}

fn old_path(exe: &Path) -> PathBuf {
    let mut old = exe.as_os_str().to_owned();
    old.push(".old");
    PathBuf::from(old)
}

/// Removes a stale `fsp.exe.old` a Windows upgrade left behind (the old binary was running).
pub fn remove_stale_old(exe: &Path) {
    let _ = fs::remove_file(old_path(exe));
}

/// Replaces the binary at `exe` with release `target_version`, checked as `verify` says. The
/// caller prints the closing line.
pub fn replace(exe: &Path, target_version: Version, base_url: &str) -> Result<()> {
    let dir = exe.parent().context("fsp has no folder")?;
    let dir_text = dir.to_string_lossy().into_owned();
    let target = host_target().ok_or_else(|| {
        anyhow!(
            "no fsp release is published for {} {}; build it from source (see \
             docs/getting-started.md)",
            std::env::consts::OS,
            std::env::consts::ARCH
        )
    })?;
    let tag = target_version.tag();
    let name = archive_name(target);
    let pid = std::process::id();
    let scratch = Scratch {
        archive: dir.join(format!(".fsp-upgrade-{pid}.{name}")),
        unpacked: dir.join(format!(".fsp-upgrade-{pid}.d")),
    };

    // Creating the temp file is the writability check: no sudo, no guessing from mode bits.
    if let Err(e) = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&scratch.archive)
    {
        if matches!(
            e.kind(),
            ErrorKind::PermissionDenied | ErrorKind::ReadOnlyFilesystem
        ) {
            bail!("{}", not_writable_message(&dir_text, cfg!(windows)));
        }
        return Err(anyhow!(e).context(format!("could not write in {dir_text}")));
    }

    curl(&format!("{base_url}/{tag}/{name}"), Some(&scratch.archive))?;
    let sidecar = curl(&format!("{base_url}/{tag}/{name}.sha256"), None)?;
    let pins_url =
        env_nonempty("FSP_PINS_URL").unwrap_or_else(|| format!("{PINS_URL}/{tag}/{PINS_PATH}"));
    let pins = curl(&pins_url, None)
        .ok()
        .and_then(|bytes| parse_pins(&String::from_utf8_lossy(&bytes)));

    let actual = sha256_hex(&scratch.archive).context("could not read the download")?;
    let allow = env_nonempty("FSP_UPGRADE_ALLOW_UNPINNED").as_deref() == Some("1");
    verify(
        &actual,
        &String::from_utf8_lossy(&sidecar),
        pins.as_ref(),
        target,
        target_version,
        allow,
    )
    .map_err(|m| anyhow!(m))?;

    fs::create_dir(&scratch.unpacked).context("could not make a folder to unpack into")?;
    let zip = is_windows_target(target);
    let unpack = Command::new("tar")
        .arg(if zip { "-xf" } else { "-xzf" })
        .arg(&scratch.archive)
        .arg("-C")
        .arg(&scratch.unpacked)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| {
            if e.kind() == ErrorKind::NotFound {
                anyhow!("fsp upgrade needs `tar` on PATH to unpack {name}")
            } else {
                anyhow!("could not run tar: {e}")
            }
        })?;
    if !unpack.status.success() {
        bail!(
            "could not unpack {name}: {}",
            String::from_utf8_lossy(&unpack.stderr).trim()
        );
    }
    let fresh = scratch.unpacked.join(binary_name(target));
    if !fresh.is_file() {
        bail!("{name} did not contain {}", binary_name(target));
    }
    make_executable(&fresh)?;

    // The new binary must run and say it is the release asked for before it replaces anything.
    let banner = Command::new(&fresh)
        .arg("--version")
        .stdin(Stdio::null())
        .output()
        .context("the downloaded fsp does not run")?;
    let said = String::from_utf8_lossy(&banner.stdout).into_owned();
    if !banner.status.success() || !version_banner_ok(&said, target_version) {
        bail!(
            "the downloaded fsp says `{}`, not `fsp {target_version}`; nothing was changed",
            said.trim()
        );
    }

    install(&fresh, exe)
}

#[cfg(unix)]
fn make_executable(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o755))
        .context("could not make the new fsp executable")
}

#[cfg(not(unix))]
fn make_executable(_: &Path) -> Result<()> {
    Ok(())
}

/// Puts `fresh` at `exe`. Unix renames over the running binary. Windows cannot, so the running
/// one moves to `fsp.exe.old` first (deleted by the next `fsp upgrade`), and moves back if the
/// new one cannot take its place.
fn install(fresh: &Path, exe: &Path) -> Result<()> {
    if cfg!(windows) {
        let old = old_path(exe);
        let _ = fs::remove_file(&old);
        fs::rename(exe, &old).with_context(|| format!("could not move {} aside", exe.display()))?;
        if let Err(e) = fs::rename(fresh, exe) {
            let _ = fs::rename(&old, exe);
            return Err(anyhow!(e).context("could not move the new fsp in; the old one was kept"));
        }
        Ok(())
    } else {
        fs::rename(fresh, exe).with_context(|| format!("could not replace {}", exe.display()))
    }
}
