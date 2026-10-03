//! The protocol `flutter run --machine` speaks on stdin and stdout (since 0.9.0), which `fsp dev`
//! drives: JSON-RPC, one message per line, each wrapped in a JSON array so a stray line of plain
//! text cannot be mistaken for one (`[{"event":"app.start","params":{...}}]`).
//!
//! Everything here is pure: [`parse_line`] turns one line of flutter's stdout into [`Msg`]s, and
//! [`restart`] and [`stop`] write the two requests `fsp dev` sends. Parsing is lenient on purpose:
//! an event it does not know is [`Event::Other`], and a field that is missing is `None`, so a
//! flutter that adds to the protocol (it has only ever added) does not break `fsp dev`.

use serde_json::{Value, json};

/// What one line of flutter's stdout is.
#[derive(Debug, Clone, PartialEq)]
pub enum Line {
    /// A JSON array of messages (usually one).
    Messages(Vec<Msg>),
    /// Anything else: show it as a log line.
    Text(String),
}

/// One message: an event flutter sends on its own, or the answer to a request of ours.
#[derive(Debug, Clone, PartialEq)]
pub enum Msg {
    Event(Event),
    Response(Response),
}

/// The answer to a request: `{"id":N,"result":{...}}` or `{"id":N,"error":"..."}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub id: u64,
    /// `Ok` carries the reply, `Err` the error text of a request that threw.
    pub outcome: Result<Reply, String>,
}

/// A reply that did not throw. `app.restart` answers `{"code":0,"message":"..."}`, and a
/// non-zero `code` is a failure; `app.stop` answers `true`, which is code 0.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reply {
    pub code: i64,
    pub message: String,
}

impl Response {
    /// Why it did not: the reply's message or the error, `None` when it worked.
    #[must_use]
    pub fn failure(&self) -> Option<String> {
        match &self.outcome {
            Ok(r) if r.code == 0 => None,
            Ok(r) if r.message.is_empty() => Some(format!("code {}", r.code)),
            Ok(r) => Some(r.message.clone()),
            Err(e) => Some(e.clone()),
        }
    }
}

/// The events of `flutter run --machine` that `fsp dev` reads.
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    /// `daemon.connected`
    Connected { version: Option<String> },
    /// `daemon.logMessage`: `level` is `error`, `warning`, `status` or `info`.
    LogMessage { level: String, message: String },
    /// `app.start`
    AppStart {
        app_id: String,
        device_id: Option<String>,
        supports_restart: bool,
        mode: Option<String>,
    },
    /// `app.debugPort`
    DebugPort {
        app_id: String,
        ws_uri: Option<String>,
    },
    /// `app.devTools`
    DevTools { uri: String },
    /// `app.started`
    Started { app_id: String },
    /// `app.log`
    Log {
        app_id: String,
        log: String,
        error: bool,
    },
    /// `app.progress`
    Progress {
        message: Option<String>,
        finished: bool,
    },
    /// `app.stop`
    Stop {
        app_id: String,
        error: Option<String>,
    },
    /// `app.webLaunchUrl`, which flutter sends without an `appId`.
    WebLaunchUrl { url: String },
    /// Any other event: the name, ignored.
    Other(String),
}

/// One line of flutter's stdout. A line that is not a JSON array of objects is [`Line::Text`];
/// objects in an array that are neither an event nor a response are skipped.
#[must_use]
pub fn parse_line(line: &str) -> Line {
    let trimmed = line.trim();
    if !trimmed.starts_with('[') {
        return Line::Text(line.to_string());
    }
    let Ok(Value::Array(items)) = serde_json::from_str::<Value>(trimmed) else {
        return Line::Text(line.to_string());
    };
    if items.is_empty() || !items.iter().all(Value::is_object) {
        return Line::Text(line.to_string());
    }
    Line::Messages(items.iter().filter_map(message).collect())
}

fn message(v: &Value) -> Option<Msg> {
    if let Some(name) = v.get("event").and_then(Value::as_str) {
        let params = v.get("params").unwrap_or(&Value::Null);
        return Some(Msg::Event(event(name, params)));
    }
    let id = v.get("id").and_then(Value::as_u64)?;
    if v.get("error").is_none() && v.get("result").is_none() {
        return None;
    }
    let outcome = if let Some(e) = v.get("error") {
        Err(e.as_str().map_or_else(|| e.to_string(), str::to_string))
    } else {
        let result = v.get("result").unwrap_or(&Value::Null);
        Ok(Reply {
            code: result.get("code").and_then(Value::as_i64).unwrap_or(0),
            message: text(result, "message").unwrap_or_default(),
        })
    };
    Some(Msg::Response(Response { id, outcome }))
}

fn text(params: &Value, key: &str) -> Option<String> {
    params.get(key).and_then(Value::as_str).map(str::to_string)
}

fn event(name: &str, p: &Value) -> Event {
    let app_id = || text(p, "appId").unwrap_or_default();
    match name {
        "daemon.connected" => Event::Connected {
            version: text(p, "version"),
        },
        "daemon.logMessage" => Event::LogMessage {
            level: text(p, "level").unwrap_or_default(),
            message: text(p, "message").unwrap_or_default(),
        },
        "app.start" => Event::AppStart {
            app_id: app_id(),
            device_id: text(p, "deviceId"),
            supports_restart: p
                .get("supportsRestart")
                .and_then(Value::as_bool)
                .unwrap_or(true),
            mode: text(p, "mode"),
        },
        "app.debugPort" => Event::DebugPort {
            app_id: app_id(),
            ws_uri: text(p, "wsUri"),
        },
        "app.devTools" => match text(p, "uri") {
            Some(uri) => Event::DevTools { uri },
            None => Event::Other(name.to_string()),
        },
        "app.started" => Event::Started { app_id: app_id() },
        "app.log" => Event::Log {
            app_id: app_id(),
            log: text(p, "log").unwrap_or_default(),
            error: p.get("error").and_then(Value::as_bool).unwrap_or(false),
        },
        "app.progress" => Event::Progress {
            message: text(p, "message"),
            finished: p.get("finished").and_then(Value::as_bool).unwrap_or(false),
        },
        "app.stop" => Event::Stop {
            app_id: app_id(),
            error: text(p, "error"),
        },
        "app.webLaunchUrl" => match text(p, "url") {
            Some(url) => Event::WebLaunchUrl { url },
            None => Event::Other(name.to_string()),
        },
        other => Event::Other(other.to_string()),
    }
}

/// `app.restart`: a hot restart when `full`, a hot reload when not. `debounce` lets flutter merge
/// requests that arrive within 50 ms of each other.
#[must_use]
pub fn restart(id: u64, app_id: &str, full: bool, reason: &str, debounce: bool) -> String {
    let mut params = json!({
        "appId": app_id,
        "fullRestart": full,
        "reason": reason,
    });
    if debounce {
        params["debounce"] = json!(true);
    }
    request(id, "app.restart", &params)
}

/// `app.stop`: stops the app and then flutter itself.
#[must_use]
pub fn stop(id: u64, app_id: &str) -> String {
    request(id, "app.stop", &json!({ "appId": app_id }))
}

fn request(id: u64, method: &str, params: &Value) -> String {
    json!([{ "id": id, "method": method, "params": params }]).to_string()
}
