//! `fespalier: adapters:` (since 0.9.0): packages that plug into the generated `main()`.
//!
//! ```yaml
//! fespalier:
//!   adapters: [fespalier_sentry, fespalier_connectivity]   # Dart package names, in order
//! ```
//!
//! The generator needs no table and no manifest: a package named `n` always ships
//! `package:n/fespalier_adapter.dart`, with a top-level `adapter`, a `FespalierAdapter` (see
//! `packages/fespalier/lib/src/adapter.dart`). Its members have a no-op default, so the
//! generated `main()` calls all of them the same way for every package, and the Dart compiler
//! checks the shapes. Since 0.11.0 `app.g.dart` imports them as `AppAdapters`, whatever `main:`
//! says, so an app with `main: manual` calls them from its own `main()` too. The output is a
//! function of the pubspec alone: not of `.dart_tool/`, nor of the pub cache, so `fsp check`
//! gives the same bytes before and after `pub get`.
//!
//! The first package is the outermost: its zone and its wrapper go around the others'.
//!
//! `adapters: auto` (since 0.23.0) takes the first-party adapter packages ([`FIRST_PARTY`]) that are
//! under `dependencies:`, in that order. It is opt-in: every first-party adapter needs a `configure`
//! call in `main()`, and one that is unconfigured reports a `FlutterError`, so turning one on for an
//! app that depends on its package for something else (`fespalier_download` for `fespalier_maps`'
//! file packs, or for a `startup.dart` override) would add an error to that app. A package of the
//! app's own is never taken: `fsp` reads no package to find its `fespalier_adapter.dart`.

use serde::Serialize;

use crate::entry::MainHooks;

/// A first-party package that ships `lib/fespalier_adapter.dart` (since 0.23.0).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FirstParty {
    /// The package: `fespalier_push`.
    pub name: &'static str,
    /// The class whose `configure` the app calls in `main()` before `AppMain.run()` (docs/adapters.md,
    /// "Adapters that need your code"): `FespalierPush`.
    pub configure: &'static str,
}

/// Every first-party package that ships `lib/fespalier_adapter.dart`, what `adapters: auto` takes
/// and what `fsp doctor` looks for. `entry_tests::first_party_adapters_are_the_packages_that_ship_one`
/// compares it with `packages/*/lib/fespalier_adapter.dart`.
pub const FIRST_PARTY: [FirstParty; 4] = [
    FirstParty {
        name: "fespalier_analytics",
        configure: "FespalierAnalytics",
    },
    FirstParty {
        name: "fespalier_download",
        configure: "FespalierDownload",
    },
    FirstParty {
        name: "fespalier_launch",
        configure: "FespalierLaunch",
    },
    FirstParty {
        name: "fespalier_push",
        configure: "FespalierPush",
    },
];

/// The first-party adapter package called `name`, if it is one.
#[must_use]
pub fn first_party(name: &str) -> Option<FirstParty> {
    FIRST_PARTY.iter().copied().find(|a| a.name == name)
}

/// Whether `name` is a first-party adapter package.
#[must_use]
pub fn is_first_party(name: &str) -> bool {
    first_party(name).is_some()
}

/// What `app.g.dart` needs for `AppAdapters` (since 0.11.0): the adapters' libraries, in order.
#[derive(Debug, Serialize)]
pub struct AdaptersCx {
    pub imports: Vec<AdapterImport>,
}

/// One adapter package: `import 'package:{name}/fespalier_adapter.dart' as {alias};`.
#[derive(Debug, Serialize)]
pub struct AdapterImport {
    pub name: String,
    /// `_a0`: its index in the pubspec's list.
    pub alias: String,
}

/// The `AppAdapters` of `app.g.dart`, or `None` for an app with no adapters (its output is then
/// what it was before they existed).
pub fn cx(adapters: &[String]) -> Option<AdaptersCx> {
    (!adapters.is_empty()).then(|| AdaptersCx {
        imports: adapters
            .iter()
            .enumerate()
            .map(|(i, name)| AdapterImport {
                name: name.clone(),
                alias: format!("_a{i}"),
            })
            .collect(),
    })
}

/// What `adapters` add to the generated `main()`, as [`MainHooks`] fields. Each is a call on
/// `AppAdapters`, which `app.g.dart` imports the adapters for (since 0.11.0; before, `main()`
/// imported them itself): the generated `main()` and a `main: manual` app's own `main()` make
/// the same calls.
pub fn hooks(adapters: &[String]) -> MainHooks {
    let mut hooks = MainHooks::default();
    if adapters.is_empty() {
        return hooks;
    }
    hooks.wrappers.push("AppAdapters.zone".into());
    hooks
        .before_run
        .push("if (AppAdapters.beforeRun() case final ready?) await ready;".into());
    hooks
        .provider_observers
        .push("AppAdapters.providerObservers()".into());
    hooks.overrides.push("AppAdapters.overrides()".into());
    hooks
        .router_observers
        .push("AppAdapters.routerObservers()".into());
    hooks.root_wrappers.push("AppAdapters.wrap".into());
    hooks.attach = true;
    hooks.launch = true;
    hooks
}
