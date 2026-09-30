//! Finds each file's one declaration, works out what every constructor and
//! function parameter receives, and checks that the files fit together.
//!
//! Nothing here is a base class or an interface: a `page.dart` is any widget,
//! and its constructor says what it wants. Parameters are filled by name first
//! (`id` ← the `$id` segment, `child`, `error`, `retry`, `uri`, `data`), then by
//! type (`Product product` ← what `data.dart` yields). Anything else that is
//! nullable or a List of String/int/double/bool is a query parameter
//! (`int? page` ← `?page=2`). `transition()` is filled the same way: `key`,
//! `child` and `state`.

use std::collections::{BTreeMap, HashMap};

use heck::ToUpperCamelCase;

use crate::dart::{self, Class, Module, Span, Ty};
use crate::diag::Diags;
use crate::scan::{Kind, Node, Seg};

pub const SEGMENT_TYPES: [&str; 4] = ["String", "int", "double", "bool"];

/// What a parameter receives.
#[derive(Debug, Clone, PartialEq)]
pub enum Bind {
    Segment(String),
    Query(String),
    Data,
    Child,
    Error,
    StackTrace,
    Retry,
    Uri,
    /// A transition's page key: `state.pageKey`.
    PageKey,
    /// A transition's `GoRouterState`.
    State,
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
}

impl Widget {
    /// Constructor call, given how to spell each binding.
    pub fn call(&self, value: impl Fn(&Bind) -> String) -> String {
        let args: Vec<String> = self
            .args
            .iter()
            .map(|a| if a.named { format!("{}: {}", a.name, value(&a.bind)) } else { value(&a.bind) })
            .collect();
        format!("_i{}.{}({})", self.import, self.class, args.join(", "))
    }

}

#[derive(Debug, Clone)]
pub struct Data {
    pub import: usize,
    /// The file exports its own provider (`final data = FutureProvider...`);
    /// otherwise fespalier wraps its `data()` function in one.
    pub provider: bool,
    pub stream: bool,
    pub ty: String,
    /// Segments the provider is keyed by, in path order.
    pub keys: Vec<String>,
    /// Keyed by a named record `(a: .., b: ..)` rather than a bare value.
    pub record: bool,
}

/// A `transition()` function, applied to every page at or below its folder.
#[derive(Debug, Clone)]
pub struct Transition {
    pub import: usize,
    /// `Bind::Child` is the page as it would be built without a transition.
    pub args: Vec<Arg>,
}

#[derive(Debug, Clone)]
pub struct Guard {
    pub import: usize,
    pub keys: Vec<String>,
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
    /// `Product` for `ProductPage`; the typed route is `ProductRoute`.
    pub name: Option<String>,
    pub data: Option<Data>,
    pub loading: Option<Widget>,
    pub error: Option<Widget>,
    pub layout: Option<Widget>,
    pub guard: Option<Guard>,
    /// The nearest transition.dart at or above this folder; only for pages.
    pub transition: Option<Transition>,
    /// Query parameters any of this route's files ask for: (name, Dart type),
    /// the type being `T?` or `List<T>`.
    pub query: Vec<(String, String)>,
    /// Query parameters this folder's layout asks for.
    pub layout_query: Vec<(String, String)>,
}

#[derive(Debug, Default)]
pub struct App {
    pub imports: Vec<String>,
    pub routes: Vec<Route>,
    pub not_found: Option<Widget>,
    /// Type of each dynamic segment, keyed by the folder that declares it.
    pub seg_types: HashMap<usize, String>,
}

impl App {
    pub fn seg_type(&self, folder: usize) -> &str {
        self.seg_types.get(&folder).map_or("String", String::as_str)
    }

    /// `(name, type)` for each of a route's segments, in path order.
    pub fn typed_segs(&self, r: &Route) -> Vec<(String, String)> {
        r.segs.iter().map(|(n, f)| (n.clone(), self.seg_type(*f).to_string())).collect()
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
}

/// `int?` → a nullable int, `List<String>` → every `?x=` value.
fn query_type(ty: &Ty) -> Option<String> {
    let t = ty.text.as_str();
    if let Some(inner) = t.strip_suffix('?').filter(|i| SEGMENT_TYPES.contains(i)) {
        return Some(format!("{inner}?"));
    }
    let list = t.strip_suffix('?').unwrap_or(t);
    let inner = list.strip_prefix("List<")?.strip_suffix('>')?;
    SEGMENT_TYPES.contains(&inner).then(|| format!("List<{inner}>"))
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
    file: &'a str,
    /// For inherited views: the folder of the route this use is for.
    covering: Option<&'a str>,
    /// Where query parameters land; `None` where there are none (not_found).
    scope: Option<Scope>,
}

pub fn resolve(root: &Node, diags: &mut Diags) -> App {
    let mut r = Resolver {
        app: App::default(),
        import_ix: HashMap::new(),
        route_names: HashMap::new(),
        patterns: HashMap::new(),
        constraints: vec![],
        queries: HashMap::new(),
        query_order: vec![],
        diags,
    };
    r.node(root, &Inherited::default());
    r.settle_segment_types();
    for (scope, name) in std::mem::take(&mut r.query_order) {
        let ty = r.queries[&(scope, name.clone())].0.clone();
        match scope {
            Scope::Route(id) => r.app.routes[id].query.push((name, ty)),
            Scope::Layout(id) => r.app.routes[id].layout_query.push((name, ty)),
        }
    }
    r.app
}

struct Resolver<'a> {
    app: App,
    import_ix: HashMap<String, usize>,
    route_names: HashMap<String, String>,
    /// URL pattern → the page.dart that serves it.
    patterns: HashMap<String, String>,
    constraints: Vec<Constraint>,
    /// Query parameter types as first declared: (type, file, line).
    queries: HashMap<(Scope, String), (String, String, usize)>,
    query_order: Vec<(Scope, String)>,
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
            name: None,
            data: None,
            loading: None,
            error: None,
            layout: None,
            guard: None,
            transition: None,
            query: vec![],
            layout_query: vec![],
        });

        let mut segs = up.segs.clone();
        if let Some(Seg::Dynamic(n)) = &node.seg {
            if segs.iter().any(|(s, _)| s == n) {
                self.diags.error(&node.dir, None, format!("`${n}` is already a segment higher up this path"));
            } else {
                segs.push((n.clone(), id));
            }
        }
        let mut url = up.url.clone();
        if let Some(seg @ (Seg::Static(_) | Seg::Dynamic(_))) = &node.seg {
            url.push(seg.clone());
        }
        let modules: BTreeMap<Kind, Module> = node.files.iter().map(|(k, src)| (*k, dart::parse(src))).collect();

        // page.dart names the route; data.dart feeds it.
        let page_file = node.rel(Kind::Page);
        let page_class = modules.get(&Kind::Page).and_then(|m| self.widget_class(m, &page_file));
        let name = page_class.as_ref().map(|c| route_name(&c.name));
        if let (Some(n), Some(c)) = (&name, &page_class) {
            if let Some(prev) = self.route_names.insert(n.clone(), page_file.clone()) {
                self.diags.error(&page_file, Some(&c.span), format!("route name `{n}Route` is already taken by {prev}; rename the class"));
            }
            // `(a)/x/page.dart` and `(b)/x/page.dart` would both be /x.
            let pattern = pattern(&url);
            if let Some(prev) = self.patterns.insert(pattern.clone(), page_file.clone()) {
                self.diags.error(&page_file, Some(&c.span), format!("{prev} already serves {pattern}; (group) folders don't add to the URL"));
            }
        }
        let data = modules.get(&Kind::Data).and_then(|m| self.data(m, node, &segs, id));
        if data.is_some() && !node.files.contains_key(&Kind::Page) {
            self.diags.error(&node.rel(Kind::Data), None, "data.dart has no page.dart to feed");
        }
        let page = page_class.map(|c| {
            let cx = BindCx {
                role: Role::Page,
                segs: &segs,
                data: data.as_ref().map(|d| d.ty.as_str()),
                file: &page_file,
                covering: None,
                scope: Some(Scope::Route(id)),
            };
            let w = self.bind(&c, &cx);
            if let Some(d) = &data {
                if !w.args.iter().any(|a| a.bind == Bind::Data) {
                    self.diags.warn(
                        &page_file,
                        Some(&c.span),
                        format!("{} doesn't take what data.dart yields; add `final {} data;` to its constructor", c.name, d.ty),
                    );
                }
            }
            w
        });

        // loading.dart / error.dart apply here and to every folder below.
        let mut here = Inherited {
            segs: segs.clone(),
            url: url.clone(),
            loading: up.loading.clone(),
            error: up.error.clone(),
            transition: up.transition.clone(),
        };
        for (kind, slot) in [(Kind::Loading, &mut here.loading), (Kind::Error, &mut here.error)] {
            if let Some(m) = modules.get(&kind) {
                let file = node.rel(kind);
                if let Some(class) = self.widget_class(m, &file) {
                    *slot = Some(Fallback { import: self.import(&file), class, file });
                }
            }
        }
        // Likewise transition.dart, once for the whole subtree.
        if let Some(m) = modules.get(&Kind::Transition) {
            here.transition = self.transition(m, node).or(here.transition);
        }
        let (loading, error) = if data.is_some() {
            let covering = show_dir(&node.dir);
            let bind = |r: &mut Self, f: &Option<Fallback>, role| {
                f.as_ref().map(|f| {
                    let cx = BindCx {
                        role,
                        segs: &segs,
                        data: None,
                        file: &f.file,
                        covering: Some(&covering),
                        scope: Some(Scope::Route(id)),
                    };
                    let mut w = r.bind(&f.class, &cx);
                    w.import = f.import;
                    w
                })
            };
            (bind(self, &here.loading, Role::Loading), bind(self, &here.error, Role::Error))
        } else {
            (None, None)
        };

        let layout = modules.get(&Kind::Layout).and_then(|m| {
            let file = node.rel(Kind::Layout);
            let c = self.widget_class(m, &file)?;
            let cx = BindCx { role: Role::Layout, segs: &segs, data: None, file: &file, covering: None, scope: Some(Scope::Layout(id)) };
            Some(self.bind(&c, &cx))
        });
        let guard = modules.get(&Kind::Guard).and_then(|m| self.guard(m, node, &segs, id));
        if let Some(m) = modules.get(&Kind::NotFound) {
            let file = node.rel(Kind::NotFound);
            if node.dir.is_empty() {
                if let Some(c) = self.widget_class(m, &file) {
                    let cx = BindCx { role: Role::NotFound, segs: &[], data: None, file: &file, covering: None, scope: None };
                    self.app.not_found = Some(self.bind(&c, &cx));
                }
            } else {
                self.diags.error(&file, None, "not_found.dart only works at the root of the app folder");
            }
        }

        let has_page = page.is_some();
        let transition = here.transition.clone().filter(|_| has_page);
        let r = &mut self.app.routes[id];
        (r.segs, r.url, r.page, r.name, r.data, r.loading, r.error, r.layout, r.guard, r.transition) =
            (segs, url, page, name, data, loading, error, layout, guard, transition);

        let mut children = vec![];
        let mut any_route = has_page;
        for c in &node.children {
            let (cid, routes) = self.node(c, &here);
            children.push(cid);
            any_route |= routes;
        }
        if !any_route && node.children.is_empty() && !node.dir.is_empty() {
            self.diags.warn(&node.dir, None, "folder has no page.dart and no routes below it; skipped");
        }
        self.app.routes[id].children = children;
        (id, any_route)
    }

    /// The one public widget class a view file exports.
    fn widget_class(&mut self, m: &Module, file: &str) -> Option<Class> {
        let public: Vec<&Class> = m.classes.iter().filter(|c| c.is_public()).collect();
        let widgets: Vec<&Class> =
            public.iter().copied().filter(|c| c.superclass.as_deref().is_some_and(|s| s.ends_with("Widget"))).collect();
        match (public.as_slice(), widgets.as_slice()) {
            ([one], _) | (_, [one]) => Some((*one).clone()),
            ([], _) => {
                self.diags.error(file, None, "expected a public widget class");
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
                    self.diags.error(cx.file, Some(&p.span), format!("can't fill `super.{}`; only `super.key` is allowed", p.name));
                }
                continue;
            }
            let bind = if !p.named && positional_gap {
                None
            } else {
                by_name(&p.name, cx)
                    .or_else(|| {
                        // Optional, and nullable or a List: it comes from the query.
                        let (scope, ty) = (cx.scope.filter(|_| !p.required)?, p.ty.as_ref()?);
                        let qty = query_type(ty)?;
                        self.declare_query(scope, &p.name, qty, cx.file, &p.span).then(|| Bind::Query(p.name.clone()))
                    })
                    .or_else(|| by_type(p.ty.as_ref()?, cx))
            };
            let Some(bind) = bind else {
                if p.required {
                    let msg = unfillable(&p.name, cx);
                    self.diags.error(cx.file, Some(&p.span), msg);
                } else if !p.named {
                    positional_gap = true;
                }
                continue;
            };
            match (&bind, &p.ty, cx.data) {
                (Bind::Segment(name), Some(ty), _) => {
                    let folder = cx.segs.iter().find(|(n, _)| n == name).map(|(_, f)| *f).unwrap();
                    self.constraints.push(Constraint {
                        folder,
                        name: name.clone(),
                        ty: ty.clone(),
                        file: cx.file.to_string(),
                        span: p.span.clone(),
                    });
                }
                (Bind::Data, Some(ty), Some(want)) if !ty.is(want) => {
                    self.diags.error(cx.file, Some(&p.span), format!("`{}` is {} but data.dart yields {want}", p.name, ty.text));
                }
                _ => {}
            }
            args.push(Arg { name: p.name.clone(), named: p.named, bind });
        }
        let import = self.import(cx.file);
        Widget { import, class: class.name.clone(), args }
    }

    fn declare_query(&mut self, scope: Scope, name: &str, ty: String, file: &str, span: &Span) -> bool {
        let key = (scope, name.to_string());
        match self.queries.get(&key) {
            None => {
                self.queries.insert(key.clone(), (ty, file.to_string(), span.line));
                self.query_order.push(key);
                true
            }
            Some((t0, f0, l0)) if *t0 != ty => {
                let msg = format!("`?{name}` is {t0} in {f0}:{l0} but {ty} here");
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
        route: usize,
        what: &str,
        keyed: bool,
    ) -> Option<String> {
        if !p.named {
            self.diags.error(file, Some(&p.span), format!("{what} takes segments as named parameters, e.g. `{{required int {}}}`", p.name));
            return None;
        }
        let Some((_, folder)) = segs.iter().find(|(n, _)| n == &p.name) else {
            let Some(qty) = p.ty.as_ref().and_then(query_type).filter(|_| !p.required) else {
                let msg = format!(
                    "`{}` isn't a segment of this path ({}); for a query parameter make it optional and nullable, e.g. `String? {}`",
                    p.name,
                    show_segs(segs),
                    p.name
                );
                self.diags.error(file, Some(&p.span), msg);
                return None;
            };
            if keyed && qty.starts_with("List<") {
                // Lists compare by identity, so they can't key a provider.
                let msg = format!("`{}`: data can't be keyed by a List; take a `String?` and split it", p.name);
                self.diags.error(file, Some(&p.span), msg);
                return None;
            }
            return self.declare_query(Scope::Route(route), &p.name, qty, file, &p.span).then(|| p.name.clone());
        };
        match &p.ty {
            Some(ty) => self.constraints.push(Constraint {
                folder: *folder,
                name: p.name.clone(),
                ty: ty.clone(),
                file: file.to_string(),
                span: p.span.clone(),
            }),
            None => self.diags.error(file, Some(&p.span), format!("give `{}` a type (String, int, double or bool)", p.name)),
        }
        Some(p.name.clone())
    }

    fn data(&mut self, m: &Module, node: &Node, segs: &[(String, usize)], route: usize) -> Option<Data> {
        let file = node.rel(Kind::Data);
        if let Some(f) = m.functions.iter().find(|f| f.name == "data") {
            match f.params.first() {
                Some(p) if !p.named && p.ty.as_ref().is_some_and(|t| t.is("Ref")) => {}
                _ => self.diags.error(&file, Some(&f.span), "data() must take `Ref ref` first"),
            }
            let mut keys = vec![];
            for p in f.params.iter().skip(1) {
                keys.extend(self.url_param(&file, p, segs, route, "data()", true));
            }
            let Some(ret) = &f.ret else {
                self.diags.error(&file, Some(&f.span), "data() needs an explicit return type (Future<T>, Stream<T> or T)");
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
            return Some(Data { import, provider: false, stream, ty, record: keys.len() > 1, keys });
        }

        if let Some(v) = m.variables.iter().find(|v| v.name == "data") {
            const KINDS: &str = "FutureProvider, StreamProvider, AsyncNotifierProvider or StreamNotifierProvider";
            let Some(call) = &v.call else {
                self.diags.error(&file, Some(&v.span), format!("`data` must be a {KINDS}"));
                return None;
            };
            let (value_ix, stream) = match call.chain[0].as_str() {
                "FutureProvider" => (0, false),
                "StreamProvider" => (0, true),
                "AsyncNotifierProvider" => (1, false),
                "StreamNotifierProvider" => (1, true),
                other => {
                    self.diags.error(&file, Some(&v.span), format!("`data` must be a {KINDS}, not {other}"));
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
                self.diags.error(&file, Some(&v.span), format!("give the provider its type arguments, e.g. `{example}`"));
                return None;
            }
            let ty = call.type_args[value_ix].text.clone();
            let (mut keys, mut record) = (vec![], false);
            if family {
                let arg = &call.type_args[want - 1];
                if let Some(fields) = &arg.record {
                    record = true;
                    for (name, fty) in fields {
                        let p = dart::Param {
                            name: name.clone(),
                            ty: Some(fty.clone()),
                            named: true,
                            required: true,
                            is_super: false,
                            span: v.span.clone(),
                        };
                        keys.extend(self.url_param(&file, &p, segs, route, "the family argument", true));
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
            let import = self.import(&file);
            return Some(Data { import, provider: true, stream, ty, keys, record });
        }

        self.diags.error(&file, None, "expected `Future<T> data(Ref ref, {...segments})` or `final data = FutureProvider<T>(...)`");
        None
    }

    fn guard(&mut self, m: &Module, node: &Node, segs: &[(String, usize)], route: usize) -> Option<Guard> {
        let file = node.rel(Kind::Guard);
        if !node.files.contains_key(&Kind::Page) {
            self.diags.error(&file, None, "guard.dart needs a page.dart in the same folder");
            return None;
        }
        let Some(f) = m.functions.iter().find(|f| f.name == "guard") else {
            self.diags.error(&file, None, "expected `GuardResult guard(ProviderContainer c, {...segments})`");
            return None;
        };
        let ok_ret = f
            .ret
            .as_ref()
            .is_some_and(|r| ["GuardResult", "FutureOr<String?>", "Future<String?>", "String?"].contains(&r.text.as_str()));
        if !ok_ret {
            self.diags.error(&file, Some(&f.span), "guard() must return GuardResult (a location to redirect to, or null)");
        }
        match f.params.first() {
            Some(p) if !p.named && p.ty.as_ref().is_some_and(|t| t.is("ProviderContainer")) => {}
            _ => self.diags.error(&file, Some(&f.span), "guard() must take `ProviderContainer c` first"),
        }
        let mut keys = vec![];
        for p in f.params.iter().skip(1) {
            keys.extend(self.url_param(&file, p, segs, route, "guard()", false));
        }
        Some(Guard { import: self.import(&file), keys: in_path_order(keys, segs) })
    }

    /// `Page<void> transition(LocalKey key, Widget child)`: parameters are
    /// filled by name, then by type; other optional ones keep their default.
    fn transition(&mut self, m: &Module, node: &Node) -> Option<Transition> {
        let file = node.rel(Kind::Transition);
        let Some(f) = m.functions.iter().find(|f| f.name == "transition") else {
            self.diags.error(&file, None, "expected `Page<void> transition(LocalKey key, Widget child)`");
            return None;
        };
        if !f.ret.as_ref().is_some_and(|r| r.generic().0.ends_with("Page")) {
            self.diags.error(&file, Some(&f.span), "transition() must return a Page, e.g. `Page<void>`");
            return None;
        }
        let mut args = vec![];
        let mut positional_gap = false;
        for p in &f.params {
            let bind = if !p.named && positional_gap { None } else { transition_bind(p) };
            let Some(bind) = bind else {
                if p.required {
                    let msg = format!("can't fill `{}`: transition() gets `key`, `child` and `state`", p.name);
                    self.diags.error(&file, Some(&p.span), msg);
                } else if !p.named {
                    positional_gap = true;
                }
                continue;
            };
            args.push(Arg { name: p.name.clone(), named: p.named, bind });
        }
        if !args.iter().any(|a| a.bind == Bind::Child) {
            self.diags.error(&file, Some(&f.span), "transition() must take the page as `Widget child`");
            return None;
        }
        Some(Transition { import: self.import(&file), args })
    }

    /// Every file that uses `$id` must agree on its type; nobody saying means String.
    fn settle_segment_types(&mut self) {
        let mut first: HashMap<usize, (String, String, usize)> = HashMap::new();
        for c in &self.constraints {
            if !SEGMENT_TYPES.contains(&c.ty.text.as_str()) {
                self.diags.error(&c.file, Some(&c.span), format!("`{} {}`: segments are String, int, double or bool", c.ty.text, c.name));
                continue;
            }
            match first.get(&c.folder) {
                None => {
                    first.insert(c.folder, (c.ty.text.clone(), c.file.clone(), c.span.line));
                }
                Some((t0, f0, l0)) if *t0 != c.ty.text => self.diags.error(
                    &c.file,
                    Some(&c.span),
                    format!("`${}` is {t0} in {f0}:{l0} but {} here", c.name, c.ty.text),
                ),
                _ => {}
            }
        }
        self.app.seg_types = first.into_iter().map(|(k, (t, _, _))| (k, t)).collect();
    }
}

/// What a parameter called `name` receives in this role, going by its name.
fn by_name(name: &str, cx: &BindCx) -> Option<Bind> {
    match (cx.role, name) {
        (Role::Page, "data") if cx.data.is_some() => return Some(Bind::Data),
        (Role::Error, "error") => return Some(Bind::Error),
        (Role::Error, "stackTrace") => return Some(Bind::StackTrace),
        (Role::Error, "retry") => return Some(Bind::Retry),
        (Role::Layout, "child") => return Some(Bind::Child),
        (Role::NotFound, "uri") => return Some(Bind::Uri),
        _ => {}
    }
    cx.segs.iter().any(|(n, _)| n == name).then(|| Bind::Segment(name.to_string()))
}

/// What a parameter of type `ty` receives in this role, going by its type.
fn by_type(ty: &Ty, cx: &BindCx) -> Option<Bind> {
    match (cx.role, ty.text.as_str()) {
        (Role::Page, t) if cx.data == Some(t) => Some(Bind::Data),
        (Role::Error, "Object" | "Object?" | "dynamic") => Some(Bind::Error),
        (Role::Error, "StackTrace" | "StackTrace?") => Some(Bind::StackTrace),
        (Role::Error, "VoidCallback" | "void Function()") => Some(Bind::Retry),
        (Role::Layout, "Widget") => Some(Bind::Child),
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
        _ => None,
    };
    by_name.or_else(|| match p.ty.as_ref()?.text.trim_end_matches('?') {
        "LocalKey" | "ValueKey<String>" => Some(Bind::PageKey),
        "Widget" => Some(Bind::Child),
        "GoRouterState" => Some(Bind::State),
        _ => None,
    })
}

fn unfillable(name: &str, cx: &BindCx) -> String {
    let segs = show_segs(cx.segs);
    match (cx.role, cx.covering) {
        (Role::Loading | Role::Error, Some(dir)) => {
            let extra = if cx.role == Role::Error { ", `error`, `stackTrace`, `retry`," } else { "" };
            format!("can't fill `{name}` for {dir}: it isn't one of its segments ({segs}){extra} or a query parameter (optional and nullable)")
        }
        (Role::Page, _) => match cx.data {
            Some(t) => format!("can't fill `{name}`: it isn't a segment of this path ({segs}), data.dart's {t}, or a query parameter (optional and nullable)"),
            None => format!("can't fill `{name}`: it isn't a segment of this path ({segs}) or a query parameter (optional and nullable)"),
        },
        (Role::Layout, _) => format!("can't fill `{name}`: a layout gets `Widget child` and the segments above it ({segs})"),
        (Role::NotFound, _) => format!("can't fill `{name}`: not_found.dart only gets `Uri uri`"),
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
            Seg::Group(_) => None,
        })
        .collect();
    format!("/{}", parts.join("/"))
}

fn in_path_order(keys: Vec<String>, segs: &[(String, usize)]) -> Vec<String> {
    let mut out: Vec<String> = segs.iter().map(|(n, _)| n).filter(|n| keys.contains(n)).cloned().collect();
    out.extend(keys.into_iter().filter(|k| !segs.iter().any(|(n, _)| n == k)));
    out
}

fn show_segs(segs: &[(String, usize)]) -> String {
    if segs.is_empty() {
        return "it has none".into();
    }
    segs.iter().map(|(n, _)| format!("${n}")).collect::<Vec<_>>().join(", ")
}

fn show_dir(dir: &str) -> String {
    if dir.is_empty() { "/".into() } else { format!("{dir}/") }
}

/// `ProductPage` → `Product`; also strips `Screen` and `View`.
fn route_name(class: &str) -> String {
    for suffix in ["Page", "Screen", "View"] {
        if let Some(stem) = class.strip_suffix(suffix) {
            if !stem.is_empty() {
                return stem.to_string();
            }
        }
    }
    class.to_string()
}

/// `products/$id` → `ProductsId`.
pub fn pascal(dir: &str) -> String {
    dir.replace(['/', '$'], "_").to_upper_camel_case()
}
