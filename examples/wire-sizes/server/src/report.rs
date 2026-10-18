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

/// The whole report, as Markdown.
///
/// # Errors
/// When a run cannot be set up, or the scenario's own numbers cannot be measured.
pub async fn generate() -> Result<String, cratestack::CratestackError> {
    Ok(report(&measure_all(&Scenario::default()).await?))
}

/// Renders the measurement as Markdown.
///
/// Split from [`generate`] so the rendering can be tested against a `Run` built by hand, without a
/// router: the interesting failures here are arithmetic and formatting, not I/O.
#[must_use]
pub fn report(runs: &[Run]) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "{}", summary_table(runs));
    let _ = writeln!(out);
    let _ = writeln!(out, "{}", overhead_table(runs));
    let _ = writeln!(out);
    let _ = writeln!(out, "{}", per_op_table(runs));
    out
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
    // Every variant sends the same ops in the same order, so the ops come from the first run.
    let ops: Vec<String> = runs.first().map_or_else(Vec::new, |run| {
        let mut ops: Vec<String> = Vec::new();
        for exchange in &run.exchanges {
            let op = exchange.path.trim_start_matches("/rpc/").to_owned();
            if !ops.contains(&op) {
                ops.push(op);
            }
        }
        ops
    });

    let mut out = String::new();
    let _ = writeln!(out, "| Op | Call | JSON | CBOR | COSE |");
    let _ = writeln!(out, "| --- | ---: | ---: | ---: | ---: |");
    for op in &ops {
        let mut cells = Vec::new();
        for run in runs {
            let measured = run.of_op(op);
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
            calls_of(runs, op),
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
        let text = report(&runs);
        assert!(text.contains("Request bytes"));
        assert!(text.contains("External AAD"));
        assert!(text.contains("| Op | Call |"));
    }
}
