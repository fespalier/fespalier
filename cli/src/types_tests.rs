//! `types.rs`: the canonical form of a type, with a fake [`Scope`] in place of `enums::Libs`.

use std::collections::HashMap;

use crate::types::{self, Canonical, Declared, Scope};

const PAGE: &str = "lib/app/page.dart";
const IDS: &str = "lib/models/ids.dart";
const PRODUCT: &str = "lib/models/product.dart";

/// What a file sees: `(file, prefix, name)` → the declaring file and the typedef's alias, if any.
#[derive(Default)]
struct Fake(HashMap<(String, Option<String>, String), (String, Option<String>)>);

impl Fake {
    fn sees(
        mut self,
        file: &str,
        prefix: Option<&str>,
        name: &str,
        decl: &str,
        alias: Option<&str>,
    ) -> Self {
        self.0.insert(
            (file.into(), prefix.map(str::to_string), name.into()),
            (decl.into(), alias.map(str::to_string)),
        );
        self
    }
}

impl Scope for Fake {
    fn declared(&self, path: &str, prefix: Option<&str>, name: &str) -> Option<Declared> {
        let key = (
            path.to_string(),
            prefix.map(str::to_string),
            name.to_string(),
        );
        let (decl, alias) = self.0.get(&key)?;
        Some(Declared {
            decl: decl.clone(),
            name: name.to_string(),
            alias: alias.clone(),
        })
    }
}

fn canon(scope: &Fake, file: &str, text: &str) -> Canonical {
    types::canonical(scope, file, text)
}

/// The names the page and `ids.dart` see: the product, and the typedefs of the models.
fn models() -> Fake {
    let mut f = Fake::default();
    for file in [PAGE, IDS] {
        f = f
            .sees(file, None, "Product", PRODUCT, None)
            .sees(file, None, "Category", PRODUCT, None)
            .sees(file, None, "ProductView", IDS, Some("Product"))
            .sees(file, None, "Chain", IDS, Some("ProductView"))
            .sees(file, None, "ProductId", IDS, Some("int"))
            .sees(file, None, "MaybeInt", IDS, Some("int?"))
            .sees(file, None, "Json", IDS, Some("Map<String, Object?>"))
            .sees(
                file,
                None,
                "PayFields",
                IDS,
                Some("({int amount, String note})"),
            )
            .sees(file, None, "Retry", IDS, Some("void Function()"))
            .sees(file, None, "Cat", IDS, Some("Category"))
            .sees(file, None, "Generic", IDS, None);
    }
    f
}

#[test]
fn a_typedef_is_the_declaration_it_names() {
    let f = models().sees(PAGE, None, "PV", PAGE, Some("Product"));
    let c = canon(&f, PAGE, "PV");
    assert_eq!(c.key, "lib/models/product.dart#Product");
    assert_eq!(c.expanded, "Product");
    assert!(c.followed && c.declared);
    assert!(c.unknown.is_empty());
}

#[test]
fn a_chain_of_typedefs_is_followed_to_the_end() {
    let f = models();
    let c = canon(&f, PAGE, "Chain");
    assert_eq!(c.key, canon(&f, PAGE, "Product").key);
    assert_eq!(c.expanded, "Product");
}

#[test]
fn an_import_prefix_is_dropped_and_resolved() {
    let f = models().sees(PAGE, Some("ids"), "ProductView", IDS, Some("Product"));
    let prefixed = canon(&f, PAGE, "ids.ProductView");
    assert_eq!(prefixed.key, "lib/models/product.dart#Product");
    assert_eq!(prefixed.expanded, "Product");
    assert_eq!(prefixed.key, canon(&f, PAGE, "ProductView").key);
    // Another prefix of the same library is the same type.
    let m = models().sees(PAGE, Some("m"), "Product", PRODUCT, None);
    assert_eq!(
        canon(&m, PAGE, "m.Product").key,
        canon(&m, PAGE, "Product").key
    );
}

#[test]
fn a_typedef_of_a_dart_core_type_comes_to_it() {
    let f = models();
    let c = canon(&f, PAGE, "List<ProductId>");
    assert_eq!(c.key, "List<int>");
    assert_eq!(c.expanded, "List<int>");
    assert!(c.followed && !c.declared && c.unknown.is_empty());
    assert_eq!(canon(&f, PAGE, "MaybeInt?").key, "int?");
    assert_eq!(canon(&f, PAGE, "MaybeInt").key, "int?");
}

#[test]
fn a_record_typedef_is_its_record() {
    let f = models();
    let c = canon(&f, PAGE, "PayFields");
    assert_eq!(c.key, "({int amount, String note})");
    assert_eq!(c.key, canon(&f, PAGE, "({int amount, String note})").key);
}

#[test]
fn a_function_type_and_a_map_typedef_are_spelled_the_same() {
    let f = models();
    assert_eq!(canon(&f, PAGE, "Retry").key, "void Function()");
    assert_eq!(
        canon(&f, PAGE, "Json").key,
        canon(&f, PAGE, "Map<String, Object?>").key
    );
}

#[test]
fn a_name_nothing_declares_is_unknown_and_listed_once() {
    let f = models();
    let c = canon(&f, PAGE, "Map<JsonMap, JsonMap>");
    assert_eq!(c.unknown, ["JsonMap"]);
    assert!(!c.followed && !c.declared);
    assert_eq!(c.key, "Map<JsonMap, JsonMap>");
}

#[test]
fn a_cycle_stops_at_the_depth_limit() {
    let f = Fake::default()
        .sees("a.dart", None, "A", "a.dart", Some("B"))
        .sees("a.dart", None, "B", "a.dart", Some("A"));
    let c = canon(&f, "a.dart", "A");
    assert!(c.followed);
    assert_eq!(c.key, "a.dart#A");
}

#[test]
fn a_nullable_alias_is_not_doubled() {
    let f = models();
    assert_eq!(canon(&f, PAGE, "MaybeInt?").expanded, "int?");
}

#[test]
fn a_generic_typedef_is_a_declared_type_not_followed() {
    let f = models();
    let generic = canon(&f, PAGE, "Generic<int>");
    assert!(!generic.followed && generic.declared);
    assert_ne!(generic.key, canon(&f, PAGE, "Map<String, int>").key);
}

#[test]
fn the_hint_names_only_the_names_one_side_could_not_follow() {
    let f = models();
    let a = canon(&f, PAGE, "JsonMap");
    let b = canon(&f, PAGE, "Map<String, Object?>");
    assert_eq!(
        types::hint(&a, &b),
        "; fsp follows typedefs in this package's files only, and found no declaration of `JsonMap` there, so it compares it as spelled"
    );
    // A name both sides leave unfollowed is not the cause.
    let c = canon(&f, PAGE, "Map<JsonMap, int>");
    assert_eq!(
        types::hint(&c, &canon(&f, PAGE, "Map<JsonMap, String>")),
        ""
    );
}

#[test]
fn the_hint_lists_two_and_three_names() {
    let f = models();
    let a = canon(&f, PAGE, "A");
    let b = canon(&f, PAGE, "B");
    assert!(
        types::hint(&a, &b)
            .ends_with("found no declaration of `A` or `B` there, so it compares them as spelled")
    );
    let three = canon(&f, PAGE, "Map<A, B>");
    let c = canon(&f, PAGE, "C");
    assert!(types::hint(&three, &c).ends_with(
        "found no declaration of `A`, `B` or `C` there, so it compares them as spelled"
    ));
    assert_eq!(types::hint_of(&[]), "");
}
