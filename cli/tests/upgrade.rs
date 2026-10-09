//! Runs the built `fsp upgrade` against a fake release server (a `TcpListener` that answers
//! `/releases/latest` with a 302 to `/releases/tag/<tag>`, as GitHub does). The binary is copied
//! into a throwaway folder so that it does not look like a source build. The lookup uses the
//! system `curl`, so these tests skip without it unless `FSP_REQUIRE_CURL=1` (CI sets it).

#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    reason = "integration-test helpers: a failed unwrap is a failed test"
)]

use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::sync::{Mutex, PoisonError};
use std::thread;

/// This binary's own version, what `fsp upgrade` compares with.
const CURRENT: &str = env!("CARGO_PKG_VERSION");

/// One process starts at a time: copying the binary and exec'ing it must not overlap another
/// thread's fork, or the exec fails with ETXTBSY ("Text file busy", rust-lang/rust#114554).
static SPAWN: Mutex<()> = Mutex::new(());

fn curl_available() -> bool {
    let _spawning = SPAWN.lock().unwrap_or_else(PoisonError::into_inner);
    let present = Command::new("curl")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success());
    if !present {
        assert!(
            std::env::var("FSP_REQUIRE_CURL").as_deref() != Ok("1"),
            "curl is required (FSP_REQUIRE_CURL=1) and is not on PATH"
        );
        eprintln!("skipped: curl is not on PATH");
    }
    present
}

/// A release server on a free port. `latest` is the tag `/releases/latest` redirects to; none
/// means it answers 200 with no redirect (a repository with no release). `files` are served
/// (200) to any path ending with their suffix, and with `files` set everything else is a 404.
struct Server {
    url: String,
    base: String,
    pins: String,
}

type Files = Vec<(String, Vec<u8>)>;

fn answer(mut stream: TcpStream, latest: Option<&str>, files: &Files, port: u16) {
    let mut request = Vec::new();
    let mut buf = [0u8; 1024];
    while !request.windows(4).any(|w| w == b"\r\n\r\n") {
        match stream.read(&mut buf) {
            Ok(0) | Err(_) => return,
            Ok(n) => request.extend_from_slice(&buf[..n]),
        }
    }
    let line = String::from_utf8_lossy(&request);
    let path = line.split_whitespace().nth(1).unwrap_or("/");
    if let Some((_, body)) = files
        .iter()
        .find(|(suffix, _)| path.ends_with(suffix.as_str()))
    {
        let head = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        );
        let _ = stream.write_all(head.as_bytes());
        let _ = stream.write_all(body);
        return;
    }
    let response = match latest {
        Some(tag) if path.ends_with("/releases/latest") => format!(
            "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{port}/releases/tag/{tag}\r\n\
             Content-Length: 0\r\nConnection: close\r\n\r\n"
        ),
        _ if !files.is_empty() && !path.contains("/releases/tag/") => {
            "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_string()
        }
        _ => "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_string(),
    };
    let _ = stream.write_all(response.as_bytes());
}

impl Server {
    fn start(latest: Option<&'static str>) -> Self {
        Self::with_files(latest, Vec::new())
    }

    fn with_files(latest: Option<&'static str>, files: Files) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                answer(stream, latest, &files, port);
            }
        });
        Self {
            url: format!("http://127.0.0.1:{port}/releases/latest"),
            base: format!("http://127.0.0.1:{port}/dl"),
            pins: format!("http://127.0.0.1:{port}/pins/release_checksums.dart"),
        }
    }
}

/// A place to install the copy of `fsp` into, under a throwaway folder that is also its HOME.
struct Install {
    home: tempfile::TempDir,
    exe: PathBuf,
}

impl Install {
    /// `relative` is the copy's path under the folder, e.g. `bin/fsp` or `Cellar/fsp/0.1.0/bin/fsp`.
    fn at(relative: &str) -> Self {
        let home = tempfile::tempdir().unwrap();
        let exe = home.path().join(relative);
        fs::create_dir_all(exe.parent().unwrap()).unwrap();
        let _spawning = SPAWN.lock().unwrap_or_else(PoisonError::into_inner);
        fs::copy(env!("CARGO_BIN_EXE_fsp"), &exe).unwrap();
        Self { home, exe }
    }

    fn run(&self, server: Option<&Server>, args: &[&str]) -> Output {
        self.run_with(server, args, |_| {})
    }

    fn run_with(
        &self,
        server: Option<&Server>,
        args: &[&str],
        tweak: impl FnOnce(&mut Command),
    ) -> Output {
        let mut command = Command::new(&self.exe);
        command
            .arg("upgrade")
            .args(args)
            .current_dir(self.home.path())
            .env("HOME", self.home.path())
            .env_remove("CARGO_HOME")
            .env_remove("SCOOP")
            .env_remove("FSP_BASE_URL")
            .env_remove("FSP_RELEASES_URL")
            .env_remove("FSP_PINS_URL")
            .env_remove("FSP_UPGRADE_ALLOW_UNPINNED")
            .env_remove("FSP_PINS_URL")
            .env_remove("FSP_UPGRADE_ALLOW_UNPINNED")
            .env_remove("HTTPS_PROXY")
            .env_remove("https_proxy")
            .env_remove("ALL_PROXY");
        if let Some(server) = server {
            command
                .env("FSP_RELEASES_URL", &server.url)
                .env("FSP_BASE_URL", &server.base)
                .env("FSP_PINS_URL", &server.pins);
        }
        tweak(&mut command);
        let _spawning = SPAWN.lock().unwrap_or_else(PoisonError::into_inner);
        command.output().unwrap()
    }
}

fn stdout(out: &Output) -> String {
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn stderr(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr).into_owned()
}

#[test]
fn check_exits_3_when_a_newer_release_exists() {
    if !curl_available() {
        return;
    }
    let server = Server::start(Some("v99.0.0"));
    let out = Install::at("bin/fsp").run(Some(&server), &["--check"]);
    assert_eq!(
        out.status.code(),
        Some(3),
        "{}{}",
        stdout(&out),
        stderr(&out)
    );
    let text = stdout(&out);
    assert!(text.contains(CURRENT) && text.contains("99.0.0"), "{text}");
    assert!(text.contains("script"), "{text}");
}

#[test]
fn check_exits_0_when_up_to_date_or_ahead() {
    if !curl_available() {
        return;
    }
    let install = Install::at("bin/fsp");
    for tag in ["v0.0.1", Box::leak(format!("v{CURRENT}").into_boxed_str())] {
        let server = Server::start(Some(tag));
        let out = install.run(Some(&server), &["--check"]);
        assert_eq!(
            out.status.code(),
            Some(0),
            "{tag}: {}{}",
            stdout(&out),
            stderr(&out)
        );
        assert!(stdout(&out).contains("is the latest"), "{}", stdout(&out));
    }
}

#[test]
fn check_exits_1_when_the_lookup_fails() {
    if !curl_available() {
        return;
    }
    // A port nothing listens on.
    let dead = {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        Server {
            url: format!("http://127.0.0.1:{port}/releases/latest"),
            base: format!("http://127.0.0.1:{port}/dl"),
            pins: format!("http://127.0.0.1:{port}/pins"),
        }
    };
    let out = Install::at("bin/fsp").run(Some(&dead), &["--check"]);
    assert_eq!(out.status.code(), Some(1), "{}", stdout(&out));
    assert!(
        stderr(&out).contains("could not look up"),
        "{}",
        stderr(&out)
    );
}

#[test]
fn check_exits_1_when_there_is_no_release() {
    if !curl_available() {
        return;
    }
    let server = Server::start(None);
    let out = Install::at("bin/fsp").run(Some(&server), &["--check"]);
    assert_eq!(out.status.code(), Some(1));
    assert!(stderr(&out).contains("no release"), "{}", stderr(&out));
}

#[test]
fn json_prints_one_object() {
    if !curl_available() {
        return;
    }
    let server = Server::start(Some("v99.0.0"));
    let install = Install::at("bin/fsp");
    let out = install.run(Some(&server), &["--check", "--json"]);
    assert_eq!(out.status.code(), Some(3));
    let text = stdout(&out);
    assert_eq!(text.lines().count(), 1, "{text}");
    let json: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(json["current"], CURRENT);
    assert_eq!(json["latest"], "99.0.0");
    assert_eq!(json["target"], "99.0.0");
    assert_eq!(json["method"], "script");
    assert_eq!(json["upToDate"], false);
    let command = json["command"].as_str().unwrap();
    assert!(command.contains("FSP_VERSION=v99.0.0"), "{command}");

    // --json without --check still writes nothing and exits 0.
    let out = install.run(Some(&server), &["--dry-run", "--json"]);
    assert_eq!(out.status.code(), Some(0));
    let json: serde_json::Value = serde_json::from_str(&stdout(&out)).unwrap();
    assert_eq!(json["upToDate"], false);
}

#[test]
fn dry_run_says_what_it_would_do_and_changes_nothing() {
    if !curl_available() {
        return;
    }
    let server = Server::start(Some("v99.0.0"));
    let install = Install::at("bin/fsp");
    let before = fs::read(&install.exe).unwrap();
    let out = install.run(Some(&server), &["--dry-run"]);
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    let text = stdout(&out);
    assert!(
        text.contains("99.0.0") && text.contains("FSP_VERSION=v99.0.0"),
        "{text}"
    );
    assert_eq!(fs::read(&install.exe).unwrap(), before);
}

#[test]
fn an_explicit_version_needs_no_network_and_a_downgrade_is_named() {
    // No server, no FSP_RELEASES_URL: the lookup must not run.
    let install = Install::at("bin/fsp");
    let out = install.run(None, &["--dry-run", "--version", "0.0.1"]);
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    let text = stdout(&out);
    assert!(
        text.contains("0.0.1") && text.contains("downgrade"),
        "{text}"
    );
    assert!(text.contains("FSP_VERSION=v0.0.1"), "{text}");

    let out = install.run(None, &["--version", "latest"]);
    assert_eq!(out.status.code(), Some(1));
    assert!(
        stderr(&out).contains("vX.Y.Z") || stderr(&out).contains("v1.2.3"),
        "{}",
        stderr(&out)
    );
}

#[test]
fn the_dart_run_cache_is_refused_without_a_lookup() {
    let install = Install::at(&format!("fespalier/{CURRENT}-x86_64-unknown-linux-gnu/fsp"));
    let out = install.run(None, &[]);
    assert_eq!(out.status.code(), Some(1));
    let text = stderr(&out);
    assert!(
        text.contains("dart run fespalier") && text.contains("ref:"),
        "{text}"
    );
    assert!(text.contains(CURRENT), "{text}");
}

#[test]
fn check_still_reports_for_the_dart_run_cache() {
    if !curl_available() {
        return;
    }
    let server = Server::start(Some("v99.0.0"));
    let install = Install::at(&format!("fespalier/{CURRENT}-x86_64-unknown-linux-gnu/fsp"));
    let out = install.run(Some(&server), &["--check", "--json"]);
    assert_eq!(out.status.code(), Some(3));
    let json: serde_json::Value = serde_json::from_str(&stdout(&out)).unwrap();
    assert_eq!(json["method"], "dart-run");
    assert_eq!(json["command"], serde_json::Value::Null);
}

#[test]
fn a_source_build_is_refused_and_named() {
    let install = Install::at("work/cli/target/debug/fsp");
    let out = install.run(None, &[]);
    assert_eq!(out.status.code(), Some(1));
    assert!(stderr(&out).contains("source tree"), "{}", stderr(&out));
}

#[test]
fn scoop_and_cargo_print_their_command() {
    if !curl_available() {
        return;
    }
    let server = Server::start(Some("v99.0.0"));

    let scoop = Install::at("scoop/apps/fsp/current/fsp");
    let out = scoop.run(Some(&server), &[]);
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    let text = stdout(&out);
    assert!(text.contains("scoop update fsp"), "{text}");

    let cargo = Install::at(".cargo/bin/fsp");
    let out = cargo.run(Some(&server), &[]);
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    let text = stdout(&out);
    assert!(
        text.contains("cargo install --git https://github.com/fespalier/fespalier"),
        "{text}"
    );
    assert!(text.contains("--tag v99.0.0 --locked fespalier"), "{text}");

    // CARGO_HOME moves it.
    let custom = Install::at("cargo-home/bin/fsp");
    let home = custom.home.path().join("cargo-home");
    let out = custom.run_with(Some(&server), &["--check", "--json"], |c| {
        c.env("CARGO_HOME", &home);
    });
    let json: serde_json::Value = serde_json::from_str(&stdout(&out)).unwrap();
    assert_eq!(json["method"], "cargo");
}

#[cfg(unix)]
#[test]
fn homebrew_runs_brew_upgrade_with_the_formula() {
    use std::os::unix::fs::PermissionsExt;

    if !curl_available() {
        return;
    }
    let server = Server::start(Some("v99.0.0"));
    let install = Install::at(&format!("Cellar/fsp/{CURRENT}/bin/fsp"));
    let bin = install.home.path().join("fakebin");
    fs::create_dir_all(&bin).unwrap();
    let log = install.home.path().join("brew.log");
    {
        let _spawning = SPAWN.lock().unwrap_or_else(PoisonError::into_inner);
        let brew = bin.join("brew");
        fs::write(
            &brew,
            format!(
                "#!/bin/sh\necho \"$@\" >> '{}'\nexit ${{FAKE_BREW_EXIT:-0}}\n",
                log.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&brew, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let with_path = |c: &mut Command| {
        c.env("PATH", &path);
    };

    // A dry run does not call brew.
    let out = install.run_with(Some(&server), &["--dry-run"], with_path);
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    assert!(
        stdout(&out).contains("brew upgrade fespalier/tap/fsp"),
        "{}",
        stdout(&out)
    );
    assert!(!log.exists(), "a dry run ran brew");

    let out = install.run_with(Some(&server), &[], with_path);
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    assert_eq!(
        fs::read_to_string(&log).unwrap().trim(),
        "upgrade fespalier/tap/fsp"
    );

    // brew's own exit code is fsp's.
    let out = install.run_with(Some(&server), &[], |c| {
        c.env("PATH", &path).env("FAKE_BREW_EXIT", "7");
    });
    assert_eq!(out.status.code(), Some(7));

    // Homebrew cannot install a chosen release.
    let out = install.run_with(None, &["--version", "0.0.1"], with_path);
    assert_eq!(out.status.code(), Some(1));
    assert!(
        stderr(&out).contains("FSP_VERSION=v0.0.1"),
        "{}",
        stderr(&out)
    );
}

// --- Replacing a script install ----------------------------------------------------------------

#[cfg(unix)]
mod replace {
    use super::*;
    use sha2::{Digest, Sha256};
    use std::os::unix::fs::PermissionsExt;

    const NEW: &str = "9.9.9";

    fn tar_available() -> bool {
        let _spawning = SPAWN.lock().unwrap_or_else(PoisonError::into_inner);
        let present = Command::new("tar")
            .arg("--version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
        if !present {
            assert!(
                std::env::var("FSP_REQUIRE_CURL").as_deref() != Ok("1"),
                "tar is required (FSP_REQUIRE_CURL=1) and is not on PATH"
            );
            eprintln!("skipped: tar is not on PATH");
        }
        present
    }

    fn ready() -> bool {
        curl_available() && tar_available()
    }

    /// The release target of this host, the archive name the binary will ask for.
    fn target() -> &'static str {
        match (std::env::consts::OS, std::env::consts::ARCH) {
            ("linux", "x86_64") => "x86_64-unknown-linux-gnu",
            ("linux", "aarch64") => "aarch64-unknown-linux-gnu",
            ("macos", "x86_64") => "x86_64-apple-darwin",
            ("macos", "aarch64") => "aarch64-apple-darwin",
            (os, arch) => panic!("no release target for {os} {arch}"),
        }
    }

    /// A `.tar.gz` holding a tiny `fsp` script that prints `banner`.
    fn archive(banner: &str) -> Vec<u8> {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("fsp");
        let tar = dir.path().join("out.tar.gz");
        let _spawning = SPAWN.lock().unwrap_or_else(PoisonError::into_inner);
        fs::write(&script, format!("#!/bin/sh\necho '{banner}'\n")).unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let status = Command::new("tar")
            .arg("-czf")
            .arg(&tar)
            .arg("-C")
            .arg(dir.path())
            .arg("fsp")
            .status()
            .unwrap();
        assert!(status.success());
        fs::read(&tar).unwrap()
    }

    fn sha(bytes: &[u8]) -> String {
        Sha256::digest(bytes)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }

    fn pins(version: &str, hash: &str) -> String {
        format!(
            "// GENERATED\nconst pinnedVersion = '{version}';\n\
             const pinnedChecksums = <String, String>{{\n  '{}':\n      '{hash}',\n}};\n",
            target()
        )
    }

    /// What the fake release serves for `v9.9.9`.
    struct Release {
        // Built once: gzip stamps a time in the header, so two builds differ.
        bytes: Vec<u8>,
        sidecar: Option<String>,
        pins: Option<String>,
    }

    impl Release {
        /// Everything agrees.
        fn good() -> (Self, String) {
            let bytes = archive(&format!("fsp {NEW}"));
            let hash = sha(&bytes);
            let release = Self {
                bytes,
                sidecar: Some(format!("{hash}  fsp-{}.tar.gz\n", target())),
                pins: Some(pins(NEW, &hash)),
            };
            (release, hash)
        }

        /// An archive of `banner` that both sources vouch for, pinned as `version`.
        fn vouched(banner: &str, version: &str) -> Self {
            let bytes = archive(banner);
            let hash = sha(&bytes);
            Self {
                bytes,
                sidecar: Some(format!("{hash}  x\n")),
                pins: Some(pins(version, &hash)),
            }
        }

        fn serve(&self, latest: &'static str) -> Server {
            let mut files: Files = vec![(format!("/fsp-{}.tar.gz", target()), self.bytes.clone())];
            if let Some(sidecar) = &self.sidecar {
                files.push((
                    format!("/fsp-{}.tar.gz.sha256", target()),
                    sidecar.clone().into_bytes(),
                ));
            }
            if let Some(pins) = &self.pins {
                files.push((
                    "/pins/release_checksums.dart".into(),
                    pins.clone().into_bytes(),
                ));
            }
            Server::with_files(Some(latest), files)
        }
    }

    fn folder_entries(install: &Install) -> Vec<String> {
        fs::read_dir(install.exe.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect()
    }

    /// The binary is as it was, and nothing else is in its folder.
    fn assert_untouched(install: &Install, before: &[u8]) {
        assert_eq!(
            fs::read(&install.exe).unwrap(),
            before,
            "the binary changed"
        );
        assert_eq!(
            folder_entries(install),
            ["fsp"],
            "temporary files were left behind"
        );
    }

    fn refused(release: &Release, expect: &[&str]) {
        let server = release.serve("v9.9.9");
        let install = Install::at("bin/fsp");
        let before = fs::read(&install.exe).unwrap();
        let out = install.run(Some(&server), &[]);
        let err = stderr(&out);
        assert_eq!(out.status.code(), Some(1), "{}{err}", stdout(&out));
        for needle in expect {
            assert!(err.contains(needle), "missing `{needle}` in: {err}");
        }
        assert_untouched(&install, &before);
    }

    #[test]
    fn a_verified_archive_replaces_the_binary() {
        if !ready() {
            return;
        }
        let (release, _) = Release::good();
        let server = release.serve("v9.9.9");
        let install = Install::at("bin/fsp");
        let out = install.run(Some(&server), &[]);
        assert_eq!(
            out.status.code(),
            Some(0),
            "{}{}",
            stdout(&out),
            stderr(&out)
        );
        let text = stdout(&out);
        assert!(
            text.contains(&format!("\u{2713} fsp {CURRENT} \u{2192} {NEW}")),
            "{text}"
        );
        assert!(text.contains("bin/fsp"), "{text}");
        assert!(
            fs::read_to_string(&install.exe)
                .unwrap()
                .contains("fsp 9.9.9")
        );
        let mode = fs::metadata(&install.exe).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o755);
        assert_eq!(folder_entries(&install), ["fsp"]);
    }

    #[test]
    fn a_bad_hash_against_the_sidecar_is_refused() {
        if !ready() {
            return;
        }
        let (mut release, hash) = Release::good();
        let wrong = "1".repeat(64);
        release.sidecar = Some(format!("{wrong}  x\n"));
        refused(&release, &[&hash, &wrong, ".sha256"]);
    }

    #[test]
    fn a_bad_hash_against_the_pin_is_refused() {
        if !ready() {
            return;
        }
        let (mut release, hash) = Release::good();
        let wrong = "2".repeat(64);
        release.pins = Some(pins(NEW, &wrong));
        refused(&release, &[&hash, &wrong, "pinned"]);
    }

    #[test]
    fn pins_for_another_version_are_refused() {
        if !ready() {
            return;
        }
        let (mut release, hash) = Release::good();
        release.pins = Some(pins("0.14.0", &hash));
        refused(&release, &["0.14.0", NEW]);
    }

    #[test]
    fn missing_pins_are_refused_and_the_dev_switch_allows_them() {
        if !ready() {
            return;
        }
        let (mut release, _) = Release::good();
        release.pins = None;
        refused(&release, &["FSP_UPGRADE_ALLOW_UNPINNED=1"]);

        let server = release.serve("v9.9.9");
        let install = Install::at("bin/fsp");
        let out = install.run_with(Some(&server), &[], |c| {
            c.env("FSP_UPGRADE_ALLOW_UNPINNED", "1");
        });
        assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
        assert!(
            fs::read_to_string(&install.exe)
                .unwrap()
                .contains("fsp 9.9.9")
        );
    }

    #[test]
    fn a_binary_that_says_the_wrong_version_is_refused() {
        if !ready() {
            return;
        }
        // Hashes and pins agree on this archive, but its fsp claims another release.
        refused(
            &Release::vouched("fsp 1.2.3", NEW),
            &["fsp 1.2.3", "fsp 9.9.9"],
        );
    }

    #[test]
    fn an_archive_that_is_not_there_is_refused() {
        if !ready() {
            return;
        }
        // Only the pins exist: the archive is a 404.
        let server = Server::with_files(Some("v9.9.9"), vec![("/pins/x".into(), vec![1])]);
        let install = Install::at("bin/fsp");
        let before = fs::read(&install.exe).unwrap();
        let out = install.run(Some(&server), &[]);
        assert_eq!(out.status.code(), Some(1));
        assert!(
            stderr(&out).contains("could not download"),
            "{}",
            stderr(&out)
        );
        assert_untouched(&install, &before);
    }

    #[test]
    fn a_downgrade_says_so() {
        if !ready() {
            return;
        }
        let release = Release::vouched("fsp 0.0.1", "0.0.1");
        let server = release.serve("v99.0.0");
        let install = Install::at("bin/fsp");
        let out = install.run(Some(&server), &["--version", "0.0.1"]);
        assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
        let text = stdout(&out);
        assert!(text.contains("downgrade"), "{text}");
        assert!(
            fs::read_to_string(&install.exe)
                .unwrap()
                .contains("fsp 0.0.1")
        );
    }

    #[test]
    fn a_dry_run_downloads_and_changes_nothing() {
        if !ready() {
            return;
        }
        let (release, _) = Release::good();
        let server = release.serve("v9.9.9");
        let install = Install::at("bin/fsp");
        let before = fs::read(&install.exe).unwrap();
        let out = install.run(Some(&server), &["--dry-run"]);
        assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
        assert!(stdout(&out).contains("Would download"), "{}", stdout(&out));
        assert_untouched(&install, &before);
    }

    #[test]
    fn a_folder_that_cannot_be_written_is_refused_without_elevation() {
        if !ready() {
            return;
        }
        let (release, _) = Release::good();
        let server = release.serve("v9.9.9");
        let install = Install::at("bin/fsp");
        let dir = install.exe.parent().unwrap().to_path_buf();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o555)).unwrap();
        // root writes anywhere; the refusal can only be seen by someone who cannot.
        let probe = dir.join(".probe");
        let can_write = fs::write(&probe, b"").is_ok();
        let _ = fs::remove_file(&probe);
        let out = install.run(Some(&server), &[]);
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
        if can_write {
            eprintln!("skipped: this user can write to a read-only folder");
            return;
        }
        assert_eq!(out.status.code(), Some(1));
        let err = stderr(&out);
        assert!(
            err.contains("FSP_INSTALL_DIR") && err.contains("never uses sudo"),
            "{err}"
        );
    }
}
