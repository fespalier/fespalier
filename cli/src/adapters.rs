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
//! says, so an app with `main: manual` calls them from its own `main()` too. The output is a function of the pubspec alone: not of `.dart_tool/`, nor of
//! the pub cache, so `fsp check` gives the same bytes before and after `pub get`.
//!
//! The first package is the outermost: its zone and its wrapper go around the others'.

use serde::Serialize;

use crate::entry::MainHooks;

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
    hooks
}
