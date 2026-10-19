//! The report: the measurement rendered as Markdown.
//!
//! The report is **generated, never hand-written**, so a number in it cannot drift from the code
//! that produced it. [`measure_all`] drives every variant through [`crate::runner::run`]; [`report`]
//! renders the result. `src/bin/report.rs` prints that text, and a test compares it with the
//! committed `REPORT.md`, which is what makes the committed numbers checkable rather than claimed.

use std::fmt::Write as _;

use crate::Variant;
use crate::measure::Exchange;
use crate::runner;
use crate::scenario::{EnvelopeOverhead, Run, Scenario};

/// A realistic-size token for the plain variants' baseline, so the run is authorized.
///
/// **Not a credential.** The server does not verify it; it is here because the plain variants have
/// no signature to identify their caller, and would be refused before the payload was reached. It
/// is a real JWT of the length these things run to, which is the property the measurement needs.
pub const BEARER_BASELINE: &str =
    "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";

/// Drives every variant through one scenario.
///
/// # Errors
/// When a run cannot be set up. A *refusal* is not an error: it is a measured answer.
pub async fn measure_all(scenario: &Scenario) -> Result<Vec<Run>, cratestack::CratestackError> {
    let mut runs = Vec::new();
    for variant in Variant::all() {
        // A `cose` server carries its credential in the body and has no header to send; the plain
        // variants have nothing else, so the bearer is the only way for them to be authorized.
        let bearer = match variant {
            Variant::Json | Variant::Cbor => Some(BEARER_BASELINE),
            Variant::Cose => None,
        };
        runs.push(runner::run(variant, scenario, bearer).await?);
    }
    Ok(runs)
}

/// The payload sizes the sweep measures, in bytes of note text.
///
/// The default scenario's note is 27 bytes, where every difference is a large percentage of a tiny
/// number. The sweep asks the natural follow-up — *does this hold at a real size?* — and **the
/// answer depends on the payload's content, which is why both dimensions are measured.**
pub const SWEEP_SIZES: [usize; 8] = [
    16,
    64,
    256,
    1024,
    4096,
    // The sizes a real app actually sends. Measured rather than extrapolated.
    55 * 1024,
    120 * 1024,
    300 * 1024,
];

/// What a payload is *made of*, which decides whether JSON has to escape anything.
///
/// **This dimension was missing at first, and its absence produced a wrong answer.** The sweep
/// originally built payloads with `"x".repeat(n)` — one repeated byte — and reported that JSON's
/// penalty over CBOR is a fixed ~14 bytes at every size. That is true of a payload with nothing
/// JSON must escape, and no real payload is like that: a `"` becomes `\"`, a newline `\n`, a tab
/// `\t`, and a control byte six characters of `\u0001`. CBOR passes all of them through raw, so
/// on text that is *mostly* escapable — a CRLF log, JSON itself, a code sample — JSON's penalty is
/// **~17%, and it scales**, not 14 bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PayloadKind {
    /// One repeated ASCII letter. The degenerate case, kept as the control: nothing to escape.
    Repeated,
    /// Ordinary prose: letters, spaces, a little punctuation.
    Prose,
    /// Base64, as a thumbnail or an encrypted field arrives.
    Base64,
    /// A CRLF-terminated, tab-indented log: **most bytes escapable**, where JSON loses badly.
    Escapable,
}

impl PayloadKind {
    /// The name used in the report.
    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::Repeated => "repeated",
            Self::Prose => "prose",
            Self::Base64 => "base64",
            Self::Escapable => "escapable",
        }
    }

    /// Every kind, for the sweep.
    #[must_use]
    pub fn all() -> [Self; 4] {
        [Self::Repeated, Self::Prose, Self::Base64, Self::Escapable]
    }

    /// `n` bytes of this kind of text.
    ///
    /// Deterministic on purpose: a measurement that moved between runs could not be committed to a
    /// report. The base64 generator is a seeded LCG, not `rand`, so no dependency is added for it.
    #[must_use]
    pub fn text(self, n: usize) -> String {
        match self {
            Self::Repeated => "x".repeat(n),
            Self::Prose => {
                const WORDS: [&str; 14] = [
                    "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "and", "then",
                    "some", "more", "words", "here",
                ];
                let mut out = String::with_capacity(n + 8);
                let mut i = 0;
                while out.len() < n {
                    out.push_str(WORDS[i % WORDS.len()]);
                    out.push(' ');
                    i += 1;
                }
                out.truncate(n);
                out
            }
            Self::Base64 => {
                const ALPHABET: &[u8] =
                    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
                let mut out = String::with_capacity(n);
                // A fixed starting state, so the same bytes come out every time.
                let mut state: u64 = 0x2545_f491_4f6c_dd1d;
                for _ in 0..n {
                    state = state
                        .wrapping_mul(6_364_136_223_846_793_005)
                        .wrapping_add(1_442_695_040_888_963_407);
                    out.push(char::from(
                        ALPHABET[(state >> 33) as usize % ALPHABET.len()],
                    ));
                }
                out
            }
            Self::Escapable => {
                let mut out = String::with_capacity(n + 32);
                let mut i = 0_u64;
                while out.len() < n {
                    out.push('\t');
                    out.push_str("line ");
                    out.push_str(&i.to_string());
                    out.push('\t');
                    out.push_str("value=");
                    out.push_str(&(i * 7).to_string());
                    out.push_str("\r\n");
                    i += 1;
                }
                out.truncate(n);
                out
            }
        }
    }
}

/// One payload size and kind's measurement, for the sweep table.
#[derive(Clone, Debug)]
pub struct SweepRow {
    /// What the payload is made of.
    pub kind: PayloadKind,
    /// The note text's length in bytes, as it was built.
    pub note_bytes: usize,
    /// The runs at this size, one per variant.
    pub runs: Vec<Run>,
}

/// Measures the same scenario at each size, for each payload kind.
///
/// # Errors
/// When a run cannot be set up.
pub async fn measure_sweep() -> Result<Vec<SweepRow>, cratestack::CratestackError> {
    let mut rows = Vec::new();
    for kind in PayloadKind::all() {
        for note_bytes in SWEEP_SIZES {
            let scenario = Scenario {
                reads: 0,
                writes: 1,
                note_text: kind.text(note_bytes),
            };
            rows.push(SweepRow {
                kind,
                note_bytes,
                runs: measure_all(&scenario).await?,
            });
        }
    }
    Ok(rows)
}

/// The whole report, as Markdown.
///
/// # Errors
/// When a run cannot be set up, or the scenario's own numbers cannot be measured.
pub async fn generate() -> Result<String, cratestack::CratestackError> {
    let runs = measure_all(&Scenario::default()).await?;
    let sweep = measure_sweep().await?;
    Ok(report(&runs, &sweep))
}

/// Renders the measurement as Markdown.
///
/// Split from [`generate`] so the rendering can be tested against a `Run` built by hand, without a
/// router: the interesting failures here are arithmetic and formatting, not I/O.
#[must_use]
pub fn report(runs: &[Run], sweep: &[SweepRow]) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "{}", summary_table(runs));
    let _ = writeln!(out);
    let _ = writeln!(out, "{}", payload_table(runs));
    let _ = writeln!(out);
    let _ = writeln!(out, "{}", overhead_table(runs));
    let _ = writeln!(out);
    let _ = writeln!(out, "{}", per_op_table(runs));
    let _ = writeln!(out);
    let _ = writeln!(out, "{}", split_table(runs));
    let _ = writeln!(out);
    let _ = writeln!(out, "{}", credential_comparison(runs));
    let _ = writeln!(out);
    let _ = writeln!(out, "{}", sweep_table(sweep));
    out
}

/// Whether the payload is JSON, as a table cell.
///
/// The one place the report says plainly that JSON's body is *larger* than CBOR's, because a reader
/// who sees two nearly equal totals deserves to know which direction the difference runs.
#[must_use]
pub fn payload_table(runs: &[Run]) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "| Variant | Body bytes | JSON's penalty |");
    let _ = writeln!(out, "| --- | ---: | ---: |");
    let json_body = runs
        .iter()
        .find(|r| r.variant == Variant::Json)
        .map_or(0, |r| {
            r.exchanges
                .iter()
                .map(|e| e.request_body_bytes)
                .sum::<usize>()
        });
    for run in runs {
        let body: usize = run.exchanges.iter().map(|e| e.request_body_bytes).sum();
        let penalty = match run.variant {
            Variant::Json => "—".to_owned(),
            // Signed against unsigned is a different question (the signature is *inside* the body),
            // so the penalty is only computed against CBOR, the other plain codec.
            Variant::Cbor => format!("+{} vs CBOR", json_body.saturating_sub(body)),
            // The signature is *inside* the body, so this is not the same kind of penalty as
            // JSON's: it is not the codec, it is the credential.
            Variant::Cose => "n/a (the signature is inside)".to_owned(),
        };
        let _ = writeln!(out, "| `{}` | {} | {} |", run.variant.name(), body, penalty);
    }
    out
}

/// The same measurement at several payload sizes.
///
/// The question a reader asks next, and the one a single payload size cannot answer: do these
/// differences scale with the payload or stay fixed? They stay fixed, and the table shows it.
#[must_use]
pub fn sweep_table(sweep: &[SweepRow]) -> String {
    let mut out = String::new();
    let _ = writeln!(
        out,
        "| Payload | `note_text` | JSON body | CBOR body | JSON−CBOR | COSE body | COSE−CBOR |"
    );
    let _ = writeln!(out, "| --- | ---: | ---: | ---: | ---: | ---: | ---: |");
    for row in sweep {
        let body_of = |variant| {
            row.runs
                .iter()
                .find(|r| r.variant == variant)
                .map_or(0, |r| {
                    r.exchanges
                        .iter()
                        .map(|e| e.request_body_bytes)
                        .sum::<usize>()
                })
        };
        let (json, cbor, cose) = (
            body_of(Variant::Json),
            body_of(Variant::Cbor),
            body_of(Variant::Cose),
        );
        let _ = writeln!(
            out,
            "| `{}` | {} | {} | {} | +{} | {} | +{} |",
            row.kind.name(),
            row.note_bytes,
            json,
            cbor,
            json.saturating_sub(cbor),
            cose,
            cose.saturating_sub(cbor)
        );
    }
    out
}

/// Per-op request bytes **split into head and body**, per call.
///
/// This is the table an eye comparing two payloads is really reading, and the two halves move in
/// *opposite* directions between the variants: a `cose` call sends no `Authorization` header, so its
/// head is much smaller than the plain variants', while the signature makes its body much larger.
/// Reporting only the total hides that, and produces a number that reads like "the signature is
/// cheaper than a token" when it does not.
#[must_use]
pub fn split_table(runs: &[Run]) -> String {
    let mut out = String::new();
    let _ = writeln!(
        out,
        "| Op | Variant | Head/call | Body/call | Total/call | Credential |"
    );
    let _ = writeln!(out, "| --- | --- | ---: | ---: | ---: | --- |");
    for op in ops(runs) {
        for run in runs {
            let calls = run.of_op(&op);
            let count = calls.len();
            let head: usize = calls.iter().map(|e| e.request_head_bytes()).sum();
            let body: usize = calls.iter().map(|e| e.request_body_bytes).sum();
            let total: usize = calls.iter().map(|e| e.request_total_bytes()).sum();
            // `checked_div` rather than a guard: an op nobody called has no per-call figure, and
            // skipping it says so, where a printed zero would look like a measurement.
            let (Some(head), Some(body), Some(total)) = (
                head.checked_div(count),
                body.checked_div(count),
                total.checked_div(count),
            ) else {
                continue;
            };
            let credential = calls.first().map_or(0, |e| e.authorization_bytes());
            let _ = writeln!(
                out,
                "| `{}` | `{}` | {} | {} | {} | {} |",
                op,
                run.variant.name(),
                head,
                body,
                total,
                if credential > 0 {
                    format!("{credential} B header")
                } else {
                    "in the body".to_owned()
                }
            );
        }
    }
    out
}

/// The credential one run carried in `Authorization` headers, in bytes.
///
/// `0` for a `cose` run: its credential is the signature, counted in the body instead.
#[must_use]
pub fn credential_bytes(run: &Run) -> usize {
    run.exchanges
        .iter()
        .map(Exchange::authorization_bytes)
        .sum()
}

/// The signature against the `Bearer` header it replaces.
///
/// The comparison a reader actually wants, and the one the totals hide: a `cose` call's credential
/// is ~111 bytes inside the body, while the `Bearer` header the plain variants carry is ~116 bytes
/// of head. They are nearly the same size, which is the honest headline — *signing roughly replaces
/// a token, it does not add to it* — and it is invisible in a whole-request total, where the `cose`
/// call simply looks larger.
#[must_use]
pub fn credential_comparison(runs: &[Run]) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "**The credential, compared directly.**");
    let _ = writeln!(out);
    let _ = writeln!(out, "| Credential | Bytes | Where |");
    let _ = writeln!(out, "| --- | ---: | --- |");
    for run in runs {
        match run.variant {
            Variant::Cose => {
                let sealed = run.sealed().len();
                let added = run.added_total();
                let _ = writeln!(
                    out,
                    "| `cose` signature | {} | in the body ({} over {} sealed calls) |",
                    added.checked_div(sealed).unwrap_or(0),
                    added,
                    sealed
                );
            }
            Variant::Json | Variant::Cbor => {
                let calls = run.exchanges.len();
                let bytes = credential_bytes(run);
                let _ = writeln!(
                    out,
                    "| `{}` `Bearer` header | {} | in the head ({} over {} calls) |",
                    run.variant.name(),
                    bytes.checked_div(calls).unwrap_or(0),
                    bytes,
                    calls
                );
            }
        }
    }
    out
}

/// The ops a run sent, in order, without repeats.
fn ops(runs: &[Run]) -> Vec<String> {
    let mut ops: Vec<String> = Vec::new();
    if let Some(run) = runs.first() {
        for exchange in &run.exchanges {
            let op = exchange.path.trim_start_matches("/rpc/").to_owned();
            if !ops.contains(&op) {
                ops.push(op);
            }
        }
    }
    ops
}

/// The headline table: one row per variant.
#[must_use]
pub fn summary_table(runs: &[Run]) -> String {
    let mut out = String::new();
    let _ = writeln!(
        out,
        "| Variant | Credential | Request bytes | Response bytes | Request body | Credential bytes |"
    );
    let _ = writeln!(out, "| --- | --- | ---: | ---: | ---: | ---: |");
    for run in runs {
        let bodies: usize = run.exchanges.iter().map(|e| e.request_body_bytes).sum();
        // The credential is what is *not* the payload: a `Bearer` header for the plain variants,
        // the signature inside the body for `cose`.
        let credential = if run.variant == Variant::Cose {
            run.added_total()
        } else {
            run.exchanges
                .iter()
                .map(Exchange::authorization_bytes)
                .sum()
        };
        let _ = writeln!(
            out,
            "| `{}` | {} | {} | {} | {} | {} |",
            run.variant.name(),
            credential_kind(run),
            run.server_request_total(),
            run.server_response_total(),
            bodies,
            credential
        );
    }
    out
}

/// What carries the credential in a run, in words.
fn credential_kind(run: &Run) -> &'static str {
    match run.variant {
        Variant::Cose => "signature in the body",
        Variant::Json | Variant::Cbor if run.bearer => "`Authorization` header",
        Variant::Json | Variant::Cbor => "none",
    }
}

/// The `cose` overhead, per op.
#[must_use]
pub fn overhead_table(runs: &[Run]) -> String {
    let mut out = String::new();
    let _ = writeln!(
        out,
        "| Op | Payload | External AAD | Body | Added | Added % |"
    );
    let _ = writeln!(out, "| --- | ---: | ---: | ---: | ---: | ---: |");
    let Some(cose) = runs.iter().find(|r| r.variant == Variant::Cose) else {
        let _ = writeln!(out, "| _(no `cose` run)_ | | | | | |");
        return out;
    };
    for sealed in cose.sealed() {
        let _ = writeln!(
            out,
            "| `{}` | {} | {} | {} | {} | {} |",
            sealed.op,
            sealed.payload_bytes,
            sealed.aad_bytes,
            sealed.body_bytes,
            sealed.added_bytes(),
            percent(sealed.added_percent())
        );
    }
    let _ = writeln!(
        out,
        "| **Total** | **{}** | | | **{}** | |",
        cose.payload_total(),
        cose.added_total()
    );
    out
}

/// Per-op request bytes, so the scenario's shape is visible rather than only its total.
#[must_use]
pub fn per_op_table(runs: &[Run]) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "| Op | Call | JSON | CBOR | COSE |");
    let _ = writeln!(out, "| --- | ---: | ---: | ---: | ---: |");
    for op in ops(runs) {
        let mut cells = Vec::new();
        for run in runs {
            let measured = run.of_op(&op);
            let bytes: usize = measured.iter().map(|e| e.request_total_bytes()).sum();
            cells.push(format!(
                "{} × {} = {}",
                measured.len(),
                per_call(&measured),
                bytes
            ));
        }
        let _ = writeln!(
            out,
            "| `{}` | {} | {} | {} | {} |",
            op,
            calls_of(runs, &op),
            cells.first().map_or("-", String::as_str),
            cells.get(1).map_or("-", String::as_str),
            cells.get(2).map_or("-", String::as_str)
        );
    }
    out
}

/// How many times `op` was called.
fn calls_of(runs: &[Run], op: &str) -> usize {
    runs.first().map_or(0, |run| run.of_op(op).len())
}

/// One call's request bytes, or `0` when the op was not called.
fn per_call(calls: &[&Exchange]) -> usize {
    calls.first().map_or(0, |e| e.request_total_bytes())
}

/// A percentage as a Markdown cell.
fn percent(value: Option<f64>) -> String {
    value.map_or_else(|| "n/a".to_owned(), |p| format!("{p:.1}%"))
}

/// One `EnvelopeOverhead`'s added bytes as a percentage, for the binary's console output.
#[must_use]
pub fn added_percent(overhead: &EnvelopeOverhead) -> String {
    percent(overhead.added_percent())
}

#[cfg(test)]
mod tests {
    #![allow(clippy::expect_used, reason = "tests may expect")]

    use super::*;

    fn run(variant: Variant, bearer: bool, totals: (usize, usize, usize)) -> Run {
        Run {
            variant,
            bearer,
            exchanges: vec![Exchange {
                method: "POST".to_owned(),
                path: "/rpc/procedure.listNotes".to_owned(),
                request_headers: Vec::new(),
                request_body_bytes: totals.2,
                status: 200,
                response_headers: Vec::new(),
                response_body_bytes: 0,
            }],
            overhead: Vec::new(),
        }
    }

    #[test]
    fn the_summary_names_the_credential_of_each_variant() {
        let runs = vec![
            run(Variant::Json, true, (100, 50, 10)),
            run(Variant::Cbor, true, (90, 50, 10)),
            run(Variant::Cose, false, (95, 50, 10)),
        ];
        let table = summary_table(&runs);
        assert!(table.contains("`Authorization` header"), "{table}");
        assert!(table.contains("signature in the body"), "{table}");
    }

    #[test]
    fn a_variant_without_a_bearer_says_so() {
        let runs = vec![run(Variant::Json, false, (100, 50, 10))];
        assert!(summary_table(&runs).contains("| none |"));
    }

    #[test]
    fn the_overhead_table_is_honest_about_a_missing_cose_run() {
        let runs = vec![run(Variant::Json, true, (100, 50, 10))];
        let table = overhead_table(&runs);
        assert!(table.contains("no `cose` run"), "{table}");
        // It must still be a table, so a reader is not left with a dangling sentence.
        assert!(table.lines().count() >= 3, "{table}");
    }

    #[test]
    fn the_overhead_table_totals_its_rows() {
        let mut cose = run(Variant::Cose, false, (95, 50, 0));
        cose.overhead = vec![
            EnvelopeOverhead {
                op: "procedure.addNote".to_owned(),
                payload_bytes: 43,
                aad_bytes: 102,
                body_bytes: 155,
            },
            EnvelopeOverhead {
                op: "procedure.listNotes".to_owned(),
                payload_bytes: 7,
                aad_bytes: 104,
                body_bytes: 118,
            },
        ];
        let table = overhead_table(&[cose]);
        assert!(table.contains("| **Total** | **50** |"), "{table}");
        // 112 + 111.
        assert!(table.contains("**223**"), "{table}");
    }

    #[test]
    fn a_percentage_is_rendered_or_says_na() {
        assert_eq!(percent(Some(260.5)), "260.5%");
        assert_eq!(percent(None), "n/a");
    }

    #[test]
    fn the_report_renders_every_section() {
        let runs = vec![run(Variant::Json, true, (100, 50, 10))];
        let text = report(&runs, &[]);
        assert!(text.contains("Request bytes"));
        assert!(text.contains("Body bytes"));
        assert!(text.contains("External AAD"));
        assert!(text.contains("| Op | Call |"));
        assert!(text.contains("Head/call"));
        assert!(text.contains("The credential, compared directly"));
        assert!(text.contains("JSON body"));
    }

    #[test]
    fn the_payload_table_says_json_is_the_bigger_body() {
        let runs = vec![
            run(Variant::Json, true, (100, 50, 40)),
            run(Variant::Cbor, true, (100, 50, 30)),
        ];
        let table = payload_table(&runs);
        assert!(table.contains("| `json` | 40 |"), "{table}");
        assert!(table.contains("| `cbor` | 30 | +10 vs CBOR |"), "{table}");
    }

    #[test]
    fn the_sweep_table_shows_the_fixed_differences() {
        let sweep = vec![
            SweepRow {
                kind: PayloadKind::Repeated,
                note_bytes: 16,
                runs: vec![
                    run(Variant::Json, true, (0, 0, 149)),
                    run(Variant::Cbor, true, (0, 0, 133)),
                    run(Variant::Cose, false, (0, 0, 245)),
                ],
            },
            SweepRow {
                kind: PayloadKind::Repeated,
                note_bytes: 4096,
                runs: vec![
                    run(Variant::Json, true, (0, 0, 4229)),
                    run(Variant::Cbor, true, (0, 0, 4215)),
                    run(Variant::Cose, false, (0, 0, 4328)),
                ],
            },
        ];
        let table = sweep_table(&sweep);
        assert!(
            table.contains("| 16 | 149 | 133 | +16 | 245 | +112 |"),
            "{table}"
        );
        assert!(
            table.contains("| 4096 | 4229 | 4215 | +14 | 4328 | +113 |"),
            "{table}"
        );
    }
}
