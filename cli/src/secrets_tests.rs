//! What looks like a secret in `config/` (`secrets.rs`, since 0.23.0): each shape it knows, the
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
        "password_min_length_hint_url",
        "public_key",
        "csrf_header",
        "private",
    ] {
        // `password_min_length_hint_url` has the word: named like one (the value decides, see
        // app_config_tests), and the rest do not.
        assert_eq!(named_like(key), key.contains("password"), "{key}");
    }
}
