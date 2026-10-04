//! `fespalier: adapters:` (since 0.9.0): packages that plug into the generated `main()`.
//!
//! ```yaml
//! fespalier:
//!   adapters: [fespalier_sentry, fespalier_connectivity]   # Dart package names, in order
//! ```
//!
//! The generator needs no table and no manifest: a package named `n` always ships
//! `package:n/fespalier_adapter.dart`, with a top-level `adapter`, a `FespalierAdapter` (see
//! `packages/fespalier/lib/src/adapter.dart`). Its six members have a no-op default, so the
//! generated `main()` calls all of them the same way for every package, and the Dart compiler
//! checks the shapes. The output is a function of the pubspec alone: not of `.dart_tool/`, nor of
//! the pub cache, so `fsp check` gives the same bytes before and after `pub get`.
//!
//! The first package is the outermost: its zone and its wrapper go around the others'.

use crate::entry::MainHooks;

/// What `adapters` add to the generated `main()`, as [`MainHooks`] fields: for package `n` at
/// index `i`, the library is imported as `_a{i}` and the calls are on `_a{i}.adapter`.
pub fn hooks(adapters: &[String]) -> MainHooks {
    let mut hooks = MainHooks::default();
    for (i, name) in adapters.iter().enumerate() {
        let a = format!("_a{i}");
        hooks.imports.push(format!(
            "import 'package:{name}/fespalier_adapter.dart' as {a};"
        ));
        hooks.wrappers.push(format!("{a}.adapter.zone"));
        hooks.before_run.push(format!(
            "if ({a}.adapter.beforeRun() case final ready?) await ready;"
        ));
        hooks
            .provider_observers
            .push(format!("{a}.adapter.providerObservers()"));
        hooks.overrides.push(format!("{a}.adapter.overrides()"));
        hooks
            .router_observers
            .push(format!("{a}.adapter.routerObservers()"));
        hooks.root_wrappers.push(format!("{a}.adapter.wrap"));
    }
    hooks
}
