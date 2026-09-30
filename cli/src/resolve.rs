//! Reads every file's one exported symbol, checks the contracts between files
//! and produces the IR the emitter needs.

use std::collections::HashMap;

use crate::dart::{self, split_generic, tokenize, ClassDecl};
use crate::diag::Diags;
use crate::scan::{Kind, Node, Seg};

pub const ROOT_PARAMS: &str = "Params";
const SEGMENT_TYPES: [&str; 4] = ["String", "int", "double", "bool"];

/// A class exported by a user file, referenced through its import prefix.
#[derive(Clone, Debug)]
pub struct Sym {
    pub import: usize,
    pub class: String,
}

impl Sym {
    pub fn expr(&self) -> String {
        format!("_i{}.{}", self.import, self.class)
    }
}

#[derive(Clone, Debug)]
pub struct ParamsType {
    /// Simple class name, used for subtype checks.
    pub simple: String,
    /// How generated code spells the type.
    pub expr: String,
    /// Every field from the root down, in path order.
    pub fields: Vec<(String, String)>,
    /// Where it's declared: a params.dart (relative to lib/app), `None` for
    /// the root `Params`, `Some("")` for a class generated into app.g.dart.
    pub file: Option<String>,
}

impl ParamsType {
    fn root() -> Self {
        ParamsType { simple: ROOT_PARAMS.into(), expr: ROOT_PARAMS.into(), fields: vec![], file: None }
    }

    /// Constructor call, given an expression per field.
    pub fn construct(&self, value: impl Fn(&str, &str) -> String) -> String {
        if self.fields.is_empty() && self.simple == ROOT_PARAMS {
            return "const Params()".into();
        }
        let args: Vec<String> =
            self.fields.iter().map(|(n, t)| format!("{n}: {}", value(n, t))).collect();
        format!("{}({})", self.expr, args.join(", "))
    }
}

#[derive(Clone, Debug)]
pub struct Data {
    pub import: usize,
    pub stream: bool,
    pub ty: String,
}

#[derive(Debug)]
pub struct Route {
    pub dir: String,
    pub seg: Option<Seg>,
    pub children: Vec<usize>,
    pub page: Option<Sym>,
    /// `Product` for `ProductPage`; typed route is `ProductRoute`.
    pub name: Option<String>,
    pub data: Option<Data>,
    pub loading: Option<Sym>,
    pub error: Option<Sym>,
    pub layout: Option<Sym>,
    pub guard: Option<usize>,
    pub params: ParamsType,
}

#[derive(Debug)]
pub struct Synth {
    pub name: String,
    pub parent_expr: String,
    pub parent_fields: Vec<(String, String)>,
    pub field: String,
}

#[derive(Debug, Default)]
pub struct App {
    pub imports: Vec<String>,
    pub routes: Vec<Route>,
    pub synth: Vec<Synth>,
    pub not_found: Option<Sym>,
}

#[derive(Clone)]
struct Inherited {
    params: ParamsType,
    loading: Option<(Sym, String, String)>, // symbol, P, file
    error: Option<(Sym, String, String)>,
    dynamic: Vec<String>,
}

pub fn resolve(root: &Node, diags: &mut Diags) -> App {
    let mut r = Resolver {
        app: App::default(),
        import_ix: HashMap::new(),
        parent_of: HashMap::new(),
        params_file: HashMap::new(),
        route_names: HashMap::new(),
        diags,
    };
    let top = Inherited { params: ParamsType::root(), loading: None, error: None, dynamic: vec![] };
    r.node(root, &top);
    r.app
}

struct Resolver<'a> {
    app: App,
    import_ix: HashMap<String, usize>,
    /// Params class → its superclass (simple names).
    parent_of: HashMap<String, String>,
    params_file: HashMap<String, String>,
    route_names: HashMap<String, String>,
    diags: &'a mut Diags,
}

impl Resolver<'_> {
    fn import(&mut self, rel: String) -> usize {
        if let Some(&i) = self.import_ix.get(&rel) {
            return i;
        }
        let i = self.app.imports.len();
        self.app.imports.push(rel.clone());
        self.import_ix.insert(rel, i);
        i
    }

    /// Is `sup` the same as, or a superclass of, params class `sub`?
    fn is_super(&self, sup: &str, sub: &str) -> bool {
        let mut cur = Some(sub.to_string());
        while let Some(c) = cur {
            if c == sup {
                return true;
            }
            cur = self.parent_of.get(&c).cloned();
        }
        false
    }

    /// The single class in `src` extending `base`.
    fn class_of(&mut self, node: &Node, kind: Kind, base: &str) -> Option<(ClassDecl, Sym)> {
        let src = node.files.get(&kind)?;
        let file = node.rel(kind);
        let found: Vec<ClassDecl> =
            dart::classes(&tokenize(src)).into_iter().filter(|c| c.base == base).collect();
        match found.len() {
            0 => {
                self.diags.error(&file, 0, format!("expected a class extending {base}"));
                None
            }
            1 => {
                let c = found.into_iter().next().unwrap();
                let sym = Sym { import: self.import(file), class: c.name.clone() };
                Some((c, sym))
            }
            _ => {
                self.diags.error(&file, found[1].line, format!("one {base} per file; found {}", found.len()));
                None
            }
        }
    }

    fn node(&mut self, node: &Node, up: &Inherited) -> Option<usize> {
        let mut dynamic = up.dynamic.clone();
        if let Some(Seg::Dynamic(name)) = &node.seg {
            if dynamic.contains(name) {
                self.diags.error(&node.dir, 0, format!("`${name}` is already a segment higher up this path"));
            }
            dynamic.push(name.clone());
        }

        // page.dart first: its class names the route (and synthesized params).
        let page = if node.files.contains_key(&Kind::Page) {
            self.class_of(node, Kind::Page, "Screen")
        } else {
            None
        };
        let name = page.as_ref().map(|(c, _)| route_name(&c.name));
        if let (Some(n), Some((c, _))) = (&name, &page) {
            let file = node.rel(Kind::Page);
            if let Some(prev) = self.route_names.insert(n.clone(), file.clone()) {
                self.diags.error(&file, c.line, format!("route name `{n}Route` is already taken by {prev}; rename the class"));
            }
        }

        let params = self.params(node, up, &dynamic, name.as_deref());
        let data = self.data(node, &params);

        if let Some((c, _)) = &page {
            let file = node.rel(Kind::Page);
            let got = c.base_args.clone().unwrap_or_default();
            match &data {
                Some(d) if got != d.ty => self.diags.error(
                    &file,
                    c.line,
                    format!("Screen<{got}> but data.dart yields {}", d.ty),
                ),
                None if !self.is_super(&got, &params.simple) => self.diags.error(
                    &file,
                    c.line,
                    format!("Screen<{got}> but there is no data.dart, so this page receives {}", params.simple),
                ),
                _ => {}
            }
        } else if node.files.contains_key(&Kind::Data) {
            self.diags.error(&node.rel(Kind::Data), 0, "data.dart has no page.dart to feed");
        }

        let mut here = Inherited { params: params.clone(), loading: up.loading.clone(), error: up.error.clone(), dynamic };
        if node.files.contains_key(&Kind::Loading) {
            here.loading = self.fallback(node, Kind::Loading, "Loading");
        }
        if node.files.contains_key(&Kind::Error) {
            here.error = self.fallback(node, Kind::Error, "ErrorView");
        }
        // Inherited loading/error must accept this route's params.
        if data.is_some() {
            for (slot, what) in [(&here.loading, "loading"), (&here.error, "error")] {
                if let Some((_, p, file)) = slot {
                    if !self.is_super(p, &params.simple) {
                        self.diags.error(
                            file,
                            0,
                            format!("{what} view takes {p}, but it also covers {} whose params are {}", show_dir(&node.dir), params.simple),
                        );
                    }
                }
            }
        }

        let layout = if node.files.contains_key(&Kind::Layout) {
            self.class_of(node, Kind::Layout, "Layout").map(|(_, s)| s)
        } else {
            None
        };
        let guard = self.guard(node, &params, page.is_some());

        if node.files.contains_key(&Kind::NotFound) {
            if node.dir.is_empty() {
                self.app.not_found = self.class_of(node, Kind::NotFound, "NotFoundView").map(|(_, s)| s);
            } else {
                self.diags.error(&node.rel(Kind::NotFound), 0, "not_found.dart only works at the root of lib/app");
            }
        }

        let id = self.app.routes.len();
        self.app.routes.push(Route {
            dir: node.dir.clone(),
            seg: node.seg.clone(),
            children: vec![],
            page: page.map(|(_, s)| s),
            name,
            data,
            loading: here.loading.as_ref().map(|l| l.0.clone()),
            error: here.error.as_ref().map(|e| e.0.clone()),
            layout,
            guard,
            params,
        });
        let children: Vec<usize> = node.children.iter().filter_map(|c| self.node(c, &here)).collect();
        if self.app.routes[id].page.is_none() && children.is_empty() && !node.dir.is_empty() {
            self.diags.warn(&node.dir, 0, "folder has no page.dart and no routes below it; skipped");
        }
        self.app.routes[id].children = children;
        Some(id)
    }

    fn params(&mut self, node: &Node, up: &Inherited, dynamic: &[String], name: Option<&str>) -> ParamsType {
        let parent = &up.params;
        if node.files.contains_key(&Kind::Params) {
            let file = node.rel(Kind::Params);
            let src = node.files[&Kind::Params].clone();
            let classes = dart::classes(&tokenize(&src));
            let Some(c) = classes.into_iter().next() else {
                self.diags.error(&file, 0, format!("expected `class XParams extends {}`", parent.simple));
                return parent.clone();
            };
            if c.base != parent.simple {
                self.diags.error(&file, c.line, format!("{} must extend {} (the params of the folder above)", c.name, parent.simple));
            }
            if let Some(prev) = self.params_file.insert(c.name.clone(), file.clone()) {
                self.diags.error(&file, c.line, format!("{} is already declared in {prev}", c.name));
            }
            self.parent_of.insert(c.name.clone(), parent.simple.clone());

            let mut fields = parent.fields.clone();
            for f in &c.fields {
                if !SEGMENT_TYPES.contains(&f.ty.as_str()) {
                    self.diags.error(&file, f.line, format!("`{} {}`: segment fields must be String, int, double or bool", f.ty, f.name));
                }
                if !dynamic.contains(&f.name) {
                    self.diags.error(&file, f.line, format!("field `{}` has no `${}` segment in this path", f.name, f.name));
                } else if parent.fields.iter().any(|(n, _)| n == &f.name) {
                    self.diags.error(&file, f.line, format!("`{}` is already declared by {}", f.name, parent.simple));
                }
                fields.push((f.name.clone(), f.ty.clone()));
            }
            for seg in dynamic {
                if !fields.iter().any(|(n, _)| n == seg) {
                    self.diags.error(&file, c.line, format!("missing field for segment `${seg}`"));
                }
            }
            let sym = Sym { import: self.import(file.clone()), class: c.name.clone() };
            return ParamsType { simple: c.name, expr: sym.expr(), fields, file: Some(file) };
        }

        if let Some(Seg::Dynamic(seg)) = &node.seg {
            let base = name.map(str::to_string).unwrap_or_else(|| pascal(&node.dir));
            let synth = format!("{base}Params");
            if let Some(prev) = self.params_file.insert(synth.clone(), format!("{} (generated)", node.dir)) {
                self.diags.error(&node.dir, 0, format!("generated {synth} collides with {prev}; add a params.dart"));
            }
            self.parent_of.insert(synth.clone(), parent.simple.clone());
            let mut fields = parent.fields.clone();
            fields.push((seg.clone(), "String".into()));
            self.app.synth.push(Synth {
                name: synth.clone(),
                parent_expr: parent.expr.clone(),
                parent_fields: parent.fields.clone(),
                field: seg.clone(),
            });
            return ParamsType { simple: synth.clone(), expr: synth, fields, file: Some(String::new()) };
        }
        parent.clone()
    }

    fn data(&mut self, node: &Node, params: &ParamsType) -> Option<Data> {
        let src = node.files.get(&Kind::Data)?;
        let file = node.rel(Kind::Data);
        let Some(f) = dart::function(&tokenize(src), "data") else {
            self.diags.error(&file, 0, format!("expected `Future<T> data(Ref ref, {} params)`", params.simple));
            return None;
        };
        let sig_ok = !f.non_positional
            && f.params.len() == 2
            && f.params[0].ty.as_deref() == Some("Ref");
        if !sig_ok {
            self.diags.error(&file, f.line, format!("data() must take exactly (Ref ref, {} params)", params.simple));
        }
        if let Some(p) = f.params.get(1) {
            match &p.ty {
                Some(t) if !self.is_super(t, &params.simple) => self.diags.error(
                    &file,
                    f.line,
                    format!("data() takes {t}, but this route's params are {}", params.simple),
                ),
                None => self.diags.error(&file, f.line, format!("give `{}` a type ({})", p.name, params.simple)),
                _ => {}
            }
        }
        let Some(ret) = f.ret else {
            self.diags.error(&file, f.line, "data() needs an explicit return type (Future<T>, Stream<T> or T)");
            return None;
        };
        let (head, args) = split_generic(&ret);
        let (stream, ty) = match (head.as_str(), args.as_slice()) {
            ("Future" | "FutureOr", [t]) => (false, t.clone()),
            ("Stream", [t]) => (true, t.clone()),
            _ => (false, ret.clone()),
        };
        Some(Data { import: self.import(file), stream, ty })
    }

    fn fallback(&mut self, node: &Node, kind: Kind, base: &str) -> Option<(Sym, String, String)> {
        let (c, sym) = self.class_of(node, kind, base)?;
        let p = c.base_args.clone().unwrap_or_else(|| ROOT_PARAMS.into());
        Some((sym, p, node.rel(kind)))
    }

    fn guard(&mut self, node: &Node, params: &ParamsType, has_page: bool) -> Option<usize> {
        let src = node.files.get(&Kind::Guard)?;
        let file = node.rel(Kind::Guard);
        if !has_page {
            self.diags.error(&file, 0, "guard.dart needs a page.dart in the same folder");
            return None;
        }
        let Some(f) = dart::function(&tokenize(src), "guard") else {
            self.diags.error(&file, 0, format!("expected `GuardResult guard(ProviderContainer c, {} params)`", params.simple));
            return None;
        };
        let ok_ret = matches!(
            f.ret.as_deref(),
            Some("GuardResult" | "FutureOr<String?>" | "Future<String?>" | "String?")
        );
        if !ok_ret {
            self.diags.error(&file, f.line, "guard() must return GuardResult (a location to redirect to, or null)");
        }
        let sig_ok = !f.non_positional
            && f.params.len() == 2
            && f.params[0].ty.as_deref() == Some("ProviderContainer");
        if !sig_ok {
            self.diags.error(&file, f.line, format!("guard() must take (ProviderContainer c, {} params)", params.simple));
        }
        if let Some(Some(t)) = f.params.get(1).map(|p| p.ty.clone()) {
            if !self.is_super(&t, &params.simple) {
                self.diags.error(&file, f.line, format!("guard() takes {t}, but this route's params are {}", params.simple));
            }
        }
        Some(self.import(file))
    }
}

/// `ProductPage` → `Product`, `CartScreen` → `Cart`.
fn route_name(class: &str) -> String {
    for suffix in ["Page", "Screen"] {
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
    dir.split(['/', '-', '_', '.', '$'])
        .filter(|s| !s.is_empty())
        .map(|s| {
            let mut c = s.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        })
        .collect()
}

fn show_dir(dir: &str) -> String {
    if dir.is_empty() { "/".into() } else { format!("{dir}/") }
}
