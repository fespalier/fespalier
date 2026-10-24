//! Tests of `pins.rs`: where a pubspec takes fespalier and its companions from.

use std::fs;
use std::path::Path;

use serde_yaml_ng::Value;

use crate::pins::{self, Origin, Pin, is_ours, is_package};

fn yaml(text: &str) -> Value {
    serde_yaml_ng::from_str(text).unwrap()
}

const GIT: &str = "dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.21.0
  fespalier_http:
    git: {url: https://github.com/fespalier/fespalier.git/, path: packages/fespalier_http, ref: v0.21.0}
  fespalier_mine:
    path: ../mine
  http: ^1.5.0
dev_dependencies:
  fespalier_forms:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_forms
      ref: v0.20.0
dependency_overrides:
  fespalier_transport:
    path: ../fespalier/packages/fespalier_transport
";

#[test]
fn it_reads_each_package_of_this_repository_and_where_it_comes_from() {
    let pins = pins::read(&yaml(GIT)).unwrap();
    let git = |reference: &str, url: &str| Origin::Git {
        url: url.to_string(),
        reference: reference.to_string(),
    };
    assert_eq!(
        pins.fespalier,
        git("v0.21.0", "https://github.com/fespalier/fespalier")
    );
    let names: Vec<(&str, &str)> = pins
        .all
        .iter()
        .map(|p| (p.name.as_str(), p.section))
        .collect();
    // `fespalier_mine` is no package of this repository, and `http` is a third party's.
    assert_eq!(
        names,
        [
            ("fespalier", "dependencies"),
            ("fespalier_http", "dependencies"),
            ("fespalier_forms", "dev_dependencies"),
            ("fespalier_transport", "dependency_overrides"),
        ]
    );
    assert_eq!(
        pins.all[3].origin,
        Origin::Path {
            root: "../fespalier/packages".to_string()
        }
    );
    // A URL with `.git` and a slash is the same repository; another ref is not the same pin.
    assert!(pins.all[1].origin.same_as(&pins.fespalier));
    assert_eq!(
        pins.out_of_line(),
        ["fespalier_forms (dev_dependencies): https://github.com/fespalier/fespalier at v0.20.0"]
    );
    assert!(pins.has("dev_dependencies", "fespalier_forms"));
    assert!(!pins.has("dependencies", "fespalier_forms"));
}

/// A package of this repository that this `fsp` does not know (one newer than it) is told by
/// where it comes from: a git dependency on its folder of the repository fespalier comes from. A
/// `fespalier_*` package of someone else's is not one (since 0.23.1).
#[test]
fn a_package_newer_than_this_fsp_is_told_by_where_it_comes_from() {
    let text = "dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.21.0
  fespalier_next:
    git:
      url: https://github.com/fespalier/fespalier.git
      path: packages/fespalier_next/
      ref: v0.20.0
  fespalier_extras: ^1.0.0
  fespalier_fork:
    git:
      url: https://github.com/someone/else
      path: packages/fespalier_fork
      ref: v0.21.0
  fespalier_root:
    git:
      url: https://github.com/fespalier/fespalier
      ref: v0.21.0
  fespalier_moved:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_next
      ref: v0.21.0
";
    let value = yaml(text);
    let pins = pins::read(&value).unwrap();
    let names: Vec<&str> = pins.all.iter().map(|p| p.name.as_str()).collect();
    assert_eq!(names, ["fespalier", "fespalier_next"]);
    assert_eq!(
        pins.out_of_line(),
        ["fespalier_next (dependencies): https://github.com/fespalier/fespalier.git at v0.20.0"]
    );
    let own = value["dependencies"].get("fespalier");
    let entry = |name: &str| &value["dependencies"][name];
    assert!(is_ours("fespalier_next", entry("fespalier_next"), own));
    for name in [
        "fespalier_extras",
        "fespalier_fork",
        "fespalier_root",
        "fespalier_moved",
    ] {
        assert!(!is_ours(name, entry(name), own), "{name}");
    }
    // Without fespalier's own entry, only the packages fsp knows count.
    assert!(!is_ours("fespalier_next", entry("fespalier_next"), None));
    assert!(is_ours("fespalier_http", &yaml("^1.0.0"), None));
}

#[test]
fn a_checkout_is_a_folder_named_after_each_package() {
    let pins = pins::read(&yaml(
        "dependencies:\n  fespalier:\n    path: ../../packages/fespalier\n  fespalier_push:\n    path: ../../packages/fespalier_push/\n  fespalier_launch:\n    path: ../launch\n",
    ))
    .unwrap();
    let root = Origin::Path {
        root: "../../packages".to_string(),
    };
    assert_eq!(pins.fespalier, root);
    assert_eq!(pins.all[1].origin, root);
    assert_eq!(
        pins.all[2],
        Pin {
            name: "fespalier_launch".to_string(),
            section: "dependencies",
            origin: Origin::Other("path ../launch".to_string()),
        }
    );
    assert_eq!(
        pins.out_of_line(),
        ["fespalier_launch (dependencies): path ../launch"]
    );
    assert_eq!(
        root.lines("fespalier_http"),
        ["path: ../../packages/fespalier_http"]
    );
}

#[test]
fn it_refuses_a_pubspec_without_fespalier_or_with_one_it_does_not_read() {
    let none = pins::read(&yaml("dependencies:\n  http: ^1.0.0\n")).unwrap_err();
    assert!(none.contains("does not list fespalier"), "{none}");
    let hosted = pins::read(&yaml("dependencies:\n  fespalier: ^0.22.0\n")).unwrap_err();
    assert!(
        hosted.contains("fespalier comes from version ^0.22.0"),
        "{hosted}"
    );
    let no_ref = pins::read(&yaml(
        "dependencies:\n  fespalier:\n    git:\n      url: https://x/y\n      path: packages/fespalier\n",
    ))
    .unwrap_err();
    assert!(no_ref.contains("with no ref:"), "{no_ref}");
}

#[test]
fn the_lines_of_a_git_pin_are_what_fsp_create_writes() {
    let origin = Origin::Git {
        url: "https://github.com/fespalier/fespalier".to_string(),
        reference: "v1.2.3".to_string(),
    };
    assert_eq!(
        origin.lines("fespalier_forms"),
        [
            "git:",
            "  url: https://github.com/fespalier/fespalier",
            "  path: packages/fespalier_forms",
            "  ref: v1.2.3",
        ]
    );
}

/// Every package in `packages/` is one fsp knows (the DevTools extension's source is an app).
#[test]
fn every_package_of_the_repository_is_known() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../packages");
    let mut seen = 0;
    for entry in fs::read_dir(dir).unwrap() {
        let name = entry.unwrap().file_name().into_string().unwrap();
        if name == "fespalier_devtools" {
            continue;
        }
        assert!(is_package(&name), "{name}");
        seen += 1;
    }
    assert!(seen >= 20, "{seen}");
    assert!(!is_package("fespalier_devtools"));
    assert!(!is_package("http"));
}
