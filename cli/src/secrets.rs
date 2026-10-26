//! What looks like a secret in `config/` (since 0.24.0). Every value of the app's configuration
//! is compiled into the app, where anyone who has the app can read it, so a credential there is a
//! leak, however private the repository is.
//!
//! [`looks_like`] knows the shape of credentials whose format says what they are (a PEM or PGP
//! private key, a URL with a password, a Slack or Discord webhook URL, the prefixed tokens of
//! well-known services, and the older `sk-` keys by the mark in their middle): those are errors, and
//! the check is meant to be precise rather than complete. [`named_like`] reads a key's name
//! (`client_secret`, `password`): a warning, since a name can be wrong both ways. Neither can
//! catch a secret with no telling shape under an innocent name; `docs/app-config.md` says so.

/// Prefixes of credentials, with the least number of token characters (`[A-Za-z0-9_-]`) that
/// follow one in a real token, and what it is. A prefix counts only at the start of the value or
/// after a character that is not a letter, a digit or `_`, so `task_xoxb-` is not a Slack token.
const PREFIXES: &[(&str, usize, &str)] = &[
    ("ghp_", 30, "a GitHub token"),
    ("gho_", 30, "a GitHub token"),
    ("ghu_", 30, "a GitHub token"),
    ("ghs_", 30, "a GitHub token"),
    ("ghr_", 30, "a GitHub token"),
    ("github_pat_", 30, "a GitHub token"),
    ("glpat-", 20, "a GitLab token"),
    ("xoxa-", 10, "a Slack token"),
    ("xoxb-", 10, "a Slack token"),
    ("xoxp-", 10, "a Slack token"),
    ("xoxr-", 10, "a Slack token"),
    ("xoxs-", 10, "a Slack token"),
    ("xapp-", 10, "a Slack token"),
    ("sk_live_", 16, "a Stripe secret key"),
    ("sk_test_", 16, "a Stripe secret key"),
    ("rk_live_", 16, "a Stripe restricted key"),
    ("rk_test_", 16, "a Stripe restricted key"),
    ("sk-proj-", 20, "an OpenAI API key"),
    ("sk-svcacct-", 20, "an OpenAI API key"),
    ("sk-admin-", 20, "an OpenAI API key"),
    ("sk-ant-", 20, "an Anthropic API key"),
    ("GOCSPX-", 20, "a Google OAuth client secret"),
    ("tgpak_", 16, "a Tolgee API key"),
    ("tgpat_", 16, "a Tolgee token"),
    ("sntrys_", 20, "a Sentry auth token"),
    ("sntryu_", 20, "a Sentry auth token"),
    ("npm_", 30, "an npm token"),
    ("shpat_", 20, "a Shopify access token"),
    ("shpca_", 20, "a Shopify access token"),
    ("shppa_", 20, "a Shopify access token"),
    ("shpss_", 20, "a Shopify shared secret"),
    ("sb_secret_", 16, "a Supabase secret key"),
    ("sk.eyJ", 20, "a Mapbox secret token"),
    ("whsec_", 32, "a Stripe webhook secret"),
    ("dop_v1_", 64, "a DigitalOcean token"),
];

/// Prefixes whose tokens are letters and digits alone, counted over those only: `hf_` is a common
/// start of an identifier (`hf_some_long_feature_name`), whose underscores end the run.
const ALNUM_PREFIXES: &[(&str, usize, &str)] = &[("hf_", 34, "a Hugging Face token")];

fn token_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_' || c == '-'
}

/// What `value` looks like when it has the shape of a credential: `"a GitHub token"`. `None`
/// for anything else, which is not to say that it is not one.
#[must_use]
pub fn looks_like(value: &str) -> Option<&'static str> {
    // PEM (`PRIVATE KEY-----`, with a kind in front) and PGP (`PRIVATE KEY BLOCK-----`).
    if value.contains("-----BEGIN ")
        && (value.contains("PRIVATE KEY-----") || value.contains("PRIVATE KEY BLOCK-----"))
    {
        return Some("a private key");
    }
    if url_with_password(value) {
        return Some("a URL with a password in it");
    }
    if slack_webhook(value) {
        return Some("a Slack webhook URL");
    }
    if discord_webhook(value) {
        return Some("a Discord webhook URL");
    }
    for (i, _) in value.char_indices() {
        let before = value[..i].chars().next_back();
        if before.is_some_and(|c| c.is_ascii_alphanumeric() || c == '_') {
            continue;
        }
        let rest = &value[i..];
        for (prefix, least, what) in PREFIXES {
            if let Some(tail) = rest.strip_prefix(prefix)
                && tail.chars().take_while(|c| token_char(*c)).count() >= *least
            {
                return Some(what);
            }
        }
        for (prefix, least, what) in ALNUM_PREFIXES {
            if let Some(tail) = rest.strip_prefix(prefix)
                && tail.chars().take_while(char::is_ascii_alphanumeric).count() >= *least
            {
                return Some(what);
            }
        }
        if openai_legacy(rest) {
            return Some("an OpenAI API key");
        }
        if aws_key(rest) {
            return Some("an AWS access key");
        }
        if sendgrid_key(rest) {
            return Some("a SendGrid API key");
        }
    }
    if jwt_role(value).as_deref() == Some("service_role") {
        return Some("a Supabase service_role key");
    }
    None
}

/// The base64 of `OpenAI`, which every older `sk-` key has between its two random halves.
const OPENAI_MARK: &str = "T3BlbkFJ";

/// An older `sk-` key (since 0.24.1): `sk-`, a token that has `T3BlbkFJ`, the base64 of `OpenAI`,
/// in it, and at least 20 token characters on each side of it. A real key is `sk-`, 20 characters,
/// the mark and 20 more, so that is the least number, as for the other prefixes.
fn openai_legacy(s: &str) -> bool {
    const SIDE: usize = 20;
    s.strip_prefix("sk-").is_some_and(|tail| {
        let end = tail.find(|c| !token_char(c)).unwrap_or(tail.len());
        let token = &tail[..end];
        token
            .match_indices(OPENAI_MARK)
            .any(|(at, _)| at >= SIDE && token.len() - at - OPENAI_MARK.len() >= SIDE)
    })
}

/// `AKIA` or `ASIA` and 16 upper-case letters or digits, and no more.
fn aws_key(s: &str) -> bool {
    let Some(tail) = s.strip_prefix("AKIA").or_else(|| s.strip_prefix("ASIA")) else {
        return false;
    };
    let run = tail
        .chars()
        .take_while(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
        .count();
    run == 16
        && !tail
            .chars()
            .nth(16)
            .is_some_and(|c| c.is_ascii_alphanumeric())
}

/// `SG.`, 22 token characters, `.`, 43 token characters.
fn sendgrid_key(s: &str) -> bool {
    let Some(tail) = s.strip_prefix("SG.") else {
        return false;
    };
    let first = tail.chars().take_while(|c| token_char(*c)).count();
    first == 22
        && tail[first..]
            .strip_prefix('.')
            .is_some_and(|rest| rest.chars().take_while(|c| token_char(*c)).count() >= 43)
}

/// How many letters and digits `s` starts with.
fn alnum_run(s: &str) -> usize {
    s.chars().take_while(char::is_ascii_alphanumeric).count()
}

/// A Slack incoming webhook, `hooks.slack.com/services/T<team>/B<hook>/<token>`: the URL is the
/// credential, since anyone who has it can post to the channel.
fn slack_webhook(value: &str) -> bool {
    const HOST: &str = "hooks.slack.com/services/";
    value.match_indices(HOST).any(|(at, _)| {
        let mut parts = value[at + HOST.len()..].splitn(3, '/');
        let (Some(team), Some(hook), Some(token)) = (parts.next(), parts.next(), parts.next())
        else {
            return false;
        };
        team.starts_with('T')
            && alnum_run(team) >= 9
            && hook.starts_with('B')
            && alnum_run(hook) >= 9
            && alnum_run(token) >= 24
    })
}

/// A Discord webhook, `discord.com/api/webhooks/<id>/<token>` (with `discordapp.com` or an API
/// version, `/api/v10/webhooks/`, as well): the URL is the credential.
fn discord_webhook(value: &str) -> bool {
    ["discord.com/api/", "discordapp.com/api/"]
        .iter()
        .flat_map(|host| {
            value
                .match_indices(host)
                .map(move |(at, _)| at + host.len())
        })
        .any(|from| {
            let mut rest = &value[from..];
            if let Some(versioned) = rest.strip_prefix('v') {
                let digits = versioned.chars().take_while(char::is_ascii_digit).count();
                if let Some(after) = versioned[digits..].strip_prefix('/')
                    && digits > 0
                {
                    rest = after;
                }
            }
            let Some(rest) = rest.strip_prefix("webhooks/") else {
                return false;
            };
            let id = rest.chars().take_while(char::is_ascii_digit).count();
            id >= 17
                && rest[id..]
                    .strip_prefix('/')
                    .is_some_and(|token| token.chars().take_while(|c| token_char(*c)).count() >= 60)
        })
}

/// A URL whose authority has a user and a non-empty password: `https://user:pass@host/`.
fn url_with_password(value: &str) -> bool {
    let mut rest = value;
    while let Some(at) = rest.find("://") {
        let after = &rest[at + 3..];
        let end = after.find(['/', '?', '#', ' ']).unwrap_or(after.len());
        let authority = &after[..end];
        if let Some((userinfo, _host)) = authority.rsplit_once('@')
            && let Some((_, password)) = userinfo.split_once(':')
            && !password.is_empty()
        {
            return true;
        }
        rest = after;
    }
    false
}

/// The `role` claim of a JWT (`eyJ...`), decoded without checking anything: Supabase's legacy
/// keys are JWTs, `anon` (public by design) or `service_role` (a secret).
fn jwt_role(value: &str) -> Option<String> {
    let mut parts = value.trim().split('.');
    let (header, payload, _sig) = (parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() || !header.starts_with("eyJ") || !payload.starts_with("eyJ") {
        return None;
    }
    let bytes = base64url(payload)?;
    let claims: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    claims.get("role")?.as_str().map(str::to_string)
}

/// Whether `value` is a JWT at all (three dot-separated parts whose first two decode as JSON
/// objects), for the warning about a token in the configuration.
#[must_use]
pub fn is_jwt(value: &str) -> bool {
    let mut parts = value.trim().split('.');
    let (Some(header), Some(payload), Some(_), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return false;
    };
    header.starts_with("eyJ")
        && payload.starts_with("eyJ")
        && base64url(payload)
            .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
            .is_some_and(|v| v.is_object())
}

/// The role of a JWT that Supabase ships as its public key (`anon`), which needs no warning.
#[must_use]
pub fn is_public_jwt(value: &str) -> bool {
    jwt_role(value).as_deref() == Some("anon")
}

/// Base64url without padding (a JWT's parts), or `None` when it is not.
fn base64url(s: &str) -> Option<Vec<u8>> {
    let mut bits = 0u32;
    let mut n = 0;
    let mut out = vec![];
    for c in s.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'-' | b'+' => 62,
            b'_' | b'/' => 63,
            b'=' => break,
            _ => return None,
        };
        bits = (bits << 6) | u32::from(v);
        n += 6;
        if n >= 8 {
            n -= 8;
            out.push(u8::try_from((bits >> n) & 0xff).ok()?);
        }
    }
    Some(out)
}

/// Whether a key's name says that its value is a secret: `client_secret`, `password`,
/// `privateKey`, `refresh-token`. The words are read in any of the spellings a key can have. A key
/// whose last word is `url`, `uri`, `path`, `endpoint` or `link` names where something is and not
/// the thing (`password_reset_url`, `private_key_path`, `token_endpoint`), so it does not say that
/// its value is a secret: a value that is one is refused by its shape ([`looks_like`]) all the same.
#[must_use]
pub fn named_like(key: &str) -> bool {
    let words = words(key);
    if words
        .last()
        .is_some_and(|w| matches!(w.as_str(), "url" | "uri" | "path" | "endpoint" | "link"))
    {
        return false;
    }
    let has = |w: &str| words.iter().any(|x| x == w);
    let pair = |a: &str, b: &str| words.windows(2).any(|p| p[0] == a && p[1] == b);
    has("secret")
        || has("password")
        || has("passwd")
        || has("passphrase")
        || pair("private", "key")
        || pair("access", "token")
        || pair("refresh", "token")
        || pair("auth", "token")
        || pair("bearer", "token")
}

/// The lower-case words of a key: `apiBaseURL` and `api_base_url` are `api`, `base`, `url`.
fn words(key: &str) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    let mut word = String::new();
    let mut last: Option<char> = None;
    for c in key.chars() {
        let starts = c.is_ascii_uppercase() && last.is_some_and(|l| l.is_ascii_lowercase());
        if (c == '_' || c == '-' || c == '.' || starts) && !word.is_empty() {
            out.push(std::mem::take(&mut word));
        }
        if c != '_' && c != '-' && c != '.' {
            word.push(c.to_ascii_lowercase());
        }
        last = Some(c);
    }
    if !word.is_empty() {
        out.push(word);
    }
    out
}
