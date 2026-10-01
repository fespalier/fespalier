//! Finds each file's one declaration, works out what every constructor and
//! function parameter receives, and checks that the files fit together.
//!
//! Nothing here is a base class or an interface: a `page.dart` is any widget,
//! and its constructor says what it wants. Parameters are filled by name first
//! (`id` ← the `$id` segment, `child`, `error`, `retry`, `uri`, `data`), then by
//! type (`Product product` ← what `data.dart` yields). Anything else that is
//! nullable or a List of String/int/double/bool is a query parameter
//! (`int? page` ← `?page=2`). `transition()` is filled the same way: `key`,
//! `child` and `state`. A segment or query parameter can also be an app enum
//! (`Category category`, `Sort? sort`, `List<Category> path`): see `enums.rs`.

#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    reason = "sections and data are bound before the lookups that unwrap them; the resolver states those invariants"
)]

use std::collections::{BTreeMap, HashMap};

use heck::ToUpperCamelCase;

use crate::dart::{self, Class, Function, Lit, Module, Span, Ty};
use crate::diag::Diags;
use crate::enums::{self, Libs, Lookup};
use crate::extra::{self, ExtraType};
use crate::locale::{self, Localized};
use crate::scan::{ACTION_RESERVED, Kind, Node, ROUTE_MEMBERS, Seg};

/// What a segment can be, besides an enum.
pub const SEGMENT_TYPES: [&str; 4] = ["String", "int", "double", "bool"];

/// What the parts of a catch-all can be, as `List<T>`: each part is read like one segment of
/// that type (`num` and `DateTime` with `num.tryParse` and `DateTime.tryParse`). An enum is
/// one too, read by name.
pub const CATCH_ALL_ITEMS: [&str; 6] = ["String", "int", "double", "num", "bool", "DateTime"];

/// `int` for `List<int>`.
pub fn list_item(ty: &str) -> Option<&str> {
    ty.strip_prefix("List<")?.strip_suffix('>')
}

/// What a parameter receives.
#[derive(Debug, Clone, PartialEq)]
pub enum Bind {
    Segment(String),
    Query(String),
    Data,
    /// A section's data.dart, watched again below its layout: the id of the
    /// folder that holds it.
    Section(usize),
    Child,
    /// A tab layout's `StatefulNavigationShell`.
    Shell,
    Error,
    StackTrace,
    Retry,
    Uri,
    /// A transition's page key: `state.pageKey`.
    PageKey,
    /// A transition's `GoRouterState`.
    State,
    /// A transition's `bool shell`: whether it builds the page of a layout's shell
    /// (`true`) or of a route (`false`).
    IsShell,
    /// A page's `extra` parameter: the object passed to `go(..., extra:)`.
    Extra,
    /// A segment above a `not_found.dart`, as the URL spells it: a `String`, because the
    /// ones that failed to parse are the reason the file is shown.
    Raw(String),
}

#[derive(Debug, Clone)]
pub struct Arg {
    pub name: String,
    pub named: bool,
    pub bind: Bind,
}

/// A user widget and the arguments to build it with.
#[derive(Debug, Clone)]
pub struct Widget {
    pub import: usize,
    pub class: String,
    pub args: Vec<Arg>,
    /// The constructor is `const`: with no arguments, the call is `const` too, so the
    /// framework can skip rebuilding it.
    pub is_const: bool,
}

impl Widget {
    /// Constructor call, given how to spell each binding.
    pub fn call(&self, value: impl Fn(&Bind) -> String) -> String {
        let args: Vec<String> = self
            .args
            .iter()
            .map(|a| {
                if a.named {
                    format!("{}: {}", a.name, value(&a.bind))
                } else {
                    value(&a.bind)
                }
            })
            .collect();
        let konst = if self.is_const && args.is_empty() {
            "const "
        } else {
            ""
        };
        format!(
            "{konst}_i{}.{}({})",
            self.import,
            self.class,
            args.join(", ")
        )
    }
}

#[derive(Debug, Clone)]
pub struct Data {
    pub import: usize,
    /// The file exports its own provider (`final data = FutureProvider...`);
    /// otherwise fespalier wraps its `data()` function in one.
    pub provider: bool,
    /// `ProviderListenable<AsyncValue<T>> data({...}) => productProvider(id)`: the
    /// function only selects a provider that exists (a generated one, say), so
    /// nothing wraps it. The route watches and invalidates what it returns.
    pub selector: bool,
    pub stream: bool,
    pub ty: String,
    /// Segments the provider is keyed by, in path order.
    pub keys: Vec<String>,
    /// Keyed by a named record `(a: .., b: ..)` rather than a bare value.
    pub record: bool,
}

/// A name listed in `const invalidates = [...]`, with where it sits.
type Named = (String, Span);

/// What an `action.dart` function returns, which is what its helpers return: a `Future<T>`
/// stays a `Future`, a `T` stays a `T` (a sync action never gets an async gap), and a
/// `FutureOr<T>` stays one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Flow {
    Future,
    FutureOr,
    Sync,
}

/// One function of an `action.dart`: `Future<Refund> action(Ref ref, {required int id, required
/// RefundInput input})`.
#[derive(Debug, Clone)]
pub struct Action {
    /// The function's name; `action` is the plain one (`submit`, `useAction`).
    pub name: String,
    pub import: usize,
    pub flow: Flow,
    /// The segments and query parameters it takes, in path order: what keys its provider.
    pub keys: Vec<String>,
    /// The type of `input`, as the generated file spells it.
    pub input: ExtraType,
    /// The routes (or sections) whose `data.dart` a success invalidates, outermost first.
    pub invalidates: Vec<usize>,
    /// The function, for diagnostics.
    pub span: Span,
}

/// The members the generated typed route (or section handle) gets for an action.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActionNames {
    /// The provider: `action`, or `approveAction`.
    pub provider: String,
    /// Runs it once: `submit`, or the function's own name (`approve`).
    pub run: String,
    /// The hook: `useAction`, or `useApprove`.
    pub hook: String,
}

impl ActionNames {
    /// A function called `action` gets the plain names; any other, its own.
    pub fn of(function: &str) -> ActionNames {
        let mut chars = function.chars();
        let upper: String = chars
            .next()
            .map(|c| c.to_uppercase().chain(chars).collect())
            .unwrap_or_default();
        if function == "action" {
            ActionNames {
                provider: "action".into(),
                run: "submit".into(),
                hook: "useAction".into(),
            }
        } else {
            ActionNames {
                provider: format!("{function}Action"),
                run: function.into(),
                hook: format!("use{upper}"),
            }
        }
    }
}

/// A `transition()` function, applied to every page at or below its folder.
#[derive(Debug, Clone)]
pub struct Transition {
    pub import: usize,
    /// `Bind::Child` is the page as it would be built without a transition.
    pub args: Vec<Arg>,
}

/// What a folder's `navigator.dart` says: `const navigator = RouteNavigator.root;`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Navigator {
    /// Render on the root navigator, above every shell.
    Root,
    /// Back to the enclosing shell's navigator.
    Shell,
}

/// What a `guard()` or `redirect()` takes before its named parameters.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookFirst {
    /// Nothing (only a `redirect()` may).
    None,
    /// `ProviderContainer c`, the older form: read once, per call.
    Container,
    /// `Ref ref`: a guard that watches runs again when what it watches changes.
    Ref,
}

impl HookFirst {
    /// The first parameter of `f`, when it is positional and one of the kinds a hook takes.
    fn of(f: &dart::Function) -> Self {
        match f.params.first() {
            Some(p) if !p.named => match p.ty.as_ref() {
                Some(t) if t.is("Ref") => Self::Ref,
                Some(t) if t.is("ProviderContainer") => Self::Container,
                _ => Self::None,
            },
            _ => Self::None,
        }
    }

    /// How many leading parameters it takes off the list.
    fn skip(self) -> usize {
        usize::from(self != Self::None)
    }
}

/// A `guard()` or `redirect()` function and the arguments to call it with.
#[derive(Debug, Clone)]
pub struct Guard {
    pub import: usize,
    /// The leading `Ref` or `ProviderContainer` (always one for `guard()`, optional for
    /// `redirect()`).
    pub first: HookFirst,
    /// The named arguments: segments, then query parameters (each in path or
    /// declaration order), then `uri` and `extra`.
    pub args: Vec<Arg>,
    /// The `extra` parameter, when it takes one.
    pub extra: Option<HookExtra>,
}

/// The `extra` parameter of a layout, guard or redirect: what the navigation carried, as
/// the location it is at gets it (`state.extra`). A wrong type reads as `null`.
#[derive(Debug, Clone)]
pub struct HookExtra {
    pub ty: ExtraType,
    /// The parameter, for a diagnostic that points at it.
    pub span: Span,
    pub file: String,
}

impl Guard {
    /// The segments and query parameters it reads from the URL.
    pub fn keys(&self) -> Vec<String> {
        let url = |a: &&Arg| matches!(a.bind, Bind::Segment(_) | Bind::Query(_));
        self.args
            .iter()
            .filter(url)
            .map(|a| a.name.clone())
            .collect()
    }
}

/// One tab of a tab layout.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Branch {
    /// The layout folder's own page.dart.
    Own,
    /// A subfolder holding routes: its route id.
    Folder(usize),
}

/// What `tabOptions` in a tab layout sets for one tab.
#[derive(Debug, Clone, Default)]
pub struct BranchOptions {
    pub preload: bool,
    /// An app location inside the tab, as written (`/profile/edit`).
    pub initial_location: Option<String>,
}

#[derive(Debug)]
pub struct Route {
    pub dir: String,
    pub seg: Option<Seg>,
    pub children: Vec<usize>,
    /// Dynamic segments from the root down, with the folder that declares each.
    pub segs: Vec<(String, usize)>,
    /// The URL's segments from the root down; `(group)` folders add none.
    pub url: Vec<Seg>,
    pub page: Option<Widget>,
    /// Where the page's class (or the `redirect()` function) is declared, for
    /// diagnostics that name the route.
    pub page_span: Option<Span>,
    /// `Product` for `ProductPage`; the typed route is `ProductRoute`. A
    /// `redirect.dart` route is named after its path (`OldProductsId`).
    pub name: Option<String>,
    pub data: Option<Data>,
    /// The functions of this folder's `action.dart`, in the order the file declares them.
    pub actions: Vec<Action>,
    pub loading: Option<Widget>,
    pub error: Option<Widget>,
    pub layout: Option<Widget>,
    pub guard: Option<Guard>,
    /// A `redirect.dart` in place of a page: the route only redirects.
    pub redirect: Option<Guard>,
    /// The nearest transition.dart at or above this folder; only for pages, and
    /// not for one that has a `present.dart`.
    pub transition: Option<Transition>,
    /// This folder's own `present()`: the app builds the route's page itself. Not inherited.
    pub present: Option<Transition>,
    /// The `navigator.dart` in this folder, when it has a valid one.
    pub navigator: Option<Navigator>,
    /// Whether this folder's routes are on the root navigator: its own `navigator.dart`, or
    /// `present.dart` (which implies it), or else what the folder above says. A layout is a
    /// navigator of its own, so below one nothing is inherited. For a folder with a layout, it
    /// is the layout's shell that goes on the root navigator.
    pub root: bool,
    /// The nearest transition.dart at or above a layout folder: the page of its shell.
    pub shell_transition: Option<Transition>,
    /// A tab layout with a top-level `container` function: the branch container.
    pub container: bool,
    /// Query parameters any of this route's files ask for: (name, Dart type),
    /// the type being `T?` or `List<T>`.
    pub query: Vec<(String, String)>,
    /// Query parameters this folder's layout asks for.
    pub layout_query: Vec<(String, String)>,
    /// Query parameters a guard asks for when its folder has no route of its own.
    pub guard_query: Vec<(String, String)>,
    /// Set when the layout asks for a `StatefulNavigationShell`: its tabs, in order.
    pub tabs: Option<Vec<Branch>>,
    /// The options of each tab, in the same order as `tabs`.
    pub tab_options: Vec<BranchOptions>,
    /// The nearest `not_found.dart` below the root at or above this folder: what an
    /// unparsable segment shows. `None` means the root's.
    pub not_found: Option<Widget>,
    /// The folder's `meta.dart` (relative to the app folder) when it has a valid
    /// one and a route to describe. Not inherited: it belongs to this route alone.
    pub meta: Option<String>,
    /// The type of the `extra` a navigation to this route can carry: the page's or the
    /// redirect's own, or else the one type the guards and layouts above it ask for.
    pub extra: Option<ExtraType>,
    /// The `extra` parameter of this folder's layout.
    pub layout_extra: Option<HookExtra>,
    /// The literal named arguments of `const meta = Meta(code: 'x', ...)`, for `meta_unique`.
    pub meta_args: Vec<dart::ObjectArg>,
    /// The sections (route ids) above this folder, outermost first, whose data.dart the
    /// layouts above load: what `AppRoutes.dataAt` lists before the route's own data.
    pub sections: Vec<usize>,
    /// Whether this folder's paths match by case: the nearest `route.dart`'s
    /// `caseSensitive` at or above it, else the pubspec's `case_sensitive`.
    pub case_sensitive: bool,
    /// The localized segments of this route's URL, outermost first: the `paths` of the
    /// `route.dart` of each folder at or above it that has one (see `locale.rs`).
    pub localized: Vec<Localized>,
    /// `const nest = false;` in this folder's route.dart, and valid: the route is not a child
    /// of the page above it but a sibling of that page, with the folders between joined into
    /// its path (`refund/confirm`). Its own children still nest under it.
    pub sibling: bool,
}

impl Route {
    /// A page-less folder whose layout wraps a section, and whose data.dart
    /// feeds the layout and the pages below it.
    pub fn is_section(&self) -> bool {
        self.layout_folder() && self.data.is_some()
    }

    /// A folder with a layout and no page: what a section is, with or without data. Its
    /// `action.dart` writes to the section, and its query parameters are the layout's.
    pub fn layout_folder(&self) -> bool {
        self.page.is_none() && self.layout.is_some()
    }

    /// Whether the folder has typed members of its own for the section's data or actions: a
    /// section's handle (`TeamsTeamIdSection`) is generated for it.
    pub fn has_section_handle(&self) -> bool {
        self.is_section() || (self.layout_folder() && !self.actions.is_empty())
    }
}

/// The name of the typed handle of a section: `teams/$teamId` is `TeamsTeamIdSection`, `(shop)`
/// is `ShopSection`, the app folder `RootSection`.
pub fn section_name(dir: &str) -> String {
    let stem = pascal(dir);
    let stem = match stem.chars().next() {
        None => "Root".to_string(),
        Some(c) if c.is_ascii_digit() => format!("Path{stem}"),
        _ => stem,
    };
    format!("{stem}Section")
}

/// A `not_found.dart` below the root, chosen for unknown URLs under `url`.
#[derive(Debug, Clone)]
pub struct ScopedNotFound {
    pub url: Vec<Seg>,
    pub widget: Widget,
    /// Whether the folder's own path matches by case (see [`Route::case_sensitive`]).
    pub case_sensitive: bool,
    /// The localized segments of its URL, so `/produits/x` is under it as `/products/x` is.
    pub localized: Vec<Localized>,
    /// The `not_found.dart`, relative to the app folder.
    pub file: String,
}

#[derive(Debug, Default)]
pub struct App {
    pub imports: Vec<String>,
    pub routes: Vec<Route>,
    pub not_found: Option<Widget>,
    /// The `not_found.dart` files in folders below the root (not `(group)`s).
    pub not_founds: Vec<ScopedNotFound>,
    /// Type of each dynamic segment, keyed by the folder that declares it.
    pub seg_types: HashMap<usize, String>,
    /// The `extra_codec.dart` at the root of the app folder: `GoRouter(extraCodec:)`.
    pub extra_codec: Option<ExtraCodec>,
    /// The enums of segments and query parameters, as the generated file names them: it
    /// imports each the way it imports the type of an `extra`.
    pub enum_types: Vec<ExtraType>,
    /// The type of each of those as the generated file spells it (`List<_i3.Category>`) → as the
    /// app does (`List<Category>`): what the manifest and `fsp routes` show.
    pub type_names: HashMap<String, String>,
}

/// The app folder's `extra_codec.dart`, which exports `extraCodec`.
#[derive(Debug, Clone)]
pub struct ExtraCodec {
    pub import: usize,
}

impl Route {
    /// Serves a URL of its own: a page or a redirect.
    pub fn is_route(&self) -> bool {
        self.page.is_some() || self.redirect.is_some()
    }
}

impl App {
    pub fn seg_type(&self, folder: usize) -> &str {
        let default = if self.is_catch_all(folder) {
            "List<String>"
        } else {
            "String"
        };
        self.seg_types.get(&folder).map_or(default, String::as_str)
    }

    /// Whether the folder is a `$$rest` / `$$$rest` catch-all.
    pub fn is_catch_all(&self, folder: usize) -> bool {
        matches!(self.routes[folder].seg, Some(Seg::CatchAll(..)))
    }

    /// A segment's or query parameter's type as the app writes it, for what shows types: an
    /// enum is `Category`, where the generated file spells it `_i3.Category`.
    pub fn display_type(&self, ty: &str) -> String {
        self.type_names
            .get(ty)
            .cloned()
            .unwrap_or_else(|| ty.to_string())
    }

    /// `(name, type)` for each of a route's segments, in path order.
    pub fn typed_segs(&self, r: &Route) -> Vec<(String, String)> {
        r.segs
            .iter()
            .map(|(n, f)| (n.clone(), self.seg_type(*f).to_string()))
            .collect()
    }

    /// Everything a route's files ask for from the URL: segments, then query.
    pub fn url_params(&self, r: &Route) -> Vec<(String, String)> {
        let mut out = self.typed_segs(r);
        out.extend(r.query.iter().cloned());
        out
    }
}

/// Where a query parameter's type must agree: one route's files, or one layout.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum Scope {
    Route(usize),
    Layout(usize),
    /// A guard in a folder that has no page or redirect to hang its query on.
    Guard(usize),
}

/// `int?` → a nullable int, `List<String>` → every `?x=` value.
fn query_type(ty: &Ty) -> Option<String> {
    let t = ty.text.as_str();
    if let Some(inner) = t.strip_suffix('?').filter(|i| SEGMENT_TYPES.contains(i)) {
        return Some(format!("{inner}?"));
    }
    let list = t.strip_suffix('?').unwrap_or(t);
    let inner = list.strip_prefix("List<")?.strip_suffix('>')?;
    SEGMENT_TYPES
        .contains(&inner)
        .then(|| format!("List<{inner}>"))
}

/// A URL parameter's type, worked out.
#[derive(Debug, Clone)]
struct Typed {
    /// As the generated file spells it: `int?`, `List<_i3.Category>`.
    spelled: String,
    /// What two files that declare the type must agree on: the type itself, and for an enum the
    /// declaration it names.
    key: String,
    /// As the file that declares the parameter wrote it, for the errors that name it.
    shown: String,
    /// What the generated file imports to name an enum.
    import: Option<ExtraType>,
    /// The file that declares the enum, relative to the project.
    decl: Option<String>,
}

impl Typed {
    fn plain(text: String) -> Typed {
        Typed {
            spelled: text.clone(),
            key: text.clone(),
            shown: text,
            import: None,
            decl: None,
        }
    }

    /// For "`$x` is A here but B there" when A and B are enums that are spelled alike.
    fn same_name_as(&self, other: &Typed) -> String {
        match (&self.decl, &other.decl) {
            (Some(a), Some(b)) if self.shown == other.shown => {
                format!(" (two different enums: {a} and {b})")
            }
            _ => String::new(),
        }
    }
}

/// Whether a parameter's type is one a query parameter can have.
enum QueryTy {
    Is(Box<Typed>),
    /// Not one: the parameter is something else (or nothing).
    Isnt,
    /// Meant as one, but it names an enum that can't be found or used; the error is reported.
    Broken,
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Role {
    Page,
    Loading,
    Error,
    Layout,
    NotFound,
}

/// A loading.dart / error.dart, bound separately for every route it covers.
#[derive(Clone)]
struct Fallback {
    import: usize,
    class: Class,
    file: String,
}

#[derive(Clone, Default)]
struct Inherited {
    segs: Vec<(String, usize)>,
    url: Vec<Seg>,
    loading: Option<Fallback>,
    error: Option<Fallback>,
    transition: Option<Transition>,
    /// Whether a root-navigator declaration above is in effect: not reset by a layout.
    root: bool,
    /// The data.dart files of the sections above, outermost first.
    sections: Vec<SectionRef>,
    not_found: Option<Widget>,
    /// The nearest route.dart's `caseSensitive`, else the config's.
    case_sensitive: bool,
    /// The `paths` of the route.dart files above, outermost first.
    localized: Vec<Localized>,
    /// The nearest page above, which a `nest = false` below leaves; `None` without one.
    above: Option<PageAbove>,
}

/// What a `nest = false` takes a route out of: the page above it, and the folders between.
#[derive(Clone)]
struct PageAbove {
    /// That page.dart, relative to the app folder.
    page: String,
    /// The first layout.dart in a folder from that page's down to the one above this: a
    /// route that leaves the page would leave the layout too.
    layout: Option<String>,
}

/// A section's data.dart, as the files below its layout can receive it.
#[derive(Clone)]
struct SectionRef {
    id: usize,
    ty: String,
    file: String,
}

/// "Segment `$id` is `int`", as declared by one parameter somewhere.
struct Constraint {
    folder: usize,
    name: String,
    ty: Ty,
    file: String,
    span: Span,
}

struct BindCx<'a> {
    role: Role,
    segs: &'a [(String, usize)],
    data: Option<&'a str>,
    /// The sections above this file, whose data it can ask for by type or as `data`.
    sections: &'a [SectionRef],
    file: &'a str,
    /// For inherited views: the folder of the route this use is for.
    covering: Option<&'a str>,
    /// Where query parameters land; `None` where there are none (`not_found`).
    scope: Option<Scope>,
}

/// `case_sensitive` is the config's default, for folders with no `route.dart` at or above them.
/// `libs` is where the enums of segments are looked for besides the files that name them.
pub fn resolve(root: &Node, case_sensitive: bool, libs: &Libs, diags: &mut Diags) -> App {
    let mut sources = HashMap::new();
    collect_sources(root, &mut sources);
    let mut r = Resolver {
        app: App::default(),
        libs,
        sources,
        tags: 0,
        import_ix: HashMap::new(),
        route_names: HashMap::new(),
        patterns: HashMap::new(),
        not_found_urls: HashMap::new(),
        constraints: vec![],
        queries: HashMap::new(),
        query_order: vec![],
        listed: vec![],
        diags,
    };
    r.node(
        root,
        &Inherited {
            case_sensitive,
            ..Inherited::default()
        },
    );
    r.extra_codec(root);
    r.settle_segment_types();
    r.settle_extras();
    locale::check_collisions(&r.app, r.diags);
    for (scope, name) in std::mem::take(&mut r.query_order) {
        let ty = r.queries[&(scope, name.clone())].0.spelled.clone();
        match scope {
            Scope::Route(id) => r.app.routes[id].query.push((name, ty)),
            Scope::Layout(id) => r.app.routes[id].layout_query.push((name, ty)),
            Scope::Guard(id) => r.app.routes[id].guard_query.push((name, ty)),
        }
    }
    r.settle_actions();
    r.app
}

/// Every file of the tree by its path relative to the app folder.
fn collect_sources<'n>(node: &'n Node, out: &mut HashMap<String, &'n str>) {
    for (kind, src) in &node.files {
        out.insert(node.rel(*kind), src.as_str());
    }
    for c in &node.children {
        collect_sources(c, out);
    }
}

struct Resolver<'a> {
    app: App,
    libs: &'a Libs,
    /// The source of each file, for the enums the files name.
    sources: HashMap<String, &'a str>,
    /// Counts the uses of an enum's import, for the aliases of a prefixed type (see `extra_type`).
    tags: usize,
    import_ix: HashMap<String, usize>,
    route_names: HashMap<String, String>,
    /// URL pattern → the page.dart that serves it.
    patterns: HashMap<String, String>,
    /// URL pattern → the `not_found.dart` below the root that covers it.
    not_found_urls: HashMap<String, String>,
    constraints: Vec<Constraint>,
    /// Query parameter types as first declared: (type, file, line).
    queries: HashMap<(Scope, String), (Typed, String, usize)>,
    query_order: Vec<(Scope, String)>,
    /// What each `action.dart` says to invalidate (`const invalidates = [...]`), by route id:
    /// the names it lists, resolved once every route is known. `None` is the default set.
    listed: Vec<(usize, Option<Vec<Named>>)>,
    diags: &'a mut Diags,
}

impl Resolver<'_> {
    fn import(&mut self, rel: &str) -> usize {
        if let Some(&i) = self.import_ix.get(rel) {
            return i;
        }
        let i = self.app.imports.len();
        self.app.imports.push(rel.to_string());
        self.import_ix.insert(rel.to_string(), i);
        i
    }

    /// Returns the route id and whether it or anything below it is a page.
    fn node(&mut self, node: &Node, up: &Inherited) -> (usize, bool) {
        let id = self.app.routes.len();
        self.app.routes.push(Route {
            dir: node.dir.clone(),
            seg: node.seg.clone(),
            children: vec![],
            segs: vec![],
            url: vec![],
            page: None,
            page_span: None,
            name: None,
            data: None,
            actions: vec![],
            loading: None,
            error: None,
            layout: None,
            guard: None,
            redirect: None,
            transition: None,
            present: None,
            navigator: None,
            root: false,
            shell_transition: None,
            container: false,
            query: vec![],
            layout_query: vec![],
            guard_query: vec![],
            tabs: None,
            not_found: None,
            tab_options: vec![],
            meta: None,
            extra: None,
            layout_extra: None,
            meta_args: vec![],
            sections: up.sections.iter().map(|s| s.id).collect(),
            case_sensitive: up.case_sensitive,
            localized: up.localized.clone(),
            sibling: false,
        });

        let mut segs = up.segs.clone();
        if let Some(Seg::Dynamic(n) | Seg::CatchAll(n, _)) = &node.seg {
            if segs.iter().any(|(s, _)| s == n) {
                self.diags.error(
                    &node.dir,
                    None,
                    format!("`${n}` is already a segment higher up this path"),
                );
            } else {
                segs.push((n.clone(), id));
            }
        }
        let mut url = up.url.clone();
        if let Some(seg @ (Seg::Static(_) | Seg::Dynamic(_) | Seg::CatchAll(..))) = &node.seg {
            url.push(seg.clone());
        }
        let modules: BTreeMap<Kind, Module> = node
            .files
            .iter()
            .map(|(k, src)| (*k, crate::parse_cache::parse(src)))
            .collect();
        // The grammar may lag newer Dart, so this is a warning: the Dart compiler has the last word.
        for (kind, m) in &modules {
            if let Some(span) = &m.parse_error {
                let msg = "couldn't fully parse this file; if it doesn't compile, the Dart compiler will say where";
                self.diags.warn(&node.rel(*kind), Some(span), msg);
            }
        }

        if !node.dir.is_empty() && node.files.contains_key(&Kind::ExtraCodec) {
            let msg = "extra_codec.dart is only read at the root of the app folder, so this one is ignored";
            self.diags.warn(&node.rel(Kind::ExtraCodec), None, msg);
        }

        // page.dart names the route; data.dart feeds it.
        let page_file = node.rel(Kind::Page);
        let page_class = modules
            .get(&Kind::Page)
            .and_then(|m| self.widget_class(m, &page_file, Kind::Page));
        // A class names its route after itself; a function has no name of its own to give
        // (many routes can build one screen), so it takes the folder path. Either way
        // `const routeName = '...';` in page.dart has the last word.
        let given = match (&page_class, modules.get(&Kind::Page)) {
            (Some(_), Some(m)) => self.route_name_var(m, &page_file),
            _ => None,
        };
        let mut name = page_class.as_ref().map(|c| {
            given.clone().unwrap_or_else(|| {
                if c.function {
                    path_name(&url)
                } else {
                    route_name(&c.name)
                }
            })
        });
        let mut page_span = page_class.as_ref().map(|c| c.span.clone());
        if let (Some(n), Some(c)) = (&name, &page_class) {
            let fix = match (c.function, given.is_some()) {
                (false, false) => "rename the class".to_string(),
                (false, true) => "change its `routeName`".to_string(),
                (true, false) => format!(
                    "give one a different name with `const routeName = 'Name';` in {page_file}"
                ),
                (true, true) => "change its `routeName`".to_string(),
            };
            self.claim(&url, n, &page_file, &c.span, &fix);
        }
        // Without a page.dart, a data.dart with a layout.dart beside it is the data of the
        // section that layout wraps; the query parameters it takes are the layout's.
        let section_folder =
            !node.files.contains_key(&Kind::Page) && node.files.contains_key(&Kind::Layout);
        let data_scope = if section_folder {
            Scope::Layout(id)
        } else {
            Scope::Route(id)
        };
        let data = modules
            .get(&Kind::Data)
            .and_then(|m| self.data(m, node, &segs, data_scope));
        let section = data.is_some() && section_folder;
        if data.is_some() && !section && !node.files.contains_key(&Kind::Page) {
            let msg = "data.dart has no page.dart to feed; with a layout.dart beside it, it would be the data of the section below that layout";
            self.diags.error(&node.rel(Kind::Data), None, msg);
        }
        if let (true, Some(d)) = (section, &data) {
            // The section's typed handle (`AccountSection.watch(ref, {...keys})`) takes them as named parameters.
            if let Some(k) = d.keys.iter().find(|k| ROUTE_MEMBERS.contains(&k.as_str())) {
                let msg = format!(
                    "`{k}` can't be a key of a section's data.dart: the section's typed handle has a member called `{k}`; rename it"
                );
                self.diags.error(&node.rel(Kind::Data), None, msg);
            }
        }

        if let Some(m) = modules.get(&Kind::Action) {
            let actions = self.actions(m, node, &segs, data_scope, id, section_folder);
            self.app.routes[id].actions = actions;
        }

        let extra_ty = page_class.as_ref().and_then(|c| {
            c.params
                .iter()
                .find(|p| !p.is_super && p.name == "extra")?
                .ty
                .clone()
        });
        let mut extra = None;
        let page = page_class.map(|c| {
            let cx = BindCx {
                role: Role::Page,
                segs: &segs,
                data: data.as_ref().map(|d| d.ty.as_str()),
                sections: &up.sections,
                file: &page_file,
                covering: None,
                scope: Some(Scope::Route(id)),
            };
            let w = self.bind(&c, &cx);
            if let (Some(ty), Some(src)) = (&extra_ty, node.files.get(&Kind::Page))
                && w.args.iter().any(|a| a.bind == Bind::Extra) {
                    extra = Some(extra::extra_type(&ty.text, src, &page_file, w.import, &id.to_string()));
                }
            if let Some(d) = &data
                && !w.args.iter().any(|a| a.bind == Bind::Data) {
                    self.diags.warn(
                        &page_file,
                        Some(&c.span),
                        if c.function {
                            format!("{} doesn't take what data.dart yields; add a `{} data` parameter", c.display(), d.ty)
                        } else {
                            format!("{} doesn't take what data.dart yields; add `final {} data;` to its constructor", c.name, d.ty)
                        },
                    );
                }
            w
        });

        // route.dart's `caseSensitive` covers this folder and every folder below; its `paths`
        // are this folder's own segment's other spellings, and every route below has them in its URL.
        let mut localized = up.localized.clone();
        let mut case_sensitive = up.case_sensitive;
        if let Some(m) = modules.get(&Kind::Route) {
            let file = node.rel(Kind::Route);
            let spelled = locale::read(
                m,
                &file,
                node.seg.as_ref(),
                url.len().saturating_sub(1),
                self.diags,
            );
            localized.extend(spelled.filter(|l| !l.spellings.is_empty()));
            case_sensitive = self.route_config(m, &file).unwrap_or(up.case_sensitive);
            self.app.routes[id].sibling = self.nest(m, node, up.above.as_ref());
        }
        self.app.routes[id].case_sensitive = case_sensitive;
        self.app.routes[id].localized = localized.clone();

        // loading.dart / error.dart apply here and to every folder below.
        let mut here = Inherited {
            segs: segs.clone(),
            url: url.clone(),
            loading: up.loading.clone(),
            error: up.error.clone(),
            transition: up.transition.clone(),
            root: up.root,
            sections: up.sections.clone(),
            not_found: up.not_found.clone(),
            case_sensitive,
            localized: localized.clone(),
            above: up.above.clone(),
        };
        // A page is what a route below can leave; so is the layout of a folder between.
        let layout_file = node
            .files
            .contains_key(&Kind::Layout)
            .then(|| node.rel(Kind::Layout));
        if node.files.contains_key(&Kind::Page) {
            here.above = Some(PageAbove {
                page: page_file.clone(),
                layout: layout_file,
            });
        } else if let Some(above) = &mut here.above {
            above.layout = above.layout.take().or(layout_file);
        }
        if let (true, Some(d)) = (section, &data) {
            here.sections.push(SectionRef {
                id,
                ty: d.ty.clone(),
                file: node.rel(Kind::Data),
            });
        }
        for (kind, slot) in [
            (Kind::Loading, &mut here.loading),
            (Kind::Error, &mut here.error),
        ] {
            if let Some(m) = modules.get(&kind) {
                let file = node.rel(kind);
                if let Some(class) = self.widget_class(m, &file, kind) {
                    *slot = Some(Fallback {
                        import: self.import(&file),
                        class,
                        file,
                    });
                }
            }
        }
        // Likewise transition.dart, once for the whole subtree.
        if let Some(m) = modules.get(&Kind::Transition) {
            here.transition = self
                .transition(m, node, Kind::Transition, "transition")
                .or(here.transition);
        }
        // present.dart is this route's page alone; navigator.dart is inherited, like transition.dart.
        let present = modules
            .get(&Kind::Present)
            .and_then(|m| self.transition(m, node, Kind::Present, "present"));
        let navigator = modules
            .get(&Kind::Navigator)
            .and_then(|m| self.navigator(m, node));
        if present.is_some() && !node.files.contains_key(&Kind::Page) {
            let msg = "present.dart builds this folder's page, but there is no page.dart here; it is ignored";
            self.diags.warn(&node.rel(Kind::Present), None, msg);
        }
        let present = present.filter(|_| node.files.contains_key(&Kind::Page));
        if navigator == Some(Navigator::Shell) && up.root {
            let msg = "`RouteNavigator.shell` can't go back to a shell below a root-navigator route: go_router only lets its descendants use the root navigator or one above it. Put a layout.dart between the two, or drop this file";
            self.diags.error(&node.rel(Kind::Navigator), None, msg);
        }
        let root = match (navigator, &present) {
            (Some(n), _) => n == Navigator::Root,
            (None, Some(_)) => true,
            (None, None) => up.root,
        };
        // A layout is a navigator of its own: what is below it isn't on the root one.
        here.root = root && !node.files.contains_key(&Kind::Layout);
        let (loading, error) = if data.is_some() {
            let covering = show_dir(&node.dir);
            let bind = |r: &mut Self, f: &Option<Fallback>, role| {
                f.as_ref().map(|f| {
                    // A section's views are built by its layout, which reads the URL for them.
                    let scope = if section {
                        Scope::Layout(id)
                    } else {
                        Scope::Route(id)
                    };
                    let cx = BindCx {
                        role,
                        segs: &segs,
                        data: None,
                        sections: &[],
                        file: &f.file,
                        covering: Some(&covering),
                        scope: Some(scope),
                    };
                    let mut w = r.bind(&f.class, &cx);
                    w.import = f.import;
                    w
                })
            };
            (
                bind(self, &here.loading, Role::Loading),
                bind(self, &here.error, Role::Error),
            )
        } else {
            (None, None)
        };

        let mut layout_extra = None;
        let layout = modules.get(&Kind::Layout).and_then(|m| {
            let file = node.rel(Kind::Layout);
            let c = self.widget_class(m, &file, Kind::Layout)?;
            let cx = BindCx {
                role: Role::Layout,
                segs: &segs,
                data: data.as_ref().filter(|_| section).map(|d| d.ty.as_str()),
                sections: &up.sections,
                file: &file,
                covering: None,
                scope: Some(Scope::Layout(id)),
            };
            let w = self.bind(&c, &cx);
            if w.args.iter().any(|a| a.bind == Bind::Child) && w.args.iter().any(|a| a.bind == Bind::Shell) {
                let msg = format!("{} asks for both a `child` and a navigation shell; a tab layout takes only the `StatefulNavigationShell`", c.display());
                self.diags.error(&file, Some(&c.span), msg);
            }
            layout_extra = extra_of(&c.params, &w.args, node.files.get(&Kind::Layout), &file, w.import, &format!("l{id}"));
            Some(w)
        });
        let guard = modules
            .get(&Kind::Guard)
            .and_then(|m| self.guard(m, node, &segs, id));
        // redirect.dart is a route of its own, named after its path.
        let mut redirect = None;
        if let Some(m) = modules.get(&Kind::Redirect) {
            let file = node.rel(Kind::Redirect);
            if node.files.contains_key(&Kind::Page) {
                self.diags.error(
                    &file,
                    None,
                    "a folder has a page.dart or a redirect.dart, not both",
                );
            } else if let Some((r, span)) = self.redirect(m, node, &segs, id) {
                let n = path_name(&url);
                self.claim(&url, &n, &file, &span, "rename the class");
                (redirect, name, page_span) = (Some(r), Some(n), Some(span));
            }
        }
        // not_found.dart: the root's is the fallback for everything; one further down covers
        // its folder, for unknown URLs under it and for unparsable segments in its routes.
        let mut not_found = up.not_found.clone();
        if let Some(m) = modules.get(&Kind::NotFound) {
            let file = node.rel(Kind::NotFound);
            if let Some(c) = self.widget_class(m, &file, Kind::NotFound) {
                if matches!(node.seg, Some(Seg::CatchAll(..))) {
                    let msg = "a catch-all folder can't have a not_found.dart: it matches every URL below it, so none is unknown";
                    self.diags.error(&file, None, msg);
                }
                let cx = BindCx {
                    role: Role::NotFound,
                    segs: &segs,
                    data: None,
                    sections: &[],
                    file: &file,
                    covering: None,
                    scope: None,
                };
                let w = self.bind(&c, &cx);
                if node.dir.is_empty() {
                    self.app.not_found = Some(w);
                } else {
                    // A `(group)` adds nothing to the URL, so it can't be told apart by it.
                    if !matches!(node.seg, Some(Seg::Group(_))) {
                        let at = pattern(&url);
                        match self.not_found_urls.insert(at.clone(), file.clone()) {
                            Some(prev) => {
                                let msg = format!(
                                    "{at} already has {prev}; (group) folders don't add to the URL, so move or rename one"
                                );
                                self.diags.error(&file, None, msg);
                            }
                            None => self.app.not_founds.push(ScopedNotFound {
                                url: url.clone(),
                                widget: w.clone(),
                                case_sensitive,
                                localized: localized.clone(),
                                file: file.clone(),
                            }),
                        }
                    }
                    not_found = Some(w);
                }
            }
        }

        here.not_found = not_found.clone();

        let has_page = page.is_some();
        let has_route = has_page || redirect.is_some();
        // A section keyed by a query parameter makes every route below it depend on it: it is
        // one of the route's query parameters too, so its typed route can write it.
        if has_route {
            for sec in &up.sections {
                let keys = self.app.routes[sec.id]
                    .data
                    .as_ref()
                    .map(|d| d.keys.clone())
                    .unwrap_or_default();
                for key in keys.iter().filter(|k| !segs.iter().any(|(s, _)| s == *k)) {
                    if let Some((ty, ..)) = self
                        .queries
                        .get(&(Scope::Layout(sec.id), key.clone()))
                        .cloned()
                    {
                        self.declare_query(Scope::Route(id), key, ty, &sec.file, &Span::default());
                    }
                }
            }
        }
        self.app.routes[id].page_span = page_span;
        self.app.routes[id].not_found = not_found;
        self.app.routes[id].meta = modules
            .get(&Kind::Meta)
            .and_then(|m| self.meta(m, node, has_route));
        // A redirect.dart route can carry an `extra` too, which its redirect reads.
        let extra = extra.or_else(|| {
            redirect
                .as_ref()
                .and_then(|g| g.extra.as_ref())
                .map(|e| e.ty.clone())
        });
        if self.app.routes[id].meta.is_some() {
            let literals = modules.get(&Kind::Meta).and_then(|m| {
                m.variables
                    .iter()
                    .find(|v| v.name == "meta")?
                    .ctor_args
                    .clone()
            });
            self.app.routes[id].meta_args = literals.unwrap_or_default();
        }
        self.app.routes[id].extra = extra;
        self.app.routes[id].layout_extra = layout_extra;
        let transition = here
            .transition
            .clone()
            .filter(|_| has_page && present.is_none());
        let shell_transition = here.transition.clone().filter(|_| layout.is_some());
        let r = &mut self.app.routes[id];
        (
            r.segs,
            r.url,
            r.page,
            r.name,
            r.data,
            r.loading,
            r.error,
            r.layout,
            r.guard,
            r.redirect,
            r.transition,
        ) = (
            segs, url, page, name, data, loading, error, layout, guard, redirect, transition,
        );
        (r.present, r.navigator, r.root, r.shell_transition) =
            (present, navigator, root, shell_transition);

        let mut children = vec![];
        let mut with_routes = vec![];
        let mut any_route = has_route;
        for c in &node.children {
            let (cid, routes) = self.node(c, &here);
            children.push(cid);
            if routes {
                with_routes.push(cid);
            }
            any_route |= routes;
        }
        if matches!(node.seg, Some(Seg::CatchAll(..))) && !with_routes.is_empty() {
            let msg = "a catch-all matches the rest of the path, so no route can go below it; move the routes beside it";
            self.diags.error(&node.dir, None, msg);
        }
        let is_tabs = self.app.routes[id]
            .layout
            .as_ref()
            .is_some_and(|w| w.args.iter().any(|a| a.bind == Bind::Shell));
        if is_tabs {
            let tabs = self.tabs(node, modules.get(&Kind::Layout), has_page, &with_routes);
            let options = self.tab_options(
                node,
                modules.get(&Kind::Layout),
                id,
                has_page,
                &with_routes,
                &tabs,
            );
            self.app.routes[id].tabs = Some(tabs);
            self.app.routes[id].container = self.container(node, modules.get(&Kind::Layout));
            if self.app.routes[id].redirect.is_some() {
                let msg = "a tab layout folder can't hold a redirect.dart; put the redirect in a subfolder";
                self.diags.error(&node.rel(Kind::Redirect), None, msg);
            }
            self.app.routes[id].tab_options = options;
        }
        if !is_tabs
            && let Some(f) = modules
                .get(&Kind::Layout)
                .and_then(|m| m.functions.iter().find(|f| f.name == "container"))
        {
            let msg = "container() is only used by a tab layout (one that takes a `StatefulNavigationShell`); it is ignored here";
            self.diags.warn(&node.rel(Kind::Layout), Some(&f.span), msg);
        }
        if self.app.routes[id].guard.is_some() && !any_route {
            let msg = "guard.dart guards no routes: there is no page.dart or redirect.dart at or below this folder";
            self.diags.warn(&node.rel(Kind::Guard), None, msg);
        }
        let bare = !node.files.contains_key(&Kind::Page) && !node.files.contains_key(&Kind::Guard);
        if !any_route && node.children.is_empty() && !node.dir.is_empty() && bare {
            self.diags.warn(
                &node.dir,
                None,
                "folder has no page.dart and no routes below it; skipped",
            );
        }
        self.app.routes[id].children = children;
        (id, any_route)
    }

    /// Records the URL and typed-route name a page or redirect takes, and
    /// reports a clash with an earlier one.
    fn claim(&mut self, url: &[Seg], name: &str, file: &str, span: &Span, fix: &str) {
        // `(a)/x/page.dart` and `(b)/x/page.dart` would both be /x: one error for that,
        // and the route-name clash only when the URLs differ.
        let pattern = pattern(url);
        // An optional catch-all (`/docs/*rest?`) also serves the path without it (`/docs`).
        if let Some((Seg::CatchAll(_, true), parent)) = url.split_last() {
            let at = self::pattern(parent);
            if let Some(prev) = self.patterns.get(&at).filter(|p| p.as_str() != file) {
                let msg = format!(
                    "{at} is served by both {prev} and {file}: an optional catch-all also matches the path without it; use `$$rest` instead, or drop the page above"
                );
                self.diags.error(file, Some(span), msg);
            } else {
                self.patterns.insert(at, file.to_string());
            }
        }
        let same_url = self.patterns.insert(pattern.clone(), file.to_string());
        let same_name = self.route_names.insert(name.to_string(), file.to_string());
        if let Some(prev) = same_url {
            let msg = format!(
                "{pattern} is served by both {prev} and {file}; (group) folders don't add to the URL, so move or rename one"
            );
            self.diags.error(file, Some(span), msg);
        } else if let Some(prev) = same_name {
            self.diags.error(
                file,
                Some(span),
                format!("route name `{name}Route` is already taken by {prev}; {fix}"),
            );
        }
    }

    /// The tabs of a tab layout: the folder's own page, then each subfolder that
    /// holds routes, or the order `const tabs = [...]` in layout.dart gives.
    fn tabs(
        &mut self,
        node: &Node,
        layout: Option<&Module>,
        has_page: bool,
        with_routes: &[usize],
    ) -> Vec<Branch> {
        let file = node.rel(Kind::Layout);
        let name_of = |r: &Self, b: Branch| r.tab_name(b);
        let all = all_tabs(has_page, with_routes);
        let Some(var) = layout.and_then(|m| m.variables.iter().find(|v| v.name == "tabs")) else {
            return all;
        };
        let Some(listed) = &var.strings else {
            self.diags.error(&file, Some(&var.span), "`tabs` must be a list of string literals naming the branches, e.g. `const tabs = ['home', 'search'];`");
            return all;
        };
        let known: Vec<String> = all.iter().map(|&b| name_of(self, b)).collect();
        let mut order: Vec<Branch> = vec![];
        for (name, span) in listed {
            match known.iter().position(|k| k == name) {
                None => {
                    let msg = format!(
                        "`tabs` lists `{name}`, which is not a branch here; the branches are {}",
                        show_list(&known)
                    );
                    self.diags.error(&file, Some(span), msg);
                }
                Some(i) if order.contains(&all[i]) => {
                    self.diags
                        .error(&file, Some(span), format!("`tabs` lists `{name}` twice"));
                }
                Some(i) => order.push(all[i]),
            }
        }
        for (b, name) in all.iter().zip(&known) {
            if !order.contains(b) {
                let msg = format!(
                    "`tabs` is missing the branch `{name}`; list every branch once ({})",
                    show_list(&known)
                );
                self.diags.error(&file, Some(&var.span), msg);
            }
        }
        order
    }

    /// How a tab is named in `tabs` and `tabOptions`: its folder, or `.` for the layout's own page.
    fn tab_name(&self, b: Branch) -> String {
        match b {
            Branch::Own => ".".to_string(),
            Branch::Folder(c) => self.app.routes[c]
                .dir
                .rsplit('/')
                .next()
                .unwrap_or_default()
                .to_string(),
        }
    }

    /// The URLs of the pages inside a tab, with their localized segments.
    fn tab_urls(&self, layout: usize, b: Branch) -> Vec<(&[Seg], &[Localized])> {
        fn walk<'a>(app: &'a App, id: usize, out: &mut Vec<(&'a [Seg], &'a [Localized])>) {
            let r = &app.routes[id];
            if r.page.is_some() {
                out.push((&r.url, &r.localized));
            }
            for &c in &r.children {
                walk(app, c, out);
            }
        }
        let mut out = vec![];
        match b {
            Branch::Own => out.push((
                self.app.routes[layout].url.as_slice(),
                self.app.routes[layout].localized.as_slice(),
            )),
            Branch::Folder(c) => walk(&self.app, c, &mut out),
        }
        out
    }

    /// `const tabOptions = {'search': TabOptions(preload: true)};` in layout.dart,
    /// as the options of each tab in `order`.
    fn tab_options(
        &mut self,
        node: &Node,
        layout: Option<&Module>,
        layout_id: usize,
        has_page: bool,
        with_routes: &[usize],
        order: &[Branch],
    ) -> Vec<BranchOptions> {
        let mut out = vec![BranchOptions::default(); order.len()];
        let Some(var) = layout.and_then(|m| m.variables.iter().find(|v| v.name == "tabOptions"))
        else {
            return out;
        };
        let file = node.rel(Kind::Layout);
        let Some(entries) = &var.objects else {
            let msg = "`tabOptions` must be a map from tab names to `TabOptions(...)` calls with literal arguments, e.g. `const tabOptions = {'search': TabOptions(preload: true)};`";
            self.diags.error(&file, Some(&var.span), msg);
            return out;
        };
        let all = all_tabs(has_page, with_routes);
        let known: Vec<String> = all.iter().map(|&b| self.tab_name(b)).collect();
        let mut seen: Vec<&str> = vec![];
        for e in entries {
            let Some(i) = known.iter().position(|k| *k == e.key) else {
                let msg = format!(
                    "`tabOptions` lists `{}`, which is not a branch here; the branches are {}",
                    e.key,
                    show_list(&known)
                );
                self.diags.error(&file, Some(&e.key_span), msg);
                continue;
            };
            if seen.contains(&e.key.as_str()) {
                self.diags.error(
                    &file,
                    Some(&e.key_span),
                    format!("`tabOptions` lists `{}` twice", e.key),
                );
                continue;
            }
            seen.push(&e.key);
            if e.class != "TabOptions" {
                let msg = format!(
                    "`tabOptions` gives `{}` a `{}`; it takes `TabOptions(...)`",
                    e.key, e.class
                );
                self.diags.error(&file, Some(&e.key_span), msg);
                continue;
            }
            let mut opts = BranchOptions::default();
            for a in &e.args {
                match (a.name.as_str(), &a.value) {
                    ("preload", Lit::Bool(b)) => opts.preload = *b,
                    ("preload", _) => self.diags.error(&file, Some(&a.span), "`preload` must be `true` or `false`"),
                    ("initialLocation", Lit::Str(loc)) => {
                        let path = loc.split(['?', '#']).next().unwrap_or_default();
                        let want: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
                        let urls = self.tab_urls(layout_id, all[i]);
                        let matches = |(u, localized): &(&[Seg], &[Localized])| {
                            let segs: Vec<&Seg> = u.iter().filter(|s| !matches!(s, Seg::Group(_))).collect();
                            let rest = match segs.last() {
                                Some(Seg::CatchAll(_, optional)) => Some(*optional),
                                _ => None,
                            };
                            let fixed = segs.len() - usize::from(rest.is_some());
                            let long_enough = match rest {
                                Some(optional) => want.len() >= fixed + usize::from(!optional),
                                None => want.len() == fixed,
                            };
                            long_enough
                                && segs.iter().take(fixed).zip(&want).enumerate().all(|(i, (s, w))| match s {
                                    // A localized folder is reached by any of its spellings.
                                    Seg::Static(x) => locale::at(localized, i).map_or(x == w, |l| l.alternatives().iter().any(|a| a == w || locale::percent_encode(a) == *w)),
                                    _ => true,
                                })
                        };
                        if !loc.starts_with('/') {
                            let msg = format!("`initialLocation` is an app location and starts with `/`, e.g. `/{}`", loc.trim_start_matches('.'));
                            self.diags.error(&file, Some(&a.span), msg);
                        } else if !urls.iter().any(matches) {
                            let routes: Vec<String> = urls.iter().map(|(u, _)| pattern(u)).collect();
                            let msg = format!(
                                "`initialLocation` `{loc}` is not a route in the `{}` tab; go_router needs one of them: {}",
                                e.key,
                                show_list(&routes)
                            );
                            self.diags.error(&file, Some(&a.span), msg);
                        } else {
                            opts.initial_location = Some(loc.clone());
                        }
                    }
                    ("initialLocation", _) => self.diags.error(&file, Some(&a.span), "`initialLocation` must be a string literal without `$`, e.g. `'/profile/edit'`"),
                    (other, _) => {
                        let msg = format!("`TabOptions` has no `{other}`; it takes `preload` and `initialLocation`");
                        self.diags.error(&file, Some(&a.span), msg);
                    }
                }
            }
            if let Some(at) = order.iter().position(|&b| b == all[i]) {
                out[at] = opts;
            }
        }
        out
    }

    /// `const routeName = 'KycShopName';` in page.dart: the name of the typed route.
    fn route_name_var(&mut self, m: &Module, file: &str) -> Option<String> {
        let v = m.variables.iter().find(|v| v.name == "routeName")?;
        let Some(name) = &v.string else {
            self.diags.error(file, Some(&v.span), "`routeName` must be a plain string literal, e.g. `const routeName = 'KycShopName';`");
            return None;
        };
        if !valid_route_name(name) {
            let msg = format!(
                "`routeName` is `{name}`; it names the route class `{name}Route`, so it must be UpperCamelCase (letters, digits, `_`), e.g. `KycShopName`"
            );
            self.diags.error(file, Some(&v.span), msg);
            return None;
        }
        Some(name.clone())
    }

    /// `const meta = <any const expression>;` in a folder's meta.dart: the manifest
    /// refers to it by import, so it must be a `const` variable called `meta`.
    fn meta(&mut self, m: &Module, node: &Node, has_route: bool) -> Option<String> {
        let file = node.rel(Kind::Meta);
        let mut found = m.variables.iter().filter(|v| v.name == "meta");
        let Some(v) = found.next() else {
            self.diags
                .error(&file, None, "expected `const meta = <a const expression>;`");
            return None;
        };
        if let Some(again) = found.next() {
            self.diags
                .error(&file, Some(&again.span), "`meta` is declared twice");
        }
        if !v.is_const {
            let msg = "`meta` must be `const` (the route manifest lists it in a const list): write `const meta = ...;`";
            self.diags.error(&file, Some(&v.span), msg);
            return None;
        }
        if !has_route {
            let msg = "meta.dart describes a route, but this folder has no page.dart or redirect.dart; it is ignored";
            self.diags.warn(&file, None, msg);
            return None;
        }
        Some(file)
    }

    /// `const navigator = RouteNavigator.root;` in a folder's navigator.dart: the navigator
    /// its routes render on. Read from the source, like `tabs`, so it must be one of the two
    /// enum values, spelled out.
    fn navigator(&mut self, m: &Module, node: &Node) -> Option<Navigator> {
        let file = node.rel(Kind::Navigator);
        let mut found = m.variables.iter().filter(|v| v.name == "navigator");
        let Some(v) = found.next() else {
            self.diags.error(
                &file,
                None,
                "expected `const navigator = RouteNavigator.root;` (or `RouteNavigator.shell`)",
            );
            return None;
        };
        if let Some(again) = found.next() {
            self.diags
                .error(&file, Some(&again.span), "`navigator` is declared twice");
        }
        if !v.is_const {
            self.diags.error(
                &file,
                Some(&v.span),
                "`navigator` must be `const`: write `const navigator = RouteNavigator.root;`",
            );
            return None;
        }
        // An import prefix (`fsp.RouteNavigator.root`) is fine.
        let parts: Vec<&str> = v.value.as_deref().unwrap_or_default().split('.').collect();
        let ident = |p: &str| {
            p.chars()
                .next()
                .is_some_and(|c| c.is_alphabetic() || c == '_')
                && p.chars().all(|c| c.is_alphanumeric() || c == '_')
        };
        let value = match parts.as_slice() {
            ["RouteNavigator", which] => Some(*which),
            [prefix, "RouteNavigator", which] if ident(prefix) => Some(*which),
            _ => None,
        };
        match value {
            Some("root") => Some(Navigator::Root),
            Some("shell") => Some(Navigator::Shell),
            _ => {
                let msg = "`navigator` must be `RouteNavigator.root` or `RouteNavigator.shell`, written out: fsp reads it from the source";
                self.diags.error(&file, Some(&v.span), msg);
                None
            }
        }
    }

    /// `Widget container(BuildContext context, StatefulNavigationShell shell, List<Widget> children)`
    /// in a tab layout.dart: the `navigatorContainerBuilder` of its `StatefulShellRoute`. The
    /// parameters are positional with fixed types (their names mean nothing here).
    fn container(&mut self, node: &Node, layout: Option<&Module>) -> bool {
        let Some(f) = layout.and_then(|m| m.functions.iter().find(|f| f.name == "container"))
        else {
            return false;
        };
        let file = node.rel(Kind::Layout);
        let want: [(&str, &[&str]); 3] = [
            ("the BuildContext", &["BuildContext"]),
            ("the StatefulNavigationShell", &["StatefulNavigationShell"]),
            (
                "the branch navigators, a List<Widget>",
                &["List<Widget>", "Iterable<Widget>"],
            ),
        ];
        let signature = "container() takes three positional parameters: `Widget container(BuildContext context, StatefulNavigationShell shell, List<Widget> children)`";
        if f.params.len() != 3
            || f.params
                .iter()
                .any(|p| p.named || !p.required || p.is_super)
        {
            self.diags.error(&file, Some(&f.span), signature);
            return false;
        }
        let mut ok = true;
        for (p, (gets, accepts)) in f.params.iter().zip(want) {
            match &p.ty {
                None => {
                    self.diags.error(
                        &file,
                        Some(&p.span),
                        format!("give `{}` a type: it gets {gets}", p.name),
                    );
                    ok = false;
                }
                Some(ty) if !accepts.contains(&bare_type(&ty.text)) => {
                    let msg = format!("`{}` gets {gets}, but it's declared {}", p.name, ty.text);
                    self.diags.error(&file, Some(&p.span), msg);
                    ok = false;
                }
                Some(_) => {}
            }
        }
        if f.ret
            .as_ref()
            .is_some_and(|r| bare_type(&r.text) != "Widget")
        {
            self.diags.error(
                &file,
                Some(&f.span),
                "container() must return a Widget: the container of the branch navigators",
            );
            ok = false;
        }
        ok
    }

    /// `const caseSensitive = false;` in a folder's route.dart: whether paths match by case
    /// in this folder and below. It is read from the source, so it must be a `true` or `false`
    /// literal.
    fn route_config(&mut self, m: &Module, file: &str) -> Option<bool> {
        let mut found = m.variables.iter().filter(|v| v.name == "caseSensitive");
        let Some(v) = found.next() else {
            // A route.dart may hold only `paths`, or only `nest`.
            if !m
                .variables
                .iter()
                .any(|v| v.name == "paths" || v.name == "nest")
            {
                self.diags.error(file, None, "expected `const caseSensitive = false;` (or `true`), or `const paths = {'fr': 'produits'};`");
            }
            return None;
        };
        if let Some(again) = found.next() {
            self.diags
                .error(file, Some(&again.span), "`caseSensitive` is declared twice");
        }
        if v.boolean.is_none() {
            let msg = "`caseSensitive` must be a `true` or `false` literal: fsp reads it from the source, it doesn't run it";
            self.diags.error(file, Some(&v.span), msg);
        }
        v.boolean
    }

    /// `const nest = false;` in a folder's route.dart: its route is not a child of the page
    /// above but a sibling of it, with a compound path. Returns whether it is, and reports a
    /// declaration that can't be honoured: it is read from the source, so it must be a `true`
    /// or `false` literal, and `true` (the default) says nothing.
    fn nest(&mut self, m: &Module, node: &Node, above: Option<&PageAbove>) -> bool {
        let file = node.rel(Kind::Route);
        let mut found = m.variables.iter().filter(|v| v.name == "nest");
        let Some(v) = found.next() else {
            return false;
        };
        if let Some(again) = found.next() {
            self.diags
                .error(&file, Some(&again.span), "`nest` is declared twice");
        }
        match v.boolean {
            None => {
                let msg = "`nest` must be a `true` or `false` literal: fsp reads it from the source, it doesn't run it";
                self.diags.error(&file, Some(&v.span), msg);
                return false;
            }
            Some(true) => return false,
            Some(false) => {}
        }
        let error = |r: &mut Self, msg: String| r.diags.error(&file, Some(&v.span), msg);
        if node.dir.is_empty() {
            let msg = "`nest = false` takes a route out of the page above it, and the app folder has nothing above it; drop it".to_string();
            error(self, msg);
            return false;
        }
        if matches!(node.seg, Some(Seg::Group(_))) {
            let msg = "`nest = false` is about a folder's own route, and a `(group)` has none: it adds nothing to the URL, so what is in it nests under the page above the group and not under a page beside it. To make a sibling with a compound path without this file, repeat the segment under a group: `(group)/refund/confirm/page.dart`".to_string();
            error(self, msg);
            return false;
        }
        if !node.files.contains_key(&Kind::Page) && !node.files.contains_key(&Kind::Redirect) {
            let msg = "`nest = false` is about this folder's own route, and it has no page.dart or redirect.dart; put it in the route.dart of each folder whose route should not nest".to_string();
            error(self, msg);
            return false;
        }
        let Some(above) = above else {
            let msg = "`nest = false` takes this route out of the page above it, and there is no page.dart above this folder: it is not nested under anything, so drop it".to_string();
            error(self, msg);
            return false;
        };
        if let Some(layout) = &above.layout {
            let msg = format!(
                "`nest = false` takes this route out of `{}`, and `{layout}` sits in the folders it leaves, so the route would escape that layout's shell. Move the layout above that page's folder, or drop `nest = false`",
                above.page
            );
            error(self, msg);
            return false;
        }
        true
    }

    /// The one public widget class a view file exports, or the top-level function named
    /// after the file (`Widget page(...)`) that builds the widget instead.
    fn widget_class(&mut self, m: &Module, file: &str, kind: Kind) -> Option<Class> {
        let public: Vec<&Class> = m.classes.iter().filter(|c| c.is_public()).collect();
        let widgets: Vec<&Class> = public
            .iter()
            .copied()
            .filter(|c| {
                c.superclass
                    .as_deref()
                    .is_some_and(|s| s.ends_with("Widget"))
            })
            .collect();
        let fns: Vec<&Function> = m
            .functions
            .iter()
            .filter(|f| view_fn_names(kind).contains(&f.name.as_str()))
            .collect();
        if let Some(f) = fns.first() {
            if let Some(other) = fns.get(1) {
                let msg = format!(
                    "both `{}()` and `{}()` are here; keep one",
                    f.name, other.name
                );
                self.diags.error(file, Some(&other.span), msg);
                return None;
            }
            if !widgets.is_empty() {
                let names: Vec<&str> = widgets.iter().map(|c| c.name.as_str()).collect();
                let msg = format!(
                    "found the widget class {} and the function `{}()`; a view file has one or the other. Keep the class, or move it to its own file and build it from the function",
                    names.join(", "),
                    f.name
                );
                self.diags.error(file, Some(&f.span), msg);
                return None;
            }
            let ret = f.ret.as_ref().map(|t| t.text.as_str());
            if ret.is_some_and(|t| t == "void" || t.starts_with("Future")) {
                let msg = format!(
                    "`{}()` must return a Widget, not {}",
                    f.name,
                    ret.unwrap_or_default()
                );
                self.diags.error(file, Some(&f.span), msg);
                return None;
            }
            return Some(f.as_view());
        }
        match (public.as_slice(), widgets.as_slice()) {
            ([one], _) | (_, [one]) => Some((*one).clone()),
            ([], _) => {
                self.diags
                    .error(file, None, "expected a public widget class");
                None
            }
            (many, _) => {
                let names: Vec<&str> = many.iter().map(|c| c.name.as_str()).collect();
                self.diags.error(
                    file,
                    Some(&many[1].span),
                    format!("expected one public widget class, found {}; make the others private (`_Name`)", names.join(", ")),
                );
                None
            }
        }
    }

    /// Works out every constructor argument of `class` for this use of it.
    fn bind(&mut self, class: &Class, cx: &BindCx) -> Widget {
        let mut args = vec![];
        let mut positional_gap = false;
        for p in &class.params {
            if p.is_super {
                if p.required && p.name != "key" {
                    self.diags.error(
                        cx.file,
                        Some(&p.span),
                        format!("can't fill `super.{}`; only `super.key` is allowed", p.name),
                    );
                }
                continue;
            }
            let bind = if !p.named && positional_gap {
                None
            } else {
                by_name(&p.name, cx)
                    .or_else(|| {
                        // Optional, and nullable or a List: it comes from the query. (Of a type that isn't
                        // a plain one, it is when that is an enum: other optional parameters are left alone.)
                        let (scope, ty) = (cx.scope.filter(|_| !p.required)?, p.ty.as_ref()?);
                        let QueryTy::Is(qty) = self.query_typed(ty, cx.file, None) else {
                            return None;
                        };
                        self.declare_query(scope, &p.name, *qty, cx.file, &p.span)
                            .then(|| Bind::Query(p.name.clone()))
                    })
                    .or_else(|| by_type(p.ty.as_ref()?, cx))
                    .or_else(|| self.data_by_type(p, cx))
            };
            let Some(bind) = bind else {
                if p.required {
                    let mut msg = unfillable(&p.name, cx);
                    if class.function && (p.name == "ref" || p.name == "context") {
                        msg.push_str("; a view function is a plain function with no BuildContext or ref: put hooks and `ref` in the widget it returns");
                    }
                    self.diags.error(cx.file, Some(&p.span), msg);
                } else if !p.named {
                    positional_gap = true;
                }
                continue;
            };
            if let Some(ty) = &p.ty
                && let Some(msg) = mismatch(&p.name, &bind, ty)
            {
                self.diags.error(cx.file, Some(&p.span), msg);
            }
            if let (Bind::Section(sid), Some(ty)) = (&bind, &p.ty) {
                let sec = cx
                    .sections
                    .iter()
                    .find(|s| s.id == *sid)
                    .expect("a section bind names a section above");
                if !ty.is(&sec.ty) {
                    let msg = format!(
                        "`{}` is {} but the section's data.dart ({}) yields {}",
                        p.name, ty.text, sec.file, sec.ty
                    );
                    self.diags.error(cx.file, Some(&p.span), msg);
                }
            }
            match (&bind, &p.ty, cx.data) {
                (Bind::Segment(name), Some(ty), _) => {
                    let folder = cx
                        .segs
                        .iter()
                        .find(|(n, _)| n == name)
                        .map(|(_, f)| *f)
                        .unwrap();
                    self.constraints.push(Constraint {
                        folder,
                        name: name.clone(),
                        ty: ty.clone(),
                        file: cx.file.to_string(),
                        span: p.span.clone(),
                    });
                }
                (Bind::Data, Some(ty), Some(want)) if !ty.is(want) => {
                    self.diags.error(
                        cx.file,
                        Some(&p.span),
                        format!("`{}` is {} but data.dart yields {want}", p.name, ty.text),
                    );
                }
                _ => {}
            }
            args.push(Arg {
                name: p.name.clone(),
                named: p.named,
                bind,
            });
        }
        let import = self.import(cx.file);
        Widget {
            import,
            class: class.name.clone(),
            args,
            is_const: class.is_const,
        }
    }

    /// A parameter whose type is one a data.dart yields: the route's own, or a section
    /// above. Two of them yielding the same type are ambiguous.
    fn data_by_type(&mut self, p: &dart::Param, cx: &BindCx) -> Option<Bind> {
        if !matches!(cx.role, Role::Page | Role::Layout) {
            return None;
        }
        let ty = p.ty.as_ref()?;
        let own = (cx.data == Some(ty.text.as_str())).then_some(Bind::Data);
        let mut found: Vec<(Bind, String)> = own
            .into_iter()
            .map(|b| (b, "this folder's data.dart".to_string()))
            .collect();
        for s in cx.sections.iter().filter(|s| ty.is(&s.ty)) {
            found.push((Bind::Section(s.id), format!("the section's {}", s.file)));
        }
        if found.len() > 1 {
            let names: Vec<&str> = found.iter().map(|(_, n)| n.as_str()).collect();
            let msg = format!(
                "`{}` is {}, which {} all yield; name the parameter `data` to get the nearest, or give one of them another type",
                p.name,
                ty.text,
                names.join(" and ")
            );
            self.diags.error(cx.file, Some(&p.span), msg);
        }
        found.into_iter().next().map(|(b, _)| b)
    }

    /// A query parameter's type: a plain one, or an enum's (`Sort?`, `List<Sort>`). With `strict`
    /// (the parameter and where to point at: a `data()`'s or a guard's, which can't be anything
    /// else) a type that should be an enum but can't be found is an error.
    fn query_typed(&mut self, ty: &Ty, file: &str, strict: Option<(&Span, &str)>) -> QueryTy {
        if let Some(q) = query_type(ty) {
            return QueryTy::Is(Box::new(Typed::plain(q)));
        }
        let Some((base, list)) = enums::query_shape(&ty.text) else {
            return QueryTy::Isnt;
        };
        let whole = if list {
            format!("List<{base}>")
        } else {
            format!("{base}?")
        };
        self.tags += 1;
        let tag = format!("q{}", self.tags);
        let err = strict.map(|(span, name)| {
            let fallback = if list {
                format!("List<String> {name}")
            } else {
                format!("String? {name}")
            };
            (
                span,
                format!("{} {name}", ty.text),
                "a query parameter",
                fallback,
            )
        });
        match self.enum_typed(
            base,
            &whole,
            file,
            &tag,
            err.as_ref()
                .map(|(s, d, w, f)| (*s, d.as_str(), *w, f.as_str())),
        ) {
            Some(t) => QueryTy::Is(Box::new(t)),
            None if strict.is_some() => QueryTy::Broken,
            None => QueryTy::Isnt,
        }
    }

    /// The enum `base` as the file `file` names it, as the type `whole` (`base`, nullable or in a
    /// list). `None` when it isn't one fsp can find or name; `err` (where to point at, the
    /// parameter as written, what it is, what to write instead) says so, when given.
    fn enum_typed(
        &mut self,
        base: &str,
        whole: &str,
        file: &str,
        tag: &str,
        err: Option<(&Span, &str, &str, &str)>,
    ) -> Option<Typed> {
        let src = *self.sources.get(file)?;
        let lookup = self.libs.find(file, src, base);
        if let Lookup::Found(found) = lookup {
            let import = self.import(file);
            let spelled = extra::extra_type(whole, src, file, import, tag);
            let key = whole.replacen(base, &found.key(), 1);
            let decl = Some(found.decl.clone());
            return Some(Typed {
                spelled: spelled.ty.clone(),
                key,
                shown: whole.to_string(),
                import: Some(spelled),
                decl,
            });
        }
        if let Some((span, decl, what, fallback)) = err {
            let msg = match lookup {
                Lookup::Private => format!(
                    "`{decl}`: `{base}` is private to its file, so the generated file can't name it; make the enum public"
                ),
                _ => format!(
                    "`{decl}`: no enum called `{base}` in this file or the files it imports or exports under this package's lib/; {what} can only be a String, int, double or bool, or an enum. If `{base}` is declared elsewhere, take a `{fallback}` and parse it in the page"
                ),
            };
            self.diags.error(file, Some(span), msg);
        }
        None
    }

    /// Lists the type of an enum segment or query parameter for the generated file to import.
    fn use_type(&mut self, t: &Typed) {
        if let Some(import) = &t.import {
            self.app
                .type_names
                .insert(t.spelled.clone(), extra::unprefixed(&import.source));
            self.app.enum_types.push(import.clone());
        }
    }

    fn declare_query(
        &mut self,
        scope: Scope,
        name: &str,
        ty: Typed,
        file: &str,
        span: &Span,
    ) -> bool {
        if matches!(scope, Scope::Route(_)) && ROUTE_MEMBERS.contains(&name) {
            let msg = format!(
                "`{name}` can't be a query parameter: the typed route class has a member called `{name}`; rename it"
            );
            self.diags.error(file, Some(span), msg);
            return false;
        }
        let key = (scope, name.to_string());
        match self.queries.get(&key) {
            None => {
                self.use_type(&ty);
                self.queries
                    .insert(key.clone(), (ty, file.to_string(), span.line));
                self.query_order.push(key);
                true
            }
            Some((t0, f0, l0)) if t0.key != ty.key => {
                let msg = format!(
                    "`?{name}` is {} in {f0}:{l0} but {} here{}",
                    t0.shown,
                    ty.shown,
                    t0.same_name_as(&ty)
                );
                self.diags.error(file, Some(span), msg);
                false
            }
            _ => true,
        }
    }

    /// A named parameter of `data()`, `guard()` or a provider's family record:
    /// a segment, or a query parameter.
    fn url_param(
        &mut self,
        file: &str,
        p: &dart::Param,
        segs: &[(String, usize)],
        scope: Scope,
        what: &str,
    ) -> Option<String> {
        if !p.named {
            self.diags.error(
                file,
                Some(&p.span),
                format!(
                    "{what} takes segments as named parameters, e.g. `{{required int {}}}`",
                    p.name
                ),
            );
            return None;
        }
        let Some((_, folder)) = segs.iter().find(|(n, _)| n == &p.name) else {
            let qty = match p
                .ty
                .as_ref()
                .filter(|_| !p.required)
                .map(|t| self.query_typed(t, file, Some((&p.span, &p.name))))
            {
                Some(QueryTy::Is(t)) => *t,
                Some(QueryTy::Broken) => return None,
                _ => {
                    let hooks = what == "guard()" || what == "redirect()";
                    // Already optional with a type, so "make it optional and nullable" would
                    // send the reader round in a circle: it is the type that isn't a query type.
                    let hint = match p.ty.as_ref().filter(|_| !p.required) {
                        Some(t) => format!(
                            "if `{}` is meant as a query parameter, its type `{}` isn't one: use a nullable String, int, double or bool, an enum, or a List of those",
                            p.name, t.text
                        ),
                        None => format!(
                            "for a query parameter make it optional and nullable, e.g. `String? {}`",
                            p.name
                        ),
                    };
                    let msg = format!(
                        "`{}` isn't a segment of this path ({}){}; {hint}",
                        p.name,
                        show_segs(segs),
                        if hooks {
                            format!(
                                " at or above its folder; {what} can also take `Uri uri` and `extra`"
                            )
                        } else {
                            String::new()
                        },
                    );
                    self.diags.error(file, Some(&p.span), msg);
                    return None;
                }
            };
            return self
                .declare_query(scope, &p.name, qty, file, &p.span)
                .then(|| p.name.clone());
        };
        match &p.ty {
            Some(ty) => self.constraints.push(Constraint {
                folder: *folder,
                name: p.name.clone(),
                ty: ty.clone(),
                file: file.to_string(),
                span: p.span.clone(),
            }),
            None => self.diags.error(
                file,
                Some(&p.span),
                format!("give `{}` a type (String, int, double or bool)", p.name),
            ),
        }
        Some(p.name.clone())
    }

    fn data(
        &mut self,
        m: &Module,
        node: &Node,
        segs: &[(String, usize)],
        scope: Scope,
    ) -> Option<Data> {
        let file = node.rel(Kind::Data);
        if let Some(f) = m.functions.iter().find(|f| f.name == "data") {
            if let Some(ty) = f.ret.as_ref().and_then(selected_value) {
                return self.selector(f, ty, &file, segs, scope);
            }
            if f.ret
                .as_ref()
                .is_some_and(|r| r.generic().0 == "ProviderListenable")
            {
                let msg = "a data() that selects a provider must return `ProviderListenable<AsyncValue<T>>`, so the page can be given a `T`";
                self.diags.error(&file, Some(&f.span), msg);
                return None;
            }
            match f.params.first() {
                Some(p) if !p.named && p.ty.as_ref().is_some_and(|t| t.is("Ref")) => {}
                _ => self
                    .diags
                    .error(&file, Some(&f.span), "data() must take `Ref ref` first"),
            }
            let mut keys = vec![];
            for p in f.params.iter().skip(1) {
                keys.extend(self.url_param(&file, p, segs, scope, "data()"));
            }
            let Some(ret) = &f.ret else {
                self.diags.error(
                    &file,
                    Some(&f.span),
                    "data() needs an explicit return type (Future<T>, Stream<T> or T)",
                );
                return None;
            };
            let (head, args) = ret.generic();
            let (stream, ty) = match (head, args.as_slice()) {
                ("Future" | "FutureOr", [t]) => (false, t.to_string()),
                ("Stream", [t]) => (true, t.to_string()),
                _ => (false, ret.text.clone()),
            };
            let keys = in_path_order(keys, segs);
            let import = self.import(&file);
            return Some(Data {
                import,
                provider: false,
                selector: false,
                stream,
                ty,
                record: keys.len() > 1,
                keys,
            });
        }

        if let Some(v) = m.variables.iter().find(|v| v.name == "data") {
            const KINDS: &str =
                "FutureProvider, StreamProvider, AsyncNotifierProvider or StreamNotifierProvider";
            let Some(call) = &v.call else {
                self.diags
                    .error(&file, Some(&v.span), format!("`data` must be a {KINDS}"));
                return None;
            };
            let (value_ix, stream) = match call.chain[0].as_str() {
                "FutureProvider" => (0, false),
                "StreamProvider" => (0, true),
                "AsyncNotifierProvider" => (1, false),
                "StreamNotifierProvider" => (1, true),
                other => {
                    self.diags.error(
                        &file,
                        Some(&v.span),
                        format!("`data` must be a {KINDS}, not {other}"),
                    );
                    return None;
                }
            };
            let family = call.chain.iter().any(|c| c == "family");
            let want = value_ix + 1 + usize::from(family);
            if call.type_args.len() != want {
                let example = match (value_ix, family) {
                    (0, false) => "FutureProvider<Product>",
                    (0, true) => "FutureProvider.family<Product, int>",
                    (_, false) => "AsyncNotifierProvider<ProductNotifier, Product>",
                    (_, true) => "AsyncNotifierProvider.family<ProductNotifier, Product, int>",
                };
                self.diags.error(
                    &file,
                    Some(&v.span),
                    format!("give the provider its type arguments, e.g. `{example}`"),
                );
                return None;
            }
            let ty = call.type_args[value_ix].text.clone();
            let (mut keys, mut record) = (vec![], false);
            if family {
                let arg = &call.type_args[want - 1];
                if let Some(fields) = &arg.record {
                    record = true;
                    for (name, fty) in fields {
                        if !segs.iter().any(|(n, _)| n == name) {
                            // A provider you write is keyed by what the path holds; the
                            // generated one is the only one that can carry a query parameter.
                            let msg = format!(
                                "`{name}` isn't a segment of this path ({}); a provider you write can be keyed by segments only. \
                                 To use a query parameter, write `Future<{ty}> data(Ref ref, {{{fty} {name}}})` instead, or select your provider from `data()`",
                                show_segs(segs),
                                fty = if fty.text.ends_with('?') {
                                    fty.text.clone()
                                } else {
                                    format!("{}?", fty.text)
                                },
                            );
                            self.diags.error(&file, Some(&v.span), msg);
                            continue;
                        }
                        let p = dart::Param {
                            name: name.clone(),
                            ty: Some(fty.clone()),
                            named: true,
                            required: true,
                            is_super: false,
                            span: v.span.clone(),
                        };
                        keys.extend(self.url_param(&file, &p, segs, scope, "the family argument"));
                    }
                } else if let [(name, folder)] = segs {
                    keys.push(name.clone());
                    self.constraints.push(Constraint {
                        folder: *folder,
                        name: name.clone(),
                        ty: arg.clone(),
                        file: file.clone(),
                        span: v.span.clone(),
                    });
                } else {
                    self.diags.error(
                        &file,
                        Some(&v.span),
                        format!(
                            "this path has {} segments, so the family argument must be a record naming the ones it uses, e.g. `({{int id}})`",
                            segs.len()
                        ),
                    );
                }
            }
            let keys = in_path_order(keys, segs);
            if let Some((name, _)) = segs
                .iter()
                .find(|(n, f)| keys.contains(n) && self.app.is_catch_all(*f))
            {
                let msg = format!(
                    "`{name}` is a catch-all, a List that a provider can't be keyed by (lists compare by identity); \
                     write `Future<{ty}> data(Ref ref, {{required List<T> {name}}})` (T being the parts' type) and fespalier keys it by the path"
                );
                self.diags.error(&file, Some(&v.span), msg);
            }
            let import = self.import(&file);
            return Some(Data {
                import,
                provider: true,
                selector: false,
                stream,
                ty,
                keys,
                record,
            });
        }

        self.diags.error(
            &file,
            None,
            "expected `Future<T> data(Ref ref, {...segments})`, `ProviderListenable<AsyncValue<T>> data({...segments})` or `final data = FutureProvider<T>(...)`",
        );
        None
    }

    /// `ProviderListenable<AsyncValue<T>> data({...segments}) => productProvider(id)`:
    /// selects a provider that already exists. It takes what the function form takes,
    /// minus the `Ref`: it returns the provider, it doesn't read one.
    fn selector(
        &mut self,
        f: &dart::Function,
        ty: String,
        file: &str,
        segs: &[(String, usize)],
        scope: Scope,
    ) -> Option<Data> {
        let mut keys = vec![];
        for p in &f.params {
            if !p.named && p.ty.as_ref().is_some_and(|t| t.is("Ref")) {
                let msg = "a data() that returns a `ProviderListenable` takes no `Ref`: it selects the provider (`=> productProvider(id)`), it doesn't read one";
                self.diags.error(file, Some(&p.span), msg);
                continue;
            }
            keys.extend(self.url_param(file, p, segs, scope, "data()"));
        }
        let keys = in_path_order(keys, segs);
        let import = self.import(file);
        Some(Data {
            import,
            provider: false,
            selector: true,
            stream: false,
            ty,
            record: keys.len() > 1,
            keys,
        })
    }

    /// `Future<T> action(Ref ref, {...segments, required Input input})`: every public
    /// top-level function of an action.dart that takes a `Ref` first is an action (one called
    /// `action` is always one, so a missing `Ref` is reported on it).
    fn actions(
        &mut self,
        m: &Module,
        node: &Node,
        segs: &[(String, usize)],
        scope: Scope,
        id: usize,
        section_folder: bool,
    ) -> Vec<Action> {
        let file = node.rel(Kind::Action);
        if !node.files.contains_key(&Kind::Page) && !section_folder {
            let msg = "action.dart has nothing to write to: put it beside a page.dart (the route it belongs to) or, in a folder without a page, beside the layout.dart of a section";
            self.diags.error(&file, None, msg);
            return vec![];
        }
        let takes_ref = |f: &Function| {
            f.params
                .first()
                .is_some_and(|p| !p.named && p.ty.as_ref().is_some_and(|t| t.is("Ref")))
        };
        let functions: Vec<&Function> = m
            .functions
            .iter()
            .filter(|f| !f.name.starts_with('_') && (f.name == "action" || takes_ref(f)))
            .collect();
        if functions.is_empty() {
            let msg = "expected `Future<T> action(Ref ref, {...segments, required Input input})`; any public function that takes a `Ref` first is an action";
            self.diags.error(&file, None, msg);
            return vec![];
        }
        let listed = self.invalidates(m, &file);
        self.listed.push((id, listed));
        let src = node.files[&Kind::Action].as_str();
        let mut out = vec![];
        for f in functions {
            let what = format!("{}()", f.name);
            let has_ref = takes_ref(f);
            if !has_ref {
                let msg = format!("{what} must take `Ref ref` first");
                self.diags.error(&file, Some(&f.span), msg);
            }
            let mut keys = vec![];
            let mut input = None;
            for p in f.params.iter().skip(usize::from(has_ref)) {
                if p.name != "input" {
                    keys.extend(self.url_param(&file, p, segs, scope, &what));
                    continue;
                }
                let msg = if !p.named {
                    Some(format!(
                        "{what} takes `input` as a named parameter, e.g. `{{required Input input}}`"
                    ))
                } else if !p.required {
                    Some(format!(
                        "`input` of {what} must be `required`: there is nothing to run without it"
                    ))
                } else if p.ty.is_none() {
                    Some("give `input` a type: it is what the action is called with".to_string())
                } else {
                    None
                };
                match (msg, &p.ty) {
                    (Some(msg), _) => self.diags.error(&file, Some(&p.span), msg),
                    (None, ty) => input = ty.clone(),
                }
            }
            let input = match input {
                Some(ty) => Some(ty),
                None if f.params.iter().any(|p| p.name == "input") => None,
                None => {
                    let msg = format!(
                        "{what} needs an `input` parameter, the value it writes: `{{required Input input}}`; segments and query parameters are its other named parameters"
                    );
                    self.diags.error(&file, Some(&f.span), msg);
                    None
                }
            };
            if matches!(scope, Scope::Layout(_))
                && let Some(k) = keys.iter().find(|k| ROUTE_MEMBERS.contains(&k.as_str()))
            {
                let msg = format!(
                    "`{k}` can't be a key of a section's action: the section's typed handle has a member called `{k}`; rename it"
                );
                self.diags.error(&file, Some(&f.span), msg);
            }
            let flow = self.action_flow(f, &file);
            let (Some(input), Some(flow)) = (input, flow) else {
                continue;
            };
            let import = self.import(&file);
            out.push(Action {
                name: f.name.clone(),
                import,
                flow,
                keys: in_path_order(keys, segs),
                input: extra::extra_type(
                    &input.text,
                    src,
                    &file,
                    import,
                    &format!("a{id}_{}", f.name),
                ),
                invalidates: vec![],
                span: f.span.clone(),
            });
        }
        out
    }

    /// What an action returns: `Future<T>`, `FutureOr<T>` or a plain `T`.
    fn action_flow(&mut self, f: &Function, file: &str) -> Option<Flow> {
        let Some(ret) = &f.ret else {
            let msg = format!(
                "{}() needs an explicit return type (Future<T>, FutureOr<T> or T)",
                f.name
            );
            self.diags.error(file, Some(&f.span), msg);
            return None;
        };
        let (head, args) = ret.generic();
        match (head, args.len()) {
            ("Future", 1) => Some(Flow::Future),
            ("FutureOr", 1) => Some(Flow::FutureOr),
            ("Future" | "FutureOr", _) => {
                let msg = format!(
                    "give the {head} of {}() its type argument, e.g. `{head}<Refund>`",
                    f.name
                );
                self.diags.error(file, Some(&f.span), msg);
                None
            }
            ("Stream", _) => {
                let msg = format!(
                    "{}() returns a Stream, but an action is one write with one result: return a Future<T>, FutureOr<T> or T",
                    f.name
                );
                self.diags.error(file, Some(&f.span), msg);
                None
            }
            _ => Some(Flow::Sync),
        }
    }

    /// `const invalidates = [OrderRoute, TeamsTeamIdSection];`: the names it lists, `None` when
    /// the file has none (the default set) and the empty list for `<Object>[]`.
    fn invalidates(&mut self, m: &Module, file: &str) -> Option<Vec<Named>> {
        let v = m.variables.iter().find(|v| v.name == "invalidates")?;
        if let (Some(names), true) = (&v.names, v.is_const) {
            return Some(names.clone());
        }
        let msg = "`invalidates` must be a const list literal of typed routes and sections: `const invalidates = [OrderRoute, TeamsTeamIdSection];`, or `const invalidates = <Object>[];` for none";
        self.diags.error(file, Some(&v.span), msg);
        // Without a usable list the default stays: the actions still work.
        None
    }

    /// Settles what each action invalidates, and what its helpers are called, once every route,
    /// section and query parameter is known.
    fn settle_actions(&mut self) {
        let listed = std::mem::take(&mut self.listed);
        // The names `invalidates` can use: a route's class and a section's handle.
        let mut targets: HashMap<String, usize> = HashMap::new();
        for (id, r) in self.app.routes.iter().enumerate() {
            if let (true, Some(name)) = (r.is_route(), &r.name) {
                targets.entry(format!("{name}Route")).or_insert(id);
            }
            if r.has_section_handle() {
                targets.entry(section_name(&r.dir)).or_insert(id);
            }
        }
        for (rid, names) in listed {
            let file = format!("{}action.dart", folder_prefix(&self.app.routes[rid].dir));
            let own = self.app.routes[rid].data.is_some().then_some(rid);
            let (ids, explicit) = match names {
                None => (
                    self.app.routes[rid]
                        .sections
                        .iter()
                        .copied()
                        .chain(own)
                        .collect::<Vec<_>>(),
                    false,
                ),
                Some(names) => {
                    let mut ids = vec![];
                    for (n, span) in names {
                        let Some(&t) = targets.get(&n) else {
                            let msg = format!(
                                "`invalidates` names `{n}`, which is neither a typed route nor a section handle; list classes like `OrderRoute` or `TeamsTeamIdSection`"
                            );
                            self.diags.error(&file, Some(&span), msg);
                            continue;
                        };
                        if self.app.routes[t].data.is_none() {
                            let msg = format!(
                                "`invalidates` names `{n}`, which has no data.dart: there is nothing to invalidate"
                            );
                            self.diags.error(&file, Some(&span), msg);
                        } else if !ids.contains(&t) {
                            ids.push(t);
                        }
                    }
                    (ids, true)
                }
            };
            for i in 0..self.app.routes[rid].actions.len() {
                let ok = self.action_keys(rid, i, &ids, explicit, &file);
                let a = &mut self.app.routes[rid].actions[i];
                a.invalidates = if ok { ids.clone() } else { vec![] };
            }
        }
        self.action_names();
    }

    /// Whether the action takes every key of the `data.dart` it must invalidate, with the type
    /// that data has for it: a family is invalidated for the key the action was called with.
    fn action_keys(
        &mut self,
        rid: usize,
        i: usize,
        ids: &[usize],
        explicit: bool,
        file: &str,
    ) -> bool {
        let a = self.app.routes[rid].actions[i].clone();
        let mine = self.key_types(&self.app.routes[rid]);
        let mut ok = true;
        for &t in ids {
            let target = &self.app.routes[t];
            let Some(d) = &target.data else { continue };
            let theirs = self.key_types(target);
            let data_file = format!("{}data.dart", folder_prefix(&target.dir));
            for k in &d.keys {
                let want = theirs.iter().find(|(n, _)| n == k).map(|(_, ty)| ty);
                let have = mine.iter().find(|(n, _)| n == k).map(|(_, ty)| ty);
                let fix = if explicit {
                    "or leave that route out of `invalidates`"
                } else {
                    "or list what to invalidate with `const invalidates = [...]`"
                };
                let msg = match (have.filter(|_| a.keys.contains(k)), want) {
                    (Some(have), Some(want)) if have != want => Some(format!(
                        "{}() takes `{k}` as {have}, but {data_file} is keyed by it as {want}",
                        a.name,
                    )),
                    (None, want) => Some(format!(
                        "{data_file} is keyed by `{k}`, which {}() doesn't take, so it can't tell which one to invalidate after a success: take it ({}), {fix}",
                        a.name,
                        want.map_or(format!("`{k}`"), |t| format!("`{t} {k}`")),
                    )),
                    _ => None,
                };
                if let Some(msg) = msg {
                    self.diags.error(file, Some(&a.span), msg);
                    ok = false;
                }
            }
        }
        ok
    }

    /// The segments and query parameters a route's (or a section's) `data.dart` can be keyed by.
    fn key_types(&self, r: &Route) -> Vec<(String, String)> {
        if r.layout_folder() {
            let mut out = self.app.typed_segs(r);
            out.extend(r.layout_query.iter().cloned());
            out
        } else {
            self.app.url_params(r)
        }
    }

    /// Reports the helpers of an action that share a name with something else on the typed
    /// route or section handle: its members, its fields, or another action's helpers.
    fn action_names(&mut self) {
        for rid in 0..self.app.routes.len() {
            let r = &self.app.routes[rid];
            if r.actions.is_empty() {
                continue;
            }
            let file = format!("{}action.dart", folder_prefix(&r.dir));
            let mut taken: Vec<(String, String)> = ACTION_RESERVED
                .iter()
                .map(|n| ((*n).to_string(), "a member of the typed route".to_string()))
                .collect();
            taken.extend(self.key_types(r).into_iter().map(|(n, _)| {
                let what = format!("`{n}`, a segment or query parameter of the route");
                (n, what)
            }));
            let mut errors = vec![];
            for a in &r.actions {
                let n = ActionNames::of(&a.name);
                for (name, role) in [
                    (&n.provider, "provider"),
                    (&n.run, "helper"),
                    (&n.hook, "hook"),
                ] {
                    match taken.iter().find(|(t, _)| t == name) {
                        Some((_, owner)) => errors.push((
                            a.span.clone(),
                            format!(
                                "the {role} of {}() would be called `{name}`, which is already {owner}; rename the function",
                                a.name
                            ),
                        )),
                        None => taken.push((name.clone(), format!("the {role} of {}()", a.name))),
                    }
                }
            }
            for (span, msg) in errors {
                self.diags.error(&file, Some(&span), msg);
            }
        }
    }

    /// `GuardResult guard(ProviderContainer c, {...})`: runs before every route at
    /// and below its folder.
    fn guard(
        &mut self,
        m: &Module,
        node: &Node,
        segs: &[(String, usize)],
        route: usize,
    ) -> Option<Guard> {
        let file = node.rel(Kind::Guard);
        let Some(f) = m.functions.iter().find(|f| f.name == "guard") else {
            self.diags.error(
                &file,
                None,
                "expected `GuardResult guard(Ref ref, {...segments})`",
            );
            return None;
        };
        let ok_ret = f.ret.as_ref().is_some_and(|r| {
            [
                "GuardResult",
                "FutureOr<String?>",
                "Future<String?>",
                "String?",
            ]
            .contains(&r.text.as_str())
        });
        if !ok_ret {
            self.diags.error(
                &file,
                Some(&f.span),
                "guard() must return GuardResult (a location to redirect to, or null)",
            );
        }
        let first = HookFirst::of(f);
        if first == HookFirst::None {
            let msg = if takes_widget_ref(f) {
                "a guard runs outside the widget tree: take `Ref`"
            } else {
                "guard() must take `Ref ref` first (or `ProviderContainer c`, the older form)"
            };
            self.diags.error(&file, Some(&f.span), msg);
        }
        // Its query parameters belong to the folder's own route when it has one
        // (they show up on the typed route); otherwise to the guard alone.
        let has_route =
            node.files.contains_key(&Kind::Page) || node.files.contains_key(&Kind::Redirect);
        let scope = if has_route {
            Scope::Route(route)
        } else {
            Scope::Guard(route)
        };
        let args = self.hook_args(
            &file,
            f.params.iter().skip(first.skip().max(1)),
            segs,
            scope,
            "guard()",
        );
        let import = self.import(&file);
        let extra = extra_of(
            &f.params,
            &args,
            node.files.get(&Kind::Guard),
            &file,
            import,
            &format!("g{route}"),
        );
        Some(Guard {
            import,
            first,
            args,
            extra,
        })
    }

    /// `String redirect({...})` in a folder in place of page.dart.
    fn redirect(
        &mut self,
        m: &Module,
        node: &Node,
        segs: &[(String, usize)],
        route: usize,
    ) -> Option<(Guard, Span)> {
        let file = node.rel(Kind::Redirect);
        let Some(f) = m.functions.iter().find(|f| f.name == "redirect") else {
            self.diags
                .error(&file, None, "expected `String redirect({...segments})`");
            return None;
        };
        let ok_ret = f.ret.as_ref().is_some_and(|r| {
            ["String", "FutureOr<String>", "Future<String>"].contains(&r.text.as_str())
        });
        if !ok_ret {
            self.diags.error(
                &file,
                Some(&f.span),
                "redirect() must return the location to go to: a String (or Future<String>)",
            );
        }
        let first = HookFirst::of(f);
        if first == HookFirst::None && takes_widget_ref(f) {
            let msg = "a redirect runs outside the widget tree: take `Ref`";
            self.diags.error(&file, Some(&f.span), msg);
        }
        let args = self.hook_args(
            &file,
            f.params
                .iter()
                .skip(first.skip().max(usize::from(takes_widget_ref(f)))),
            segs,
            Scope::Route(route),
            "redirect()",
        );
        let import = self.import(&file);
        let extra = extra_of(
            &f.params,
            &args,
            node.files.get(&Kind::Redirect),
            &file,
            import,
            &format!("r{route}"),
        );
        Some((
            Guard {
                import,
                first,
                args,
                extra,
            },
            f.span.clone(),
        ))
    }

    /// The named parameters of a `guard()` or `redirect()`: `uri`, `extra`, segments and
    /// query parameters, as call arguments.
    fn hook_args<'p>(
        &mut self,
        file: &str,
        params: impl Iterator<Item = &'p dart::Param>,
        segs: &[(String, usize)],
        scope: Scope,
        what: &str,
    ) -> Vec<Arg> {
        let (mut keys, mut uri, mut extra) = (vec![], None, None);
        for p in params {
            if p.name == "extra" {
                if !p.named {
                    self.diags.error(
                        file,
                        Some(&p.span),
                        format!(
                            "{what} takes `extra` as a named parameter, e.g. `{{Object? extra}}`"
                        ),
                    );
                } else if let Some(msg) =
                    p.ty.as_ref()
                        .and_then(|ty| mismatch("extra", &Bind::Extra, ty))
                {
                    self.diags.error(file, Some(&p.span), msg);
                } else {
                    extra = Some(Arg {
                        name: "extra".into(),
                        named: true,
                        bind: Bind::Extra,
                    });
                }
                continue;
            }
            if p.named && p.name == "uri" {
                match p.ty.as_ref().and_then(|ty| mismatch("uri", &Bind::Uri, ty)) {
                    Some(msg) => self.diags.error(file, Some(&p.span), msg),
                    None => {
                        uri = Some(Arg {
                            name: "uri".into(),
                            named: true,
                            bind: Bind::Uri,
                        });
                    }
                }
                continue;
            }
            keys.extend(self.url_param(file, p, segs, scope, what));
        }
        let mut args: Vec<Arg> = in_path_order(keys, segs)
            .into_iter()
            .map(|k| {
                let bind = if segs.iter().any(|(n, _)| *n == k) {
                    Bind::Segment(k.clone())
                } else {
                    Bind::Query(k.clone())
                };
                Arg {
                    name: k,
                    named: true,
                    bind,
                }
            })
            .collect();
        args.extend(uri);
        args.extend(extra);
        args
    }

    /// `Page<void> transition(LocalKey key, Widget child)`, or `present(...)` in a
    /// present.dart, which is bound the same way: parameters are filled by name, then
    /// by type; other optional ones keep their default.
    fn transition(
        &mut self,
        m: &Module,
        node: &Node,
        kind: Kind,
        name: &str,
    ) -> Option<Transition> {
        let file = node.rel(kind);
        let Some(f) = m.functions.iter().find(|f| f.name == name) else {
            self.diags.error(
                &file,
                None,
                format!("expected `Page<void> {name}(LocalKey key, Widget child)`"),
            );
            return None;
        };
        if !f
            .ret
            .as_ref()
            .is_some_and(|r| r.generic().0.ends_with("Page"))
        {
            self.diags.error(
                &file,
                Some(&f.span),
                format!("{name}() must return a Page, e.g. `Page<void>`"),
            );
            return None;
        }
        let mut args = vec![];
        let mut positional_gap = false;
        for p in &f.params {
            let bind = if !p.named && positional_gap {
                None
            } else {
                transition_bind(p)
            };
            let Some(bind) = bind else {
                if p.required {
                    let msg = format!(
                        "can't fill `{}`: {name}() gets `key`, `child` and `state`",
                        p.name
                    );
                    self.diags.error(&file, Some(&p.span), msg);
                } else if !p.named {
                    positional_gap = true;
                }
                continue;
            };
            if let Some(msg) = p.ty.as_ref().and_then(|ty| mismatch(&p.name, &bind, ty)) {
                self.diags.error(&file, Some(&p.span), msg);
            }
            args.push(Arg {
                name: p.name.clone(),
                named: p.named,
                bind,
            });
        }
        if !args.iter().any(|a| a.bind == Bind::Child) {
            self.diags.error(
                &file,
                Some(&f.span),
                format!("{name}() must take the page as `Widget child`"),
            );
            return None;
        }
        Some(Transition {
            import: self.import(&file),
            args,
        })
    }

    /// `extra_codec.dart` at the root of the app folder: it exports `extraCodec`, a
    /// `Codec<Object?, Object?>` for `GoRouter(extraCodec:)`, as a variable or a getter.
    fn extra_codec(&mut self, root: &Node) {
        let Some(src) = root.files.get(&Kind::ExtraCodec) else {
            return;
        };
        let file = root.rel(Kind::ExtraCodec);
        let m = crate::parse_cache::parse(src);
        if !m.variables.iter().any(|v| v.name == "extraCodec")
            && !m.getters.iter().any(|g| g.name == "extraCodec")
        {
            let msg = "expected a top-level `extraCodec`: `final extraCodec = ExtraCodec({...});`, `const extraCodec = MyCodec();` or `Codec<Object?, Object?> get extraCodec => ...;`";
            self.diags.error(&file, None, msg);
            return;
        }
        let import = self.import(&file);
        self.app.extra_codec = Some(ExtraCodec { import });
    }

    /// A guard or a layout that takes `extra` sees the extra of every route it covers, so its
    /// type has to fit theirs: the page's (or redirect's) own, or, on a route that takes none,
    /// another guard's or layout's above it. `Object?` fits anything. What doesn't fit is an
    /// error at the guard's or layout's parameter, listing the routes.
    ///
    /// A route that takes no `extra` of its own is typed by the one the guards and layouts
    /// above it agree on, so its typed route can pass it.
    fn settle_extras(&mut self) {
        // Outermost first: folders come before the ones below them, and a guard before its layout.
        let mut readers: Vec<(&str, usize, HookExtra)> = vec![];
        for (id, r) in self.app.routes.iter().enumerate() {
            readers.extend(
                r.guard
                    .as_ref()
                    .and_then(|g| g.extra.clone())
                    .map(|e| ("guard", id, e)),
            );
            readers.extend(r.layout_extra.clone().map(|e| ("layout", id, e)));
        }
        if readers.is_empty() {
            return;
        }
        let covers = |folder: &Route, r: &Route| {
            folder.dir.is_empty()
                || r.dir == folder.dir
                || r.dir
                    .strip_prefix(&folder.dir)
                    .is_some_and(|rest| rest.starts_with('/'))
        };
        let mut clashes: Vec<Vec<String>> = vec![vec![]; readers.len()];
        let mut typed: Vec<(usize, ExtraType)> = vec![];
        for (id, r) in self
            .app
            .routes
            .iter()
            .enumerate()
            .filter(|(_, r)| r.is_route())
        {
            // Every guard above the route, and the layouts when it is a page: a redirect shows none.
            let chain: Vec<usize> = (0..readers.len())
                .filter(|&i| {
                    covers(&self.app.routes[readers[i].1], r)
                        && (readers[i].0 == "guard" || r.page.is_some())
                })
                .collect();
            let own = r.extra.as_ref();
            for (n, &i) in chain.iter().enumerate() {
                let want = &readers[i].2.ty.source;
                if extra::takes_any(want) {
                    continue;
                }
                // The route's own type has the last word; without one, the readers above agree among themselves.
                let other = match own {
                    Some(e) => Some((&e.file, &e.source)).filter(|(_, ty)| !extra::fits(want, ty)),
                    None => chain[..n]
                        .iter()
                        .map(|&j| &readers[j].2)
                        .find(|o| !extra::agree(want, &o.ty.source))
                        .map(|o| (&o.file, &o.ty.source)),
                };
                if let Some((file, ty)) = other {
                    clashes[i].push(format!("`{}` ({file} takes `{ty}`)", pattern(&r.url)));
                }
            }
            if r.extra.is_none() {
                let first = chain
                    .iter()
                    .find(|&&i| !extra::takes_any(&readers[i].2.ty.source));
                typed.extend(first.map(|&i| (id, readers[i].2.ty.clone())));
            }
        }
        for ((kind, _, e), mut routes) in readers.into_iter().zip(clashes) {
            if routes.is_empty() {
                continue;
            }
            routes.dedup();
            let more = routes.len().saturating_sub(5);
            routes.truncate(5);
            let list = routes.join(", ")
                + &if more > 0 {
                    format!(" and {more} more")
                } else {
                    String::new()
                };
            let msg = format!(
                "`extra` is `{}` here, but the routes it covers take other types: {list}; a {kind} sees the extra of every route it covers, so declare it as `Object?` to accept any of them, or as their type when they share one",
                e.ty.source
            );
            self.diags.error(&e.file, Some(&e.span), msg);
        }
        for (id, ty) in typed {
            self.app.routes[id].extra = Some(ty);
        }
    }

    /// Every file that uses `$id` must agree on its type; nobody saying means String.
    fn settle_segment_types(&mut self) {
        let mut first: HashMap<usize, (Typed, String, usize)> = HashMap::new();
        for c in std::mem::take(&mut self.constraints) {
            let catch_all = self.app.is_catch_all(c.folder);
            let text = c.ty.text.as_str();
            // A catch-all is a `List` of its parts' type.
            let (item, plain): (Option<&str>, &[&str]) = if catch_all {
                (list_item(text), &CATCH_ALL_ITEMS)
            } else {
                (Some(text), &SEGMENT_TYPES)
            };
            let typed = match item {
                Some(i) if plain.contains(&i) => Typed::plain(text.to_string()),
                Some(i) if enums::is_candidate(i) => {
                    let (what, fallback) = if catch_all {
                        (
                            "a catch-all segment's part",
                            format!("List<String> {}", c.name),
                        )
                    } else {
                        ("a segment", format!("String {}", c.name))
                    };
                    let decl = format!("{text} {}", c.name);
                    match self.enum_typed(
                        i,
                        text,
                        &c.file,
                        &format!("s{}", c.folder),
                        Some((&c.span, &decl, what, &fallback)),
                    ) {
                        Some(t) => t,
                        None => continue,
                    }
                }
                _ if catch_all => {
                    let msg = format!(
                        "`{} {}`: a catch-all segment is the rest of the path, a `List` of String, int, double, num, bool or DateTime, or of an enum",
                        c.ty.text, c.name
                    );
                    self.diags.error(&c.file, Some(&c.span), msg);
                    continue;
                }
                _ => {
                    let msg = format!(
                        "`{} {}`: segments are String, int, double or bool, or an enum",
                        c.ty.text, c.name
                    );
                    self.diags.error(&c.file, Some(&c.span), msg);
                    continue;
                }
            };
            match first.get(&c.folder) {
                None => {
                    self.use_type(&typed);
                    first.insert(c.folder, (typed, c.file.clone(), c.span.line));
                }
                Some((t0, f0, l0)) if t0.key != typed.key => self.diags.error(
                    &c.file,
                    Some(&c.span),
                    format!(
                        "`${}` is {} in {f0}:{l0} but {} here{}",
                        c.name,
                        t0.shown,
                        typed.shown,
                        t0.same_name_as(&typed)
                    ),
                ),
                _ => {}
            }
        }
        self.app.seg_types = first
            .into_iter()
            .map(|(k, (t, _, _))| (k, t.spelled))
            .collect();
    }
}

/// The `extra` parameter of a layout, guard or redirect, when one was bound to it: its type
/// spelled for the generated file. `tag` keeps that spelling's import aliases apart from
/// the other files' (see `extra::extra_type`).
fn extra_of(
    params: &[dart::Param],
    bound: &[Arg],
    src: Option<&String>,
    file: &str,
    import: usize,
    tag: &str,
) -> Option<HookExtra> {
    if !bound.iter().any(|a| a.bind == Bind::Extra) {
        return None;
    }
    let p = params.iter().find(|p| !p.is_super && p.name == "extra")?;
    let ty = extra::extra_type(&p.ty.as_ref()?.text, src?, file, import, tag);
    Some(HookExtra {
        ty,
        span: p.span.clone(),
        file: file.to_string(),
    })
}

/// Whether the first parameter is a `WidgetRef`, which only a widget can have.
fn takes_widget_ref(f: &dart::Function) -> bool {
    f.params
        .first()
        .is_some_and(|p| !p.named && p.ty.as_ref().is_some_and(|t| t.is("WidgetRef")))
}

/// What a parameter called `name` receives in this role, going by its name.
fn by_name(name: &str, cx: &BindCx) -> Option<Bind> {
    match (cx.role, name) {
        (Role::Page | Role::Layout, "data") if cx.data.is_some() => return Some(Bind::Data),
        (Role::Page | Role::Layout, "data") if !cx.sections.is_empty() => {
            return Some(Bind::Section(cx.sections.last().unwrap().id));
        }
        (Role::Error, "error") => return Some(Bind::Error),
        (Role::Error, "stackTrace") => return Some(Bind::StackTrace),
        (Role::Error, "retry") => return Some(Bind::Retry),
        (Role::Layout, "child") => return Some(Bind::Child),
        (Role::Layout, "navigationShell" | "shell") => return Some(Bind::Shell),
        (Role::NotFound, "uri") => return Some(Bind::Uri),
        (Role::Page | Role::Layout, "extra") => return Some(Bind::Extra),
        _ => {}
    }
    let is_segment = cx.segs.iter().any(|(n, _)| n == name);
    match cx.role {
        Role::NotFound => is_segment.then(|| Bind::Raw(name.to_string())),
        _ => is_segment.then(|| Bind::Segment(name.to_string())),
    }
}

/// What a parameter of type `ty` receives in this role, going by its type.
fn by_type(ty: &Ty, cx: &BindCx) -> Option<Bind> {
    match (cx.role, ty.text.as_str()) {
        (Role::Error, "Object" | "Object?" | "dynamic") => Some(Bind::Error),
        (Role::Error, "StackTrace" | "StackTrace?") => Some(Bind::StackTrace),
        (Role::Error, "VoidCallback" | "void Function()") => Some(Bind::Retry),
        (Role::Layout, "Widget") => Some(Bind::Child),
        (Role::Layout, "StatefulNavigationShell") => Some(Bind::Shell),
        (Role::NotFound, "Uri") => Some(Bind::Uri),
        _ => None,
    }
}

/// What a `transition()` parameter receives: `key`, `child` or `state`.
fn transition_bind(p: &dart::Param) -> Option<Bind> {
    let by_name = match p.name.as_str() {
        "key" => Some(Bind::PageKey),
        "child" => Some(Bind::Child),
        "state" => Some(Bind::State),
        "shell" | "isShell" => Some(Bind::IsShell),
        _ => None,
    };
    by_name.or_else(|| match p.ty.as_ref()?.text.trim_end_matches('?') {
        "LocalKey" | "ValueKey<String>" => Some(Bind::PageKey),
        "Widget" => Some(Bind::Child),
        "GoRouterState" => Some(Bind::State),
        _ => None,
    })
}

/// A type without an import prefix: `w.Widget` is `Widget`, `List<w.Widget>` is left alone.
fn bare_type(text: &str) -> &str {
    text.rsplit_once('.')
        .filter(|(p, t)| !format!("{p}{t}").contains(['<', '(', ' ']))
        .map_or(text, |(_, t)| t)
}

/// A parameter bound by name gets a fixed value; say so when it's declared as
/// something that value can't be assigned to. `Object` and `dynamic` take anything.
fn mismatch(name: &str, bind: &Bind, ty: &Ty) -> Option<String> {
    let (gets, accepts): (&str, &[&str]) = match bind {
        Bind::Uri => ("the requested Uri", &["Uri"]),
        Bind::Child => ("the page as a Widget", &["Widget"]),
        Bind::Shell => (
            "the StatefulNavigationShell",
            &["StatefulNavigationShell", "StatefulWidget", "Widget"],
        ),
        Bind::Error => ("the error, an Object", &[]),
        Bind::StackTrace => ("the StackTrace", &["StackTrace"]),
        Bind::Retry => (
            "the retry callback, a VoidCallback",
            &["VoidCallback", "void Function()"],
        ),
        Bind::PageKey => (
            "the page's key, a ValueKey<String>",
            &[
                "LocalKey",
                "Key",
                "ValueKey",
                "ValueKey<String>",
                "ValueKey<Object>",
                "ValueKey<dynamic>",
            ],
        ),
        Bind::State => ("the GoRouterState", &["GoRouterState"]),
        Bind::IsShell => ("whether the page is a layout's shell, a bool", &["bool"]),
        Bind::Extra => {
            let ok = ty.text.ends_with('?') || ty.text == "dynamic";
            return (!ok).then(|| {
                format!(
                    "`{name}` gets the object passed on navigation, but it isn't in the URL: a deep link or a reload leaves it null, so declare it nullable, e.g. `{}? {name}`",
                    ty.text
                )
            });
        }
        // Data has its own message; segments and queries are settled with the segment types.
        Bind::Raw(_) => {
            let ok = matches!(
                ty.text.trim_end_matches('?'),
                "String" | "Object" | "dynamic"
            );
            return (!ok).then(|| {
                format!(
                    "`{name}` gets the segment as the URL spells it, a String: a segment that doesn't parse as `{}` is why not_found.dart is shown, so declare it `String {name}`",
                    ty.text.trim_end_matches('?')
                )
            });
        }
        Bind::Data | Bind::Section(_) | Bind::Segment(_) | Bind::Query(_) => return None,
    };
    let bare = ty.text.trim_end_matches('?');
    // `w.Widget` is `Widget` under an import prefix.
    let bare = bare
        .rsplit_once('.')
        .filter(|(p, t)| !format!("{p}{t}").contains(['<', '(', ' ']))
        .map_or(bare, |(_, t)| t);
    if matches!(bare, "Object" | "dynamic") || accepts.contains(&bare) {
        return None;
    }
    Some(format!(
        "`{name}` gets {gets}, but it's declared {}",
        ty.text
    ))
}

fn unfillable(name: &str, cx: &BindCx) -> String {
    let segs = show_segs(cx.segs);
    match (cx.role, cx.covering) {
        (Role::Loading | Role::Error, Some(dir)) => {
            let extra = if cx.role == Role::Error {
                ", `error`, `stackTrace`, `retry`,"
            } else {
                ""
            };
            format!(
                "can't fill `{name}` for {dir}: it isn't one of its segments ({segs}){extra} or a query parameter (optional and nullable)"
            )
        }
        (Role::Page, _) => match cx.data {
            Some(t) => format!(
                "can't fill `{name}`: it isn't a segment of this path ({segs}), data.dart's {t}, or a query parameter (optional and nullable)"
            ),
            None => format!(
                "can't fill `{name}`: it isn't a segment of this path ({segs}) or a query parameter (optional and nullable)"
            ),
        },
        (Role::Layout, _) => format!(
            "can't fill `{name}`: a layout gets `Widget child` (or, for tabs, a `StatefulNavigationShell`), the segments above it ({segs}) and `extra`"
        ),
        (Role::NotFound, _) => format!(
            "can't fill `{name}`: not_found.dart only gets `Uri uri`, and the segments of its own path as Strings ({segs})"
        ),
        _ => format!("can't fill `{name}`: it isn't a segment of this path ({segs})"),
    }
}

/// Segments in path order, then query parameters as declared.
/// `/products/:id`
pub fn pattern(url: &[Seg]) -> String {
    let parts: Vec<String> = url
        .iter()
        .filter_map(|s| match s {
            Seg::Static(s) => Some(s.clone()),
            Seg::Dynamic(n) => Some(format!(":{n}")),
            Seg::CatchAll(n, optional) => Some(format!("*{n}{}", if *optional { "?" } else { "" })),
            Seg::Group(_) => None,
        })
        .collect();
    format!("/{}", parts.join("/"))
}

fn in_path_order(keys: Vec<String>, segs: &[(String, usize)]) -> Vec<String> {
    let mut out: Vec<String> = segs
        .iter()
        .map(|(n, _)| n)
        .filter(|n| keys.contains(n))
        .cloned()
        .collect();
    out.extend(
        keys.into_iter()
            .filter(|k| !segs.iter().any(|(n, _)| n == k)),
    );
    out
}

fn show_segs(segs: &[(String, usize)]) -> String {
    if segs.is_empty() {
        return "it has none".into();
    }
    segs.iter()
        .map(|(n, _)| format!("${n}"))
        .collect::<Vec<_>>()
        .join(", ")
}

/// Every tab a layout could have: its own page, then each subfolder holding routes.
fn all_tabs(has_page: bool, with_routes: &[usize]) -> Vec<Branch> {
    let own = has_page.then_some(Branch::Own);
    own.into_iter()
        .chain(with_routes.iter().map(|&c| Branch::Folder(c)))
        .collect()
}

fn show_list(names: &[String]) -> String {
    names
        .iter()
        .map(|n| format!("`{n}`"))
        .collect::<Vec<_>>()
        .join(", ")
}

fn show_dir(dir: &str) -> String {
    if dir.is_empty() {
        "/".into()
    } else {
        format!("{dir}/")
    }
}

/// The typed route's name from its URL, for a `redirect.dart` and for a page written as a
/// function: `/old-products/:id` → `OldProductsId` (`OldProductsIdRoute`), the root →
/// `Root`. `(group)` folders add nothing.
fn path_name(url: &[Seg]) -> String {
    let path: Vec<&str> = url
        .iter()
        .filter_map(|s| match s {
            Seg::Static(n) | Seg::Dynamic(n) | Seg::CatchAll(n, _) => Some(n.as_str()),
            Seg::Group(_) => None,
        })
        .collect();
    let name = pascal(&path.join("/"));
    match name.chars().next() {
        None => "Root".into(),
        Some(c) if c.is_ascii_digit() => format!("Path{name}"),
        _ => name,
    }
}

/// `ProductPage` → `Product`; also strips `Screen` and `View`.
fn route_name(class: &str) -> String {
    for suffix in ["Page", "Screen", "View"] {
        if let Some(stem) = class.strip_suffix(suffix)
            && !stem.is_empty()
        {
            return stem.to_string();
        }
    }
    class.to_string()
}

/// The names a view file's function can have: the file's own, and for a multi-word
/// kind its lowerCamelCase spelling too (`not_found` or `notFound`).
fn view_fn_names(kind: Kind) -> &'static [&'static str] {
    match kind {
        Kind::Page => &["page"],
        Kind::Loading => &["loading"],
        Kind::Error => &["error"],
        Kind::Layout => &["layout"],
        Kind::NotFound => &["not_found", "notFound"],
        _ => &[],
    }
}

/// Whether `name` can start a typed route's name: `KycShopName` (the route is `KycShopNameRoute`).
pub fn valid_route_name(name: &str) -> bool {
    name.chars().next().is_some_and(|c| c.is_ascii_uppercase())
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// `products/$id` → `ProductsId`.
/// `orders/$id/` for the folder `orders/$id`; nothing for the app folder: where a folder's
/// files are, relative to the app folder.
fn folder_prefix(dir: &str) -> String {
    if dir.is_empty() {
        String::new()
    } else {
        format!("{dir}/")
    }
}

pub fn pascal(dir: &str) -> String {
    dir.replace(['/', '$'], "_").to_upper_camel_case()
}

/// `ProviderListenable<AsyncValue<T>>` → `T`: the return type that makes a `data()` a selector.
fn selected_value(ret: &dart::Ty) -> Option<String> {
    let (head, args) = ret.generic();
    let ("ProviderListenable", [state]) = (head, args.as_slice()) else {
        return None;
    };
    let inner = dart::Ty {
        text: state.to_string(),
        record: None,
    };
    let (head, args) = inner.generic();
    match (head, args.as_slice()) {
        ("AsyncValue", [t]) => Some(t.to_string()),
        _ => None,
    }
}
