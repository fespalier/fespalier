//! Forms and optimistic updates on `action.dart` (since 0.8.1). There is no file kind for them:
//! `form()`, `validate()` and `optimistic()` are *companion* functions of an action, found by
//! name beside it. For the action called `action` they are the role itself; for any other action
//! `approve` they are `approveForm`, `approveValidate` and `approveOptimistic`.
//!
//! This module holds what the resolver needs to read them: the names, the field kinds a text
//! field can take, and how the fields of an action's input record are read.

use crate::config::Config;
use crate::dart::{Ty, Typedef};
use crate::diag::Diags;
use crate::resolve::App;

/// What a companion function is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Companion {
    /// `form(Profile profile)`: the values the form starts from.
    Form,
    /// `validate(Input input)`: what is wrong with an input, before the action runs.
    Validate,
    /// `optimistic(T current, Input input)`: what the page shows while the write is in flight.
    Optimistic,
}

impl Companion {
    pub const ALL: [Companion; 3] = [Companion::Form, Companion::Validate, Companion::Optimistic];

    /// The companion's name for the plain action: `form`.
    pub fn plain(self) -> &'static str {
        match self {
            Companion::Form => "form",
            Companion::Validate => "validate",
            Companion::Optimistic => "optimistic",
        }
    }

    /// The capitalised name that follows the action's: `approveForm`.
    pub fn suffix(self) -> &'static str {
        match self {
            Companion::Form => "Form",
            Companion::Validate => "Validate",
            Companion::Optimistic => "Optimistic",
        }
    }

    /// What the companion is, in a sentence: "the validation of `action()`".
    pub fn what(self) -> &'static str {
        match self {
            Companion::Form => "form",
            Companion::Validate => "validation",
            Companion::Optimistic => "optimistic patch",
        }
    }
}

/// The name of the `role` companion of the action called `action`: the role itself for a function
/// called `action`, else the action's name followed by the role (`approveForm`).
pub fn companion(action: &str, role: Companion) -> String {
    if action == "action" {
        role.plain().to_string()
    } else {
        format!("{action}{}", role.suffix())
    }
}

/// `form()` needs the `fespalier_forms` package (since 0.11.0): the generated file imports it. An
/// error at each `form()` of an app that does not list it under `dependencies:`.
pub fn check_dependency(app: &App, cfg: &Config, diags: &mut Diags) {
    if cfg.forms_dependency {
        return;
    }
    for (action, form) in app
        .routes
        .iter()
        .flat_map(|r| &r.actions)
        .filter_map(|a| a.form.as_ref().map(|f| (a, f)))
    {
        let message = missing_package(&form.function, &action.name);
        diags.error(&form.file, Some(&form.span), &message);
    }
}

/// The message of [`check_dependency`]: `form` is the form of `action`.
pub fn missing_package(form: &str, action: &str) -> String {
    format!(
        "`{form}()` is the form of `{action}()`, and since 0.11.0 forms are in the fespalier_forms package: add `fespalier_forms` under `dependencies:` in pubspec.yaml, with the same git `url` and `ref` as fespalier"
    )
}

/// The `FieldCodec` a text field of this exact type is read with, or `None` for a field of
/// another type (a `bool`, an enum, a date...), which is a plain value field.
pub fn codec(ty: &str) -> Option<&'static str> {
    Some(match ty {
        "String" => "text",
        "String?" => "optionalText",
        "int" => "integer",
        "int?" => "optionalInteger",
        "double" => "decimal",
        "double?" => "optionalDecimal",
        "num" => "number",
        "num?" => "optionalNumber",
        _ => return None,
    })
}

/// The `DraftCodec` that keeps a value field of this exact type in a draft (since 0.11.0), for a
/// `bool` and a `DateTime`; enums are found by the resolver. `None` for any other type: it is not
/// drafted.
pub fn draft_codec(ty: &str) -> Option<&'static str> {
    Some(match ty {
        "bool" => "boolean",
        "bool?" => "optionalBoolean",
        "DateTime" => "dateTime",
        "DateTime?" => "optionalDateTime",
        _ => return None,
    })
}

/// Why an input is not a record a form can read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordError {
    /// Not a record type, or not one declared here.
    NotARecord,
    /// A record with positional fields, which have no names to key errors by.
    Positional,
}

/// Whether `t` is a record type with named fields only, `({int a, String b})`.
pub fn is_record_text(t: &str) -> bool {
    let Some(inner) = t.strip_prefix('(').and_then(|r| r.strip_suffix(')')) else {
        return false;
    };
    closes_at_end(t, '(', ')') && inner.starts_with('{') && closes_at_end(inner, '{', '}')
}

/// Whether the bracket that opens `s` is the one that closes it.
fn closes_at_end(s: &str, open: char, close: char) -> bool {
    let mut depth = 0i32;
    let last = s.len();
    for (i, ch) in s.char_indices() {
        if ch == open {
            depth += 1;
        } else if ch == close {
            depth -= 1;
            if depth == 0 {
                return i + ch.len_utf8() == last;
            }
        }
    }
    false
}

/// The `(name, type)` of each field of an action's input, in order: the input is written as
/// a record type, or as the name of a `typedef` declared in the same file.
pub fn record_fields(
    input: &Ty,
    typedefs: &[Typedef],
) -> Result<Vec<(String, String)>, RecordError> {
    let is_name = !input.text.is_empty()
        && input
            .text
            .chars()
            .all(|c| c.is_alphanumeric() || c == '_' || c == '$');
    let ty = if is_name {
        match typedefs.iter().find(|t| t.name == input.text) {
            Some(t) => &t.ty,
            None => return Err(RecordError::NotARecord),
        }
    } else {
        input
    };
    match &ty.record {
        Some(fields) if is_record_text(&ty.text) && !fields.is_empty() => Ok(fields
            .iter()
            .map(|(name, ty)| (name.clone(), ty.text.clone()))
            .collect()),
        Some(_) if ty.text.starts_with('(') && !ty.text.ends_with('?') => {
            Err(RecordError::Positional)
        }
        _ => Err(RecordError::NotARecord),
    }
}
