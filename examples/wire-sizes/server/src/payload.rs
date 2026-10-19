//! What a payload actually is: its shape, what it is made of, how many fields, and whether it is
//! compressed.
//!
//! **The dimensions here exist because measuring one of them was wrong.** The first sweep built a
//! single string with `"x".repeat(n)` and concluded JSON costs a fixed ~14 bytes at any size. That
//! was a property of the one payload with nothing to escape (see [`Kind::Escapable`]), and it took
//! four rounds to find the others. So each dimension is now explicit, measured, and named in the
//! report:
//!
//! - [`Shape`] — is the call one long string, a list of records, or a nested object? A real request
//!   is rarely one string, and the codec's per-field framing is a different cost from its
//!   per-character cost.
//! - [`Kind`] — what the *text* inside is made of. This decides how much JSON must escape.
//! - [`Sizes`] — how big, from a Twitter-length note to a 300 KB document.
//! - [`Samples`] — how many *different* payloads per size. One sample proves nothing about variance.
//! - [`Compression`] — whether the body is gzipped. This decides whether any of it matters, because
//!   a compressed body makes character-level differences almost vanish.
//!
//! Everything is deterministic: a seeded generator, not `rand`, so the report can be committed. But
//! the seed *varies per sample*, so a table shows a distribution rather than one arbitrary string.

use std::fmt::Write as _;

/// The sizes a sweep measures, in bytes of payload text.
pub const SIZES: [usize; 8] = [
    64,
    256,
    1024,
    4096,
    // The sizes a real app sends. Measured, not extrapolated.
    55 * 1024,
    120 * 1024,
    300 * 1024,
    // A payload past the measurement limit, where the sweep has to say so rather than report a
    // truncated figure as if it were the whole body.
    2 * 1024 * 1024,
];

/// The sizes a *short* sweep uses, for tests that must stay fast.
pub const QUICK_SIZES: [usize; 3] = [64, 4096, 55 * 1024];

/// How a payload is laid out.
///
/// The codec's cost per field is not its cost per byte, so a request carrying 200 small notes is not
/// the same measurement as one carrying a single 200×-longer note.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Shape {
    /// One long string. The degenerate case, kept as the control: few fields, one huge value.
    OneString,
    /// A list of records: many fields, many small values. What a `listNotes` answer looks like.
    Records,
    /// A nested object: deeper structure, maps of maps. What a settings blob or an event looks like.
    Nested,
    /// One string of raw bytes, base64-encoded: what a thumbnail or a ciphertext arrives as.
    Blob,
}

impl Shape {
    /// The name used in the report.
    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::OneString => "one-string",
            Self::Records => "records",
            Self::Nested => "nested",
            Self::Blob => "blob",
        }
    }

    /// Every shape.
    #[must_use]
    pub fn all() -> [Self; 4] {
        [Self::OneString, Self::Records, Self::Nested, Self::Blob]
    }

    /// Builds `value` as this shape, roughly `target` bytes of text in total.
    ///
    /// "Roughly", because the shapes pad to a *field count* rather than to an exact byte count, so
    /// each kind can be measured at a comparable size without the layout making up the numbers. The
    /// caller records the size it got, not the size it asked for.
    #[must_use]
    pub fn build(self, kind: Kind, target: usize, seed: u64) -> Payload {
        let mut rng = Rng::new(seed);
        match self {
            Self::OneString => Payload::OneString {
                text: kind.text(target, &mut rng),
            },
            Self::Records => {
                // ~64 bytes of value per record plus the key names and punctuation, so the *value*
                // bytes stay the dominant part at every size.
                let count = (target / 64).max(1);
                let fields = (0..count)
                    .map(|i| Record {
                        // Positional, and bounded by the payload size, so the conversion cannot
                        // fail; `try_from` rather than a cast avoids the pedantic cast lint.
                        id: i64::try_from(i).unwrap_or(i64::MAX),
                        // A varying slice length, so the records are not all identical — identical
                        // records would let a compressing codec flatter itself.
                        text: kind.text(48 + rng.below(32), &mut rng),
                    })
                    .collect();
                Payload::Records { fields }
            }
            Self::Nested => {
                let count = (target / 96).max(1);
                let entries = (0..count)
                    .map(|i| {
                        (
                            format!("key_{i}_{}", rng.below(10_000)),
                            kind.text(24 + rng.below(48), &mut rng),
                        )
                    })
                    .collect();
                Payload::Nested { entries }
            }
            Self::Blob => Payload::Blob {
                // Base64 expands 3 bytes into 4 characters, so ask for 3/4 of the target to land
                // near it in characters.
                text: kind.text(target.saturating_mul(3) / 4, &mut rng),
            },
        }
    }
}

/// What the text inside a payload is made of.
///
/// This decides how much JSON must escape, which is the difference that matters most and the one a
/// degenerate payload hides.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// One repeated ASCII letter. The control: nothing to escape, no entropy.
    Repeated,
    /// Ordinary prose: letters, spaces, light punctuation.
    Prose,
    /// Base64, as a thumbnail or an encrypted field arrives.
    Base64,
    /// A CRLF-terminated, tab-indented log line: **most bytes escapable**, where JSON loses badly.
    Escapable,
    /// Keys and quotes and braces — JSON embedded in JSON, or a code sample. The worst case for
    /// JSON, because it must escape its own syntax characters wherever they appear in the data.
    JsonLike,
    /// Non-ASCII text, where UTF-8 length and JSON's `\uXXXX` escaping diverge.
    Unicode,
}

impl Kind {
    /// The name used in the report.
    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::Repeated => "repeated",
            Self::Prose => "prose",
            Self::Base64 => "base64",
            Self::Escapable => "escapable",
            Self::JsonLike => "json-like",
            Self::Unicode => "unicode",
        }
    }

    /// Every kind.
    #[must_use]
    pub fn all() -> [Self; 6] {
        [
            Self::Repeated,
            Self::Prose,
            Self::Base64,
            Self::Escapable,
            Self::JsonLike,
            Self::Unicode,
        ]
    }

    /// `n` bytes (roughly) of this kind of text, drawn from `rng`.
    ///
    /// Varying with the seed is the point: [`Kind::Prose`] picking the same words every time would
    /// be another degenerate case wearing a costume.
    #[must_use]
    pub fn text(self, n: usize, rng: &mut Rng) -> String {
        match self {
            // The control: nothing to escape, no entropy.
            Self::Repeated => "x".repeat(n),
            Self::Prose => prose(n, rng),
            Self::Base64 => base64(n, rng),
            Self::Escapable => escapable(n),
            Self::JsonLike => json_like(n),
            Self::Unicode => unicode(n, rng),
        }
    }
}

/// Ordinary prose, in sentences. Drawn from the generator so two samples differ.
fn prose(n: usize, rng: &mut Rng) -> String {
    const WORDS: [&str; 24] = [
        "the",
        "quick",
        "brown",
        "fox",
        "jumps",
        "over",
        "lazy",
        "dog",
        "and",
        "then",
        "some",
        "more",
        "words",
        "here",
        "because",
        "however",
        "therefore",
        "although",
        "between",
        "through",
        "without",
        "against",
        "already",
        "another",
    ];
    let mut out = String::with_capacity(n + 8);
    let mut capitalise = true;
    while out.len() < n {
        let word = WORDS[rng.below(WORDS.len())];
        if capitalise {
            let mut chars = word.chars();
            if let Some(first) = chars.next() {
                out.extend(first.to_uppercase());
                out.push_str(chars.as_str());
            }
        } else {
            out.push_str(word);
        }
        out.push(' ');
        capitalise = out.ends_with(". ");
    }
    out.truncate(n);
    out
}

/// Base64, as a thumbnail or an encrypted field arrives.
fn base64(n: usize, rng: &mut Rng) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(n);
    for _ in 0..n {
        out.push(char::from(ALPHABET[rng.below(ALPHABET.len())]));
    }
    out
}

/// A CRLF-terminated, tab-indented log line: most bytes escapable.
fn escapable(n: usize) -> String {
    let mut out = String::with_capacity(n + 32);
    let mut i = 0_u64;
    while out.len() < n {
        let _ = write!(out, "\tline {i}\tvalue={}\r\n", i * 7);
        i += 1;
    }
    out.truncate(n);
    out
}

/// JSON as a *string value*, so every brace and quote is a character JSON must escape once more.
/// CBOR escapes none of them, which is the worst case for JSON.
fn json_like(n: usize) -> String {
    let mut out = String::with_capacity(n + 48);
    let mut i = 0_u64;
    while out.len() < n {
        let _ = write!(
            out,
            "{{\"id\":{i},\"name\":\"item {i}\",\"tags\":[\"a\",\"b\"],\"ok\":true}},\\n"
        );
        i += 1;
    }
    out.truncate(n);
    out
}

/// Multi-byte characters, where UTF-8 length and JSON's `\\uXXXX` escaping diverge.
fn unicode(n: usize, rng: &mut Rng) -> String {
    const PIECES: [&str; 12] = [
        "café ",
        "日本語 ",
        "emoji 😀 ",
        "naïve ",
        "Ω ",
        "Привет ",
        "🌍 ",
        "école ",
        "χρόνος ",
        "Grüße ",
        "mañana ",
        "θάλασσα ",
    ];
    let mut out = String::with_capacity(n + 32);
    while out.len() < n {
        out.push_str(PIECES[rng.below(PIECES.len())]);
    }
    // Truncating on a byte boundary could split a character, which would make the payload invalid
    // UTF-8 inside a JSON string. Trim back to the last whole character.
    if out.len() > n {
        let mut end = n;
        while end > 0 && !out.is_char_boundary(end) {
            end -= 1;
        }
        out.truncate(end);
    }
    out
}

/// Whether a body is compressed, and how.
///
/// The dimension that can make every other one moot: gzip finds repeated structure wherever it is,
/// so a JSON body and its CBOR twin compress to within a few bytes of each other even when the raw
/// difference is 17%.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Compression {
    /// No `Content-Encoding`.
    None,
    /// `Content-Encoding: gzip`.
    Gzip,
}

impl Compression {
    /// The name used in the report.
    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Gzip => "gzip",
        }
    }

    /// Whether this is a compressed variant.
    #[must_use]
    pub fn is_compressed(self) -> bool {
        matches!(self, Self::Gzip)
    }
}

/// One record of a [`Shape::Records`] payload.
#[derive(Clone, Debug)]
pub struct Record {
    /// The record's id.
    pub id: i64,
    /// The record's text.
    pub text: String,
}

/// A payload, laid out as a [`Shape`].
///
/// Kept as data rather than as JSON text so the serde value is built the same way for every codec:
/// the encoders must see one identical structure, or the comparison measures two calls.
#[derive(Clone, Debug)]
pub enum Payload {
    /// One long string.
    OneString {
        /// The text.
        text: String,
    },
    /// A list of records.
    Records {
        /// The records.
        fields: Vec<Record>,
    },
    /// A map of string to string.
    Nested {
        /// The entries.
        entries: Vec<(String, String)>,
    },
    /// A base64 blob.
    Blob {
        /// The encoded text.
        text: String,
    },
}

impl Payload {
    /// The payload as the `serde_json::Value` every codec will encode.
    ///
    /// One value, whatever the shape: the encoders must be handed the same tree, or a size
    /// difference could come from the structure rather than the encoding.
    #[must_use]
    pub fn value(&self) -> cratestack::serde_json::Value {
        use cratestack::serde_json::json;
        match self {
            Self::OneString { text } => json!({ "text": text }),
            Self::Records { fields } => json!({
                "notes": fields
                    .iter()
                    .map(|r| json!({ "id": r.id, "text": r.text }))
                    .collect::<Vec<_>>(),
            }),
            Self::Nested { entries } => {
                let map: cratestack::serde_json::Map<String, cratestack::serde_json::Value> =
                    entries.iter().map(|(k, v)| (k.clone(), json!(v))).collect();
                json!({ "settings": map })
            }
            Self::Blob { text } => json!({ "data": text }),
        }
    }

    /// The number of bytes of text this payload carries, before any encoding.
    ///
    /// The figure the tables compare sizes by: the *input* size, so two encodings of the same
    /// payload are recognised as the same payload.
    #[must_use]
    pub fn text_bytes(&self) -> usize {
        match self {
            Self::OneString { text } | Self::Blob { text } => text.len(),
            Self::Records { fields } => fields.iter().map(|r| r.text.len()).sum(),
            Self::Nested { entries } => entries.iter().map(|(k, v)| k.len() + v.len()).sum(),
        }
    }
}

/// A small deterministic generator, so the report can be committed.
///
/// Not `rand`: a measurement whose payload changed between runs could not be diffed, and the
/// committed `REPORT.md` check depends on reproducibility. `splitmix64` is enough for choosing
/// words and lengths.
#[derive(Clone, Debug)]
pub struct Rng(u64);

impl Rng {
    /// A generator from a seed.
    #[must_use]
    pub fn new(seed: u64) -> Self {
        Self(seed.wrapping_add(0x9e37_79b9_7f4a_7c15))
    }

    /// The next raw value.
    pub fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    /// A value below `bound`, or `0` when `bound` is zero.
    ///
    /// Returns `usize` because every caller indexes with it; keeping it `u64` forced a truncating
    /// cast at each call site, which is the shape of the bug this lint exists to prevent.
    pub fn below(&mut self, bound: usize) -> usize {
        if bound == 0 {
            return 0;
        }
        // `bound` is a slice length or a small constant in every caller, so the modulo fits.
        usize::try_from(self.next_u64() % bound as u64).unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_shape_builds_and_is_roughly_the_size_asked_for() {
        for shape in Shape::all() {
            for target in [64_usize, 4096] {
                let payload = shape.build(Kind::Prose, target, 1);
                let text = payload.text_bytes();
                assert!(
                    text > 0,
                    "{} at {target} should carry some text",
                    shape.name()
                );
                // The shapes pad to a field count, so an exact match is not expected; being within a
                // factor of four of the target is, or the sizes in the table would mean nothing.
                assert!(
                    text <= target * 3,
                    "{} at {target} built {text} bytes, which is not near the target",
                    shape.name()
                );
            }
        }
    }

    #[test]
    fn a_different_seed_gives_different_text() {
        let mut a = Rng::new(1);
        let mut b = Rng::new(2);
        assert_ne!(
            Kind::Prose.text(400, &mut a),
            Kind::Prose.text(400, &mut b),
            "two seeds should not produce identical prose, or the samples are not samples"
        );
    }

    #[test]
    fn the_same_seed_gives_identical_text() {
        let mut a = Rng::new(7);
        let mut b = Rng::new(7);
        assert_eq!(
            Kind::Escapable.text(300, &mut a),
            Kind::Escapable.text(300, &mut b)
        );
    }

    #[test]
    fn unicode_text_stays_valid_after_truncation() {
        for target in [1_usize, 3, 7, 15, 64, 100] {
            let mut rng = Rng::new(target as u64);
            let text = Kind::Unicode.text(target, &mut rng);
            // The only assertion that matters: it is a `String`, so building one that split a
            // character would have panicked before this line.
            assert!(text.len() <= target + 32, "{text:?} is longer than asked");
        }
    }

    #[test]
    fn records_are_not_all_identical() {
        // Identical records would let a compressing codec flatter itself, so the text must vary.
        let Payload::Records { fields } = Shape::Records.build(Kind::Prose, 4096, 3) else {
            panic!("records shape should build records");
        };
        assert!(fields.len() > 1);
        assert_ne!(fields[0].text, fields[1].text);
    }

    #[test]
    fn a_payload_renders_one_value_for_every_codec() {
        let payload = Shape::Nested.build(Kind::Base64, 512, 5);
        let value = payload.value();
        assert!(value.get("settings").is_some(), "{value}");
        // The same tree every time, so a size difference cannot come from the structure.
        assert_eq!(value, payload.value());
    }
}
