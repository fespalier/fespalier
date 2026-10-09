//! The feature table of `fsp create`: the one place that says what `--features x` adds to a new
//! app. The plan, `--list-features`, the CI matrix and the `--local-packages` overrides all read
//! this table, and the tests in `create_tests.rs` check it against `packages/` and the
//! companions' own pubspecs, so a package or a dependency cannot be forgotten.

/// A dependency that is not fespalier's: a version range, or a git commit (never a tag: a tag
/// `ref: v…` would be read as fespalier's own version by `cli/tests/versions.rs`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(
    dead_code,
    reason = "the recipes that use these land with the features; the plan and the tests already read them"
)]
pub enum Source {
    /// `name: "<range>"`. The range is third party: it is written outside any release-please
    /// annotation, and never holds fespalier's version.
    Range(&'static str),
    /// `git: {url, ref: <commit>}`, pinned by the full 40-digit commit.
    Git {
        url: &'static str,
        commit: &'static str,
    },
}

/// One third-party package a feature adds to `dependencies:`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ThirdParty {
    pub name: &'static str,
    pub source: Source,
}

/// What `--features <id>` adds.
#[derive(Debug, Clone, Copy)]
pub struct Recipe {
    /// What the user types: lower case, digits and `_`.
    pub id: &'static str,
    /// One line, for `--list-features`.
    pub description: &'static str,
    /// The `packages/<name>` companions it depends on, by git at fespalier's tag.
    pub companions: &'static [&'static str],
    /// Dependencies of other repositories.
    pub third_party: &'static [ThirdParty],
    /// The lowest Flutter it works on, `major.minor`.
    pub flutter_floor: &'static str,
    /// Lines of the `fespalier:` section of the pubspec, each as written under the key.
    pub config: &'static [&'static str],
    /// `(template, path)`: files it writes, the path relative to the app.
    pub files: &'static [(&'static str, &'static str)],
    /// Features it needs; they are added when not asked for.
    pub requires: &'static [&'static str],
    /// Features it cannot be combined with.
    pub conflicts: &'static [&'static str],
}

/// The features `fsp create` can add. Empty until the features land (one change per group).
pub const RECIPES: &[Recipe] = &[];

/// Every `packages/fespalier_*` (the Flutter packages of this repository, except the DevTools
/// extension's source) that is not a create feature, and why. A package that is neither a
/// recipe's companion nor here fails `create_tests::every_package_is_a_feature_or_has_a_reason`.
/// A feature that lands moves its package out of this list.
#[allow(
    dead_code,
    reason = "only the tests read it: it is the record of why a package is not a feature"
)]
pub const NOT_A_CREATE_FEATURE: &[(&str, &str)] = &[
    (
        "fespalier_adaptive",
        "not yet: it becomes the `adaptive` feature and `--template tabs` in a later release",
    ),
    (
        "fespalier_analytics",
        "needs a vendor SDK and its console setup (docs/adapters.md); the app brings its backend",
    ),
    (
        "fespalier_auth",
        "not yet: it becomes the `auth` feature in a later release",
    ),
    (
        "fespalier_biometrics",
        "needs `local_auth` and device setup, a compiled recipe in the skills, not a dependency",
    ),
    (
        "fespalier_connectivity",
        "not yet: it becomes the `connectivity` feature in a later release",
    ),
    (
        "fespalier_cratestack",
        "needs a generated CrateStack client that is specific to the app, so there is nothing to scaffold",
    ),
    (
        "fespalier_dio",
        "waits for the planned fespalier_http package, which the `http` feature will use",
    ),
    (
        "fespalier_flags",
        "not yet: it becomes the `flags` feature in a later release",
    ),
    (
        "fespalier_forms",
        "not yet: it becomes the `forms` feature in a later release",
    ),
    (
        "fespalier_frb",
        "needs a Rust core and flutter_rust_bridge, which are the app's own",
    ),
    (
        "fespalier_http",
        "the `http` feature lands once fespalier_http has DioHttpClient and its docs",
    ),
    (
        "fespalier_image",
        "not yet: it becomes the `image` feature in a later release",
    ),
    (
        "fespalier_maps",
        "needs a tile source, a style and platform setup, which are the app's own",
    ),
    (
        "fespalier_otel",
        "not yet: it becomes the `otel` feature in a later release",
    ),
    (
        "fespalier_push",
        "needs a vendor SDK and device setup (docs/adapters.md); the app brings its source",
    ),
    (
        "fespalier_riverpod",
        "nothing to scaffold: it adds providers per page instance, used where a page needs them",
    ),
    (
        "fespalier_sentry",
        "not yet: it becomes the `sentry` feature in a later release",
    ),
    (
        "fespalier_sign_keypair",
        "needs Flutter 3.44 and a git dependency of another repository",
    ),
    (
        "fespalier_storage",
        "not yet: it becomes the `storage` feature in a later release",
    ),
    (
        "fespalier_tolgee",
        "not yet: it becomes the `i18n` feature in a later release",
    ),
];

/// The `fespalier_*` packages each companion depends on in its `dependencies:` (not
/// `dev_dependencies:`), besides `fespalier` itself. `--local-packages` overrides all of them: an
/// app resolves a companion's own git dependency on the others at the checkout only when each
/// is overridden. `create_tests` compares this table with the pubspecs.
pub const COMPANION_DEPS: &[(&str, &[&str])] = &[
    ("fespalier_auth", &["fespalier_http"]),
    ("fespalier_cratestack", &["fespalier_dio"]),
    ("fespalier_dio", &["fespalier_http"]),
    ("fespalier_sign_keypair", &["fespalier_auth"]),
];

/// The companions `names` need at the checkout: themselves and everything they depend on, sorted.
#[must_use]
pub fn companion_closure(names: &[&str]) -> Vec<String> {
    let mut all: Vec<String> = vec![];
    let mut stack: Vec<&str> = names.to_vec();
    while let Some(name) = stack.pop() {
        if all.iter().any(|n| n == name) {
            continue;
        }
        all.push(name.to_string());
        if let Some((_, deps)) = COMPANION_DEPS.iter().find(|(n, _)| *n == name) {
            stack.extend(deps.iter().copied());
        }
    }
    all.sort();
    all
}
