# App configuration and profiles

Your app's own values, such as an API's address or a feature that is on in staging but not in production, are typed constants of one class, `AppConfig`, generated from `config/`: one file of values for every build, and one file per profile that changes some of them. There is no package to add and no `fespalier:` key to write, and the feature is on when `config/app.yaml` exists (since 0.24.0). Every value is compiled into the app, so every value is public: [secrets](#secrets) never go here.

## config/app.yaml and AppConfig

`config/app.yaml` is the app's values, in YAML, with the comment above a key becoming the doc comment of its constant. This is the shop example of fespalier's tests:

```yaml
# The app's name, on the splash.
app_name: Shop
api:
  # The API every call goes to.
  #
  # No trailing slash.
  base_url: https://api.example.com
  timeout_ms: 8000
  retry_ratio: 1
sentry_dsn: null
new_checkout: false
hosts: [api.example.com]
```

`fsp` generates `lib/app.config.g.dart` from it, and what the app reads is a class of constants (abbreviated here):

```dart
abstract final class AppConfig {
  static const String profile = _profile;

  /// The app's name, on the splash.
  ///
  /// `app_name` in config/app.yaml.
  static const String appName = 'Shop';

  /// The API every call goes to.
  ///
  /// No trailing slash.
  ///
  /// `api.base_url` in config/app.yaml; set by `dev` and `staging`.
  static const String apiBaseUrl = _profile == 'dev'
      ? 'http://localhost:8080'
      : _profile == 'staging'
      ? 'https://staging.example.com'
      : 'https://api.example.com';

  /// `api.timeout_ms` in config/app.yaml.
  static const int apiTimeoutMs = 8000;
}
```

The file goes beside `output`, as the generated `main()` does: `lib/app.g.dart` gives `lib/app.config.g.dart`, and `output: lib/router/routes.g.dart` gives `lib/router/routes.config.g.dart`. Commit it, as you commit `app.g.dart`. `fsp gen`, `fsp watch` and `fsp dev` write it, and `fsp check` checks the files of `config/` without writing anything. Import it as `package:<your app>/app.config.g.dart`. `AppConfig` is a fixed name, so an app that has a class of its own called `AppConfig` imports the generated file with a prefix (`import 'package:demo/app.config.g.dart' as generated;`, then `generated.AppConfig.apiBaseUrl`; since 0.24.0). A `lib/app.config.dart` beside it would be claimed by `build_runner`'s `.g.dart` builders, which would delete the file: `fsp` warns about that case. Moving `output` moves this file too, and the file at the old place stays: an import of it keeps compiling with the values it had, so `fsp` warns about a file that starts with its header at `lib/app.config.g.dart` when `output` puts the configuration elsewhere (since 0.24.0), and you delete it.

**An error in `config/` does not stop the routes** (since 0.24.0). `lib/app.g.dart` does not depend on `config/`, so `fsp gen`, `fsp watch` and `fsp dev` write the route outputs and leave only `lib/app.config.g.dart` as it was, then fail with a line that says so, and `fsp` exits 1:

```text
1 error(s) in config/; lib/app.config.g.dart left unchanged; lib/app.g.dart is up to date
```

In `fsp dev` a new route reloads while the error stays on screen, and fixing the file writes the configuration, which restarts the app when the values of the profile it runs changed ([Profiles](#profiles)). `fsp check` writes nothing and ends with `1 error(s) in config/`. `fsp build` generates first and stops on it (exit 1) before it runs anything, since a build with a configuration that is out of date would compile the old values. An error in the routes themselves still stops every output, the configuration included: `N error(s); lib/app.g.dart and lib/app.config.g.dart left unchanged`.

**Names.** Each value is a `static const` of `AppConfig` in lowerCamelCase. `fsp` reads each key in words, as it does for the [variables of the task's commands](#tasks-and-the-configuration) (since 0.24.0), so the spelling of the key does not matter: `redirect-uri`, `redirect_uri`, `redirectUri` and `REDIRECT_URI` are all `redirectUri`, and `API_URL` is `apiUrl`, so a key written like a `--dart-define` name is fine. A map is a group, and its keys add to the name, so `api.base_url` is `apiBaseUrl`. A key is letters, digits, `_` and `-`, starting with a letter. These are errors:

- a Dart reserved word, and the name `profile` (which is `AppConfig.profile`, the active profile);
- `int`, `double` and `bool`, which the generated class writes as types in its own declarations, so a constant of that name would hide them from every other constant (since 0.24.0);
- `hashCode`, `runtimeType`, `toString` and `noSuchMethod`, which every Dart object has, so a static member of that name conflicts with them (since 0.24.0);
- two keys that make one constant. A group's name is only the start of a longer one: `api.int` is `apiInt`.

Flat constants, rather than nested objects, are on purpose: a field of a `const` object is not a constant expression, so `AppConfig.api.timeoutMs` could not be the default of a `const` widget or flag.

**Types.** The type of a key is the same in every file that sets it:

| In the YAML      | In Dart                     | Notes                                                                               |
| ---------------- | --------------------------- | ----------------------------------------------------------------------------------- |
| `"text"`, `text` | `String`                    |                                                                                     |
| `true`, `false`  | `bool`                      |                                                                                     |
| `8000`           | `int`                       | Up to 2^53: an int beyond that is not exact on the web, so write it as a string.    |
| `0.5`            | `double`                    | An int and a double of one key make a `double`, so `1` is written `1.0`.            |
| `[a, b]`         | `List<String>` and so on    | A list holds one type. A map, a nested list, a null or a tag inside it is an error. |
| `null`           | nullable, such as `String?` | The type comes from another file, and null everywhere is an error.                  |
| `[]`             | a list                      | It takes its item type from another file, and an empty list everywhere is an error. |

A `NaN` or an infinity is an error, and so is a string with a NUL character: every value is also a variable of [the task's commands](#tasks-and-the-configuration), and a command's environment cannot hold one (since 0.24.0). A YAML tag of your own (`!env`, `!Ref`) is an error. YAML's own `!!str`, `!!int`, `!!float` and `!!bool` are read as YAML says (`!!str 123` is the string `123`), and any other `!!` tag, `!!binary` for one, is dropped by the parser: the text after it is the value, and is not decoded (since 0.24.0). YAML 1.2 reads `yes`, `no`, `on` and `off` as strings and `1.10` as the number 1.1, so write what you mean as text.

Every value is a constant, so `const` contexts work with it, and so does `if (AppConfig.newCheckout)`: the compiler can leave out the code behind a value that is off in a release build.

## Profiles

A profile is `config/app.<profile>.yaml`, and it changes values that `config/app.yaml` has. In the shop example, `config/app.dev.yaml` is:

```yaml
api:
  base_url: http://localhost:8080
  retry_ratio: 0.5
new_checkout: true
hosts: [localhost, 10.0.2.2]
```

and `config/app.staging.yaml` is:

```yaml
api:
  base_url: https://staging.example.com
sentry_dsn: https://abc@o1.ingest.sentry.io/2
```

The rules:

- A profile **only changes values that `config/app.yaml` has**. A key it does not have is an error, so a typo cannot silently add a value:

  ```text
  `api.base_ur` is not in config/app.yaml: a profile only changes values that config/app.yaml has (a typo?)
  ```

- A map is merged key by key. A list is replaced as a whole.
- **Every profile file is in the committed output** (since 0.24.0): `lib/app.config.g.dart` holds the values of every `config/app.*.yaml`, and you commit it. So never git-ignore a profile: a `config/app.local.yaml` with a LAN address in it would reach git through the generated file, and CI's regeneration would differ from your commit. A value that must stay out of the repository is the app's own `String.fromEnvironment`.
- An empty profile file is a profile that changes nothing, which is useful for a flavour's name.
- A profile name is letters, digits, `_` and `-`, starting with a letter, and camelCase is allowed. `default` (the name of `config/app.yaml` alone) and the Flutter build modes `debug`, `profile` and `release` are not profile names, and two names that differ only in case are an error. With a `config/app.yaml`, a file named `app.yml` or `app.<name>.yml` is an error: rename it to `.yaml`.
- Without a `config/app.yaml` the feature is off (since 0.24.0), and `fsp` reads nothing in `config/`. A `config/app.yml`, a `config/app.<name>.yml` or a `config/app.<name>.yaml` there, which may be another tool's, gets one warning line for each file and no more: `config/app.dev.yaml is ignored: fsp reads only config/app.yaml and the config/app.<profile>.yaml beside it, and config/app.yaml is not there`. Every other file of `config/` is not mentioned.

**How a build picks its profile.** The generated file decides in this order:

1. `--dart-define=FSP_PROFILE=<name>`, which is what `fsp dev --profile` and `fsp build --profile` pass. An empty value means `default`.
2. Else the flavour: `--flavor`, or `default-flavor:` under `flutter:` in `pubspec.yaml`, when a profile has that name.
3. Else `dev` in a debug build, when there is a `config/app.dev.yaml`.
4. Else `default`, which is `config/app.yaml` alone.

So a release build with no flag gets `config/app.yaml`, which is why the production values belong there, and an editor's `flutter run` or `flutter test` gets `dev`. A flavour's build needs no second flag.

A `FSP_PROFILE` that names no profile stops the build. The generated file has a constant division by zero for that case, so the compiler reports `Constant evaluation error` at `_fspProfileNamesNoFileOfConfig`, and nothing runs with the wrong values. `AppConfig.profile` says which profile a build has.

## Running and building with a profile

- `fsp dev --profile staging` runs the app with the values of `config/app.staging.yaml` over `config/app.yaml`, and passes `--dart-define=FSP_PROFILE=staging` to `flutter run`, in front of your arguments after `--`.
- `fsp build apk --profile prod` does the same for a build. The profile line is printed on stderr after the generation line.
- Both print which profile and why, as one line: `profile staging (FSP_PROFILE): config/app.staging.yaml over config/app.yaml`, with `(the flavour)` or `(a debug build)` in place of `(FSP_PROFILE)` when that is the reason, and `profile default: config/app.yaml` for the default. `--dry-run` prints the same line.
- A define of your own after `--`, `--dart-define=FSP_PROFILE=<name>`, names the profile too; both at once is an error.
- `fsp` reads the profile, the flavour (`--flavor`) and the build mode (`--release`, `--profile`, `--debug`) only from the arguments after `--` (since 0.24.0). A `--dart-define-from-file`, or a flutter command of your own in `tasks: dev: run:` that has a `--flavor` or a `--release`, is not read, so the profile line `fsp` prints (and the `FSP_PROFILE` and `FSP_CONFIG_*` variables of the task's commands) can differ from the profile the app compiles. `AppConfig.profile` says which one it is.
- By hand and in CI: `flutter build web --dart-define=FSP_PROFILE=prod`. In VS Code, a launch configuration in `.vscode/launch.json` can pass the same define with `"toolArgs": ["--dart-define=FSP_PROFILE=staging"]`.
- `--profile release` is refused, because it names a Flutter build mode and not a profile. The message is:

  ```text
  `--profile release` names a profile of config/, and `release` is a Flutter build mode: pass that to flutter after `--` (`-- --release`)
  ```

  Flutter's mode goes after `--`.

- `fsp dev` hot restarts the app when a change in `config/` changes a value of the profile the app runs, and prints `[fsp] hot restart: lib/app.config.g.dart changed` (in the full-screen view, without `[fsp]`). It restarts and does not reload, because a value read once, into a provider or a `static final`, keeps its old value through a hot reload. Such a change is an edit of the profile's own file or of a key of `config/app.yaml` that the profile does not set, a key added or removed, or a type that changed. The define and the flavour are those of the running `flutter`, so an edit restarts the same profile. A profile file added or removed restarts the app too, since it can change which profile they pick (a debug build without a `dev` profile runs `default`, and with one it runs `dev`): `fsp dev` then chooses the profile again, and prints its line when it is another.
- An edit that changes no value of the profile the app runs, only another profile's or a comment (since 0.24.1), writes `lib/app.config.g.dart` and hot reloads the app, `[fsp] hot reload: lib/app.config.g.dart changed` (0.24.0 restarted for it). The app reads the values of its own profile only (`_profile` is a constant of the build's define and flavour), and none of them changed, so the reload loses no state and leaves no old value behind. `hot_reload: false` in `tasks: dev:` turns these reloads and restarts off, as it turns the others off. A `config/` folder made while `fsp dev` runs is watched from the next save under `lib/`.

UNCHECKED on a device: `fsp build apk --profile staging` and `fsp build ipa --profile staging` run the staging values, and show `AppConfig.profile` on a screen to prove it; `flutter run --flavor staging` on Android and iOS, with a flavour set up in Gradle and Xcode, picks `config/app.staging.yaml` with no `--profile`; editing `config/app.staging.yaml` on a phone restarts the app with the new value. UNCHECKED on macOS (read in the code, never run on a Mac): an edit in `config/` may not wake `fsp watch` and `fsp dev` when `--project` is a relative path or goes through a symbolic link, since FSEvents reports a change at its real, absolute path and `fsp` compares it with the folder as it was given.

## Tasks and the configuration

`fsp dev` and `fsp build` give the commands of their `before`, `with`, `run` and `after` steps two kinds of variable (since 0.24.0): `FSP_PROFILE`, the active profile, and one `FSP_CONFIG_<PATH>` for each value of that profile. `api.base_url` is `FSP_CONFIG_API_BASE_URL`, and a list is JSON. A null is not set. The values are read when `fsp` starts, so a command that runs on is not told of a change in `config/`; the next start has the new value.

```yaml
tasks:
  dev:
    with:
      api: dart run tool/api.dart --port "$FSP_CONFIG_API_PORT" # api.port in config/app.yaml
```

`fsp run <task>` has no build and no profile, so it sets neither variable: a task that wants one calls `fsp build --profile x`, or passes the define itself. `tasks: env:` is unchanged: it is the process variables of the commands, and it is not the app's values, which are `config/`. Every spelling of a key is one variable, as it is one constant (`apiURL`, `api_url` and `API_URL` are `FSP_CONFIG_API_URL`), so two of them are the error about [names](#configappyaml-and-appconfig), not a second one. A string with a NUL character is refused for the same reason (since 0.24.0).

## Tests

`flutter test` is a debug build, so the tests run with `dev` when there is a `config/app.dev.yaml`. `flutter test --dart-define=FSP_PROFILE=staging` tests another profile. A constant cannot change from one test to the next, so a value that a test must vary is read through a provider of your own whose default is the constant (`final apiBaseUrl = Provider((ref) => AppConfig.apiBaseUrl);`), and the test overrides the provider. `fsp test` is unchanged.

## Secrets

Every value of `config/` is compiled into the app, and anyone who has the app (an APK, an IPA, a web page's JavaScript) can read it, however private the repository is. So `fsp` refuses what has the shape of a credential, warns about what has a name like one, and cannot catch everything.

**Refused** (an error, and the file is not written): a PEM private key or a PGP private key block; a URL with a password in it (`https://user:<password>@host/`); a Slack incoming-webhook URL (`hooks.slack.com/services/...`) and a Discord webhook URL (`discord.com/api/webhooks/...`), since the URL is the credential; an AWS access key id; a SendGrid API key; a Supabase `service_role` key (a JWT whose payload says so); and the prefixed tokens of GitHub, GitLab, Slack, Stripe (secret and restricted keys and webhook signing secrets, `whsec_`), OpenAI (and, since 0.24.1, its older keys: `sk-` and a token with `T3BlbkFJ` in it), Anthropic, Google OAuth client secrets, Tolgee, Sentry auth tokens, npm, Shopify, Supabase secret keys, Mapbox secret tokens, Hugging Face (`hf_`) and DigitalOcean (`dop_v1_`), each with the least number of characters a real token has (the PGP block, the webhook URLs, `whsec_`, `hf_` and `dop_v1_` since 0.24.0). The message is the same for each:

```text
`stripe.key` in config/app.yaml looks like a Stripe secret key: every value in config/ is compiled into the app, where anyone who has the app can read it; keep the secret on a server and give the app only what it may show (docs/app-config.md, "Secrets")
```

Public keys pass on purpose: a Stripe publishable key, a Mapbox public token, a Google API key, a Supabase publishable key or `anon` JWT, and a Sentry DSN.

**Warned about** (the file is written, and `fsp` prints the warning): a non-empty string under a key named like a secret (`secret`, `password`, `passwd`, `passphrase`, `private key`, `access token`, `refresh token`, `auth token` or `bearer token`, in any spelling of the key), and any other JWT. A key whose last word is `url`, `uri`, `path`, `endpoint` or `link` (`password_reset_url`, `private_key_path`, `token_endpoint`) names where something is and not the secret, so its name gets no warning (since 0.24.0): a value with a credential's shape under such a name is refused all the same, and a JWT still gets its own warning. The warning for a name says that it is a secret or that it is not, and what to do about each:

```text
`api.password` in config/app.yaml is named like a secret: every value in config/ is compiled into the app, where anyone who has the app can read it; if it is a secret, keep it on a server (docs/app-config.md, "Secrets"), and if it is not, give it a name that says so
```

**Not caught**: a secret with no telling shape under an innocent name; a secret that is split or encoded; anything passed with `--dart-define` by hand, or read through the app's own `String.fromEnvironment`; and assets and native files. The check reads the names and shapes of the values, not what they mean.

**Where a secret goes instead:**

- On a server: a backend of yours that calls the third-party API with its key, or that signs what the app asks for, as `fespalier_image`'s `signer:` does ([Responsive images](responsive-images.md)).
- Short-lived credentials that your server gives a signed-in user ([Authentication](auth.md)).
- A key that the device makes stays in its keystore ([biometric secrets](guards.md#biometric-unlock-fespalier_biometrics)).
- Keys that only CI needs (the store upload, the signing key, Sentry's auth token for symbols) stay in CI's secret store, and are never a `--dart-define` or a file of `config/`.
- Tolgee's API key never goes into a build ([Translations](i18n-tolgee.md)).

Public keys belong here: a Stripe publishable key, a Firebase or Maps key that is restricted by app, a Sentry DSN, a Supabase anon key.

## Values that change at run time

A value of `config/` is fixed in the build. To change one while the app runs, read a feature flag: `fespalier_flags` takes a constant as its fallback, so `const BoolFlag('new_checkout', fallback: AppConfig.newCheckout)` is legal, and a `FlagSource` backed by a remote service (the recipes in [Feature flags](guards.md#feature-flags-fespalier_flags)) changes it at run time. A flag whose source is down reads its fallback, the value of `config/`.

## Flavours and profiles

A flavour is a build variant that Flutter knows (`--flavor`), and it is not a profile: `fsp` only reads its name, in step 2 of the rules above. With `--flavor staging`, a profile named `staging` is picked, and no `--profile` is needed. A flavour that no profile is named after is fine: nothing is picked, and there is no error. The flavours themselves are set up in Gradle and Xcode, and `fsp links` describes an app's identity on a device, which is a different thing: see [Flavours](cli.md#flavours).
