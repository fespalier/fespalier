//! What `fsp upgrade` decides, with no I/O: the install method from a path, the version out of a
//! redirect, the version order, and the action for a method and the flags.

use crate::upgrade::{
    Action, Env, Method, Version, detect, plan, script_command, version_from_release_url,
};

fn v(major: u64, minor: u64, patch: u64) -> Version {
    Version(major, minor, patch)
}

fn env() -> Env {
    Env {
        home: Some("/home/ann".into()),
        cargo_home: None,
        scoop: None,
    }
}

// --- Detection -------------------------------------------------------------------------------

#[test]
fn dart_run_cache_is_read_on_both_separators() {
    let unix = "/home/ann/.cache/fespalier/0.14.0-x86_64-unknown-linux-gnu/fsp";
    assert_eq!(detect(unix, &env()), Method::DartRun("0.14.0".into()));
    let win = r"C:\Users\ann\AppData\Local\fespalier\0.14.0-x86_64-pc-windows-msvc\fsp.exe";
    assert_eq!(detect(win, &env()), Method::DartRun("0.14.0".into()));
    let verbatim =
        r"\\?\C:\Users\ann\AppData\Local\fespalier\0.14.0-x86_64-pc-windows-msvc\fsp.exe";
    assert_eq!(detect(verbatim, &env()), Method::DartRun("0.14.0".into()));
}

#[test]
fn a_folder_that_only_looks_like_the_cache_is_not_it() {
    // No version before the dash, a tag with a `v`, or another grandparent.
    for path in [
        "/home/ann/.cache/fespalier/latest-x86_64/fsp",
        "/home/ann/.cache/fespalier/v0.14.0-x86_64/fsp",
        "/home/ann/.cache/other/0.14.0-x86_64/fsp",
    ] {
        assert_eq!(detect(path, &env()), Method::Script, "{path}");
    }
}

#[test]
fn a_cargo_build_of_the_source_tree() {
    assert_eq!(
        detect("/work/fespalier/cli/target/debug/fsp", &env()),
        Method::Source
    );
    assert_eq!(
        detect("/work/fespalier/cli/target/release/fsp", &env()),
        Method::Source
    );
    assert_eq!(
        detect(r"C:\work\fespalier\cli\target\debug\fsp.exe", &env()),
        Method::Source
    );
    // A folder called target is not a build.
    assert_eq!(detect("/opt/target/bin/fsp", &env()), Method::Script);
}

#[test]
fn homebrew_is_the_cellar() {
    assert_eq!(
        detect("/opt/homebrew/Cellar/fsp/0.14.0/bin/fsp", &env()),
        Method::Homebrew
    );
    assert_eq!(
        detect(
            "/home/linuxbrew/.linuxbrew/Cellar/fsp/0.14.0/bin/fsp",
            &env()
        ),
        Method::Homebrew
    );
    // Another formula's Cellar is not ours.
    assert_eq!(
        detect("/opt/homebrew/Cellar/fspx/1.0/bin/fsp", &env()),
        Method::Script
    );
}

#[test]
fn scoop_is_apps_fsp_under_scoop_or_the_scoop_variable() {
    let win = r"C:\Users\ann\scoop\apps\fsp\0.14.0\fsp.exe";
    assert_eq!(detect(win, &env()), Method::Scoop);
    assert_eq!(
        detect(r"C:\Users\ann\SCOOP\Apps\fsp\current\fsp.exe", &env()),
        Method::Scoop
    );
    assert_eq!(
        detect("/c/Users/ann/scoop/apps/fsp/current/fsp.exe", &env()),
        Method::Scoop
    );
    // A relocated Scoop root, named by $SCOOP.
    let moved = Env {
        scoop: Some(r"D:\tools".into()),
        ..env()
    };
    assert_eq!(
        detect(r"D:\tools\apps\fsp\0.14.0\fsp.exe", &moved),
        Method::Scoop
    );
    assert_eq!(
        detect(r"D:\tools\apps\other\fsp.exe", &moved),
        Method::Script
    );
}

#[test]
fn cargo_is_bin_under_cargo_home() {
    assert_eq!(detect("/home/ann/.cargo/bin/fsp", &env()), Method::Cargo);
    assert_eq!(
        detect(
            r"C:\Users\ann\.cargo\bin\fsp.exe",
            &Env {
                home: Some(r"C:\Users\ann".into()),
                ..env()
            }
        ),
        Method::Cargo
    );
    let custom = Env {
        cargo_home: Some("/opt/cargo".into()),
        ..env()
    };
    assert_eq!(detect("/opt/cargo/bin/fsp", &custom), Method::Cargo);
    // With CARGO_HOME set, the default is not the home.
    assert_eq!(detect("/home/ann/.cargo/bin/fsp", &custom), Method::Script);
    // Only bin/ is cargo's: a file next to it is not.
    assert_eq!(
        detect("/home/ann/.cargo/registry/fsp", &env()),
        Method::Script
    );
}

#[test]
fn everything_else_is_a_script_install() {
    assert_eq!(detect("/home/ann/.local/bin/fsp", &env()), Method::Script);
    assert_eq!(
        detect(r"C:\Users\ann\AppData\Local\fespalier\bin\fsp.exe", &env()),
        Method::Script
    );
    assert_eq!(
        detect("/usr/local/bin/fsp", &Env::default()),
        Method::Script
    );
}

#[test]
fn the_first_rule_wins() {
    // The cache wins over a source tree that happens to hold a `target/debug`.
    let both = "/work/target/debug/fespalier/0.14.0-x86_64/fsp";
    assert_eq!(detect(both, &env()), Method::DartRun("0.14.0".into()));
}

// --- Versions --------------------------------------------------------------------------------

#[test]
fn versions_parse_and_order_as_numbers() {
    assert_eq!(Version::parse("v0.15.0"), Some(v(0, 15, 0)));
    assert_eq!(Version::parse("0.15.0"), Some(v(0, 15, 0)));
    assert_eq!(Version::parse(" v1.2.3\n"), Some(v(1, 2, 3)));
    for bad in [
        "",
        "v",
        "1.2",
        "1.2.3.4",
        "1.2.x",
        "v1.2.3-rc.1",
        "1..3",
        "-1.2.3",
        "latest",
    ] {
        assert_eq!(Version::parse(bad), None, "{bad:?}");
    }
    assert!(v(0, 15, 0) > v(0, 14, 9));
    assert!(
        v(0, 10, 0) > v(0, 9, 0),
        "10 is more than 9, not less as text"
    );
    assert!(v(1, 0, 0) > v(0, 99, 99));
    assert_eq!(v(0, 15, 0).to_string(), "0.15.0");
    assert_eq!(v(0, 15, 0).tag(), "v0.15.0");
}

#[test]
fn the_release_redirect_is_read_for_its_tag() {
    let ok = |url: &str| version_from_release_url(url).unwrap();
    assert_eq!(
        ok("https://github.com/fespalier/fespalier/releases/tag/v0.15.0"),
        v(0, 15, 0)
    );
    assert_eq!(
        ok("https://github.com/fespalier/fespalier/releases/tag/v0.15.0\n"),
        v(0, 15, 0)
    );
    assert_eq!(
        ok("http://127.0.0.1:9/releases/tag/v1.2.3?x=1#y"),
        v(1, 2, 3)
    );
    assert_eq!(ok("https://h/o/r/releases/tag/v1.2.3/"), v(1, 2, 3));
    // No release yet: /releases/latest ends at /releases.
    let none = version_from_release_url("https://github.com/fespalier/fespalier/releases");
    assert!(none.unwrap_err().to_string().contains("no release"));
    let odd = version_from_release_url("https://h/releases/tag/nightly").unwrap_err();
    assert!(odd.to_string().contains("nightly"));
    assert!(version_from_release_url("").is_err());
}

// --- The decision table ----------------------------------------------------------------------

fn decide(method: &Method, current: Version, target: Version, explicit: bool) -> Action {
    plan(
        method,
        current,
        target,
        explicit,
        "/home/ann/.local/bin",
        false,
    )
    .action
}

#[test]
fn an_install_that_cannot_be_upgraded_from_here_is_refused_even_when_current() {
    let now = v(0, 14, 0);
    for method in [Method::DartRun("0.14.0".into()), Method::Source] {
        for target in [v(0, 14, 0), v(0, 15, 0)] {
            let plan = plan(&method, now, target, false, "/d", false);
            assert!(matches!(plan.action, Action::Refuse(_)), "{method:?}");
            assert_eq!(plan.command, None);
        }
    }
    let Action::Refuse(text) = decide(&Method::DartRun("0.14.0".into()), now, v(0, 15, 0), false)
    else {
        panic!("refused")
    };
    assert!(text.contains("dart run fespalier"), "{text}");
    assert!(text.contains("0.14.0"), "{text}");
    assert!(text.contains("ref:"), "{text}");
}

#[test]
fn up_to_date_or_ahead_does_nothing() {
    for method in [
        Method::Homebrew,
        Method::Scoop,
        Method::Cargo,
        Method::Script,
    ] {
        assert_eq!(
            decide(&method, v(0, 15, 0), v(0, 15, 0), false),
            Action::UpToDate
        );
        assert_eq!(
            decide(&method, v(0, 16, 0), v(0, 15, 0), false),
            Action::UpToDate
        );
    }
    // An explicit tag is a request for exactly that: ahead of it is a downgrade, not "current".
    assert_eq!(
        decide(&Method::Script, v(0, 15, 0), v(0, 15, 0), true),
        Action::UpToDate
    );
    assert_eq!(
        decide(&Method::Script, v(0, 16, 0), v(0, 15, 0), true),
        Action::Script
    );
}

#[test]
fn a_newer_release_follows_the_method() {
    let (now, next) = (v(0, 14, 0), v(0, 15, 0));
    assert_eq!(decide(&Method::Homebrew, now, next, false), Action::Brew);
    assert_eq!(
        decide(&Method::Scoop, now, next, false),
        Action::Print(vec!["scoop update".into(), "scoop update fsp".into()])
    );
    assert_eq!(
        decide(&Method::Cargo, now, next, false),
        Action::Print(vec![
            "cargo install --git https://github.com/fespalier/fespalier --tag v0.15.0 --locked \
             fespalier"
                .into()
        ])
    );
    assert_eq!(decide(&Method::Script, now, next, false), Action::Script);
}

#[test]
fn an_explicit_version_is_for_script_installs_and_cargo_only() {
    let (now, other) = (v(0, 14, 0), v(0, 13, 0));
    for method in [Method::Homebrew, Method::Scoop] {
        let Action::Refuse(text) = decide(&method, now, other, true) else {
            panic!("refused")
        };
        assert!(text.contains("FSP_VERSION=v0.13.0"), "{text}");
    }
    assert_eq!(decide(&Method::Script, now, other, true), Action::Script);
    // The tag is in cargo's own command.
    assert!(matches!(
        decide(&Method::Cargo, now, other, true),
        Action::Print(_)
    ));
}

#[test]
fn the_json_command_names_the_target() {
    let p = plan(
        &Method::Homebrew,
        v(0, 14, 0),
        v(0, 15, 0),
        false,
        "/d",
        false,
    );
    assert_eq!(p.command.as_deref(), Some("brew upgrade fespalier/tap/fsp"));
    let p = plan(
        &Method::Script,
        v(0, 14, 0),
        v(0, 15, 0),
        false,
        "/home/ann/bin",
        false,
    );
    let command = p.command.unwrap();
    assert!(command.contains("FSP_VERSION=v0.15.0"), "{command}");
    assert!(
        command.contains("FSP_INSTALL_DIR='/home/ann/bin'"),
        "{command}"
    );
    let windows = script_command(v(0, 15, 0), r"C:\bin", true);
    assert!(
        windows.starts_with("$env:FSP_VERSION='v0.15.0'"),
        "{windows}"
    );
    assert!(windows.ends_with("install.ps1 | iex"), "{windows}");
}

// --- Replacing in place: names, pins, verification -------------------------------------------

mod replace {
    use crate::upgrade::Version;
    use crate::upgrade_replace::{
        Pins, archive_name, binary_name, not_writable_message, parse_pins, parse_sidecar,
        target_for, verify, version_banner_ok,
    };

    /// A copy of the generated `release_checksums.dart` of 0.14.0 (the real file's format).
    const REAL: &str = include_str!("../tests/fixtures/release_checksums.dart");
    const LINUX: &str = "x86_64-unknown-linux-gnu";
    const HASH: &str = "9cb6ef7f8ad8045743eef9b3dd3355348f761f22da2a2976372867296d18bf06";
    const OTHER: &str = "0000000000000000000000000000000000000000000000000000000000000001";

    fn v(major: u64, minor: u64, patch: u64) -> Version {
        Version(major, minor, patch)
    }

    fn pins() -> Pins {
        parse_pins(REAL).unwrap()
    }

    #[test]
    fn the_real_pins_file_is_read() {
        let pins = pins();
        assert_eq!(pins.version, "0.14.0");
        assert_eq!(pins.checksums.len(), 5);
        assert_eq!(pins.get(LINUX), Some(HASH));
        assert_eq!(
            pins.get("x86_64-pc-windows-msvc"),
            Some("48b0144d086252bcdbc10d53a385f0fb6a3cd7107eb4a5aa42ddb24faa1f767e")
        );
        assert_eq!(pins.get("riscv64-unknown-linux-gnu"), None);
    }

    #[test]
    fn a_file_without_pins_is_read_as_empty_or_not_at_all() {
        let empty = "// header with `''` in a comment\nconst pinnedVersion = '';\n\
                     const pinnedChecksums = <String, String>{};\n";
        let pins = parse_pins(empty).unwrap();
        assert_eq!(pins.version, "");
        assert!(pins.checksums.is_empty());
        assert_eq!(parse_pins("<html>404</html>"), None);
        assert_eq!(parse_pins(""), None);
    }

    #[test]
    fn a_sidecar_is_its_first_word() {
        assert_eq!(
            parse_sidecar(&format!("{HASH}  fsp-x.tar.gz\n")),
            Some(HASH.into())
        );
        assert_eq!(
            parse_sidecar(&format!("{}\n", HASH.to_uppercase())),
            Some(HASH.into())
        );
        assert_eq!(parse_sidecar("not a hash"), None);
        assert_eq!(parse_sidecar(""), None);
    }

    #[test]
    fn archives_and_binaries_are_named_per_target() {
        assert_eq!(archive_name(LINUX), "fsp-x86_64-unknown-linux-gnu.tar.gz");
        assert_eq!(
            archive_name("aarch64-apple-darwin"),
            "fsp-aarch64-apple-darwin.tar.gz"
        );
        assert_eq!(
            archive_name("x86_64-pc-windows-msvc"),
            "fsp-x86_64-pc-windows-msvc.zip"
        );
        assert_eq!(binary_name(LINUX), "fsp");
        assert_eq!(binary_name("x86_64-pc-windows-msvc"), "fsp.exe");
    }

    #[test]
    fn the_host_maps_to_the_five_release_targets() {
        assert_eq!(target_for("linux", "x86_64"), Some(LINUX));
        assert_eq!(
            target_for("linux", "aarch64"),
            Some("aarch64-unknown-linux-gnu")
        );
        assert_eq!(target_for("macos", "x86_64"), Some("x86_64-apple-darwin"));
        assert_eq!(target_for("macos", "aarch64"), Some("aarch64-apple-darwin"));
        assert_eq!(
            target_for("windows", "x86_64"),
            Some("x86_64-pc-windows-msvc")
        );
        assert_eq!(
            target_for("windows", "aarch64"),
            Some("x86_64-pc-windows-msvc")
        );
        assert_eq!(target_for("linux", "riscv64"), None);
        assert_eq!(target_for("freebsd", "x86_64"), None);
    }

    fn check(sidecar: &str, pins: Option<&Pins>, allow: bool) -> Result<(), String> {
        verify(HASH, sidecar, pins, LINUX, v(0, 14, 0), allow)
    }

    #[test]
    fn a_download_that_both_sources_vouch_for_is_accepted() {
        assert_eq!(check(&format!("{HASH}  a\n"), Some(&pins()), false), Ok(()));
    }

    #[test]
    fn a_mismatch_with_the_sidecar_names_both_values() {
        let err = check(&format!("{OTHER}  a\n"), Some(&pins()), false).unwrap_err();
        assert!(
            err.contains(HASH) && err.contains(OTHER) && err.contains(".sha256"),
            "{err}"
        );
        // Even the dev escape hatch does not excuse a wrong hash.
        assert!(check(OTHER, Some(&pins()), true).is_err());
        assert!(
            check("garbage", Some(&pins()), true)
                .unwrap_err()
                .contains("SHA-256")
        );
    }

    #[test]
    fn a_mismatch_with_the_pin_names_both_values() {
        let mut changed = pins();
        changed.checksums[4].1 = OTHER.to_string();
        let err = check(HASH, Some(&changed), false).unwrap_err();
        assert!(
            err.contains(HASH) && err.contains(OTHER) && err.contains("pinned"),
            "{err}"
        );
        assert!(check(HASH, Some(&changed), true).is_err());
    }

    #[test]
    fn pins_of_another_version_are_refused_unless_staged() {
        let err = verify(HASH, HASH, Some(&pins()), LINUX, v(0, 15, 0), false).unwrap_err();
        assert!(err.contains("0.14.0") && err.contains("0.15.0"), "{err}");
        assert_eq!(
            verify(HASH, HASH, Some(&pins()), LINUX, v(0, 15, 0), true),
            Ok(())
        );
    }

    #[test]
    fn missing_pins_are_refused_unless_staged() {
        let blank = Pins {
            version: String::new(),
            checksums: vec![],
        };
        for pins in [None, Some(&blank)] {
            let err = check(HASH, pins, false).unwrap_err();
            assert!(err.contains("FSP_UPGRADE_ALLOW_UNPINNED=1"), "{err}");
            assert_eq!(check(HASH, pins, true), Ok(()));
        }
    }

    #[test]
    fn a_target_the_pins_lack_is_refused_even_when_staged() {
        let mut no_linux = pins();
        no_linux.checksums.retain(|(t, _)| t != LINUX);
        let err = check(HASH, Some(&no_linux), true).unwrap_err();
        assert!(err.contains(LINUX), "{err}");
    }

    #[test]
    fn the_new_binary_must_say_which_release_it_is() {
        assert!(version_banner_ok("fsp 0.15.0\n", v(0, 15, 0)));
        assert!(!version_banner_ok("fsp 0.14.0\n", v(0, 15, 0)));
        assert!(!version_banner_ok("fsp 0.15.0-rc1\n", v(0, 15, 0)));
        assert!(!version_banner_ok("", v(0, 15, 0)));
    }

    #[test]
    fn an_unwritable_folder_names_the_install_script() {
        let unix = not_writable_message("/usr/local/bin", false);
        assert!(unix.contains("/usr/local/bin") && unix.contains("FSP_INSTALL_DIR="));
        assert!(unix.contains("never uses sudo"), "{unix}");
        let win = not_writable_message(r"C:\Tools", true);
        assert!(win.contains("install.ps1") && win.contains("FSP_INSTALL_DIR"));
    }
}
