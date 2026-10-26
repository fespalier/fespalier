# Diagnostics: the app's configuration (`config/`, since 0.24.0)

As of 0.24.0 (`cli/src/app_config.rs` for `config/app.yaml`, its profiles, `AppConfig`, `--profile` and the variables of the
tasks; `cli/src/secrets.rs` for what looks like a credential). Messages are quoted as `fsp` prints them, with `{name}` for the
part that changes: a key in dotted form (`api.base_url`), a file (`config/app.staging.yaml`), a profile name. The user
documentation is [App configuration and profiles](https://github.com/fespalier/fespalier/blob/main/docs/app-config.md); the
usage is in `fespalier`, `references/app-config.md`.

Errors in `config/` are diagnostics on the `config/...` file, with a code frame when the key is in block style (`✗
config/app.yaml:2  message`; a flow map's key has no frame). **An error stops the pass and leaves every output as it was**
(`1 error(s); lib/app.g.dart and lib/app.config.g.dart left unchanged`, since the configuration is one of the outputs);
a warning does not stop it. `fsp check --json` gives the file, line and column.

## The files of `config/`

| Message                                                                                                                       | Cause and fix                                                                                                                              |
| ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| ``fsp reads `.yaml` files in config/: rename {rel} to {DIR}/{fixed}``                                                         | A `config/app.yml` or `config/app.<name>.yml`. The `.yml` form is not read: rename it to `.yaml`.                                          |
| `` `default` is the name of config/app.yaml alone, not of a profile: rename {rel} ``                                          | A `config/app.default.yaml`. `default` is the name of `config/app.yaml` itself, so give the file another name.                             |
| `` `{p}` is a Flutter build mode (`flutter run --{p}`), not a profile: rename {rel} ``                                        | A file named after `debug`, `profile` or `release`. Flutter's build modes are not profiles: rename the file.                               |
| `` `{p}` is not a profile name: use letters, digits, `_` and `-`, starting with a letter (config/app.<profile>.yaml) ``       | A profile name with a dot, a space or a digit first. Use letters, digits, `_` and `-`, starting with a letter.                             |
| ``the profiles `{other}` and `{p}` differ only in case, which a file system on macOS or Windows cannot hold: rename one``     | Two profiles that differ only in case, such as `Staging` and `staging`. Rename one.                                                        |
| `{DIR}/app.{first}.yaml is a profile of config/app.yaml, which is missing: a profile changes values that config/app.yaml has` | A profile without `config/app.yaml`. Write `config/app.yaml` (every value of every build), or remove the profile.                          |
| `{output} was generated from config/app.yaml, which is gone: delete {output}, or put config/app.yaml back` (a **warning**)    | `config/app.yaml` was deleted, and `lib/app.config.g.dart` is left over. `fsp` never deletes it: delete it yourself, or put the file back. |
| `cannot read {rel}: {error}`                                                                                                  | The file cannot be read (a permission, a folder where a file was expected).                                                                |
| `{rel} is not YAML that fsp can read: {message}`                                                                              | The YAML does not parse. The code frame points at the place the parser stopped; fix the syntax there.                                      |
| ``config/app.yaml has no values: write `key: value` lines, which `fsp gen` turns into the constants of AppConfig``            | `config/app.yaml` is empty, or holds only `null`. Write the values.                                                                        |
| ``config/app.yaml must be a map of keys to values (`api_url: https://...`)``                                                  | `config/app.yaml` is a list or a single value at the top. Its top level is a map of keys.                                                  |
| `{rel} must be a map of the keys of config/app.yaml it changes`                                                               | A profile file is a list or a value at the top. A profile is a map of the keys it changes.                                                 |

## The keys and the names

| Message                                                                                                        | Cause and fix                                                                                                                                                                                                             |
| -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `` `{key}` would be the constant AppConfig.{name}, and `{name}` is a reserved word in Dart: rename the key ``  | The key becomes a Dart reserved word (`default`, `class`, `new`, `null` and so on). Rename the key; the constant is its lowerCamelCase name.                                                                              |
| `` `{key}` would be the constant AppConfig.profile, which is the name of the active profile: rename the key `` | A key named `profile`. `AppConfig.profile` is the active profile, so rename the key.                                                                                                                                      |
| `` `{key}` and `{other}` would both be the constant AppConfig.{name}: rename one ``                            | Two keys make one name: `redirect-uri` and `redirectUri` are both `redirectUri`. Rename one.                                                                                                                              |
| `` `{key}` and `{other}` would both be the variable {VAR} of the task's commands: rename one ``                | Two keys make one `FSP_CONFIG_*` variable, such as `apiURL` and `api_url`. Rename one.                                                                                                                                    |
| `` `{key}` is not a key fsp can name: a key is letters, digits, `_` and `-`, starting with a letter ``         | A key with another character, or one that starts with a digit or `_`. A key of a map that is not a string gets the message `` `{shown}` in `{map}` is not a key fsp can name: ... `` (the same text, with the map named). |
| `` `{shown}` is not a key fsp can name: a key is letters, digits, `_` and `-`, starting with a letter ``       | A key that is not a string: a number, a `true` or a `null` as a key. Quote it, or make it a name.                                                                                                                         |
| `` `{key}` is an empty map: give it keys, or remove it ``                                                      | A map with no keys. Give it keys, or remove it.                                                                                                                                                                           |

## The values

| Message                                                                                                                    | Cause and fix                                                                                                                                                                             |
| -------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `` `{key}` is not in config/app.yaml: a profile only changes values that config/app.yaml has (a typo?) ``                  | A profile sets a key that `config/app.yaml` does not have. Check the spelling, or add the key to `config/app.yaml` first.                                                                 |
| `` `{key}` is a map in config/app.yaml: {rel} can change the values in it, not replace it ``                               | A profile sets a map key to a value. A profile changes the keys inside a map; it cannot replace the map.                                                                                  |
| `` `{key}` is a value in config/app.yaml, not a map ``                                                                     | A profile gives a key a map of its own, where `config/app.yaml` has a value. Make the profile's value a value, or make the key a map in `config/app.yaml`.                                |
| `` `{key}` is {n}, more than an int holds exactly on the web (2^53): write it as a string ``                               | An integer beyond 2^53, which the web cannot hold exactly. Write it as a string.                                                                                                          |
| `` `{key}` is {n}, which is not a finite number ``                                                                         | `.nan`, `.inf` or `-.inf`. Write a number, or a string.                                                                                                                                   |
| `` `{key}` is a list of {kinds}: a list holds strings, numbers or booleans ``                                              | A list with a map, a list, or a null in it (`{kinds}` is `maps`, `lists` or `nulls`). Flatten it, or write the list of values.                                                            |
| `` `{key}` has the tag `{tag}`, which fsp does not read: write the value alone ``                                          | A YAML tag such as `!!str` or `!env`. Write the value without the tag.                                                                                                                    |
| `` `{key}` holds {a} and {b}: a list holds one type ``                                                                     | A list with a string and a number, for instance. A list holds one type of value.                                                                                                          |
| `` `{key}` is {have} in {typed_in} and {ty} in {rel}: a key has one type in every file ``                                  | The same key has two types in two files, such as a string in `config/app.yaml` and a boolean in a profile. Make the values one type. An integer and a double make a double (write `1.0`). |
| `` `{key}` is null in config/app.yaml and in every profile, so fsp cannot tell its type: give it a value in one of them `` | A key that is `null` everywhere, so its type is unknown. Give it a value in one of the files.                                                                                             |
| `` `{key}` is an empty list in every file, so fsp cannot tell what it holds: give it a value in one of them ``             | An empty list everywhere, so its item type is unknown. Give it an item in one of the files.                                                                                               |

## Secrets

Every value of `config/` is compiled into the app, so a credential there is an error, and a name that sounds like a secret is a
warning. The error names the key and the file, never the value:

| Message                                                                                                                                                                                                                                                                         | Cause and fix                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `` `{key}` in {rel} looks like {what}: every value in config/ is compiled into the app, where anyone who has the app can read it; keep the secret on a server and give the app only what it may show (docs/app-config.md, "Secrets") ``                                         | The value has the shape of a credential. `{what}` is one of: a private key, a URL with a password in it, an AWS access key, a SendGrid API key, a Supabase service_role key, or a token of a named service (a GitHub, GitLab, Slack, Stripe, OpenAI, Anthropic or Google client secret, a Tolgee key or token, a Sentry auth token, an npm, Shopify or Supabase secret key, or a Mapbox secret token). Take the value out of `config/`, and let your server hold it. Public keys pass (a Stripe publishable key, a Sentry DSN, a Supabase anon key). |
| `` `{key}` in {rel} is named like a secret: every value in config/ is compiled into the app, where anyone who has the app can read it; if it is a secret, keep it on a server (docs/app-config.md, "Secrets"), and if it is not, give it a name that says so `` (a **warning**) | A non-empty value under a key named `secret`, `password`, `passwd`, `passphrase`, `private key`, or `access`, `refresh`, `auth` or `bearer` `token`, in any spelling. If it is a secret, move it to a server; if it is not, rename the key so that the name says so.                                                                                                                                                                                                                                                                                 |
| `` `{key}` in {rel} is a JWT: every value in config/ is compiled into the app, where anyone who has the app can read it; if the token grants access, keep it on a server (docs/app-config.md, "Secrets") `` (a **warning**)                                                     | A JWT that is not a Supabase `anon` key. A token that grants access stays on a server.                                                                                                                                                                                                                                                                                                                                                                                                                                                               |

Secrets with no telling shape under an innocent name, split or encoded values, and values passed with `--dart-define` by hand are
not caught: the check reads shapes and names, not meaning.

## The command line: `--profile` and `FSP_PROFILE`

These come from `fsp dev`, `fsp build` and `fsp run`, before anything runs. `{how}` is `--profile {name}` or
`--dart-define=FSP_PROFILE={name}` (a define after `--`).

| Message                                                                                                                         | Cause and fix                                                                                                                                  |
| ------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `` `{how}`: this app has no config/app.yaml, so it has no profiles (docs/app-config.md) ``                                      | The app has no `config/app.yaml`, so no profile can be named. Create `config/app.yaml`, or drop the flag.                                      |
| `` `{how}` names a profile of config/, and `{name}` is a Flutter build mode: pass that to flutter after `--` (`-- --{name}`) `` | `--profile release` (or `debug`, `profile`): Flutter's mode, not a profile. Put it after `--`: `fsp build web -- --release`.                   |
| `` `{how}`: there is no config/app.{name}.yaml; the profiles are {list} ``                                                      | The name is not a profile. `{list}` is `default` and the profiles that exist: name one of them, or create the file.                            |
| `` `--profile {a}` and `--dart-define=FSP_PROFILE={b}` after `--` both name the profile: keep one ``                            | Both were given. Keep one of them.                                                                                                             |
| `profile {name} ({why}): config/app.{name}.yaml over config/app.yaml` (printed, not an error)                                   | The profile the build will have, and why: `FSP_PROFILE`, `the flavour` or `a debug build`. `profile default: config/app.yaml` for the default. |
| `hot restart: lib/app.config.g.dart changed` (printed by `fsp dev`, `[fsp]` in front in plain output)                           | A file of `config/` changed, and the app restarts for its values. Not an error.                                                                |

A build whose `FSP_PROFILE` names no profile of `config/` (a `flutter build` or `flutter run` by hand, or a define `fsp` did not
check) stops in the compiler, not in `fsp`:

```text
lib/app.config.g.dart:<line>:7: Error: Constant evaluation error
```

The error is on `_fspProfileNamesNoFileOfConfig`, the constant that divides by zero for an unknown profile. Name a profile of
`config/`, or `default`. `AppConfig.profile` names the profile a build has, which helps when a build looks wrong without an error.

## The generated file beside `output`

`lib/app.config.g.dart` is claimed by a `lib/app.config.dart`, the way `lib/app.g.dart` is claimed by `lib/app.dart`. The warning
is the one of `diagnostics-config-and-meta.md` for `lib/app.g.dart`, with the file named:

```text
`build_runner` can delete `lib/app.config.g.dart`: `lib/app.config.dart` exists, so the builders that write `.g.dart` files ...
```

Set `fespalier: output:` to another file (which moves the configuration's file too), or rename `lib/app.config.dart`.
