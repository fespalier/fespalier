//! `fespalier: otel: true` (since 0.19.0): the generated `main()` starts `otel_zone` and installs
//! `FespalierOtel`, so the app writes no OpenTelemetry wiring of its own.
//!
//! ```yaml
//! dependencies:
//!   fespalier_otel: ...   # next to fespalier, at the same git ref
//!   otel_zone: ...        # a git dependency pinned to a commit, 8a72fc4 (the rc.4 line) or later
//! fespalier:
//!   telemetry: true
//!   otel: true
//! ```
//!
//! It is not an adapter. Every `otel_zone` call takes an `OtelZone`, which `fespalier_otel` cannot
//! name without a dependency on `otel_zone`, so the wiring is written here, into `app.main.g.dart`
//! (`app.g.dart` is the same as without the key). The output depends on the pubspec alone: the
//! service name is the pubspec's `name`, and the version is read at run time (`FLUTTER_BUILD_NAME`),
//! never written, so a version bump does not change the file.
//!
//! The zone is `otel_zone`'s `runGuarded`, off the web (it never runs its body there), and only when
//! startup.dart exports no `zone()`: an app's own zone (Sentry's) wins. It is the innermost
//! wrapper, inside the adapters' zones (`adapters.rs`).

use crate::config::Config;
use crate::entry::MainHooks;

/// The hooks `otel: true` adds to the generated `main()` (see [`MainHooks`]): nothing without the
/// key, so an app that does not use it gets the file it had.
pub fn hooks(cfg: &Config) -> MainHooks {
    let mut hooks = MainHooks::default();
    if !cfg.otel {
        return hooks;
    }
    hooks.otel = Some(cfg.package.clone().unwrap_or_else(|| "app".into()));
    hooks.weak_wrapper = Some("_otelZone".into());
    // Both are null when the SDK never came up, so an `if` case drops them.
    hooks
        .provider_observers
        .push("[if (AppMain.observability.riverpodObserver() case final o?) o]".into());
    hooks
        .router_observers
        .push("[if (AppMain.observability.routeObserver() case final o?) o]".into());
    hooks
}
