//! The generated entry point (since 0.8.1): `lib/app.main.g.dart`, class `AppMain`, written from
//! the three files at the root of the app folder, `app.dart`, `startup.dart` and `splash.dart`,
//! and read by `lib/main.dart` as `Future<void> main() => AppMain.run();`.
//!
//! Which files exist decides everything (`fespalier: main:` says whether they are read), and the
//! file is separate from `app.g.dart`, which is byte-for-byte what it was without them, unless the
//! app lists `fespalier: adapters:`: then `app.g.dart` also holds `AppAdapters` (since 0.11.0), and
//! this main calls it.

use serde::Serialize;

use crate::config::{Config, MainMode};
use crate::dart::{Class, Function, Module, Param};
use crate::diag::Diags;
use crate::resolve::{App, view_class};
use crate::scan::{Kind, Node};
use crate::templates;

/// What other features add to the generated `main()`. `fespalier: adapters:` fills it (since
/// 0.9.0, see `adapters.rs`); with every field empty the output is what the root files alone say.
#[derive(Debug, Default)]
pub struct MainHooks {
    /// Calls that wrap `main()`, outermost first, each a `Future<void> Function(Future<void> Function())`
    /// expression; they go outside startup.dart's own `zone()`.
    pub wrappers: Vec<String>,
    /// Statements run in `_main()` after `ensureInitialized()`, before `runApp` (`await _c.open();`).
    pub before_run: Vec<String>,
    /// Expressions of `List<ProviderObserver>` spread before startup.dart's `providerObservers`.
    pub provider_observers: Vec<String>,
    /// Expressions of `List<Override>`, spread in order into `StartupGate(extraOverrides:)`:
    /// before `startup()`'s own overrides, read once after it succeeded (since 0.9.0).
    pub overrides: Vec<String>,
    /// Expressions of `List<NavigatorObserver>`, spread in order before startup.dart's
    /// `routerObservers` into `AppMain.routerObservers()`, which the generated router passes to
    /// `AppRoutes.router(observers:)` (since 0.9.0).
    pub router_observers: Vec<String>,
    /// Expressions of `Widget Function(Widget)`, outermost first, around the `StartupGate` that
    /// `AppMain.root()` returns (since 0.9.0).
    pub root_wrappers: Vec<String>,
    /// `StartupGate(attach: AppRoutes.attach)`: the router and the app's container go to the
    /// adapters' `attach` (since 0.11.0).
    pub attach: bool,
}

const ROOT_FILES: [Kind; 3] = [Kind::App, Kind::Startup, Kind::Splash];

/// Whether `lib/app.main.g.dart` is written: always with `main: generated`, never with
/// `main: manual`, and with `main: auto` when the app folder's root has one of the three files or
/// the app lists `adapters:` (since 0.9.0: an adapter with no generated `main()` would do nothing).
pub fn wanted(root: &Node, cfg: &Config) -> bool {
    match cfg.main {
        MainMode::Generated => true,
        MainMode::Manual => false,
        MainMode::Auto => {
            !cfg.adapters.is_empty() || ROOT_FILES.iter().any(|k| root.files.contains_key(k))
        }
    }
}

/// The generated main for the app, or `None` when none is wanted (see [`wanted`]). Reads the
/// three root files and reports what is wrong with them (`diags`); with errors the text is
/// still returned, and not written (`gen` stops on any error).
pub fn emit(
    root: &Node,
    app: &App,
    cfg: &Config,
    hooks: &MainHooks,
    diags: &mut Diags,
) -> Option<String> {
    if cfg.main == MainMode::Manual {
        for kind in ROOT_FILES {
            if root.files.contains_key(&kind) {
                let msg = format!(
                    "`main: manual` is set in pubspec.yaml, so {} is not read and no {} is written",
                    kind.file(),
                    cfg.output_main()
                );
                diags.warn(&root.rel(kind), None, msg);
            }
        }
        return None;
    }
    if !wanted(root, cfg) {
        return None;
    }
    let mut imports: Vec<ImportCx> = vec![];
    let mut import = |kind: Kind| {
        let alias = format!("_i{}", imports.len());
        imports.push(ImportCx {
            path: cfg.import_path(&root.rel(kind)),
            alias: alias.clone(),
        });
        alias
    };
    let module = |kind: Kind| {
        root.files
            .get(&kind)
            .map(|src| crate::parse_cache::parse(src))
    };

    // app.dart: the widget around the router, and optionally how the router is built.
    let app_file = module(Kind::App);
    let app_alias = app_file.as_ref().map(|_| import(Kind::App));
    let app_widget = match (&app_file, &app_alias) {
        (Some(m), Some(alias)) => app_widget(root, m, alias, diags),
        _ => None,
    };
    let own_router = app_file
        .as_ref()
        .is_some_and(|m| app_router_fn(root, m, diags));
    // The adapters' router observers reach an app.dart router() only when it passes them on.
    if own_router
        && !hooks.router_observers.is_empty()
        && let (Some(m), Some(src)) = (&app_file, root.files.get(&Kind::App))
        && let Some(f) = function(m, "router")
        && src
            .get(f.extent.clone())
            .is_some_and(|text| !text.contains("routerObservers"))
    {
        let msg = "app.dart's router() builds the router itself, so the adapters' router observers are not added: pass `observers: AppMain.routerObservers()` to `AppRoutes.router(...)` there";
        diags.warn(&root.rel(Kind::App), Some(&f.span), msg);
    }

    // startup.dart: startup(), zone(), observers and retry.
    let startup_file = module(Kind::Startup);
    let startup_alias = startup_file.as_ref().map(|_| import(Kind::Startup));
    let startup = match (&startup_file, &startup_alias) {
        (Some(m), Some(_)) => read_startup(root, m, own_router, diags),
        _ => StartupExports::default(),
    };

    // splash.dart: shown while an async startup() runs, and when it fails.
    let splash_file = module(Kind::Splash);
    let splash_alias = splash_file.as_ref().map(|_| import(Kind::Splash));
    let splash = match (&splash_file, &splash_alias) {
        (Some(m), Some(alias)) => splash_widget(root, m, alias, diags),
        _ => None,
    };
    // A startup() that was rejected has been reported already.
    let has_startup_fn = startup_file
        .as_ref()
        .is_some_and(|m| function(m, "startup").is_some());
    if splash_file.is_some() && startup.startup.is_none() && !has_startup_fn {
        let msg = "splash.dart is shown while startup() runs and when it fails, and startup.dart has no startup(), so it is never shown";
        diags.warn(&root.rel(Kind::Splash), None, msg);
    }

    let sx = startup_alias.as_deref().unwrap_or_default();
    let zone_call = match startup.zone {
        Some(Zone::Future) => format!("{sx}.zone(_main)"),
        Some(Zone::Or) => format!("Future<void>.sync(() => {sx}.zone(_main))"),
        None => "_main()".to_string(),
    };
    let run = hooks.wrappers.iter().rev().fold(zone_call, |inner, wrap| {
        if inner == "_main()" {
            format!("{wrap}(_main)")
        } else {
            format!("{wrap}(() => {inner})")
        }
    });

    let provider_observers = if hooks.provider_observers.is_empty() {
        startup
            .provider_observers
            .then(|| format!("{sx}.providerObservers"))
    } else {
        let mut parts: Vec<String> = hooks
            .provider_observers
            .iter()
            .map(|o| format!("...{o}"))
            .collect();
        if startup.provider_observers {
            parts.push(format!("...{sx}.providerObservers"));
        }
        Some(format!("[{}]", parts.join(", ")))
    };

    let has_app = app_widget.is_some();
    let hook_observers = !hooks.router_observers.is_empty();
    let router_fn = match (own_router, startup.router_observers, hook_observers) {
        (true, ..) => Some(format!(
            "{}.router()",
            app_alias.as_deref().unwrap_or_default()
        )),
        (false, _, true) => Some("AppRoutes.router(observers: AppMain.routerObservers())".into()),
        (false, true, false) => Some(format!("AppRoutes.router(observers: {sx}.routerObservers)")),
        (false, false, false) => None,
    };
    // The adapters' observers, then startup.dart's (which an app.dart router() has none of).
    let router_observers = hook_observers.then(|| {
        let mut parts: Vec<String> = hooks
            .router_observers
            .iter()
            .map(|o| format!("...{o}"))
            .collect();
        if startup.router_observers {
            parts.push(format!("...{sx}.routerObservers"));
        }
        format!("[{}]", parts.join(", "))
    });
    let extra_overrides = (!hooks.overrides.is_empty()).then(|| {
        let parts: Vec<String> = hooks.overrides.iter().map(|o| format!("...{o}")).collect();
        format!("[{}]", parts.join(", "))
    });
    let zone_note = match (hooks.wrappers.is_empty(), startup.zone.is_some()) {
        (true, true) => "everything runs inside startup.dart's `zone()`: ",
        (true, false) => "",
        (false, true) => "everything runs inside the adapters' zones and startup.dart's `zone()`: ",
        (false, false) => "everything runs inside the adapters' zones: ",
    };
    let cx = FileCx {
        app_dir: &cfg.app_dir,
        output_file: cfg.output.rsplit('/').next().unwrap_or(&cfg.output),
        deferred: app.routes.iter().any(crate::resolve::Route::defers_page),
        material: !has_app,
        attach: hooks.attach,
        imports: &imports,
        zone_note,
        run,
        before_run: &hooks.before_run,
        root_wrappers: &hooks.root_wrappers,
        extra_overrides,
        router_observers,
        overrides: startup
            .startup
            .filter(|s| s.overrides)
            .map(|_| format!("{sx}.startup")),
        startup: startup
            .startup
            .filter(|s| !s.overrides)
            .map(|_| format!("{sx}.startup")),
        splash: splash.as_deref(),
        provider_observers,
        retry: startup.retry.then(|| format!("{sx}.retry")),
        router_fn,
        app_body: app_widget
            .unwrap_or_else(|| "MaterialApp.router(routerConfig: router)".to_string()),
    };
    Some(templates::render("main.g.dart", cx))
}

#[derive(Serialize)]
struct ImportCx {
    path: String,
    alias: String,
}

#[derive(Serialize)]
struct FileCx<'a> {
    app_dir: &'a str,
    /// The generated routes' library, in the same folder: `app.g.dart`.
    output_file: &'a str,
    /// Some route's page loads on demand: `AppRoutes.loadDeferred()` exists.
    deferred: bool,
    /// No `app.dart`: the file names `MaterialApp`, which `material.dart` has.
    material: bool,
    /// `StartupGate(attach: AppRoutes.attach)`.
    attach: bool,
    imports: &'a [ImportCx],
    /// How the doc comment of `run` says what runs inside the zones: startup.dart's `zone()` and
    /// the adapters', or nothing.
    zone_note: &'a str,
    /// What `AppMain.run()` returns, wrappers and `zone()` included.
    run: String,
    before_run: &'a [String],
    /// The adapters' widget wrappers, outermost first, around what `AppMain.root()` returns.
    root_wrappers: &'a [String],
    /// The expression of `StartupGate(extraOverrides:)`'s list (the adapters' overrides), when
    /// there are any.
    extra_overrides: Option<String>,
    /// The body of `AppMain.routerObservers()`, when the adapters add router observers.
    router_observers: Option<String>,
    /// `startup()` that returns the overrides, or the one that returns none (never both).
    overrides: Option<String>,
    startup: Option<String>,
    /// The call that builds splash.dart's widget from `error`, `stackTrace` and `retry`.
    splash: Option<&'a str>,
    /// The expression of `ProviderScope(observers:)`, when there are any.
    provider_observers: Option<String>,
    retry: Option<String>,
    /// How the app's router is made, when it is not `AppRoutes.router()`.
    router_fn: Option<String>,
    /// `AppMain.app`'s body.
    app_body: String,
}

/// What startup.dart exports.
#[derive(Default)]
struct StartupExports {
    startup: Option<StartupFn>,
    zone: Option<Zone>,
    provider_observers: bool,
    router_observers: bool,
    retry: bool,
}

#[derive(Clone, Copy)]
struct StartupFn {
    /// It returns the providers to override.
    overrides: bool,
}

#[derive(Clone, Copy)]
enum Zone {
    /// `Future<void> zone(...)`.
    Future,
    /// `FutureOr<void> zone(...)`.
    Or,
}

/// A type without whitespace, import prefixes (`r.Override`) or the nullable mark's neighbours:
/// `Future< List<w.Override> >` → `Future<List<Override>>`.
fn plain(ty: &str) -> String {
    let squeezed: String = ty.chars().filter(|c| !c.is_whitespace()).collect();
    let mut out = String::new();
    let mut ident = String::new();
    for c in squeezed.chars() {
        if c.is_alphanumeric() || c == '_' {
            ident.push(c);
        } else if c == '.' && !ident.is_empty() {
            ident.clear();
        } else {
            out.push_str(&ident);
            ident.clear();
            out.push(c);
        }
    }
    out.push_str(&ident);
    out
}

fn bare(ty: &Option<crate::dart::Ty>) -> Option<String> {
    ty.as_ref().map(|t| plain(&t.text))
}

fn function<'m>(m: &'m Module, name: &str) -> Option<&'m Function> {
    m.functions.iter().find(|f| f.name == name)
}

/// Whether the parameter is typed as something a `GoRouter` can be passed as.
fn router_typed(p: &Param) -> bool {
    p.ty.as_ref().is_some_and(|t| {
        matches!(
            plain(t.text.trim_end_matches('?')).as_str(),
            "GoRouter" | "RouterConfig<Object>" | "RouterConfig<Object?>"
        )
    })
}

/// The call that builds app.dart's widget: `_i0.App(router: router)`.
fn app_widget(root: &Node, m: &Module, alias: &str, diags: &mut Diags) -> Option<String> {
    let file = root.rel(Kind::App);
    let class = view_class(diags, m, &file, Kind::App)?;
    let params: Vec<&Param> = class.params.iter().filter(|p| !p.is_super).collect();
    // `router` by its name first, else the one parameter typed as a router.
    let router = params
        .iter()
        .find(|p| p.name == "router")
        .or_else(|| params.iter().find(|p| router_typed(p)))
        .copied();
    let Some(router) = router else {
        let msg = "the app's widget gets the router: add `required this.router` (a `GoRouter`) and pass it to `MaterialApp.router(routerConfig: router)`. If this file is not the app around the router, move it out of the app folder's root or set `main: manual`";
        diags.error(&file, Some(&class.span), msg);
        return None;
    };
    // A parameter with no type the generator can see (an untyped `this.router`) is left to Dart.
    if router.ty.is_some() && !router_typed(router) {
        let ty = router.ty.as_ref().map_or("dynamic", |t| t.text.as_str());
        let msg = format!("`router` must be a `GoRouter` (or a `RouterConfig<Object>`), not {ty}");
        diags.error(&file, Some(&router.span), msg);
        return None;
    }
    let mut ok = true;
    for p in &params {
        if p.required && !std::ptr::eq(*p, router) {
            let msg = format!(
                "`{}`: app.dart's widget is built by the generated main(), which only gives it `router`; make `{}` optional, or work it out inside the widget",
                p.name, p.name
            );
            diags.error(&file, Some(&p.span), msg);
            ok = false;
        }
    }
    ok.then(|| call(&class, alias, &[(router, "router")]))
}

/// `_i0.App(router: router)`: only the given parameters are passed, each as its value; a
/// `const` constructor with none is called `const`.
fn call(class: &Class, alias: &str, given: &[(&Param, &str)]) -> String {
    let args: Vec<String> = class
        .params
        .iter()
        .filter_map(|p| {
            let (_, value) = given.iter().find(|(g, _)| g.name == p.name)?;
            Some(if p.named {
                format!("{}: {value}", p.name)
            } else {
                (*value).to_string()
            })
        })
        .collect();
    let konst = if class.is_const && args.is_empty() && !class.function {
        "const "
    } else {
        ""
    };
    format!("{konst}{alias}.{}({})", class.name, args.join(", "))
}

/// app.dart's optional `router()`: whether it is there, and a mistake in its shape.
fn app_router_fn(root: &Node, m: &Module, diags: &mut Diags) -> bool {
    let Some(f) = function(m, "router") else {
        return false;
    };
    let returns_router = f.ret.is_none() || bare(&f.ret).as_deref() == Some("GoRouter");
    if !f.params.is_empty() || !returns_router {
        let msg = "router() builds the app's router: declare it `GoRouter router()`, with no parameters, and return `AppRoutes.router(...)`";
        diags.error(&root.rel(Kind::App), Some(&f.span), msg);
        return false;
    }
    true
}

fn read_startup(root: &Node, m: &Module, own_router: bool, diags: &mut Diags) -> StartupExports {
    let file = root.rel(Kind::Startup);
    let mut out = StartupExports::default();
    let mut found = false;

    // The list-valued exports are variables or getters, never functions.
    for (name, observer) in [
        ("providerObservers", "ProviderObserver"),
        ("routerObservers", "NavigatorObserver"),
    ] {
        if let Some(f) = function(m, name) {
            let msg = format!(
                "`{name}` is a list, not a function: `List<{observer}> get {name} => [...];`"
            );
            diags.error(&file, Some(&f.span), msg);
            found = true;
        }
        let there =
            m.variables.iter().any(|v| v.name == name) || m.getters.iter().any(|g| g.name == name);
        if there {
            found = true;
            if name == "providerObservers" {
                out.provider_observers = true;
            } else if own_router {
                let span = m.variables.iter().find(|v| v.name == name).map(|v| &v.span);
                let msg = "app.dart's router() builds the router itself, so `routerObservers` is not used: pass them to `AppRoutes.router(observers: ...)` there, and remove this one";
                diags.error(&file, span, msg);
            } else {
                out.router_observers = true;
            }
        }
    }

    if let Some(f) = function(m, "startup") {
        found = true;
        if f.params.is_empty() {
            match bare(&f.ret).as_deref() {
                Some("void" | "Future<void>" | "FutureOr<void>") => {
                    out.startup = Some(StartupFn { overrides: false });
                }
                Some("List<Override>" | "Future<List<Override>>" | "FutureOr<List<Override>>") => {
                    out.startup = Some(StartupFn { overrides: true });
                }
                _ => {
                    let msg = "startup() must return `Future<void>` or `void`, or the providers it overrides: `Future<List<Override>>` or `List<Override>`";
                    diags.error(&file, Some(&f.span), msg);
                }
            }
        } else {
            let msg = "startup() takes no parameters: it runs before the ProviderScope exists, so return the overrides it makes (`Future<List<Override>> startup()`) instead";
            diags.error(&file, Some(&f.span), msg);
        }
    }

    if let Some(f) = function(m, "zone") {
        found = true;
        let body_ok = f.params.len() == 1
            && !f.params[0].named
            && bare(&f.params[0].ty).as_deref() == Some("Future<void>Function()");
        match (body_ok, bare(&f.ret).as_deref()) {
            (true, Some("Future<void>")) => out.zone = Some(Zone::Future),
            (true, Some("FutureOr<void>")) => out.zone = Some(Zone::Or),
            _ => {
                let msg = "zone() wraps all of main(): declare it `Future<void> zone(Future<void> Function() body)` and call `body()` inside it";
                diags.error(&file, Some(&f.span), msg);
            }
        }
    }

    if let Some(f) = function(m, "retry") {
        found = true;
        let shape_ok = f.params.len() == 2
            && f.params.iter().all(|p| !p.named)
            && (f.ret.is_none() || bare(&f.ret).as_deref() == Some("Duration?"));
        if shape_ok {
            out.retry = true;
        } else {
            let msg = "retry() is the ProviderScope's retry policy: `Duration? retry(int retryCount, Object error)`";
            diags.error(&file, Some(&f.span), msg);
        }
    }

    if !found {
        let msg = "startup.dart exports none of `startup()`, `zone()`, `providerObservers`, `routerObservers` or `retry()`; add one, or delete the file";
        diags.error(&file, None, msg);
    }
    out
}

/// What splash.dart can ask for, by name, and the type each has to have.
const SPLASH_PARAMS: [(&str, &[&str], &str); 3] = [
    ("error", &["Object?", "dynamic"], "Object?"),
    ("stackTrace", &["StackTrace?"], "StackTrace?"),
    (
        "retry",
        &["VoidCallback?", "void Function()?"],
        "VoidCallback?",
    ),
];

/// The call that builds splash.dart's widget: `_i2.Splash(error: error, retry: retry)`.
fn splash_widget(root: &Node, m: &Module, alias: &str, diags: &mut Diags) -> Option<String> {
    let file = root.rel(Kind::Splash);
    let class = view_class(diags, m, &file, Kind::Splash)?;
    let mut given: Vec<(&Param, &str)> = vec![];
    let mut ok = true;
    for p in class.params.iter().filter(|p| !p.is_super) {
        let Some((name, types, written)) = SPLASH_PARAMS.iter().find(|(n, ..)| *n == p.name) else {
            if p.required {
                let msg = format!(
                    "splash.dart is built before the app, so it can ask only for `error`, `stackTrace` and `retry` (each null while startup() runs); `{}` is none of them",
                    p.name
                );
                diags.error(&file, Some(&p.span), msg);
                ok = false;
            }
            continue;
        };
        if let Some(ty) = &p.ty {
            let text = plain(&ty.text);
            if !types.iter().any(|t| plain(t) == text) {
                let msg = format!(
                    "splash.dart is shown while startup() runs too, when there is no `{name}`: make it `{written} {name}`"
                );
                diags.error(&file, Some(&p.span), msg);
                ok = false;
                continue;
            }
        }
        given.push((p, *name));
    }
    ok.then(|| call(&class, alias, &given))
}
