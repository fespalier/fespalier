//! Just enough Dart lexing to read the constrained shapes trellis files have:
//! `class X extends Base<T>`, `final Type name;` and `Ret fn(A a, B b)`.
//!
//! This is deliberately not a Dart parser. Anything it cannot see, the Dart
//! compiler still catches in the generated code; the point here is to give
//! file-level errors before that happens.

#[derive(Clone, Debug, PartialEq)]
pub enum Tk {
    Ident(String),
    Sym(char),
    Arrow,
    Str,
    Num,
}

#[derive(Clone, Debug)]
pub struct Token {
    pub tk: Tk,
    pub line: usize,
}

impl Token {
    fn is_ident(&self, s: &str) -> bool {
        matches!(&self.tk, Tk::Ident(i) if i == s)
    }
    fn is_sym(&self, c: char) -> bool {
        self.tk == Tk::Sym(c)
    }
    fn ident(&self) -> Option<&str> {
        match &self.tk {
            Tk::Ident(i) => Some(i),
            _ => None,
        }
    }
}

pub fn tokenize(src: &str) -> Vec<Token> {
    let c: Vec<char> = src.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    let mut line = 1;
    while i < c.len() {
        let ch = c[i];
        if ch == '\n' {
            line += 1;
            i += 1;
        } else if ch.is_whitespace() {
            i += 1;
        } else if ch == '/' && c.get(i + 1) == Some(&'/') {
            while i < c.len() && c[i] != '\n' {
                i += 1;
            }
        } else if ch == '/' && c.get(i + 1) == Some(&'*') {
            // Dart block comments nest.
            let mut depth = 0;
            while i < c.len() {
                if c[i] == '/' && c.get(i + 1) == Some(&'*') {
                    depth += 1;
                    i += 2;
                } else if c[i] == '*' && c.get(i + 1) == Some(&'/') {
                    depth -= 1;
                    i += 2;
                    if depth == 0 {
                        break;
                    }
                } else {
                    if c[i] == '\n' {
                        line += 1;
                    }
                    i += 1;
                }
            }
        } else if ch == '\'' || ch == '"' {
            let l = line;
            i = skip_string(&c, i, false, &mut line);
            out.push(Token { tk: Tk::Str, line: l });
        } else if ch == 'r' && matches!(c.get(i + 1), Some('\'') | Some('"')) {
            let l = line;
            i = skip_string(&c, i + 1, true, &mut line);
            out.push(Token { tk: Tk::Str, line: l });
        } else if ch.is_alphabetic() || ch == '_' || ch == '$' {
            let s = i;
            while i < c.len() && (c[i].is_alphanumeric() || c[i] == '_' || c[i] == '$') {
                i += 1;
            }
            out.push(Token { tk: Tk::Ident(c[s..i].iter().collect()), line });
        } else if ch.is_ascii_digit() {
            while i < c.len() && (c[i].is_ascii_alphanumeric() || c[i] == '.') {
                i += 1;
            }
            out.push(Token { tk: Tk::Num, line });
        } else if ch == '=' && c.get(i + 1) == Some(&'>') {
            out.push(Token { tk: Tk::Arrow, line });
            i += 2;
        } else {
            out.push(Token { tk: Tk::Sym(ch), line });
            i += 1;
        }
    }
    out
}

/// Returns the index just past the string starting at `i` (a quote char).
fn skip_string(c: &[char], i: usize, raw: bool, line: &mut usize) -> usize {
    let q = c[i];
    let triple = c.get(i + 1) == Some(&q) && c.get(i + 2) == Some(&q);
    let mut j = if triple { i + 3 } else { i + 1 };
    while j < c.len() {
        let ch = c[j];
        if ch == '\n' {
            *line += 1;
        }
        if !raw && ch == '\\' {
            j += 2;
            continue;
        }
        if !raw && ch == '$' && c.get(j + 1) == Some(&'{') {
            // Interpolation: skip a balanced expression, which may hold strings.
            j += 2;
            let mut depth = 1;
            while j < c.len() && depth > 0 {
                match c[j] {
                    '{' => depth += 1,
                    '}' => depth -= 1,
                    '\'' | '"' => {
                        j = skip_string(c, j, false, line);
                        continue;
                    }
                    '\n' => *line += 1,
                    _ => {}
                }
                j += 1;
            }
            continue;
        }
        if ch == q {
            if !triple {
                return j + 1;
            }
            if c.get(j + 1) == Some(&q) && c.get(j + 2) == Some(&q) {
                return j + 3;
            }
        }
        j += 1;
    }
    j
}

/// Renders type tokens canonically: `Future < List<A> >` → `Future<List<A>>`.
pub fn type_string(toks: &[Token]) -> String {
    let mut s = String::new();
    let mut prev_word = false;
    for t in toks {
        match &t.tk {
            Tk::Ident(i) => {
                if prev_word {
                    s.push(' ');
                }
                s.push_str(i);
                prev_word = true;
            }
            Tk::Sym(',') => {
                s.push_str(", ");
                prev_word = false;
            }
            Tk::Sym(ch) => {
                s.push(*ch);
                prev_word = false;
            }
            _ => prev_word = false,
        }
    }
    s
}

/// `Future<List<A>>` → ("Future", ["List<A>"]).
pub fn split_generic(ty: &str) -> (String, Vec<String>) {
    let Some(open) = ty.find('<') else {
        return (ty.to_string(), vec![]);
    };
    if !ty.ends_with('>') {
        return (ty.to_string(), vec![]);
    }
    let head = ty[..open].to_string();
    let inner = &ty[open + 1..ty.len() - 1];
    let mut args = vec![];
    let mut depth = 0;
    let mut cur = String::new();
    for ch in inner.chars() {
        match ch {
            '<' | '(' => depth += 1,
            '>' | ')' => depth -= 1,
            ',' if depth == 0 => {
                args.push(cur.trim().to_string());
                cur.clear();
                continue;
            }
            _ => {}
        }
        cur.push(ch);
    }
    args.push(cur.trim().to_string());
    (head, args)
}

#[derive(Debug, Clone)]
pub struct ClassDecl {
    pub name: String,
    pub base: String,
    /// Type arguments of the base, canonical: `Screen<List<A>>` → `List<A>`.
    pub base_args: Option<String>,
    pub line: usize,
    /// `final Type name;` instance fields.
    pub fields: Vec<Field>,
}

#[derive(Debug, Clone)]
pub struct Field {
    pub name: String,
    pub ty: String,
    pub line: usize,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct FnDecl {
    pub name: String,
    /// `None` when the return type is left to inference.
    pub ret: Option<String>,
    pub params: Vec<Param>,
    /// True if any parameter is named (`{...}`) or optional (`[...]`).
    pub non_positional: bool,
    pub line: usize,
}

#[derive(Debug, Clone)]
pub struct Param {
    pub ty: Option<String>,
    pub name: String,
}

/// Index of the token closing the group opened at `i` (`(`, `[`, `{` or `<`).
fn matching(t: &[Token], i: usize) -> Option<usize> {
    let (open, close) = match t[i].tk {
        Tk::Sym('(') => ('(', ')'),
        Tk::Sym('[') => ('[', ']'),
        Tk::Sym('{') => ('{', '}'),
        Tk::Sym('<') => ('<', '>'),
        _ => return None,
    };
    let mut depth = 0;
    for (j, tok) in t.iter().enumerate().skip(i) {
        if tok.is_sym(open) {
            depth += 1;
        } else if tok.is_sym(close) {
            depth -= 1;
            if depth == 0 {
                return Some(j);
            }
        }
    }
    None
}

/// Top-level class declarations.
pub fn classes(t: &[Token]) -> Vec<ClassDecl> {
    let mut out = vec![];
    let mut depth = 0i32;
    let mut i = 0;
    while i < t.len() {
        if t[i].is_sym('{') {
            depth += 1;
        } else if t[i].is_sym('}') {
            depth -= 1;
        } else if depth == 0 && t[i].is_ident("class") {
            if let Some((decl, end)) = class_at(t, i) {
                out.push(decl);
                i = end + 1;
                continue;
            }
        }
        i += 1;
    }
    out
}

fn class_at(t: &[Token], i: usize) -> Option<(ClassDecl, usize)> {
    let name = t.get(i + 1)?.ident()?.to_string();
    let line = t[i + 1].line;
    let mut j = i + 2;
    if t.get(j)?.is_sym('<') {
        j = matching(t, j)? + 1;
    }
    let (mut base, mut base_args) = (String::new(), None);
    if t.get(j)?.is_ident("extends") {
        base = t.get(j + 1)?.ident()?.to_string();
        j += 2;
        if t.get(j)?.is_sym('<') {
            let end = matching(t, j)?;
            base_args = Some(type_string(&t[j + 1..end]));
            j = end + 1;
        }
    }
    while j < t.len() && !t[j].is_sym('{') {
        j += 1;
    }
    let body_end = matching(t, j)?;
    let fields = fields_in(&t[j + 1..body_end]);
    Some((ClassDecl { name, base, base_args, line, fields }, body_end))
}

fn fields_in(body: &[Token]) -> Vec<Field> {
    let mut out = vec![];
    let mut depth = 0i32;
    let mut i = 0;
    while i < body.len() {
        let tok = &body[i];
        if tok.is_sym('{') || tok.is_sym('(') {
            depth += 1;
        } else if tok.is_sym('}') || tok.is_sym(')') {
            depth -= 1;
        } else if depth == 0 && tok.is_ident("final") {
            let is_static = i > 0 && body[i - 1].is_ident("static");
            let mut j = i + 1;
            while j < body.len() && !body[j].is_sym(';') && !body[j].is_sym('=') {
                j += 1;
            }
            let decl = &body[i + 1..j.min(body.len())];
            // `final A a, b;` and function types are out of scope.
            let mut angle = 0i32;
            let top_comma = decl.iter().any(|t| {
                match t.tk {
                    Tk::Sym('<') => angle += 1,
                    Tk::Sym('>') => angle -= 1,
                    _ => {}
                }
                angle == 0 && t.is_sym(',')
            });
            let simple = decl.len() >= 2 && !top_comma && !decl.iter().any(|t| t.is_sym('('));
            if !is_static && simple {
                if let Some(name) = decl.last().and_then(|t| t.ident()) {
                    out.push(Field {
                        name: name.to_string(),
                        ty: type_string(&decl[..decl.len() - 1]),
                        line: tok.line,
                    });
                }
            }
            i = j;
            continue;
        }
        i += 1;
    }
    out
}

/// A top-level function declaration by name.
pub fn function(t: &[Token], name: &str) -> Option<FnDecl> {
    let mut depth = 0i32;
    let mut stmt_start = 0;
    for i in 0..t.len() {
        let tok = &t[i];
        if tok.is_sym('{') || tok.is_sym('(') || tok.is_sym('[') {
            depth += 1;
        } else if tok.is_sym('}') || tok.is_sym(')') || tok.is_sym(']') {
            depth -= 1;
            if depth == 0 && tok.is_sym('}') {
                stmt_start = i + 1;
            }
        } else if depth == 0 && tok.is_sym(';') {
            stmt_start = i + 1;
        } else if depth == 0
            && tok.is_ident(name)
            && t.get(i + 1).is_some_and(|n| n.is_sym('('))
            && !(i > 0 && t[i - 1].is_sym('.'))
        {
            let ret_toks = skip_annotations(&t[stmt_start..i]);
            let close = matching(t, i + 1)?;
            let (params, non_positional) = params_of(&t[i + 2..close]);
            return Some(FnDecl {
                name: name.to_string(),
                ret: (!ret_toks.is_empty()).then(|| type_string(ret_toks)),
                params,
                non_positional,
                line: tok.line,
            });
        }
    }
    None
}

fn skip_annotations(mut t: &[Token]) -> &[Token] {
    while t.first().is_some_and(|x| x.is_sym('@')) {
        let mut j = 2; // `@` + name
        while t.get(j).is_some_and(|x| x.is_sym('.')) {
            j += 2;
        }
        if t.get(j).is_some_and(|x| x.is_sym('(')) {
            j = matching(t, j).map_or(t.len(), |e| e + 1);
        }
        t = &t[j.min(t.len())..];
    }
    t
}

fn params_of(t: &[Token]) -> (Vec<Param>, bool) {
    let non_positional = t.iter().any(|x| x.is_sym('{') || x.is_sym('['));
    let mut out = vec![];
    let mut depth = 0i32;
    let mut cur: Vec<Token> = vec![];
    let flush = |cur: &mut Vec<Token>, out: &mut Vec<Param>| {
        let toks: Vec<Token> = cur
            .drain(..)
            .filter(|x| !x.is_sym('{') && !x.is_sym('}') && !x.is_sym('[') && !x.is_sym(']'))
            .filter(|x| !x.is_ident("required") && !x.is_ident("final"))
            .collect();
        if let Some(name) = toks.last().and_then(|x| x.ident()) {
            let ty = &toks[..toks.len() - 1];
            out.push(Param {
                name: name.to_string(),
                ty: (!ty.is_empty()).then(|| type_string(ty)),
            });
        }
    };
    for tok in t {
        match tok.tk {
            Tk::Sym('<') | Tk::Sym('(') => depth += 1,
            Tk::Sym('>') | Tk::Sym(')') => depth -= 1,
            Tk::Sym(',') if depth == 0 => {
                flush(&mut cur, &mut out);
                continue;
            }
            _ => {}
        }
        cur.push(tok.clone());
    }
    flush(&mut cur, &mut out);
    (out, non_positional)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_class_with_nested_generics_and_fields() {
        let src = r#"
            import 'package:x/y.dart'; // comment with class Fake extends Nope
            /* block /* nested */ class Hidden extends Nope {} */
            class ProductsPage extends Screen< List<Product> > {
              const ProductsPage(super.data, {super.key});
              static final cache = 1;
              final int id;
              final Map<String, int> counts;
              String get label => 'class Nope extends X ${id.toString()}';
            }
        "#;
        let t = tokenize(src);
        let cs = classes(&t);
        assert_eq!(cs.len(), 1);
        assert_eq!(cs[0].name, "ProductsPage");
        assert_eq!(cs[0].base, "Screen");
        assert_eq!(cs[0].base_args.as_deref(), Some("List<Product>"));
        let f: Vec<_> = cs[0].fields.iter().map(|f| (f.name.as_str(), f.ty.as_str())).collect();
        assert_eq!(f, vec![("id", "int"), ("counts", "Map<String, int>")]);
    }

    #[test]
    fn reads_function_signature() {
        let src = r#"
            import 'a.dart';
            @riverpod
            Future<List<Product>> data(Ref ref, ProductsParams p) async {
              return ref.watch(api).data(1);
            }
        "#;
        let f = function(&tokenize(src), "data").unwrap();
        assert_eq!(f.ret.as_deref(), Some("Future<List<Product>>"));
        assert_eq!(f.params.len(), 2);
        assert_eq!(f.params[1].ty.as_deref(), Some("ProductsParams"));
        assert!(!f.non_positional);
    }

    #[test]
    fn inferred_return_type_is_none() {
        let f = function(&tokenize("data(Ref ref, Params p) => 1;"), "data").unwrap();
        assert!(f.ret.is_none());
    }

    #[test]
    fn splits_generics() {
        assert_eq!(
            split_generic("Map<String, List<int>>"),
            ("Map".into(), vec!["String".into(), "List<int>".into()])
        );
        assert_eq!(split_generic("Product"), ("Product".into(), vec![]));
    }
}
