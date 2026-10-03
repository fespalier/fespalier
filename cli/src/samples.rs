//! The sample values of dynamic folders, shared by `fsp maestro` (`fespalier.maestro.samples`)
//! and `fsp test` (`fespalier.test.samples`, or else the Maestro ones): a route like
//! `products/$id` has no URL of its own until something says which `id` to open.
//!
//! Each function takes the full config key (`fespalier.maestro.samples`), so a message names the
//! section the mistake is in.

use std::collections::{BTreeMap, HashMap};

use anyhow::{Result, bail};
use serde_yaml_ng::Value;

use crate::config::Config;
use crate::links::url_segment;
use crate::resolve::{App, Route};
use crate::scan::Seg;

/// What a dynamic folder's sample is, as text: one segment, or the parts of a catch-all.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SampleValue {
    One(String),
    Many(Vec<String>),
}

/// A sample as text: a string, a number or a boolean.
fn sample_text(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        Value::Bool(b) => Some(b.to_string()),
        _ => None,
    }
}

/// The samples as the pubspec has them, checked for their shape: each value is a text, a number,
/// a boolean or a list of them. `key` is the full key, for the message.
pub fn parse(
    key: &str,
    raw: Option<&BTreeMap<String, Value>>,
) -> Result<Vec<(String, SampleValue)>> {
    let mut samples = vec![];
    for (folder, value) in raw.into_iter().flatten() {
        let sample = match value {
            Value::Sequence(items) => items
                .iter()
                .map(sample_text)
                .collect::<Option<Vec<String>>>()
                .map(SampleValue::Many),
            one => sample_text(one).map(SampleValue::One),
        };
        let Some(sample) = sample else {
            bail!(
                "`{key}`: the value of `{folder}` must be a text, a number, a boolean or a list of them"
            );
        };
        samples.push((folder.clone(), sample));
    }
    Ok(samples)
}

/// The parts of a sample, for each dynamic folder (an index into `app.routes`) that has one,
/// after checking each against the folder it is for.
pub fn resolve(
    app: &App,
    cfg: &Config,
    key: &str,
    samples: &[(String, SampleValue)],
) -> Result<HashMap<usize, Vec<String>>> {
    let mut out = HashMap::new();
    for (folder_key, value) in samples {
        let k = folder_key;
        let Some(folder) = app.routes.iter().position(|f| f.dir == *k) else {
            bail!(
                "`{key}`: `{k}` is not a folder of {}; write it as `fsp routes` prints it, without `/page.dart` (`products/$id`)",
                cfg.app_dir
            );
        };
        let optional = match &app.routes[folder].seg {
            Some(Seg::Dynamic(_)) => None,
            Some(Seg::CatchAll(_, optional)) => Some(*optional),
            _ => bail!(
                "`{key}`: `{k}` is not a `$segment` folder; samples give the values of dynamic segments"
            ),
        };
        let parts: Vec<String> = match (value, optional) {
            (SampleValue::One(s), _) => vec![s.clone()],
            (SampleValue::Many(_), None) => {
                bail!("`{key}`: `{k}` is one segment; give one value, not a list")
            }
            (SampleValue::Many(parts), Some(_)) => parts.clone(),
        };
        if parts.is_empty() && optional == Some(false) {
            bail!("`{key}`: `{k}` is a catch-all that needs at least one part");
        }
        let ty = app.seg_type(folder);
        let element = ty
            .strip_prefix("List<")
            .and_then(|t| t.strip_suffix('>'))
            .unwrap_or(ty);
        for part in &parts {
            if part.is_empty() {
                bail!("`{key}`: `{k}` is empty; a segment can't be");
            }
            let fits = match element {
                "int" => part.parse::<i64>().is_ok(),
                "double" | "num" => part.parse::<f64>().is_ok_and(f64::is_finite),
                "bool" => matches!(part.as_str(), "true" | "false"),
                _ => true,
            };
            if !fits {
                bail!(
                    "`{key}`: `{k}` is a `{}` segment, and `{part}` is not one",
                    app.display_type(ty)
                );
            }
        }
        out.insert(folder, parts);
    }
    Ok(out)
}

/// The path of the route's URL with the samples filled in, percent-encoded: `/products/1`,
/// `/docs/guides/intro`. `Err` is the folder that has no sample. An optional catch-all with
/// none is left off.
pub fn link_path(
    app: &App,
    r: &Route,
    samples: &HashMap<usize, Vec<String>>,
) -> std::result::Result<String, String> {
    let mut out = String::new();
    let mut dynamic = r.segs.iter();
    for seg in &r.url {
        match seg {
            Seg::Static(s) => {
                out.push('/');
                out.push_str(&url_segment(s));
            }
            Seg::Dynamic(_) | Seg::CatchAll(..) => {
                let folder = dynamic.next().map_or(0, |(_, f)| *f);
                match (samples.get(&folder), seg) {
                    (Some(parts), _) => {
                        for p in parts {
                            out.push('/');
                            out.push_str(&url_segment(p));
                        }
                    }
                    (None, Seg::CatchAll(_, true)) => {}
                    (None, _) => return Err(app.routes[folder].dir.clone()),
                }
            }
            Seg::Group(_) => {}
        }
    }
    Ok(if out.is_empty() { "/".into() } else { out })
}
