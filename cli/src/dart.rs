//! Reads the declarations fespalier cares about out of a Dart file, using the
//! tree-sitter Dart grammar: top-level classes (with their unnamed constructor
//! and fields), functions, and `final x = SomeProvider<...>(...)` variables.
//!
//! This is a syntax tree, not the analyzer: types are compared by their
//! canonical spelling. Anything that slips through is still caught by the Dart
//! compiler in the generated code.

use std::collections::HashMap;
use std::ops::Range;

use tree_sitter::{Node, Parser};

#[derive(Debug, Clone, Default)]
pub struct Module {
    pub classes: Vec<Class>,
    pub functions: Vec<Function>,
    pub variables: Vec<Variable>,
    /// Where the grammar first gave up on the file (an ERROR or MISSING node),
    /// after primary constructors were read separately. The file may still be
    /// valid Dart the grammar is too old for; the declarations above are read
    /// on a best-effort basis.
    pub parse_error: Option<Span>,
}

#[derive(Debug, Clone)]
pub struct Class {
    pub name: String,
    pub superclass: Option<String>,
    /// Parameters of the unnamed constructor; empty when there is none.
    pub params: Vec<Param>,
    pub span: Span,
}

impl Class {
    pub fn is_public(&self) -> bool {
        !self.name.starts_with('_')
    }
}

#[derive(Debug, Clone)]
pub struct Function {
    pub name: String,
    /// `None` when the return type is left to inference.
    pub ret: Option<Ty>,
    pub params: Vec<Param>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct Variable {
    pub name: String,
    /// Set when the initializer is a call like `FutureProvider.family<A, B>(...)`.
    pub call: Option<Call>,
    /// Set when the initializer is a list of plain string literals, like
    /// `const tabs = ['home', 'search'];`: each string with where it sits.
    pub strings: Option<Vec<(String, Span)>>,
    /// Set when the initializer is a map from string literals to constructor
    /// calls, like `const tabOptions = {'search': TabOptions(preload: true)};`.
    pub objects: Option<Vec<ObjectEntry>>,
    /// Declared with `const` (not `final`, `var` or `late`).
    pub is_const: bool,
    pub span: Span,
}

/// `'search': TabOptions(preload: true, initialLocation: '/search')`
#[derive(Debug, Clone)]
pub struct ObjectEntry {
    pub key: String,
    pub key_span: Span,
    /// The class called: `TabOptions`.
    pub class: String,
    pub args: Vec<ObjectArg>,
}

#[derive(Debug, Clone)]
pub struct ObjectArg {
    pub name: String,
    pub value: Lit,
    pub span: Span,
}

/// An argument value the generator can read without evaluating Dart.
#[derive(Debug, Clone, PartialEq)]
pub enum Lit {
    Bool(bool),
    Str(String),
    /// Anything else: a number, an interpolated string, an expression.
    Other,
}

/// `FutureProvider.autoDispose.family<T, Arg>(...)`
#[derive(Debug, Clone)]
pub struct Call {
    /// `["FutureProvider", "autoDispose", "family"]`
    pub chain: Vec<String>,
    pub type_args: Vec<Ty>,
}

#[derive(Debug, Clone)]
pub struct Param {
    pub name: String,
    /// Declared type, or for `this.x` the type of field `x`.
    pub ty: Option<Ty>,
    pub named: bool,
    /// Positional parameters outside `[...]`, and named ones marked `required`.
    pub required: bool,
    /// `super.key` and friends: forwarded to the superclass, never ours to fill.
    pub is_super: bool,
    pub span: Span,
}

/// A type as written, normalized: `Future< List<A> >` → `Future<List<A>>`.
#[derive(Debug, Clone, PartialEq)]
pub struct Ty {
    pub text: String,
    /// Named fields when this is a record type `({int id, String name})`.
    pub record: Option<Vec<(String, Ty)>>,
}

impl Ty {
    pub fn is(&self, s: &str) -> bool {
        self.text == s
    }

    /// `Future<List<A>>` → ("Future", ["List<A>"]).
    pub fn generic(&self) -> (&str, Vec<&str>) {
        let t = self.text.as_str();
        let (Some(open), true) = (t.find('<'), t.ends_with('>')) else { return (t, vec![]) };
        let inner = &t[open + 1..t.len() - 1];
        let (mut args, mut depth, mut start) = (vec![], 0i32, 0);
        for (i, ch) in inner.char_indices() {
            match ch {
                '<' | '(' | '{' => depth += 1,
                '>' | ')' | '}' => depth -= 1,
                ',' if depth == 0 => {
                    args.push(inner[start..i].trim());
                    start = i + 1;
                }
                _ => {}
            }
        }
        args.push(inner[start..].trim());
        (&t[..open], args)
    }
}

/// Where a declaration sits in its file.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Span {
    pub line: usize,
    pub bytes: Range<usize>,
}

impl Span {
    fn of(n: Node) -> Span {
        Span { line: n.start_position().row + 1, bytes: n.byte_range() }
    }
}

pub fn parse(src: &str) -> Module {
    let mut parser = Parser::new();
    parser
        .set_language(&tree_sitter_dart::LANGUAGE.into())
        .expect("tree-sitter-dart grammar is compatible with this tree-sitter");
    let Some(mut tree) = parser.parse(src, None) else { return Module::default() };
    let mut primary = HashMap::new();
    let mut patched = None;
    if tree.root_node().has_error() {
        // Primary constructors (`class A(final int id) extends B`) are newer than
        // the grammar: hide their parameter lists, read them separately.
        let headers = primary_headers(src);
        if !headers.is_empty() {
            let (text, params) = split_primary(&mut parser, src, &headers);
            if let Some(t) = parser.parse(&text, None) {
                (tree, primary, patched) = (t, params, Some(text));
            }
        }
    }
    let r = Reader { src: patched.as_deref().unwrap_or(src), primary };
    let root = tree.root_node();
    let mut m = Module { parse_error: first_error(root, r.src), ..Module::default() };
    let mut cur = root.walk();
    let top: Vec<Node> = root.named_children(&mut cur).collect();
    for (i, n) in top.iter().enumerate() {
        match n.kind() {
            "class_declaration" => {
                // A class the grammar closed too early leaves its later members
                // at the top level, so its fields show up as plain variables.
                let rest: Vec<&Node> = top[i + 1..].iter().take_while(|s| s.kind() != "class_declaration").collect();
                let damaged = n.has_error() || rest.iter().any(|s| s.kind() == "ERROR");
                let orphans = if damaged { r.orphan_fields(&rest) } else { HashMap::new() };
                m.classes.extend(r.class(*n, &orphans));
            }
            "function_declaration" => m.functions.extend(r.function(*n)),
            "top_level_variable_declaration" => m.variables.extend(r.variables(*n)),
            _ => {}
        }
    }
    m
}

/// The first ERROR or MISSING node, cut to its first line so the code frame
/// stays small when the grammar swallows the rest of the file.
fn first_error(root: Node, src: &str) -> Option<Span> {
    // An ERROR node can wrap everything from the top of the file; the innermost
    // error or missing node inside it is closer to what went wrong.
    fn find(n: Node) -> Option<Node> {
        if n.is_missing() {
            return Some(n);
        }
        if !n.has_error() {
            return None;
        }
        let mut cur = n.walk();
        let inner = n.children(&mut cur).find_map(find);
        inner.or(n.is_error().then_some(n))
    }
    let n = find(root)?;
    let start = n.start_byte();
    let mut end = n.end_byte().min(src.len());
    if let Some(nl) = src.get(start..end).and_then(|t| t.find('\n')) {
        end = start + nl;
    }
    if end <= start {
        // A MISSING node has no text: point at the character it should precede.
        end = src[start.min(src.len())..].chars().next().map_or(start, |c| start + c.len_utf8());
    }
    Some(Span { line: n.start_position().row + 1, bytes: start..end.max(start) })
}

struct Reader<'a> {
    src: &'a str,
    /// Primary-constructor parameters, by the byte offset of the class name.
    primary: HashMap<usize, Vec<Param>>,
}

impl Reader<'_> {
    fn text(&self, n: Node) -> &str {
        &self.src[n.byte_range()]
    }

    fn class(&self, n: Node, orphans: &HashMap<String, Ty>) -> Option<Class> {
        let name_node = n.child_by_field_name("name")?;
        let name = self.text(name_node).to_string();
        let superclass = n.child_by_field_name("superclass").and_then(|s| self.qualified(first_named(s, "type")?));
        let body = n.child_by_field_name("body")?;

        let mut fields: HashMap<String, Ty> = HashMap::new();
        let mut ctor: Option<Node> = None;
        for member in members(body) {
            let mut cur = member.walk();
            for part in member.named_children(&mut cur) {
                // A signature is a `declaration` on its own, or wrapped when it has a body.
                let kids: Vec<Node> = match part.kind() {
                    "declaration" => part.named_children(&mut part.walk()).collect(),
                    "method_declaration" => match first_named(part, "method_signature") {
                        Some(sig) => sig.named_children(&mut sig.walk()).collect(),
                        None => continue,
                    },
                    _ => continue,
                };
                // `final Type a, b;` — instance fields with an explicit type.
                if part.kind() == "declaration" && !kids.iter().any(|k| k.kind() == "static") {
                    if let (Some(ty), Some(list)) = (
                        kids.iter().find(|k| k.kind() == "type"),
                        kids.iter().find(|k| k.kind() == "initialized_identifier_list"),
                    ) {
                        let mut c3 = list.walk();
                        for id in list.named_children(&mut c3) {
                            if let Some(f) = id.child_by_field_name("name") {
                                fields.insert(self.text(f).to_string(), self.ty(*ty));
                            }
                        }
                    }
                }
                // The unnamed constructor: `const X(...)`, `X(...) {}`, `factory X(...)`, `this(...)`.
                for k in &kids {
                    if k.kind().ends_with("constructor_signature")
                        && matches!(self.ctor_name(*k).as_deref(), Some(c) if c == name || c == "this")
                    {
                        ctor = Some(*k);
                    }
                }
            }
        }
        for (f, ty) in orphans {
            fields.entry(f.clone()).or_insert_with(|| ty.clone());
        }

        let params = match ctor.and_then(|c| first_named(c, "formal_parameter_list")) {
            Some(list) => self.params(list, &fields),
            None => self.primary.get(&name_node.start_byte()).cloned().unwrap_or_default(),
        };
        Some(Class { name, superclass, params, span: Span::of(name_node) })
    }

    /// The typed fields of a class cut short by a parse error, which the
    /// grammar left behind as top-level `final int a;` declarations.
    fn orphan_fields(&self, rest: &[&Node]) -> HashMap<String, Ty> {
        let mut out = HashMap::new();
        for n in rest.iter().filter(|n| n.kind() == "top_level_variable_declaration") {
            let Some(ty) = first_named(**n, "type") else { continue };
            let mut cur = n.walk();
            for list in n.named_children(&mut cur) {
                let mut c2 = list.walk();
                for d in list.named_children(&mut c2) {
                    if let Some(f) = d.child_by_field_name("name") {
                        out.insert(self.text(f).to_string(), self.ty(ty));
                    }
                }
            }
        }
        out
    }

    /// `w.Base<T>` → `w.Base`: the name a class extends, prefix included.
    fn qualified(&self, ty: Node) -> Option<String> {
        let mut cur = ty.walk();
        let parts: Vec<&str> = ty.named_children(&mut cur).filter(|c| c.kind() == "type_identifier").map(|c| self.text(c)).collect();
        (!parts.is_empty()).then(|| parts.join("."))
    }

    /// `X` for `X(...)`, `X.named` for `X.named(...)`.
    fn ctor_name(&self, sig: Node) -> Option<String> {
        let mut cur = sig.walk();
        let parts: Vec<&str> = sig.children_by_field_name("name", &mut cur).map(|p| self.text(p)).collect();
        (!parts.is_empty()).then(|| parts.join("."))
    }

    fn function(&self, n: Node) -> Option<Function> {
        let sig = n.child_by_field_name("signature")?;
        let name_node = sig.child_by_field_name("name")?;
        let name = self.text(name_node).to_string();
        let ret = sig.child_by_field_name("return_type").map(|t| self.ty(t));
        // Generic functions carry two `parameters`: the type parameters come first.
        let params = first_named(sig, "formal_parameter_list")
            .map(|p| self.params(p, &HashMap::new()))
            .unwrap_or_default();
        Some(Function { name, ret, params, span: Span::of(name_node) })
    }

    fn variables(&self, n: Node) -> Vec<Variable> {
        let mut out = vec![];
        let is_const = n.children(&mut n.walk()).any(|k| k.kind() == "const");
        let mut cur = n.walk();
        for list in n.named_children(&mut cur) {
            let mut c2 = list.walk();
            for d in list.named_children(&mut c2) {
                let Some(name) = d.child_by_field_name("name") else { continue };
                let value = d.child_by_field_name("value");
                let call = value.and_then(|v| self.call(v));
                let strings = value.and_then(|v| self.strings(v));
                let objects = value.and_then(|v| self.objects(v));
                out.push(Variable { name: self.text(name).to_string(), call, strings, objects, is_const, span: Span::of(name) });
            }
        }
        out
    }

    /// `['a', 'b']` (optionally `const` or `<String>`) → its strings. `None` for
    /// anything else, including a list with an interpolated or non-string element.
    fn strings(&self, v: Node) -> Option<Vec<(String, Span)>> {
        if v.kind() != "list_literal" {
            return None;
        }
        let mut out = vec![];
        let mut cur = v.walk();
        for e in v.named_children(&mut cur) {
            match e.kind() {
                "type_arguments" | "comment" | "documentation_comment" => {}
                "string_literal" => out.push((string_value(self.text(e))?, Span::of(e))),
                _ => return None,
            }
        }
        Some(out)
    }

    /// `{'a': Foo(x: 1), 'b': const Foo()}` (optionally `const` or `<String, Foo>`)
    /// → its entries. `None` for anything else: a non-string key, a value that
    /// isn't a constructor call, a positional argument, a spread.
    fn objects(&self, v: Node) -> Option<Vec<ObjectEntry>> {
        if v.kind() != "set_or_map_literal" {
            return None;
        }
        let mut out = vec![];
        let mut cur = v.walk();
        for e in v.named_children(&mut cur) {
            match e.kind() {
                "type_arguments" | "comment" | "documentation_comment" => {}
                "pair" => {
                    let key = e.child_by_field_name("key")?;
                    let value = e.child_by_field_name("value")?;
                    if key.kind() != "string_literal" {
                        return None;
                    }
                    let (class, args) = match value.kind() {
                        "call_expression" => (value.child_by_field_name("function")?, value.child_by_field_name("arguments")?),
                        "const_object_expression" => (value.child_by_field_name("type")?, value.child_by_field_name("arguments")?),
                        _ => return None,
                    };
                    if !matches!(class.kind(), "identifier" | "type") {
                        return None;
                    }
                    let mut parsed = vec![];
                    let mut c2 = args.walk();
                    for a in args.named_children(&mut c2) {
                        if a.kind() != "named_argument" {
                            return None;
                        }
                        let label = first_named(a, "label")?;
                        let expr = a.named_child(u32::try_from(a.named_child_count().checked_sub(1)?).ok()?)?;
                        let lit = match expr.kind() {
                            "true" => Lit::Bool(true),
                            "false" => Lit::Bool(false),
                            "string_literal" => string_value(self.text(expr)).map_or(Lit::Other, Lit::Str),
                            _ => Lit::Other,
                        };
                        let name = self.text(label).trim_end_matches(':').trim().to_string();
                        parsed.push(ObjectArg { name, value: lit, span: Span::of(expr) });
                    }
                    out.push(ObjectEntry {
                        key: string_value(self.text(key))?,
                        key_span: Span::of(key),
                        class: self.text(class).to_string(),
                        args: parsed,
                    });
                }
                _ => return None,
            }
        }
        Some(out)
    }

    /// `A.b.c<T, U>(...)` → chain `[A, b, c]`, type args `[T, U]`.
    fn call(&self, v: Node) -> Option<Call> {
        if v.kind() != "call_expression" {
            return None;
        }
        let mut f = v.child_by_field_name("function")?;
        let mut type_args = vec![];
        if f.kind() == "instantiation_expression" {
            if let Some(ta) = f.child_by_field_name("type_arguments") {
                let mut cur = ta.walk();
                type_args = ta.named_children(&mut cur).filter(|t| t.kind() == "type").map(|t| self.ty(t)).collect();
            }
            f = f.child_by_field_name("function")?;
        }
        let mut chain = vec![];
        loop {
            match f.kind() {
                "member_expression" => {
                    chain.push(self.text(f.child_by_field_name("property")?).to_string());
                    f = f.child_by_field_name("object")?;
                }
                "identifier" => {
                    chain.push(self.text(f).to_string());
                    break;
                }
                _ => return None,
            }
        }
        chain.reverse();
        // `riverpod.FutureProvider(...)`: drop an import prefix.
        let prefix = chain.iter().take_while(|c| c.starts_with(|ch: char| ch.is_lowercase() || ch == '_')).count();
        if prefix < chain.len() && chain[prefix].starts_with(char::is_uppercase) {
            chain.drain(..prefix);
        }
        Some(Call { chain, type_args })
    }

    fn params(&self, list: Node, fields: &HashMap<String, Ty>) -> Vec<Param> {
        let mut out = vec![];
        let mut cur = list.walk();
        for child in list.children(&mut cur) {
            match child.kind() {
                "formal_parameter" => out.extend(self.param(child, fields, false, true)),
                "optional_formal_parameters" => {
                    let named = child.child(0).is_some_and(|c| c.kind() == "{");
                    let mut required = false;
                    let mut c2 = child.walk();
                    for p in child.children(&mut c2) {
                        match p.kind() {
                            "required" => required = true,
                            "formal_parameter" => {
                                out.extend(self.param(p, fields, named, required));
                                required = false;
                            }
                            _ => {}
                        }
                    }
                }
                _ => {}
            }
        }
        out
    }

    fn param(&self, p: Node, fields: &HashMap<String, Ty>, named: bool, mut required: bool) -> Option<Param> {
        let span = Span::of(p);
        // The grammar reads a leading `{required this.x` as a type called
        // `required`; treat it as the keyword.
        let mut declared = |n: Node| {
            let ty = first_named(n, "type").map(|t| self.ty(t));
            if ty.as_ref().is_some_and(|t| t.is("required")) {
                required = true;
                return None;
            }
            ty
        };
        if let Some(s) = first_named(p, "super_formal_parameter") {
            declared(s);
            let name = self.text(last_named(s, "identifier")?).to_string();
            return Some(Param { name, ty: None, named, required, is_super: true, span });
        }
        if let Some(c) = first_named(p, "constructor_param") {
            let ty = declared(c);
            let name = self.text(last_named(c, "identifier")?).to_string();
            let ty = ty.or_else(|| fields.get(&name).cloned());
            return Some(Param { name, ty, named, required, is_super: false, span });
        }
        // An untyped parameter (`ref`) has no `name` field, just an identifier.
        let name = p.child_by_field_name("name").or_else(|| last_named(p, "identifier"))?;
        let ty = declared(p);
        Some(Param { name: self.text(name).to_string(), ty, named, required, is_super: false, span })
    }

    fn ty(&self, n: Node) -> Ty {
        let mut text = String::new();
        let mut prev_word = false;
        leaves(n, &mut |leaf| {
            let s = self.text(leaf);
            let word = s.chars().next().is_some_and(|c| c.is_alphanumeric() || c == '_' || c == '$');
            if s == "," {
                text.push_str(", ");
            } else {
                // `int a`, `String? tab`, `Future<void> Function()`: a word after a word or a closer.
                if word && (prev_word || text.ends_with(['?', '>', ')'])) {
                    text.push(' ');
                }
                text.push_str(s);
            }
            prev_word = word;
        });
        let record = first_named(n, "record_type").map(|r| {
            let mut out = vec![];
            let mut cur = r.walk();
            for f in r.named_children(&mut cur).filter(|f| f.kind() == "record_type_named_field") {
                if let Some(ti) = first_named(f, "typed_identifier") {
                    if let (Some(t), Some(name)) = (ti.child_by_field_name("type"), ti.child_by_field_name("name")) {
                        out.push((self.text(name).to_string(), self.ty(t)));
                    }
                }
            }
            out
        });
        Ty { text, record }
    }
}

/// The value of a simple string literal, `None` when it interpolates. Only the
/// escapes a folder name could need are understood: `\$`, `\\`, `\'` and `\"`.
fn string_value(lit: &str) -> Option<String> {
    let raw = lit.starts_with('r');
    let q = lit.strip_prefix('r').unwrap_or(lit);
    let inner = if q.len() >= 6 && (q.starts_with("'''") || q.starts_with("\"\"\"")) {
        &q[3..q.len() - 3]
    } else if q.len() >= 2 {
        &q[1..q.len() - 1]
    } else {
        return None;
    };
    if raw {
        return Some(inner.to_string());
    }
    let mut out = String::new();
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        match c {
            '$' => return None,
            '\\' => out.push(chars.next().filter(|n| matches!(n, '$' | '\\' | '\'' | '"'))?),
            c => out.push(c),
        }
    }
    Some(out)
}

/// The class members of a body, looking through error recovery nodes.
fn members(body: Node) -> Vec<Node> {
    let mut out = vec![];
    let mut cur = body.walk();
    for c in body.named_children(&mut cur) {
        match c.kind() {
            "class_member" => out.push(c),
            "ERROR" => out.extend(members(c)),
            _ => {}
        }
    }
    out
}

/// A `class [const] Name[<T>](params)` header: a primary constructor, which
/// the grammar can't read.
struct Primary {
    konst: Option<Range<usize>>,
    name: Range<usize>,
    /// The parameter list, parentheses included.
    params: Range<usize>,
}

/// Finds primary-constructor class headers at the top level of `src`.
fn primary_headers(src: &str) -> Vec<Primary> {
    let b = src.as_bytes();
    let (mut out, mut i, mut depth) = (vec![], 0, 0usize);
    while i < b.len() {
        if let Some(end) = skip_literal(b, i) {
            i = end;
            continue;
        }
        match b[i] {
            b'{' => depth += 1,
            b'}' => depth = depth.saturating_sub(1),
            _ if depth == 0 && word_at(b, i, "class") => {
                if let Some((header, end)) = primary_header(b, i + 5) {
                    out.push(header);
                    i = end;
                    continue;
                }
            }
            _ => {}
        }
        i += 1;
    }
    out
}

/// What follows `class`: `[const] Name[<T>](...)`, and where it ends.
fn primary_header(b: &[u8], mut i: usize) -> Option<(Primary, usize)> {
    let mut konst = None;
    let mut name = word_after(b, &mut i)?;
    if &b[name.clone()] == b"const" {
        konst = Some(name);
        name = word_after(b, &mut i)?;
    }
    skip_space(b, &mut i);
    if b.get(i) == Some(&b'<') {
        let mut depth = 0;
        while i < b.len() {
            match b[i] {
                b'<' => depth += 1,
                b'>' => depth -= 1,
                b'{' | b';' => return None,
                _ => {}
            }
            i += 1;
            if depth == 0 {
                break;
            }
        }
        skip_space(b, &mut i);
    }
    if b.get(i) != Some(&b'(') {
        return None;
    }
    let close = closer(b, i)?;
    Some((Primary { konst, name, params: i..close + 1 }, close + 1))
}

fn is_word(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'$'
}

fn word_at(b: &[u8], i: usize, w: &str) -> bool {
    b[i..].starts_with(w.as_bytes()) && (i == 0 || !is_word(b[i - 1])) && !b.get(i + w.len()).is_some_and(|c| is_word(*c))
}

/// Skips whitespace and comments.
fn skip_space(b: &[u8], i: &mut usize) {
    while *i < b.len() {
        if b[*i].is_ascii_whitespace() {
            *i += 1;
        } else if let Some(end) = skip_literal(b, *i).filter(|_| b[*i] == b'/') {
            *i = end;
        } else {
            break;
        }
    }
}

/// The identifier at `i` (after any space); moves `i` past it.
fn word_after(b: &[u8], i: &mut usize) -> Option<Range<usize>> {
    skip_space(b, i);
    let start = *i;
    while *i < b.len() && is_word(b[*i]) {
        *i += 1;
    }
    (*i > start).then_some(start..*i)
}

/// The index of the bracket closing the one at `open`, skipping strings and comments.
fn closer(b: &[u8], open: usize) -> Option<usize> {
    let mut depth = 0usize;
    let mut i = open;
    while i < b.len() {
        if let Some(end) = skip_literal(b, i) {
            i = end;
            continue;
        }
        match b[i] {
            b'(' | b'[' | b'{' => depth += 1,
            b')' | b']' | b'}' => {
                depth = depth.checked_sub(1)?;
                if depth == 0 {
                    return Some(i);
                }
            }
            _ => {}
        }
        i += 1;
    }
    None
}

/// If a comment or string literal starts at `i`, the index just past it.
fn skip_literal(b: &[u8], i: usize) -> Option<usize> {
    let n = b.len();
    match b[i] {
        b'/' if b.get(i + 1) == Some(&b'/') => Some(b[i..].iter().position(|c| *c == b'\n').map_or(n, |p| i + p)),
        b'/' if b.get(i + 1) == Some(&b'*') => {
            let (mut j, mut depth) = (i + 2, 1);
            while j < n && depth > 0 {
                match (b[j], b.get(j + 1)) {
                    (b'/', Some(b'*')) => (depth, j) = (depth + 1, j + 2),
                    (b'*', Some(b'/')) => (depth, j) = (depth - 1, j + 2),
                    _ => j += 1,
                }
            }
            Some(j.min(n))
        }
        c => {
            let raw = c == b'r' && matches!(b.get(i + 1), Some(b'\'' | b'"')) && (i == 0 || !is_word(b[i - 1]));
            let start = i + usize::from(raw);
            let q = *b.get(start).filter(|q| matches!(q, b'\'' | b'"'))?;
            let triple = b.get(start + 1) == Some(&q) && b.get(start + 2) == Some(&q);
            let mut j = start + if triple { 3 } else { 1 };
            while j < n {
                match b[j] {
                    b'\\' if !raw => j += 2,
                    b'$' if !raw && b.get(j + 1) == Some(&b'{') => j = closer(b, j + 1).map_or(n, |e| e + 1),
                    b'\n' if !triple => return Some(j),
                    c if c == q && (!triple || b[j..].starts_with(&[q, q, q])) => return Some(j + if triple { 3 } else { 1 }),
                    _ => j += 1,
                }
            }
            Some(n)
        }
    }
}

/// Reads primary-constructor parameter lists apart from the source. Returns the
/// source with the headers blanked out (same length, same lines), so the class
/// itself parses as usual, and the parameters by class-name offset.
fn split_primary(parser: &mut Parser, src: &str, headers: &[Primary]) -> (String, HashMap<usize, Vec<Param>>) {
    let blank = |b: &mut [u8], r: Range<usize>| b[r].iter_mut().filter(|c| **c != b'\n').for_each(|c| *c = b' ');
    let mut patched = src.as_bytes().to_vec();
    // A scratch file where each list reads as `Name(params) {}`, at its own offset.
    let mut scratch: Vec<u8> = src.bytes().map(|c| if c == b'\n' { c } else { b' ' }).collect();
    for h in headers {
        scratch[h.name.clone()].copy_from_slice(&src.as_bytes()[h.name.clone()]);
        scratch[h.params.clone()].copy_from_slice(&src.as_bytes()[h.params.clone()]);
        // An empty body, in the first two blanks after the list.
        let blanks = (h.params.end..scratch.len()).filter(|i| scratch[*i] == b' ').take(2).collect::<Vec<_>>();
        if let [open, close] = blanks[..] {
            (scratch[open], scratch[close]) = (b'{', b'}');
        }
        blank(&mut patched, h.params.clone());
        if let Some(k) = &h.konst {
            blank(&mut patched, k.clone());
        }
    }
    let mut out = HashMap::new();
    let scratch = String::from_utf8_lossy(&scratch).into_owned();
    if let Some(tree) = parser.parse(&scratch, None) {
        let r = Reader { src: &scratch, primary: HashMap::new() };
        let root = tree.root_node();
        let mut cur = root.walk();
        for f in root.named_children(&mut cur).filter(|f| f.kind() == "function_declaration") {
            if let Some(f) = r.function(f) {
                out.insert(f.span.bytes.start, f.params);
            }
        }
    }
    (String::from_utf8_lossy(&patched).into_owned(), out)
}

fn first_named<'t>(n: Node<'t>, kind: &str) -> Option<Node<'t>> {
    let mut cur = n.walk();
    let found = n.named_children(&mut cur).find(|c| c.kind() == kind);
    found
}

fn last_named<'t>(n: Node<'t>, kind: &str) -> Option<Node<'t>> {
    let mut cur = n.walk();
    let found = n.named_children(&mut cur).filter(|c| c.kind() == kind).last();
    found
}

fn leaves<'t>(n: Node<'t>, f: &mut impl FnMut(Node<'t>)) {
    if n.child_count() == 0 {
        f(n);
        return;
    }
    let mut cur = n.walk();
    for c in n.children(&mut cur) {
        leaves(c, f);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_widget_constructor() {
        let m = parse(
            r#"
            import 'package:x/y.dart'; // class Fake extends Nope {}
            class ProductPage extends HookConsumerWidget {
              const ProductPage(this.id, {super.key, required this.product, int? limit = 1});
              ProductPage.named();
              final Map< String,List<int> > counts;
              final Product product;
              final int id;
              @override
              Widget build(BuildContext context, WidgetRef ref) => Text('class Nope extends X ${id}');
            }
            class _Private extends StatelessWidget {}
            "#,
        );
        assert_eq!(m.classes.len(), 2);
        let c = &m.classes[0];
        assert_eq!((c.name.as_str(), c.superclass.as_deref()), ("ProductPage", Some("HookConsumerWidget")));
        let p: Vec<_> = c
            .params
            .iter()
            .map(|p| (p.name.as_str(), p.ty.as_ref().map(|t| t.text.as_str()), p.named, p.required, p.is_super))
            .collect();
        assert_eq!(
            p,
            vec![
                ("id", Some("int"), false, true, false),
                ("key", None, true, false, true),
                ("product", Some("Product"), true, true, false),
                ("limit", Some("int?"), true, false, false),
            ]
        );
        assert!(!m.classes[1].is_public());
    }

    #[test]
    fn reads_functions_and_records() {
        let m = parse(
            "@riverpod\nFuture<List<Product>> data(Ref ref, {required int id, required ({int a, String b}) r}) async => [];\n\
             data2(Ref ref) => 1;",
        );
        let f = &m.functions[0];
        assert_eq!(f.ret.as_ref().unwrap().text, "Future<List<Product>>");
        assert_eq!(f.ret.as_ref().unwrap().generic(), ("Future", vec!["List<Product>"]));
        assert_eq!(f.params[2].ty.as_ref().unwrap().text, "({int a, String b})");
        let rec = f.params[2].ty.as_ref().unwrap().record.clone().unwrap();
        assert_eq!(rec.iter().map(|(n, t)| (n.as_str(), t.text.as_str())).collect::<Vec<_>>(), vec![("a", "int"), ("b", "String")]);
        assert!(m.functions[1].ret.is_none());
    }

    #[test]
    fn reads_grammar_corner_cases() {
        let m = parse("data(ref, int id) => 1;\nclass P extends StatelessWidget { const P({required this.x}); final int x; }");
        let f = &m.functions[0];
        assert_eq!((f.params[0].name.as_str(), f.params[0].ty.is_none()), ("ref", true));
        assert_eq!(f.params[1].name, "id");
        let x = &m.classes[0].params[0];
        assert_eq!((x.name.as_str(), x.required, x.ty.as_ref().map(|t| t.text.as_str())), ("x", true, Some("int")));
    }

    #[test]
    fn variables_know_whether_they_are_const() {
        let m = parse(
            "const a = 1;\nfinal b = 2;\nvar c = 3;\nlate final d = 4;\nconst E e = E();\nconst f = 1, g = 2;\nint get h => 5;",
        );
        let konst = |n: &str| m.variables.iter().find(|v| v.name == n).map(|v| v.is_const);
        assert_eq!(
            ["a", "b", "c", "d", "e", "f", "g", "h"].map(konst),
            [Some(true), Some(false), Some(false), Some(false), Some(true), Some(true), Some(true), None]
        );
    }

    #[test]
    fn reads_provider_variables() {
        let m = parse("final data = FutureProvider.autoDispose.family<Product, ({int id})>((ref, k) => x);");
        let c = m.variables[0].call.as_ref().unwrap();
        assert_eq!(c.chain, ["FutureProvider", "autoDispose", "family"]);
        assert_eq!(c.type_args[0].text, "Product");
        assert!(c.type_args[1].record.is_some());
    }

    /// `id:int`, `[opt:int]`, `{name:String}`, `{!req:int}`, `{!super.key}`.
    fn sig(params: &[Param]) -> Vec<String> {
        params
            .iter()
            .map(|p| {
                let name = if p.is_super { format!("super.{}", p.name) } else { p.name.clone() };
                let ty = p.ty.as_ref().map_or(String::new(), |t| format!(":{}", t.text));
                match (p.named, p.required) {
                    (true, true) => format!("{{!{name}{ty}}}"),
                    (true, false) => format!("{{{name}{ty}}}"),
                    (false, true) => format!("{name}{ty}"),
                    (false, false) => format!("[{name}{ty}]"),
                }
            })
            .collect()
    }

    fn class_sig<'m>(m: &'m Module, name: &str) -> (Option<&'m str>, Vec<String>) {
        let c = m.classes.iter().find(|c| c.name == name).unwrap_or_else(|| panic!("no class {name}: {:?}", m.classes));
        (c.superclass.as_deref(), sig(&c.params))
    }

    fn assert_class(m: &Module, name: &str, sup: &str, params: &[&str]) {
        assert_eq!(class_sig(m, name), (Some(sup), params.iter().map(|s| s.to_string()).collect()), "{name}");
    }

    #[test]
    fn reads_class_modifiers_and_clauses() {
        let m = parse(
            r#"
            library;
            import 'package:flutter/material.dart';
            export 'b.dart' show B;
            part 'page.g.dart';

            final class A1 extends StatelessWidget { const A1({super.key}); }
            base class A2 extends StatelessWidget { const A2({super.key}); }
            sealed class A3 extends StatelessWidget { const A3({super.key}); }
            abstract class A4 extends StatelessWidget { const A4({super.key}); }
            abstract base class A5 extends StatelessWidget { const A5({super.key}); }
            interface class A6 extends StatelessWidget { const A6({super.key}); }
            mixin class A7 { A7(); }
            class A8 extends Base with M1, M2<int> implements I1, I2 { const A8({super.key}); }
            class ListPage<T> extends StatelessWidget {
              const ListPage({super.key, required this.items, this.selected});
              final List<T> items;
              final T? selected;
            }
            class Gen<T extends Object?> extends Base<T, List<T>> { const Gen(this.x); final T x; }
            class Prefixed extends w.StatelessWidget { const Prefixed({super.key}); }
            "#,
        );
        for n in ["A1", "A2", "A3", "A4", "A5", "A6"] {
            assert_class(&m, n, "StatelessWidget", &["{super.key}"]);
        }
        assert_eq!(class_sig(&m, "A7"), (None, vec![]));
        assert_class(&m, "A8", "Base", &["{super.key}"]);
        assert_class(&m, "ListPage", "StatelessWidget", &["{super.key}", "{!items:List<T>}", "{selected:T?}"]);
        assert_class(&m, "Gen", "Base", &["x:T"]);
        assert_class(&m, "Prefixed", "w.StatelessWidget", &["{super.key}"]);
    }

    #[test]
    fn reads_state_pair() {
        let m = parse(
            r#"
            class ProductPage extends ConsumerStatefulWidget {
              const ProductPage({super.key, required this.id});
              final int id;
              @override
              ConsumerState<ProductPage> createState() => _ProductPageState();
            }
            class _ProductPageState extends ConsumerState<ProductPage> {
              @override
              Widget build(BuildContext context) => Text('${widget.id}');
            }
            "#,
        );
        assert_eq!(m.classes.len(), 2);
        assert_class(&m, "ProductPage", "ConsumerStatefulWidget", &["{super.key}", "{!id:int}"]);
        assert_class(&m, "_ProductPageState", "ConsumerState", &[]);
        assert_eq!(m.classes.iter().filter(|c| c.is_public()).count(), 1);
    }

    #[test]
    fn reads_constructor_shapes() {
        let m = parse(
            r#"
            class P1 extends StatelessWidget {
              const P1({Key? key, required this.id}) : assert(id > 0, 'id must be positive'), super(key: key);
              @override
              Widget build(BuildContext context) => Text('$id');
              final int id;
            }
            class P2 extends StatelessWidget {
              const P2({super.key, required this.id, this.tags = const [], this.m = const {}});
              P2.named() : this(id: 1);
              P2.other({int? id}) : id = id ?? 0, super();
              factory P2.fromJson(Map<String, Object?> j) => P2(id: j['id'] as int);
              final int id;
              final List<String> tags;
              final Map<String, int> m;
              static const int kMax = 3;
              static final Map<String, int> cache = {};
              late final String label = 'x';
            }
            class P3 extends StatelessWidget {
              factory P3({Key? key, required int id}) = _P3;
              const P3._({super.key});
            }
            class P4 extends StatelessWidget {
              factory P4({Key? key, required int id}) => _P4(key: key, id: id);
            }
            class P5 extends StatelessWidget {
              P5({super.key, required int a}) : b = a * 2 { debugPrint('built'); }
              final int b;
            }
            class P6 extends StatelessWidget {
              const P6(this.a, this.b, {super.key});
              final int a, b;
            }
            class P7 extends StatelessWidget {
              const P7(super.key, this.a, [this.b = 2]);
              final int a;
              final int b;
            }
            class P8 extends StatelessWidget {
              const P8({super.key, required this.pair, this.rec});
              final (int, String) pair;
              final ({int id, String? tab})? rec;
            }
            class P9 extends StatelessWidget {
              P9({super.key, required this.a, required this.b});
              late final int a, b;
            }
            "#,
        );
        assert_class(&m, "P1", "StatelessWidget", &["{key:Key?}", "{!id:int}"]);
        assert_class(
            &m,
            "P2",
            "StatelessWidget",
            &["{super.key}", "{!id:int}", "{tags:List<String>}", "{m:Map<String, int>}"],
        );
        assert_class(&m, "P3", "StatelessWidget", &["{key:Key?}", "{!id:int}"]);
        assert_class(&m, "P4", "StatelessWidget", &["{key:Key?}", "{!id:int}"]);
        assert_class(&m, "P5", "StatelessWidget", &["{super.key}", "{!a:int}"]);
        assert_class(&m, "P6", "StatelessWidget", &["a:int", "b:int", "{super.key}"]);
        assert_class(&m, "P7", "StatelessWidget", &["super.key", "a:int", "[b:int]"]);
        assert_class(&m, "P8", "StatelessWidget", &["{super.key}", "{!pair:(int, String)}", "{rec:({int id, String? tab})?}"]);
        assert_class(&m, "P9", "StatelessWidget", &["{super.key}", "{!a:int}", "{!b:int}"]);
    }

    #[test]
    fn reads_parameter_annotations_and_function_types() {
        let m = parse(
            r#"
            class P extends StatelessWidget {
              const P({
                super.key,
                @Default(1) int x = 1, // trailing
                required void Function(int) onTap,
                required this.onChanged,
                required VoidCallback retry,
                this.items,
                this.cb,
                required Future<void> Function() load,
                final String? label,
              });
              final ValueChanged<String> onChanged;
              final List<Product>? items;
              final void Function(int a, String b)? cb;
            }
            "#,
        );
        assert_class(
            &m,
            "P",
            "StatelessWidget",
            &[
                "{super.key}",
                "{x:int}",
                "{!onTap:void Function(int)}",
                "{!onChanged:ValueChanged<String>}",
                "{!retry:VoidCallback}",
                "{items:List<Product>?}",
                "{cb:void Function(int a, String b)?}",
                "{!load:Future<void> Function()}",
                "{label:String?}",
            ],
        );
    }

    #[test]
    fn reads_private_named_and_untyped_fields() {
        let m = parse(
            r#"
            class P extends StatelessWidget {
              const P({super.key, required this._id, this._x = 1, required this.inferred});
              final int _id;
              final int _x;
              final inferred = 1;
            }
            "#,
        );
        assert_class(&m, "P", "StatelessWidget", &["{super.key}", "{!_id:int}", "{_x:int}", "{!inferred}"]);
    }

    #[test]
    fn reads_functions() {
        let m = parse(
            r#"
            @riverpod
            Future<List<Product>> data(Ref ref, {required int id}) async {
              final client = ref.watch(clientProvider);
              void helper(int x) { print('class Fake extends Nope {'); }
              final f = (int a) => a + 1;
              return [for (final p in await client.all()) if (p.id == id) p];
            }
            "#,
        );
        assert_eq!(m.functions.len(), 1);
        let f = &m.functions[0];
        assert_eq!(f.ret.as_ref().unwrap().text, "Future<List<Product>>");
        assert_eq!(sig(&f.params), ["ref:Ref", "{!id:int}"]);

        let m = parse(
            r#"
            Stream<int> data(Ref ref) async* { yield 1; yield* Stream.value(2); }
            FutureOr<String?> guard(ProviderContainer c, {String? next}) async => null;
            T generic<T extends Object>(Ref ref, {required T id}) => id;
            (int, String) pair(Ref ref) => (1, 'a');
            Widget Function(BuildContext)? maybe(Ref ref) => null;
            void transition(BuildContext c, {required Widget child, MainAxisAlignment a = .center, EdgeInsets p = const .all(8)}) {}
            "#,
        );
        let by = |n: &str| m.functions.iter().find(|f| f.name == n).unwrap();
        assert_eq!(by("data").ret.as_ref().unwrap().text, "Stream<int>");
        assert_eq!(sig(&by("data").params), ["ref:Ref"]);
        assert_eq!(by("guard").ret.as_ref().unwrap().text, "FutureOr<String?>");
        assert_eq!(sig(&by("guard").params), ["c:ProviderContainer", "{next:String?}"]);
        assert_eq!(by("generic").ret.as_ref().unwrap().text, "T");
        assert_eq!(sig(&by("generic").params), ["ref:Ref", "{!id:T}"]);
        assert_eq!(by("pair").ret.as_ref().unwrap().text, "(int, String)");
        assert_eq!(by("maybe").ret.as_ref().unwrap().text, "Widget Function(BuildContext)?");
        assert_eq!(sig(&by("transition").params), ["c:BuildContext", "{!child:Widget}", "{a:MainAxisAlignment}", "{p:EdgeInsets}"]);
    }

    #[test]
    fn reads_top_level_string_lists() {
        let m = parse(
            r#"
            const tabs = ['(home)', "search", 'profile',];
            const List<String> typed = <String>['a', r'b'];
            final empty = <String>[];
            const mixed = ['a', 1];
            const interp = ['a', 'b$x'];
            const escaped = ['\$slug', r'$id', 'it\'s'];
            const bad = ['a\n'];
            const call = foo(['a']);
            final data = FutureProvider<int>((ref) => 1);
            "#,
        );
        let strings = |n: &str| {
            let v = m.variables.iter().find(|v| v.name == n).unwrap();
            v.strings.as_ref().map(|s| s.iter().map(|(t, _)| t.as_str()).collect::<Vec<_>>())
        };
        assert_eq!(strings("tabs").unwrap(), ["(home)", "search", "profile"]);
        assert_eq!(strings("typed").unwrap(), ["a", "b"]);
        assert_eq!(strings("empty").unwrap(), Vec::<&str>::new());
        assert_eq!(strings("escaped").unwrap(), ["$slug", "$id", "it's"]);
        assert!(strings("bad").is_none());
        assert!(strings("mixed").is_none() && strings("interp").is_none() && strings("call").is_none());
        assert!(strings("data").is_none());
        // Each string knows its line, for diagnostics.
        assert_eq!(m.variables[0].strings.as_ref().unwrap()[0].1.line, 2);
    }

    #[test]
    fn reads_top_level_object_maps() {
        let m = parse(
            r#"
            const tabOptions = {
              'search': TabOptions(preload: true),
              "profile": const TabOptions(initialLocation: '/profile/edit', preload: false,),
              'bare': TabOptions(),
              'odd': TabOptions(preload: flag, initialLocation: 'a$b'),
            };
            const typed = <String, TabOptions>{'a': TabOptions(preload: true)};
            const empty = <String, TabOptions>{};
            const positional = {'a': TabOptions(true)};
            const notCalls = {'a': 1};
            const dynamicKey = {key: TabOptions()};
            const list = ['a'];
            "#,
        );
        let var = |n: &str| m.variables.iter().find(|v| v.name == n).unwrap();
        let entries = var("tabOptions").objects.as_ref().unwrap();
        let keys: Vec<&str> = entries.iter().map(|e| e.key.as_str()).collect();
        assert_eq!(keys, ["search", "profile", "bare", "odd"]);
        assert!(entries.iter().all(|e| e.class == "TabOptions"));
        assert_eq!(entries[0].args.len(), 1);
        assert_eq!((entries[0].args[0].name.as_str(), &entries[0].args[0].value), ("preload", &Lit::Bool(true)));
        let profile: Vec<_> = entries[1].args.iter().map(|a| (a.name.as_str(), a.value.clone())).collect();
        assert_eq!(profile, [("initialLocation", Lit::Str("/profile/edit".into())), ("preload", Lit::Bool(false))]);
        assert!(entries[2].args.is_empty());
        // Values it can't read are kept as `Other`, so the caller can point at them.
        assert!(entries[3].args.iter().all(|a| a.value == Lit::Other));
        assert_eq!(entries[0].key_span.line, 3);
        assert_eq!(var("typed").objects.as_ref().unwrap().len(), 1);
        assert!(var("empty").objects.as_ref().unwrap().is_empty());
        for bad in ["positional", "notCalls", "dynamicKey", "list"] {
            assert!(var(bad).objects.is_none(), "{bad}");
        }
        assert!(var("list").strings.is_some());
    }

    #[test]
    fn reads_provider_shapes() {
        let m = parse(
            r#"
            final data = FutureProvider.autoDispose<List<Product>>((ref) async {
              final c = ref.watch(clientProvider);
              return c.all();
            });
            final data2 = AsyncNotifierProvider.autoDispose.family<Cart, CartState, ({int id, String? tab})>(Cart.new);
            final data3 = StreamProvider<int>((ref) => Stream.value(1));
            final data4 = r.FutureProvider<int>((ref) => 1);
            final FutureProvider<int> data5 = FutureProvider<int>((ref) => 1);
            final int plain = 3, other = 4;
            "#,
        );
        let call = |n: &str| m.variables.iter().find(|v| v.name == n).unwrap().call.clone();
        let c = call("data").unwrap();
        assert_eq!(c.chain, ["FutureProvider", "autoDispose"]);
        assert_eq!(c.type_args.iter().map(|t| t.text.as_str()).collect::<Vec<_>>(), ["List<Product>"]);
        let c = call("data2").unwrap();
        assert_eq!(c.chain, ["AsyncNotifierProvider", "autoDispose", "family"]);
        assert_eq!(c.type_args[2].text, "({int id, String? tab})");
        let rec = c.type_args[2].record.as_ref().unwrap();
        assert_eq!(rec.iter().map(|(n, t)| (n.as_str(), t.text.as_str())).collect::<Vec<_>>(), [("id", "int"), ("tab", "String?")]);
        assert_eq!(call("data3").unwrap().chain, ["StreamProvider"]);
        assert_eq!(call("data4").unwrap().chain, ["FutureProvider"]);
        assert_eq!(call("data5").unwrap().chain, ["FutureProvider"]);
        assert!(call("plain").is_none() && call("other").is_none());
    }

    #[test]
    fn ignores_noise_around_the_declarations() {
        let m = parse(
            r##"
            import 'package:flutter/material.dart';
            part 'page.g.dart';

            /// A page. Example:
            /// ```dart
            /// class Fake extends Nope {
            ///   const Fake();
            /// }
            /// ```
            typedef Callback = void Function(int);
            typedef Json = Map<String, Object?>;
            enum Color2 { red(1), green(2); const Color2(this.v); final int v; String get label => name; }
            extension StringX on String { String get shout => toUpperCase(); }
            extension type Meters(double v) implements double { Meters.zero() : this(0); }
            mixin Logger on Object { void log() {} }
            int get topGetter => 1;
            set topSetter(int v) {}
            const String kRaw = r'class Fake2 extends Nope { $x }';
            const String kMulti = '''
            class Fake3 extends Nope {
              const Fake3();
            }
            ''';
            const String kInterp = "a ${b['x'] + "}" + '{'} c ${ {1: 2}[1] } d $e";

            class RealPage extends StatelessWidget {
              const RealPage({super.key, required this.id});
              final int id;
              @override
              Widget build(BuildContext context) {
                final s = 'class Fake4 extends Nope {';
                final t = "${id > 0 ? '}' : "{"}";
                return Text(r'$id class X { ', style: const TextStyle());
              }
            }
            final data = FutureProvider<int>((ref) => 1);
            "##,
        );
        assert_eq!(m.classes.len(), 1);
        assert_class(&m, "RealPage", "StatelessWidget", &["{super.key}", "{!id:int}"]);
        assert!(m.variables.iter().any(|v| v.name == "data" && v.call.is_some()));
    }

    #[test]
    fn reads_class_next_to_newer_syntax_in_build() {
        // Each body sits before the fields and a second class follows: the
        // grammar must neither lose the class nor derail what comes after it.
        let bodies = [
            "return Column(mainAxisAlignment: .center, children: [?maybe, const Text('x'), ...others]);",
            "return Padding(padding: const .all(8), child: x);",
            "final m = {?'k': maybe, 'a': ?other}; final n = 1_000_000; final f = (_, _) => 1;",
            "final a = switch (shape) { Circle(:final r) => r, Sq(s: var s) when s > 0 => s, _ => 0 };",
            "if (json case {'id': int id, 'name': String name}) { return Text('$id $name'); }",
            "final (a, b) = (1, 2); final (x: xx, y: yy) = (x: 1, y: 2); var [first, ...rest] = [1, 2, 3];",
            "if (shape case Circle(r: > 1 && < 5)) {} for (final (a, b) in pairs) {}",
            "return switch (shape) { Circle() => const Text('c'), Sq() => Text('s') };",
            "switch (x) { case .a: break; case Foo(:var v) || Bar(:var v): break; default: }",
            "final s = '${await foo()} ${switch (x) { 1 => 'a', _ => 'b' }} ${(a, b)}';",
            "final r = (1, 'a', x: 2); print(r.$1); final t = Foo.new; final u = List<int>.new;",
            "a >>>= 1; final z = a >>> 3; final n = .5e3;",
        ];
        for body in bodies {
            let src = format!(
                "class NewPage extends StatelessWidget {{
                  const NewPage({{super.key, required this.id, this.maybe}});
                  @override
                  Widget build(BuildContext context) {{
                    {body}
                    return const SizedBox();
                  }}
                  final int id;
                  final Widget? maybe;
                }}
                class Second extends StatelessWidget {{ const Second({{super.key, required this.zz}}); final int zz; }}
                final data = Provider<int>((ref) => 1);
                Future<int> guard(Ref ref, {{required int x}}) async => 1;"
            );
            let m = parse(&src);
            assert_class(&m, "NewPage", "StatelessWidget", &["{super.key}", "{!id:int}", "{maybe:Widget?}"]);
            assert_class(&m, "Second", "StatelessWidget", &["{super.key}", "{!zz:int}"]);
            assert!(m.variables.iter().any(|v| v.name == "data" && v.call.is_some()), "{body}");
            assert_eq!(sig(&m.functions.iter().find(|f| f.name == "guard").unwrap().params), ["ref:Ref", "{!x:int}"], "{body}");
        }
    }

    #[test]
    fn keeps_going_when_the_class_body_is_broken() {
        // Garbage in the build method: the grammar recovers, we still read everything.
        let m = parse(
            "class A extends StatelessWidget {
               const A({super.key, required this.id});
               Widget build(BuildContext c) { x = ;; ) ??? @@ }
               final int id;
             }
             class Z extends StatelessWidget { const Z(this.q); final int q; }",
        );
        assert_class(&m, "A", "StatelessWidget", &["{super.key}", "{!id:int}"]);
        assert_class(&m, "Z", "StatelessWidget", &["q:int"]);

        // A stray `}` ends the class early; its fields land at the top level and
        // are still used to type `this.id`.
        let m = parse(
            "class A extends StatelessWidget {
               const A({super.key, required this.id, this.tag});
               Widget build(BuildContext c) {
                 }
               }
               final int id;
               final String? tag;
             }
             class Z extends StatelessWidget { const Z(this.q); final int q; }",
        );
        assert_class(&m, "A", "StatelessWidget", &["{super.key}", "{!id:int}", "{tag:String?}"]);
        assert_class(&m, "Z", "StatelessWidget", &["q:int"]);
    }

    #[test]
    fn reads_primary_constructors() {
        let m = parse(
            r#"
            import 'package:flutter/material.dart';
            const note = 'class Fake(int a) extends Nope {}';
            class A(final int id, {super.key, final String? tag, required final List<int> xs = const [1, 2]}) extends StatelessWidget {
              @override
              Widget build(BuildContext context) => Text('$id');
            }
            class const B<T>({super.key, required T value}) extends StatelessWidget {
              @override
              Widget build(BuildContext context) => const SizedBox();
            }
            class C extends StatelessWidget {
              const this({super.key, required final int id});
            }
            class D(
              int a, // first
              String b,
            ) extends StatelessWidget {}
            class Z extends StatelessWidget { const Z({super.key}); }
            final data = FutureProvider<int>((ref) => 1);
            "#,
        );
        assert_class(&m, "A", "StatelessWidget", &["id:int", "{super.key}", "{tag:String?}", "{!xs:List<int>}"]);
        assert_class(&m, "B", "StatelessWidget", &["{super.key}", "{!value:T}"]);
        assert_class(&m, "C", "StatelessWidget", &["{super.key}", "{!id:int}"]);
        assert_class(&m, "D", "StatelessWidget", &["a:int", "b:String"]);
        assert_class(&m, "Z", "StatelessWidget", &["{super.key}"]);
        assert_eq!(m.classes.len(), 5);
        assert!(m.variables.iter().any(|v| v.name == "data" && v.call.is_some()));
        // Lines stay put after the rewrite.
        let line = |n: &str| m.classes.iter().find(|c| c.name == n).unwrap().span.line;
        assert_eq!((line("A"), line("B"), line("Z")), (4, 8, 19));
    }

    #[test]
    fn normalizes_type_spelling() {
        let m = parse(
            "class P extends StatelessWidget { const P({required this.f, required this.r, required this.g}); \
             final Future<void>Function() f; final ({int id,String?tab}) r; final Map< String ,List<int>? >? g; }",
        );
        let ty = |i: usize| m.classes[0].params[i].ty.as_ref().unwrap().text.clone();
        assert_eq!(ty(0), "Future<void> Function()");
        assert_eq!(ty(1), "({int id, String? tab})");
        assert_eq!(ty(2), "Map<String, List<int>?>?");
    }

    /// The text and line the grammar first gave up at, if it did.
    fn error_at(src: &str) -> Option<(usize, String)> {
        parse(src).parse_error.map(|s| (s.line, src[s.bytes].to_string()))
    }

    #[test]
    fn reports_where_the_grammar_gives_up() {
        let (line, text) = error_at("class CartPage extends StatelessWidget {{\n  const CartPage({super.key});\n}\n").unwrap();
        assert_eq!((line, text.as_str()), (1, "{"));

        // Cut to the first line, however much the grammar swallows.
        let (line, text) = error_at("import 'a.dart';\n\nclass A extends B {\n  Widget build( { ;;\n  x\n  y\n").unwrap();
        assert!(line >= 3 && !text.contains('\n'), "{line} {text:?}");

        // Broken bodies are read anyway.
        let m = parse("class A extends StatelessWidget { const A({super.key}); Widget build(c) { x = ;; ) } }");
        assert!(m.parse_error.is_some());
        assert_eq!(m.classes.len(), 1);
    }

    #[test]
    fn valid_files_report_no_error() {
        for src in [
            "",
            "// nothing here\n",
            "class A extends StatelessWidget { const A({super.key, required this.id}); final int id; }",
            // Primary constructors are read separately; when that recovers the file, no error.
            "class A(final int id, {super.key}) extends StatelessWidget {}\nclass const B<T>({super.key, required T v}) extends StatelessWidget {}",
            "class C extends StatelessWidget { const this({super.key, required final int id}); }",
            "class A extends StatelessWidget { Widget build(c) => Column(mainAxisAlignment: .center, children: [?m, ...o]); }",
            "final data = FutureProvider.autoDispose.family<int, ({int id})>((ref, k) async => switch (k.id) { 1 => 2, _ => 3 });",
        ] {
            assert_eq!(error_at(src), None, "{src}");
        }
        // But a primary constructor doesn't hide a real error after it.
        assert!(error_at("class A(final int id) extends StatelessWidget {{}").is_some());
    }

    #[test]
    fn never_panics_on_truncated_files() {
        let src = r##"part of 'x.dart';
            class const A<T>(final int id, {super.key}) extends S { final s = 'é ${a('}')}'; }
            class B extends S { const B({super.key, required this.x}) : assert(x > 0); final int x;
              Widget build(c) => switch (x) { 1 => .new(), _ => r'''raw''' }; }
            final data = FutureProvider.autoDispose.family<int, ({int id})>((ref, k) async => 1);"##;
        for (i, _) in src.char_indices() {
            parse(&src[..i]);
        }
    }
}
