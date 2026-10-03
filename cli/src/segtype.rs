//! What a segment's text parses to, as the runtime's readers do (`Segment.asInt`, `asEnum`, ...).
//!
//! The `unknown_path` lint uses it to say that `/products/abc` reaches `products/$id` and then
//! shows not-found, because `abc` is not an `int`. It flags a text only when it **surely**
//! fails: where Dart's parsers and the web's might differ (a text with whitespace or any
//! non-ASCII character, an out-of-range number) the text is let through. The rules are written
//! by hand, because the crate has no regex dependency.

use crate::resolve::App;

/// How many enum values a message lists before it cuts the list.
const LISTED: usize = 6;

/// The type of one segment (for a catch-all, of each of its parts).
#[derive(Debug, Clone, PartialEq)]
pub enum SegTy {
    /// A `String`, or a type this does not know: every text is fine.
    Text,
    Int,
    Double,
    Num,
    Bool,
    DateTime,
    /// An enum, by its name as the app writes it (`Category`) and its constants in order.
    Enum {
        name: String,
        values: Vec<String>,
    },
}

impl SegTy {
    /// The type of the dynamic or catch-all folder `folder` (for a catch-all, its element type),
    /// from the type the resolver gave it. An enum is known by the constants the resolver read
    /// ([`App::enum_values`]); a type this does not know, or an enum whose constants could not
    /// be read, is [`SegTy::Text`].
    pub fn of(app: &App, folder: usize) -> SegTy {
        let spelled = app.seg_type(folder);
        let bare = |t: &str| -> String {
            let t = t.strip_suffix('?').unwrap_or(t);
            t.strip_prefix("List<")
                .and_then(|t| t.strip_suffix('>'))
                .unwrap_or(t)
                .to_string()
        };
        let ty = bare(spelled);
        match ty.as_str() {
            "int" => SegTy::Int,
            "double" => SegTy::Double,
            "num" => SegTy::Num,
            "bool" => SegTy::Bool,
            "DateTime" => SegTy::DateTime,
            _ => match app.enum_values.get(&ty) {
                Some(values) if !values.is_empty() => SegTy::Enum {
                    name: bare(&app.display_type(spelled)),
                    values: values.clone(),
                },
                _ => SegTy::Text,
            },
        }
    }

    /// Whether `part` (decoded) can be read as this type. `false` only when it surely cannot.
    /// `case_sensitive` is the route's: an enum segment matches without regard to case when
    /// the route does.
    pub fn fits(&self, part: &str, case_sensitive: bool) -> bool {
        match self {
            SegTy::Text => true,
            SegTy::Bool => part == "true" || part == "false",
            SegTy::Enum { values, .. } => {
                if values.iter().any(|v| v == part) {
                    return true;
                }
                if case_sensitive {
                    return false;
                }
                // `toLowerCase` of a non-ASCII text is not something to second-guess here.
                !part.is_ascii()
                    || values
                        .iter()
                        .any(|v| v.is_ascii() && v.eq_ignore_ascii_case(part))
            }
            // Dart trims every Unicode whitespace (U+FEFF and U+00A0 too) before it parses a
            // number or a date, and the web may differ: such a text is not judged.
            _ if !part.chars().all(|c| ('\u{21}'..='\u{7e}').contains(&c)) => true,
            SegTy::Int => is_int(part),
            SegTy::Double => is_double(part),
            SegTy::Num => is_int(part) || is_double(part),
            SegTy::DateTime => starts_like_date(part),
        }
    }

    /// What a message says after the part: `is not an int`.
    pub fn reason(&self) -> String {
        match self {
            SegTy::Text => "is not a text".into(),
            SegTy::Int => "is not an int".into(),
            SegTy::Double => "is not a double".into(),
            SegTy::Num => "is not a number".into(),
            SegTy::Bool => "is not a bool (true or false)".into(),
            SegTy::DateTime => "is not a DateTime".into(),
            SegTy::Enum { name, values } => {
                let mut shown = values
                    .iter()
                    .take(LISTED)
                    .map(String::as_str)
                    .collect::<Vec<_>>()
                    .join(", ");
                if values.len() > LISTED {
                    shown.push_str(", ...");
                }
                format!("is not a value of {name} ({shown})")
            }
        }
    }

    /// For a `bool` or an enum: the nearest value to `part`, within a couple of typos (the
    /// rule the lint uses for a misspelled static segment), or `None`.
    pub fn nearest(&self, part: &str) -> Option<String> {
        let values: Vec<&str> = match self {
            SegTy::Bool => vec!["true", "false"],
            SegTy::Enum { values, .. } => values.iter().map(String::as_str).collect(),
            _ => return None,
        };
        let have = part.to_lowercase();
        let mut best: Option<(usize, &str)> = None;
        for v in values {
            let d = distance(&have, &v.to_lowercase());
            if d <= 2 && d <= v.chars().count() / 3 && best.is_none_or(|(b, _)| d < b) {
                best = Some((d, v));
            }
        }
        best.map(|(_, v)| v.to_string())
    }
}

fn digits(s: &str) -> bool {
    s.bytes().all(|b| b.is_ascii_digit())
}

fn hex(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_hexdigit())
}

fn unsigned(s: &str) -> &str {
    s.strip_prefix(['+', '-']).unwrap_or(s)
}

fn hex_body(s: &str) -> Option<&str> {
    s.strip_prefix("0x").or_else(|| s.strip_prefix("0X"))
}

/// `^[+-]?([0-9]+|0[xX][0-9a-fA-F]+)$`: what `int.tryParse` reads. The range is not checked.
fn is_int(s: &str) -> bool {
    let t = unsigned(s);
    (!t.is_empty() && digits(t)) || hex_body(t).is_some_and(hex)
}

/// What `double.tryParse` reads, and a little more: hex is let through, because the VM rejects
/// it but dart2js may not.
fn is_double(s: &str) -> bool {
    let t = unsigned(s);
    if t == "NaN" || t == "Infinity" || hex_body(t).is_some_and(hex) {
        return true;
    }
    let (mantissa, exponent) = match t.find(['e', 'E']) {
        Some(i) => (&t[..i], Some(&t[i + 1..])),
        None => (t, None),
    };
    if let Some(e) = exponent {
        let e = unsigned(e);
        if e.is_empty() || !digits(e) {
            return false;
        }
    }
    match mantissa.split_once('.') {
        None => !mantissa.is_empty() && digits(mantissa),
        Some((whole, fraction)) => {
            digits(whole) && digits(fraction) && !(whole.is_empty() && fraction.is_empty())
        }
    }
}

/// `^[+-]?[0-9]{4}`: every text `DateTime.tryParse` reads starts so. Ranges are normalized, not
/// rejected, and the rest is not checked: this never flags a text the runtime reads.
fn starts_like_date(s: &str) -> bool {
    let t = unsigned(s);
    t.len() >= 4 && t.as_bytes()[..4].iter().all(u8::is_ascii_digit)
}

/// The Levenshtein distance between two strings, in characters.
pub(crate) fn distance(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.chars().enumerate() {
        let mut diagonal = row[0];
        row[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let above = row[j + 1];
            row[j + 1] = (above + 1)
                .min(row[j] + 1)
                .min(diagonal + usize::from(ca != *cb));
            diagonal = above;
        }
    }
    row[b.len()]
}
