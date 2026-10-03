//! What a segment's text may parse to (`segtype.rs`): only a text that surely fails is flagged.

use crate::segtype::{SegTy, distance};

fn enum_of(values: &[&str]) -> SegTy {
    SegTy::Enum {
        name: "Category".into(),
        values: values.iter().map(ToString::to_string).collect(),
    }
}

fn fits(ty: &SegTy, parts: &[&str]) -> Vec<bool> {
    parts.iter().map(|p| ty.fits(p, true)).collect()
}

#[test]
fn text_fits_everything() {
    assert!(SegTy::Text.fits("anything at all", true));
    assert!(SegTy::Text.fits("", true));
}

#[test]
fn int_is_what_int_try_parse_reads() {
    let ok = ["0", "12", "00012", "+12", "-12", "0x1F", "-0x10", "0Xff"];
    assert!(fits(&SegTy::Int, &ok).iter().all(|b| *b), "{ok:?}");
    let bad = [
        "abc", "12abc", "1_000", "1e3", "0b101", "1.5", "0x", "+", "-", "--1",
    ];
    assert!(fits(&SegTy::Int, &bad).iter().all(|b| !*b), "{bad:?}");
}

#[test]
fn double_is_what_double_try_parse_reads() {
    let ok = [
        "1",
        "1.",
        ".5",
        "1.5",
        "1E+3",
        "1e3",
        "-2.5e-3",
        "+Infinity",
        "NaN",
        "-Infinity",
        "0x1F",
    ];
    assert!(fits(&SegTy::Double, &ok).iter().all(|b| *b), "{ok:?}");
    let bad = [
        "nan", "inf", "1.5f", "1_0", ".", "e3", "1e", "1e+", "1.2.3", "abc", "", "+",
    ];
    assert!(fits(&SegTy::Double, &bad).iter().all(|b| !*b), "{bad:?}");
}

#[test]
fn num_is_an_int_or_a_double() {
    assert!(SegTy::Num.fits("12", true));
    assert!(SegTy::Num.fits("1.5", true));
    assert!(SegTy::Num.fits("0x1F", true));
    assert!(!SegTy::Num.fits("abc", true));
}

#[test]
fn bool_is_exact_and_case_sensitive() {
    assert_eq!(
        fits(
            &SegTy::Bool,
            &["true", "false", "True", "TRUE", " true", "yes", "1", ""]
        ),
        [true, true, false, false, false, false, false, false]
    );
    // No unsure rule, and the route's case setting does not matter.
    assert!(!SegTy::Bool.fits("TRUE", false));
}

#[test]
fn date_time_is_checked_by_its_start() {
    let ok = [
        "2024-12-31",
        "20241231",
        "+002024-01-01",
        "-002024-01-01",
        "2024",
    ];
    assert!(fits(&SegTy::DateTime, &ok).iter().all(|b| *b), "{ok:?}");
    let bad = ["abc", "-x", "24-12-31", "+12", ""];
    assert!(fits(&SegTy::DateTime, &bad).iter().all(|b| !*b), "{bad:?}");
}

#[test]
fn a_text_with_whitespace_or_non_ascii_is_not_judged() {
    for ty in [SegTy::Int, SegTy::Double, SegTy::Num, SegTy::DateTime] {
        for part in ["\u{FEFF}12", "\u{A0}12", "1 2", "12 ", "\t1", "é", "\u{A0}"] {
            assert!(ty.fits(part, true), "{ty:?} {part:?}");
        }
    }
    // `%C2%A012` decoded is U+00A0 then `12`: Dart trims it, so it reads as 12.
    assert!(SegTy::Int.fits("\u{a0}12", true));
}

#[test]
fn enum_matches_a_name() {
    let ty = enum_of(&["shoes", "hats", "Big"]);
    assert_eq!(
        fits(&ty, &["shoes", "hats", "Big", "Shoes", "big", "socks", ""]),
        [true, true, true, false, false, false, false]
    );
    // With the route's case off, a lowercase match is enough, and a non-ASCII text is not judged.
    let ci: Vec<bool> = ["SHOES", "Hats", "bIG", "socks", "caf\u{e9}"]
        .iter()
        .map(|p| ty.fits(p, false))
        .collect();
    assert_eq!(ci, [true, true, true, false, true]);
}

#[test]
fn reasons_are_what_the_messages_say() {
    assert_eq!(SegTy::Int.reason(), "is not an int");
    assert_eq!(SegTy::Double.reason(), "is not a double");
    assert_eq!(SegTy::Num.reason(), "is not a number");
    assert_eq!(SegTy::Bool.reason(), "is not a bool (true or false)");
    assert_eq!(SegTy::DateTime.reason(), "is not a DateTime");
    assert_eq!(
        enum_of(&["shoes", "hats"]).reason(),
        "is not a value of Category (shoes, hats)"
    );
    assert_eq!(
        enum_of(&["a", "b", "c", "d", "e", "f"]).reason(),
        "is not a value of Category (a, b, c, d, e, f)"
    );
    assert_eq!(
        enum_of(&["a", "b", "c", "d", "e", "f", "g"]).reason(),
        "is not a value of Category (a, b, c, d, e, f, ...)"
    );
}

#[test]
fn nearest_is_a_value_within_a_couple_of_typos() {
    let ty = enum_of(&["shoes", "hats"]);
    assert_eq!(ty.nearest("shoos").as_deref(), Some("shoes"));
    assert_eq!(ty.nearest("Shoes").as_deref(), Some("shoes"));
    assert_eq!(ty.nearest("socks"), None);
    assert_eq!(ty.nearest("h"), None);
    assert_eq!(SegTy::Bool.nearest("tru").as_deref(), Some("true"));
    assert_eq!(SegTy::Bool.nearest("yes"), None);
    assert_eq!(SegTy::Int.nearest("abc"), None);
}

#[test]
fn distance_counts_characters() {
    assert_eq!(distance("kitten", "sitting"), 3);
    assert_eq!(distance("", "abc"), 3);
    assert_eq!(distance("café", "cafe"), 1);
}
