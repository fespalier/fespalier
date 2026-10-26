//! What looks like a secret in `config/` (`secrets.rs`, since 0.24.0): each shape it knows, the
//! near misses it must let through, and the names it warns about.

use crate::secrets::{is_jwt, is_public_jwt, looks_like, named_like};

/// A token of `n` characters made of letters and digits.
fn tail(n: usize) -> String {
    "aB3dE5gH7jK9mN1pQ2rS4tU6vW8xY0z"
        .chars()
        .cycle()
        .take(n)
        .collect()
}

#[test]
fn each_prefix_is_its_credential() {
    let cases = [
        ("ghp_", 36, "a GitHub token"),
        ("github_pat_", 40, "a GitHub token"),
        ("glpat-", 20, "a GitLab token"),
        ("xoxb-", 24, "a Slack token"),
        ("sk_live_", 24, "a Stripe secret key"),
        ("sk_test_", 24, "a Stripe secret key"),
        ("rk_live_", 24, "a Stripe restricted key"),
        ("sk-proj-", 40, "an OpenAI API key"),
        ("sk-ant-", 40, "an Anthropic API key"),
        ("GOCSPX-", 28, "a Google OAuth client secret"),
        ("tgpak_", 30, "a Tolgee API key"),
        ("sntrys_", 40, "a Sentry auth token"),
        ("npm_", 36, "an npm token"),
        ("shpat_", 32, "a Shopify access token"),
        ("sb_secret_", 30, "a Supabase secret key"),
        ("sk.eyJ", 40, "a Mapbox secret token"),
        ("whsec_", 40, "a Stripe webhook secret"),
        ("hf_", 34, "a Hugging Face token"),
        ("dop_v1_", 64, "a DigitalOcean token"),
    ];
    for (prefix, n, what) in cases {
        let value = format!("{prefix}{}", tail(n));
        assert_eq!(looks_like(&value), Some(what), "{value}");
        // In a URL's query, after a character that is not a letter or a digit, too.
        let in_url = format!("https://api.example.com/v1?key={value}");
        assert_eq!(looks_like(&in_url), Some(what), "{in_url}");
    }
}

#[test]
fn near_misses_are_not_secrets() {
    for value in [
        // Too short to be a token.
        "ghp_short",
        "sk_live_x",
        "xoxb-1",
        // Glued to a word: not a prefix.
        &format!("task_xoxb-{}", tail(20)),
        &format!("mysk_live_{}", tail(20)),
        &format!("whsec_{}", tail(31)),
        &format!("hf_{}", tail(33)),
        &format!("dop_v1_{}", tail(63)),
        // An identifier that starts like a Hugging Face token: its underscores end the run.
        "hf_some_long_feature_flag_name_that_is_not_a_token",
        &format!("my_hf_{}", tail(40)),
        &format!("mywhsec_{}", tail(40)),
        // Public by design.
        &format!("pk_live_{}", tail(24)),
        &format!("pk.eyJ{}", tail(40)),
        &format!("AIza{}", "SyA1234567890abcdefghijklmnopqrstuv"),
        &format!("sb_publishable_{}", tail(30)),
        "https://o123.ingest.sentry.io/456",
        "https://abc@o123.ingest.sentry.io/456",
        // A locale, a slug.
        "sk-SK",
        "https://user@example.com/",
        "http://localhost:8080",
    ] {
        assert_eq!(looks_like(value), None, "{value}");
    }
}

#[test]
fn a_legacy_openai_key_is_its_credential() {
    // `sk-` and a token with `T3BlbkFJ` (the base64 of `OpenAI`) in it, since 0.24.1: built at run
    // time, so no literal has the shape of a key.
    let mark = ["T3Bl", "bkFJ"].concat();
    let key = format!("sk-{}{mark}{}", tail(20), tail(20));
    assert_eq!(looks_like(&key), Some("an OpenAI API key"), "{key}");
    let in_url = format!("https://api.example.com/v1?key={key}");
    assert_eq!(looks_like(&in_url), Some("an OpenAI API key"), "{in_url}");
    for (name, value) in [
        ("no mark", format!("sk-{}", tail(48))),
        (
            "the mark after a space",
            format!("sk-{} {mark}{}", tail(20), tail(20)),
        ),
        (
            "the mark after a dot",
            format!("sk-{}.{mark}{}", tail(20), tail(20)),
        ),
        (
            "glued to a word",
            format!("task-{}{mark}{}", tail(20), tail(20)),
        ),
        (
            "an underscore",
            format!("sk_{}{mark}{}", tail(20), tail(20)),
        ),
        (
            "the mark in lower case",
            format!("sk-{}{}{}", tail(20), mark.to_lowercase(), tail(20)),
        ),
        ("no prefix", format!("{}{mark}{}", tail(20), tail(20))),
        ("the prefix alone", "sk-".to_string()),
    ] {
        assert_eq!(looks_like(&value), None, "{name}: {value}");
    }
}

#[test]
fn a_private_key_a_password_in_a_url_and_cloud_keys_are_secrets() {
    // The key shapes are built at run time, so no literal looks like a credential to a secret scanner.
    let pem = |kind: &str| format!("-----BEGIN {kind} {}-----", "PRIVATE KEY");
    assert_eq!(
        looks_like(&format!(
            "{}\nMHcCAQEE...\n-----END EC PRIVATE KEY-----",
            pem("EC")
        )),
        Some("a private key")
    );
    assert_eq!(looks_like(&pem("OPENSSH")), Some("a private key"));
    assert_eq!(
        looks_like("postgres://app:hunter2@db.example.com:5432/app"),
        Some("a URL with a password in it")
    );
    assert_eq!(
        looks_like("https://user:@example.com/"),
        None,
        "an empty password"
    );
    let aws = format!("AKIA{}", "IOSFODNN7EXAMPLE");
    assert_eq!(looks_like(&aws), Some("an AWS access key"));
    assert_eq!(looks_like(&format!("{aws}X")), None, "17 characters");
    let sendgrid = format!("SG.{}.{}", tail(22), tail(43));
    assert_eq!(looks_like(&sendgrid), Some("a SendGrid API key"));
}

#[test]
fn a_pgp_private_key_block_is_a_private_key() {
    // Built at run time, like the PEM shapes above: no literal has the armor of a key.
    let armor = |edge: &str, kind: &str| format!("-----{edge} PGP {kind} BLOCK-----");
    let block = |kind: &str| armor("BEGIN", kind);
    let private = format!(
        "{}\nlQVYBF...\n{}",
        block("PRIVATE KEY"),
        armor("END", "PRIVATE KEY")
    );
    assert_eq!(looks_like(&private), Some("a private key"));
    assert_eq!(looks_like(&block("PRIVATE KEY")), Some("a private key"));
    // A public key block, a signature and a message are for anyone to read.
    for kind in ["PUBLIC KEY", "SIGNATURE", "MESSAGE"] {
        assert_eq!(looks_like(&block(kind)), None, "{kind}");
    }
}

#[test]
fn a_slack_or_discord_webhook_url_is_a_secret() {
    // The URL is the credential, and each is built at run time from the pieces of its shape.
    let slack = |team: &str, hook: &str, token: &str| {
        format!(
            "https://hooks.slack.com/{}/{team}/{hook}/{token}",
            "services"
        )
    };
    let team = format!("T{}", tail(10));
    let hook = format!("B{}", tail(10));
    assert_eq!(
        looks_like(&slack(&team, &hook, &tail(24))),
        Some("a Slack webhook URL")
    );
    // In a longer text, with a query.
    assert_eq!(
        looks_like(&format!("{}?x=1", slack(&team, &hook, &tail(24)))),
        Some("a Slack webhook URL")
    );
    for (name, value) in [
        ("a short token", slack(&team, &hook, &tail(12))),
        ("a short team", slack("T12", &hook, &tail(24))),
        ("a short hook", slack(&team, "B12", &tail(24))),
        ("no team letter", slack(&tail(10), &hook, &tail(24))),
        ("no hook letter", slack(&team, &tail(10), &tail(24))),
        (
            "no token",
            format!("https://hooks.slack.com/{}/{team}/{hook}", "services"),
        ),
        (
            "another host",
            slack(&team, &hook, &tail(24)).replace("hooks.slack.com", "hooks.example.com"),
        ),
        ("the host alone", "https://hooks.slack.com/".to_string()),
        (
            "a docs page",
            "https://api.slack.com/messaging/webhooks".to_string(),
        ),
    ] {
        assert_eq!(looks_like(&value), None, "{name}: {value}");
    }

    let discord = |host: &str, api: &str, id: &str, token: &str| {
        format!("https://{host}/{api}/{}/{id}/{token}", "webhooks")
    };
    let id = "1".repeat(19);
    for host in ["discord.com", "discordapp.com", "ptb.discord.com"] {
        assert_eq!(
            looks_like(&discord(host, "api", &id, &tail(68))),
            Some("a Discord webhook URL"),
            "{host}"
        );
    }
    // The API version in the path.
    assert_eq!(
        looks_like(&discord("discord.com", "api/v10", &id, &tail(68))),
        Some("a Discord webhook URL")
    );
    for (name, value) in [
        (
            "a short token",
            discord("discord.com", "api", &id, &tail(40)),
        ),
        (
            "a short id",
            discord("discord.com", "api", "12345", &tail(68)),
        ),
        (
            "no token",
            format!("https://discord.com/api/{}/{id}", "webhooks"),
        ),
        (
            "an id with letters",
            discord("discord.com", "api", &tail(19), &tail(68)),
        ),
        (
            "another host",
            discord("example.com", "api", &id, &tail(68)),
        ),
        (
            "another endpoint",
            "https://discord.com/api/users/@me".to_string(),
        ),
        ("an invite", "https://discord.gg/abcdefg".to_string()),
    ] {
        assert_eq!(looks_like(&value), None, "{name}: {value}");
    }
}

/// A JWT whose payload is `payload` (a JSON object), unsigned.
fn jwt(payload: &str) -> String {
    let b64 = |s: &str| {
        const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let bytes = s.as_bytes();
        let mut out = String::new();
        for chunk in bytes.chunks(3) {
            let n = chunk
                .iter()
                .enumerate()
                .fold(0u32, |acc, (i, b)| acc | (u32::from(*b) << (16 - 8 * i)));
            let chars = chunk.len() + 1;
            for i in 0..chars {
                out.push(A[((n >> (18 - 6 * i)) & 63) as usize] as char);
            }
        }
        out
    };
    format!(
        "{}.{}.c2lnbmF0dXJl",
        b64(r#"{"alg":"HS256","typ":"JWT"}"#),
        b64(payload)
    )
}

#[test]
fn a_supabase_service_role_key_is_a_secret_and_an_anon_key_is_not() {
    let service = jwt(r#"{"iss":"supabase","role":"service_role"}"#);
    let anon = jwt(r#"{"iss":"supabase","role":"anon"}"#);
    let other = jwt(r#"{"sub":"42"}"#);
    assert_eq!(looks_like(&service), Some("a Supabase service_role key"));
    assert_eq!(looks_like(&anon), None);
    assert!(is_jwt(&anon) && is_public_jwt(&anon));
    assert!(is_jwt(&other) && !is_public_jwt(&other));
    assert!(!is_jwt("a.b.c"));
}

#[test]
fn names_that_say_secret_in_any_spelling() {
    for key in [
        "client_secret",
        "clientSecret",
        "secret",
        "password",
        "db-password",
        "passwd",
        "passphrase",
        "private_key",
        "privateKey",
        "refresh_token",
        "accessToken",
        "auth-token",
        "bearer_token",
    ] {
        assert!(named_like(key), "{key}");
    }
    for key in [
        "api_key",
        "base_url",
        "token_header",
        "password_min_length_hint",
        "public_key",
        "csrf_header",
        "private",
    ] {
        // `password_min_length_hint` has the word: named like one (the value decides, see
        // app_config_tests), and the rest do not.
        assert_eq!(named_like(key), key.contains("password"), "{key}");
    }
}

#[test]
fn a_key_that_names_where_a_thing_is_does_not_say_it_is_a_secret() {
    // The last word is `url`, `uri`, `path`, `endpoint` or `link` (since 0.24.0): the key names
    // a place, in any spelling.
    for key in [
        "password_reset_url",
        "forgot-password-url",
        "forgotPasswordURL",
        "password_min_length_hint_url",
        "client_secret_uri",
        "privateKeyPath",
        "private_key_path",
        "token_endpoint",
        "refresh_token_endpoint",
        "secretLink",
    ] {
        assert!(!named_like(key), "{key}");
    }
    // The word has to be the last: a secret's own name stays one.
    for key in ["url_secret", "path_password", "link_access_token"] {
        assert!(named_like(key), "{key}");
    }
}
