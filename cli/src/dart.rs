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
    pub span: Span,
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
    let Some(tree) = parser.parse(src, None) else { return Module::default() };
    let r = Reader { src };
    let mut m = Module::default();
    let root = tree.root_node();
    let mut cur = root.walk();
    for n in root.named_children(&mut cur) {
        match n.kind() {
            "class_declaration" => m.classes.extend(r.class(n)),
            "function_declaration" => m.functions.extend(r.function(n)),
            "top_level_variable_declaration" => m.variables.extend(r.variables(n)),
            _ => {}
        }
    }
    m
}

struct Reader<'a> {
    src: &'a str,
}

impl Reader<'_> {
    fn text(&self, n: Node) -> &str {
        &self.src[n.byte_range()]
    }

    fn class(&self, n: Node) -> Option<Class> {
        let name_node = n.child_by_field_name("name")?;
        let name = self.text(name_node).to_string();
        let superclass = n
            .child_by_field_name("superclass")
            .and_then(|s| first_named(s, "type"))
            .and_then(|t| first_named(t, "type_identifier"))
            .map(|t| self.text(t).to_string());
        let body = n.child_by_field_name("body")?;

        let mut fields: HashMap<String, Ty> = HashMap::new();
        let mut ctor: Option<Node> = None;
        let mut cur = body.walk();
        for member in body.named_children(&mut cur) {
            let Some(decl) = first_named(member, "declaration") else { continue };
            let mut c2 = decl.walk();
            let kids: Vec<Node> = decl.named_children(&mut c2).collect();
            // `final Type a, b;` — instance fields with an explicit type.
            if !kids.iter().any(|k| k.kind() == "static") {
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
            // The unnamed generative constructor: `const X(...)` or `X(...)`.
            for k in &kids {
                if matches!(k.kind(), "constant_constructor_signature" | "constructor_signature")
                    && self.ctor_name(*k).as_deref() == Some(name.as_str())
                {
                    ctor = Some(*k);
                }
            }
        }

        let params = match ctor.and_then(|c| c.child_by_field_name("parameters")) {
            Some(list) => self.params(list, &fields),
            None => vec![],
        };
        Some(Class { name, superclass, params, span: Span::of(name_node) })
    }

    /// `X` for `X(...)`, `X.named` for `X.named(...)`.
    fn ctor_name(&self, sig: Node) -> Option<String> {
        let mut cur = sig.walk();
        let parts: Vec<String> =
            sig.children_by_field_name("name", &mut cur).map(|p| self.text(p).to_string()).collect();
        (!parts.is_empty()).then(|| parts.concat())
    }

    fn function(&self, n: Node) -> Option<Function> {
        let sig = n.child_by_field_name("signature")?;
        let name_node = sig.child_by_field_name("name")?;
        let name = self.text(name_node).to_string();
        let ret = sig.child_by_field_name("return_type").map(|t| self.ty(t));
        let params = sig
            .child_by_field_name("parameters")
            .map(|p| self.params(p, &HashMap::new()))
            .unwrap_or_default();
        Some(Function { name, ret, params, span: Span::of(name_node) })
    }

    fn variables(&self, n: Node) -> Vec<Variable> {
        let mut out = vec![];
        let mut cur = n.walk();
        for list in n.named_children(&mut cur) {
            let mut c2 = list.walk();
            for d in list.named_children(&mut c2) {
                let Some(name) = d.child_by_field_name("name") else { continue };
                let call = d.child_by_field_name("value").and_then(|v| self.call(v));
                out.push(Variable { name: self.text(name).to_string(), call, span: Span::of(name) });
            }
        }
        out
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
                if word && prev_word {
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
    fn reads_provider_variables() {
        let m = parse("final data = FutureProvider.autoDispose.family<Product, ({int id})>((ref, k) => x);");
        let c = m.variables[0].call.as_ref().unwrap();
        assert_eq!(c.chain, ["FutureProvider", "autoDispose", "family"]);
        assert_eq!(c.type_args[0].text, "Product");
        assert!(c.type_args[1].record.is_some());
    }
}
