# Changelog

## [0.13.1](https://github.com/fespalier/fespalier/compare/v0.13.0...v0.13.1) (2026-10-08)


### Bug Fixes

* a refusal is never hidden behind data kept on error ([#136](https://github.com/fespalier/fespalier/issues/136)) ([80476a2](https://github.com/fespalier/fespalier/commit/80476a2b221a548ea7151c73474b5fd2698dcc4e))
* **otel:** cap dartastic_opentelemetry_api below 1.0.0-rc.4 ([#135](https://github.com/fespalier/fespalier/issues/135)) ([feb5b0f](https://github.com/fespalier/fespalier/commit/feb5b0f5c287501cc1b2a912fd121ff249383c8c))


### Documentation

* a full-stack cose example, a fespalier app and a CrateStack server signing every request with COSE_Sign1 ([#129](https://github.com/fespalier/fespalier/issues/129)) ([fdaad6b](https://github.com/fespalier/fespalier/commit/fdaad6b8a01d98ef228dee27e8e36ce0c54b860f))
* a maps example, a pin picker and an offline pack with fespalier_maps ([#126](https://github.com/fespalier/fespalier/issues/126)) ([b03d87d](https://github.com/fespalier/fespalier/commit/b03d87d34ad8d3790a86bd4f7441199087710689))
* an adopt example, a go_router app moving to fespalier ([#127](https://github.com/fespalier/fespalier/issues/127)) ([1bf244d](https://github.com/fespalier/fespalier/commit/1bf244d83979a4d73612562e7f12edd27c491143))
* an i18n example, translated routes with fespalier_tolgee ([#125](https://github.com/fespalier/fespalier/issues/125)) ([879760b](https://github.com/fespalier/fespalier/commit/879760b8019f7bcad3dacc6c8c540a74a5eee2d2))
* an offline example, reads, intents and owned rows with fespalier_cratestack ([#128](https://github.com/fespalier/fespalier/issues/128)) ([12403f9](https://github.com/fespalier/fespalier/commit/12403f99bd48d287c73e4195bb13209cdcd7fb94))
* list every example and point skills at the examples that show them ([#122](https://github.com/fespalier/fespalier/issues/122)) ([6688fa7](https://github.com/fespalier/fespalier/commit/6688fa76237602c4c7461d18a71338596217a795))
* re-verify every skill against 0.13 ([#137](https://github.com/fespalier/fespalier/issues/137)) ([92aa0a0](https://github.com/fespalier/fespalier/commit/92aa0a0ef15701e7bd20a849cfffa5ea877c6a61))
* re-verify the troubleshooting skill against 0.13 ([#134](https://github.com/fespalier/fespalier/issues/134)) ([589cf39](https://github.com/fespalier/fespalier/commit/589cf3917c4de168f746c51a9f58e33a030a9e2a))


### Tests

* golden fsp diagnostics for broken trees, the troubleshooting skill's example ([#124](https://github.com/fespalier/fespalier/issues/124)) ([10997ac](https://github.com/fespalier/fespalier/commit/10997acff4c9e3a6085b54e2a660bcb2d7414aa8))

## [0.13.0](https://github.com/fespalier/fespalier/compare/v0.12.0...v0.13.0) (2026-10-08)


### Features

* **analytics:** fespalier_analytics, screen views with consent ([#118](https://github.com/fespalier/fespalier/issues/118)) ([e1c0abb](https://github.com/fespalier/fespalier/commit/e1c0abb8ca776d389ab7185de2b90cda5e38fcd1))
* **biometrics:** fespalier_biometrics, an unlock guard that never prompts twice ([#116](https://github.com/fespalier/fespalier/issues/116)) ([b3d22c1](https://github.com/fespalier/fespalier/commit/b3d22c13382bd2c529feed24bf6e7bb72f8b9141))
* **frb:** fespalier_frb, providers rebuilt by a Rust core's change stream ([#119](https://github.com/fespalier/fespalier/issues/119)) ([5f9407e](https://github.com/fespalier/fespalier/commit/5f9407edc9130c1d8ae35691c5ffe3f6b418fa88))
* **maps:** fespalier_maps, a pin picker that returns a place ([#113](https://github.com/fespalier/fespalier/issues/113)) ([d5be9b0](https://github.com/fespalier/fespalier/commit/d5be9b0b58873215ba65aa0ea127fbe39562a30f))
* **maps:** file packs (PMTiles), resumable over HTTP Range ([#120](https://github.com/fespalier/fespalier/issues/120)) ([265a43e](https://github.com/fespalier/fespalier/commit/265a43e3aacb2df553736202e58cdd138665d0f7))
* **maps:** offline region packs with progress, pause, resume and storage ([#117](https://github.com/fespalier/fespalier/issues/117)) ([ea4cf43](https://github.com/fespalier/fespalier/commit/ea4cf433a0f0c688cc52891ec4abc24ef1706f28))
* **push:** fespalier_push, notification taps open typed routes ([#115](https://github.com/fespalier/fespalier/issues/115)) ([6b0525f](https://github.com/fespalier/fespalier/commit/6b0525f3f81407e4667757b155642f549e677b81))
* **riverpod:** fespalier_riverpod, providers per page instance ([#121](https://github.com/fespalier/fespalier/issues/121)) ([4c903b4](https://github.com/fespalier/fespalier/commit/4c903b46cd8fe847d60f7e162c666d63800d1fdf))

## [0.12.0](https://github.com/fespalier/fespalier/compare/v0.11.0...v0.12.0) (2026-10-07)


### Features

* fsp links can skip the sitemap and manage the manifest without fingerprints ([#112](https://github.com/fespalier/fespalier/issues/112)) ([326fa04](https://github.com/fespalier/fespalier/commit/326fa04970baed828ac1da1714a4c04efb5743aa))
* sendPlatformLink, telemetryFollows, and fsp links warns when Flutter deep linking is off ([#110](https://github.com/fespalier/fespalier/issues/110)) ([ae37aae](https://github.com/fespalier/fespalier/commit/ae37aae69f3735473ffd3a63e0bc56058c2a2edb))
* startup.dart ready(container) and attach(router, container), run on the app's own container before the first route ([#111](https://github.com/fespalier/fespalier/issues/111)) ([db8d370](https://github.com/fespalier/fespalier/commit/db8d3704935c51d838d6a34254ccd52ee35275b2))


### Documentation

* README and package READMEs pass markdownlint ([#108](https://github.com/fespalier/fespalier/issues/108)) ([89b4332](https://github.com/fespalier/fespalier/commit/89b43327b6c0f0e7e10e17d28e6393f25a5391ff))

## [0.11.0](https://github.com/fespalier/fespalier/compare/v0.10.0...v0.11.0) (2026-10-07)


### ⚠ BREAKING CHANGES

* RouteHooks.onEnter takes a RouteScope, so every app with an observe.dart regenerates app.g.dart with the matching fsp; replace on a tree page now keeps the page's instance id, so a query-only replace is no leave and enter for observe.dart and telemetry.
* a FespalierTelemetry sink with an exhaustive switch on TelemetryOp stops compiling until it adds a TelemetryOp.custom case (or ends the switch with a wildcard); TelemetryStart gains name and attributes, and TelemetryEnd gains attributes.
* form() and useForm need the fespalier_forms package. Add fespalier_forms under dependencies, at the same git url and ref as fespalier, and run fsp gen: app.g.dart now imports package:fespalier_forms/fespalier_forms.dart, and fsp reports an error until the dependency is there. Code that names ActionForm, ActionField, ActionTextField, ActionFormFields, FieldCodec, ActionFormMessages, ActionFormValidation or useActionForm imports package:fespalier_forms/fespalier_forms.dart; package:fespalier no longer exports them. FieldErrors, validate() and optimistic() stay in fespalier. See docs/migration.md, 0.11.0.

### Features

* AppAdapters in app.g.dart, adapters with main: manual, FespalierAdapter.attach ([#95](https://github.com/fespalier/fespalier/issues/95)) ([17f0aa5](https://github.com/fespalier/fespalier/commit/17f0aa5b82655fbbe600fec546031c6ceff81f06))
* AppRoutes.router(launch:) and AppRoutes.onEnter ([#102](https://github.com/fespalier/fespalier/issues/102)) ([beab769](https://github.com/fespalier/fespalier/commit/beab7694405bc872172dc68db1eaa8fb067459f6))
* forms move out of fespalier into the fespalier_forms package ([b7cf9d4](https://github.com/fespalier/fespalier/commit/b7cf9d4151dc5fc050e18ec2e3e0e65bad3f95d4))
* **forms:** drafts, a form's input kept per route and restored on return ([#101](https://github.com/fespalier/fespalier/issues/101)) ([f0a3caf](https://github.com/fespalier/fespalier/commit/f0a3cafa7e6ece7b69999bf9f2da73a32595fd5a))
* **forms:** leaveIfClean, a bottom sheet that asks before unsaved changes go ([#105](https://github.com/fespalier/fespalier/issues/105)) ([d9d929a](https://github.com/fespalier/fespalier/commit/d9d929a4f8647da1260c7bfc8a447638ac496cec))
* **forms:** multi-page forms, a section's steps sharing one form and one draft ([#106](https://github.com/fespalier/fespalier/issues/106)) ([43da577](https://github.com/fespalier/fespalier/commit/43da5771320b07df5d28b153bd9b04557e3b74e6))
* fsp links edits AndroidManifest.xml and the entitlements, and --check follows them ([#100](https://github.com/fespalier/fespalier/issues/100)) ([66868e2](https://github.com/fespalier/fespalier/commit/66868e279941610d3b575626df711b3ba81e1d93))
* fsp links flavours, host-less schemes and path patterns ([#97](https://github.com/fespalier/fespalier/issues/97)) ([c7d226f](https://github.com/fespalier/fespalier/commit/c7d226f7e7fc8956f765d077fbae183cb1ccb33c))
* InboundLaunch, platform links tagged in telemetry, FespalierAdapter.launch and onEnter ([#99](https://github.com/fespalier/fespalier/issues/99)) ([d93338e](https://github.com/fespalier/fespalier/commit/d93338e6e270b3589fb5b00307ead527b216e9cd))
* leave.dart, asked before a page goes (GoRoute.onExit), with a back gesture that asks too ([#104](https://github.com/fespalier/fespalier/issues/104)) ([8acb192](https://github.com/fespalier/fespalier/commit/8acb192162be731b0bb57831d942b91d4a36f36a))
* RouteScope, a page instance's scope for observe.dart's onEnter, with hold and onLeave ([3683868](https://github.com/fespalier/fespalier/commit/3683868d7c1d5761fde34c51b0a530e518a26915))
* TelemetryOp.custom for packages' own operations ([4f13b41](https://github.com/fespalier/fespalier/commit/4f13b4190f249aefca7aa8d3165fcfca6763f376))


### Bug Fixes

* **skills:** no code span ends in a space, so markdownlint passes on skills and docs ([#94](https://github.com/fespalier/fespalier/issues/94)) ([c5529c8](https://github.com/fespalier/fespalier/commit/c5529c86311fd63c653e3411fb1dbd1d587cc2b8))


### Continuous Integration

* the 0.9.0 adapters step finds the adapter import in app.g.dart ([#107](https://github.com/fespalier/fespalier/issues/107)) ([7a8dadc](https://github.com/fespalier/fespalier/commit/7a8dadcbab31cb06356178969ab05550065e974b))

## [0.10.0](https://github.com/fespalier/fespalier/compare/v0.9.1...v0.10.0) (2026-10-07)


### Features

* fespalier_cratestack, offline-first reads, intents and sync for CrateStack clients ([#90](https://github.com/fespalier/fespalier/issues/90)) ([95fc0c6](https://github.com/fespalier/fespalier/commit/95fc0c62de3e3646186fdc6bbcb4e3dbb7bd0f88))
* fespalier_tolgee, translations from Tolgee's CDN with a bundled fallback and route locales ([#89](https://github.com/fespalier/fespalier/issues/89)) ([9178376](https://github.com/fespalier/fespalier/commit/9178376152372166cb2c0f6a7002862e1661ad66))


### Bug Fixes

* **release:** release-please no longer rewrites third-party version ranges in READMEs ([#86](https://github.com/fespalier/fespalier/issues/86)) ([d194156](https://github.com/fespalier/fespalier/commit/d194156a95587138c1217ce8e6ce4d8d3325683c))


### Documentation

* a five-minute README, and the reference in one-topic pages under docs/ ([#91](https://github.com/fespalier/fespalier/issues/91)) ([bfbbf87](https://github.com/fespalier/fespalier/commit/bfbbf87f8aa3531004a1362ec1cf472e5d174e65))

## [0.9.1](https://github.com/fespalier/fespalier/compare/v0.9.0...v0.9.1) (2026-10-04)


### Bug Fixes

* semantics_ids keeps each page's text as separate nodes ([#84](https://github.com/fespalier/fespalier/issues/84)) ([31e3d46](https://github.com/fespalier/fespalier/commit/31e3d46b50c1f608c8552d4129e209f1de33cbe1))

## [0.9.0](https://github.com/fespalier/fespalier/compare/v0.8.1...v0.9.0) (2026-10-04)


### Features

* adapters in the generated main() and pages named by their route pattern ([#83](https://github.com/fespalier/fespalier/issues/83)) ([81c169a](https://github.com/fespalier/fespalier/commit/81c169af0c26afcd33f51ed9d385d38c8ed99848))
* fespalier_adaptive, nav.dart menus as a bar, rail or drawer by width ([#73](https://github.com/fespalier/fespalier/issues/73)) ([d69a567](https://github.com/fespalier/fespalier/commit/d69a567add34d5ca973a4165cd01e3403675e7ba))
* fespalier_auth and fespalier_sign_keypair, sign-in and DPoP-bound requests ([#71](https://github.com/fespalier/fespalier/issues/71)) ([14d86a1](https://github.com/fespalier/fespalier/commit/14d86a19c1cab5bd20dac9d4ffedec775a0eb8ed))
* fespalier_dio, requests cancelled with their page, server field errors and no retried writes ([#78](https://github.com/fespalier/fespalier/issues/78)) ([db979ca](https://github.com/fespalier/fespalier/commit/db979cad371fb31e0bb5493c8226ce516e66cdd4))
* fespalier_flags, fespalier_storage and fespalier_connectivity, flag-gated routes, bounded offline caches and refetch on reconnect ([#77](https://github.com/fespalier/fespalier/issues/77)) ([d5d8f52](https://github.com/fespalier/fespalier/commit/d5d8f52cdb6218de55ee7c4e766d9e63a5d5591e))
* fespalier_image, images at the size their layout needs from imgproxy, EmgR, Cloudinary, imgix or Thumbor ([#80](https://github.com/fespalier/fespalier/issues/80)) ([d454a7f](https://github.com/fespalier/fespalier/commit/d454a7f0e743807b840b2e789cd80b4d0a89e4e2))
* fespalier_sentry, errors and crashes tagged with their route, file and action, linked to their OpenTelemetry trace ([#81](https://github.com/fespalier/fespalier/issues/81)) ([987c8b7](https://github.com/fespalier/fespalier/commit/987c8b75529f6437fc7d181bd2277e291c3399b6))
* FespalierTelemetry.combine, a within() hook so HTTP spans nest under data spans, and navigation.source ([#72](https://github.com/fespalier/fespalier/issues/72)) ([88e8a2a](https://github.com/fespalier/fespalier/commit/88e8a2af2c8f6acd30fccb52ad086f43c7e229b7))
* fsp dev, fsp build and fsp run, with tasks in pubspec.yaml and a terminal UI ([#69](https://github.com/fespalier/fespalier/issues/69)) ([2e353b7](https://github.com/fespalier/fespalier/commit/2e353b7d194823c2c57cdcb38ada6cd91dcc7ff3))


### Bug Fixes

* fespalier builds and passes its tests on the Flutter 3.32 floor, and CI now runs it there ([#75](https://github.com/fespalier/fespalier/issues/75)) ([a01c214](https://github.com/fespalier/fespalier/commit/a01c214cb0a334dfa09fc71e6871ffe0c0f5864b))
* RouteLink compiles on Flutter 3.32, the package's declared floor ([#74](https://github.com/fespalier/fespalier/issues/74)) ([37ff8f6](https://github.com/fespalier/fespalier/commit/37ff8f6953d173d2af75d7be2483da674850c70d))


### Documentation

* fill the roadmap ([#68](https://github.com/fespalier/fespalier/issues/68)) ([0780ef8](https://github.com/fespalier/fespalier/commit/0780ef88998becbbb4d53f6e95bd551330f02f45))
* the roadmap lists what 0.9.0 ships, and one troubleshooting row per area ([#82](https://github.com/fespalier/fespalier/issues/82)) ([eac58f5](https://github.com/fespalier/fespalier/commit/eac58f5be8e581872e4d2dd46e6ec4b944f23301))


### Tests

* no more "Text file busy" when a test writes a stand-in executable while another spawns ([#79](https://github.com/fespalier/fespalier/issues/79)) ([3ecfafe](https://github.com/fespalier/fespalier/commit/3ecfafe991ae53416b65c23cf61e0fa9f1682327))

## [0.8.1](https://github.com/fespalier/fespalier/compare/v0.8.0...v0.8.1) (2026-10-03)


### Features

* plain-language telemetry dashboards and fsp telemetry --report ([#64](https://github.com/fespalier/fespalier/issues/64)) ([295c925](https://github.com/fespalier/fespalier/commit/295c9256ec0d756255cbc7f5869b2e1a8cd1cc5f))


### Bug Fixes

* point at fespalier/fespalier, make the Homebrew and Scoop push optional, ship the wave as 0.8.1 ([#65](https://github.com/fespalier/fespalier/issues/65)) ([f82ed13](https://github.com/fespalier/fespalier/commit/f82ed13fecab6e002efe6b6933fb5e98e513dcba))


### Chores

* cut the next release as 0.8.1 from after [#61](https://github.com/fespalier/fespalier/issues/61) ([#67](https://github.com/fespalier/fespalier/issues/67)) ([90c788b](https://github.com/fespalier/fespalier/commit/90c788b30a48fd422a422b3ba3ed878f3592be97))
* release main ([#52](https://github.com/fespalier/fespalier/issues/52)) ([c4f8b65](https://github.com/fespalier/fespalier/commit/c4f8b655f8bb907cabbd6409ad1bdf5715d4b679))

## [0.8.0](https://github.com/vaam-apps/fespalier/compare/v0.7.0...v0.8.0) (2026-10-03)


### Features

* a generated main() from app.dart, startup.dart and splash.dart ([#62](https://github.com/vaam-apps/fespalier/issues/62)) ([90694ba](https://github.com/vaam-apps/fespalier/commit/90694baf4bfd22f749c681e837fcb23da29b7206))
* data freshness, refetch on resume and reconnect, and a persistent data cache ([#58](https://github.com/vaam-apps/fespalier/issues/58)) ([16776ce](https://github.com/vaam-apps/fespalier/commit/16776cebaf65e1804bb825964741d2244eca9743))
* DevTools shows who holds a provider and traces data that returns one ([#56](https://github.com/vaam-apps/fespalier/issues/56)) ([b797607](https://github.com/vaam-apps/fespalier/commit/b797607000ba65b9bd9427c799b3d0a0350b6c09))
* forms on action.dart with typed fields, validation and optimistic updates ([#60](https://github.com/vaam-apps/fespalier/issues/60)) ([502df50](https://github.com/vaam-apps/fespalier/commit/502df5021bd05773a269cf5bdff7d071828e5abd))
* fsp size reports the web build per deferred route, with budgets ([#51](https://github.com/vaam-apps/fespalier/issues/51)) ([9af2059](https://github.com/vaam-apps/fespalier/commit/9af2059da04a825d140cd4255b3d42dfba5088cf))
* fsp telemetry, a local OpenTelemetry stack with ready-made dashboards ([#61](https://github.com/vaam-apps/fespalier/issues/61)) ([6a20a28](https://github.com/vaam-apps/fespalier/commit/6a20a28b8da0cebe8e0671a07b62546b6c8d4076))
* fsp test generates a widget smoke test per route ([#55](https://github.com/vaam-apps/fespalier/issues/55)) ([3bb6c06](https://github.com/vaam-apps/fespalier/commit/3bb6c06597e1c865b3a2dcfe0f3615dcd566d276))
* navigation menus generated from the route tree ([#59](https://github.com/vaam-apps/fespalier/issues/59)) ([1211d03](https://github.com/vaam-apps/fespalier/commit/1211d03d2bf5dfa3238d89cfe1a083008559f939))
* observe.dart lifecycle hooks and OpenTelemetry instrumentation ([#63](https://github.com/vaam-apps/fespalier/issues/63)) ([a0605b2](https://github.com/vaam-apps/fespalier/commit/a0605b2bf7f9e6b9f6f1b13b5acfb6141aea8490))
* scroll restoration per route ([#57](https://github.com/vaam-apps/fespalier/issues/57)) ([81dc0a0](https://github.com/vaam-apps/fespalier/commit/81dc0a0698ed358f1212489b614bf2f3ea02a92a))
* shared-element transitions with typed route heroes ([#53](https://github.com/vaam-apps/fespalier/issues/53)) ([ab3e264](https://github.com/vaam-apps/fespalier/commit/ab3e264a6306b5877886fab3f479e36f4f311784))
* unknown_path checks a literal path's segment types ([#50](https://github.com/vaam-apps/fespalier/issues/50)) ([0d2ea11](https://github.com/vaam-apps/fespalier/commit/0d2ea112a2fbadb3db6e3d04ba6f2fe51c8aa126))


### Continuous Integration

* replay the shop's Maestro flows in Chromium on every PR ([#54](https://github.com/vaam-apps/fespalier/issues/54)) ([ecb4a41](https://github.com/vaam-apps/fespalier/commit/ecb4a41d9a8e85fe97782f12a6c3bce027a931b7))

## [0.7.0](https://github.com/vaam-apps/fespalier/compare/v0.6.0...v0.7.0) (2026-10-02)


### Features

* a DevTools extension that shows the route tree, the location and the stack ([#29](https://github.com/vaam-apps/fespalier/issues/29)) ([#46](https://github.com/vaam-apps/fespalier/issues/46)) ([08e06a4](https://github.com/vaam-apps/fespalier/commit/08e06a47d6daba9f71bee8ff299fb37f3190eee0))
* deferred routes load a page's code on demand, and preload loads it ahead ([#24](https://github.com/vaam-apps/fespalier/issues/24)) ([#44](https://github.com/vaam-apps/fespalier/issues/44)) ([2bf9b2f](https://github.com/vaam-apps/fespalier/commit/2bf9b2f8a1b0561fd7034110f256281a556e0972))
* fsp maestro writes a Maestro smoke flow per route, and semantics_ids gives pages stable ids ([#27](https://github.com/vaam-apps/fespalier/issues/27)) ([#43](https://github.com/vaam-apps/fespalier/issues/43)) ([0794c29](https://github.com/vaam-apps/fespalier/commit/0794c2916c91473ce275592a0a0ed236008247d6))
* fsp warns about string paths that match no route ([#28](https://github.com/vaam-apps/fespalier/issues/28)) ([#42](https://github.com/vaam-apps/fespalier/issues/42)) ([15a4bf9](https://github.com/vaam-apps/fespalier/commit/15a4bf9693f682f4ed531f996ecbd6ca775badf1))
* **runtime:** RouteInfo.sibling ([#47](https://github.com/vaam-apps/fespalier/issues/47)) ([36cd410](https://github.com/vaam-apps/fespalier/commit/36cd4106694312965851e970149b4d9b032a9cb1))
* **runtime:** TypedLocation.pushReplacement ([#45](https://github.com/vaam-apps/fespalier/issues/45)) ([673307d](https://github.com/vaam-apps/fespalier/commit/673307d5736e6e11896193b40d85f4f0edaea801))
* the DevTools extension shows guard decisions, data states and action runs ([#29](https://github.com/vaam-apps/fespalier/issues/29)) ([#49](https://github.com/vaam-apps/fespalier/issues/49)) ([db79b59](https://github.com/vaam-apps/fespalier/commit/db79b59ce4d008177b0c616eb1d6b12874469497))

## [0.6.0](https://github.com/vaam-apps/fespalier/compare/v0.5.0...v0.6.0) (2026-10-02)


### Features

* pumpRouter(disposeRouter: false) for tests that dispose the router themselves ([#38](https://github.com/vaam-apps/fespalier/issues/38)) ([ca896d7](https://github.com/vaam-apps/fespalier/commit/ca896d75952078caf3c58d79a3b4fed676576fa5))
* remount, when a page gets a fresh state because its URL changed ([#40](https://github.com/vaam-apps/fespalier/issues/40)) ([78b2f60](https://github.com/vaam-apps/fespalier/commit/78b2f609398e12898aafb66820145f9c745350ae))


### Bug Fixes

* typed replace and push put their URL in the browser's address bar ([#39](https://github.com/vaam-apps/fespalier/issues/39)) ([c79bd08](https://github.com/vaam-apps/fespalier/commit/c79bd0876a7f54683deb28f4d5417a3838fb1627))

## [0.5.0](https://github.com/vaam-apps/fespalier/compare/v0.4.1...v0.5.0) (2026-10-01)


### Features

* action.dart for typed writes with pending and error state ([#22](https://github.com/vaam-apps/fespalier/issues/22)) ([#33](https://github.com/vaam-apps/fespalier/issues/33)) ([1adf977](https://github.com/vaam-apps/fespalier/commit/1adf9778734bbe7e28098946d0338dabaaea4a33))
* fsp links writes App Links, Universal Links and a sitemap from the route tree ([#26](https://github.com/vaam-apps/fespalier/issues/26)) ([#36](https://github.com/vaam-apps/fespalier/issues/36)) ([81098b2](https://github.com/vaam-apps/fespalier/commit/81098b223c007e036bb68caf0465e1c40f4b4708))
* guards and redirects take a Ref, and a guard re-runs when what it watches changes ([#32](https://github.com/vaam-apps/fespalier/issues/32)) ([77d967b](https://github.com/vaam-apps/fespalier/commit/77d967b1bad1185898c46a38113fff8a851c9b19))
* RouteLink, a typed link that preloads its route's data ([#23](https://github.com/vaam-apps/fespalier/issues/23), [#24](https://github.com/vaam-apps/fespalier/issues/24)) ([#34](https://github.com/vaam-apps/fespalier/issues/34)) ([5520707](https://github.com/vaam-apps/fespalier/commit/552070713052d3037a4b7898228cc6dba9323a9a))
* XRoute.of(context) and copyWith, the URL as typed state ([#25](https://github.com/vaam-apps/fespalier/issues/25)) ([#35](https://github.com/vaam-apps/fespalier/issues/35)) ([c4418a8](https://github.com/vaam-apps/fespalier/commit/c4418a8fa7e25a95d4cdea36c883163127347125))


### Bug Fixes

* fespalier no longer causes rebuilds, leaks or order-dependent tests ([#31](https://github.com/vaam-apps/fespalier/issues/31)) ([818b21c](https://github.com/vaam-apps/fespalier/commit/818b21c1ffd60a805e7c03dec5ff66bdd47e5546))

## [0.4.1](https://github.com/vaam-apps/fespalier/compare/v0.4.0...v0.4.1) (2026-10-01)


### Documentation

* ship the agent skills in skills/, checked against the code in CI ([#20](https://github.com/vaam-apps/fespalier/issues/20)) ([218b5e2](https://github.com/vaam-apps/fespalier/commit/218b5e283de7e8dee6fdab44d9bbabfb2645d9af))

## [0.4.0](https://github.com/vaam-apps/fespalier/compare/v0.3.0...v0.4.0) (2026-10-01)


### ⚠ BREAKING CHANGES

* the Dart package is publish_to: 'none'; depend on it by git tag.

### Features

* nest = false in route.dart makes a route a sibling of the page above it ([#19](https://github.com/vaam-apps/fespalier/issues/19)) ([d676fce](https://github.com/vaam-apps/fespalier/commit/d676fce5b568b8c6c3e9909cdf73d5529348f375)), closes [#12](https://github.com/vaam-apps/fespalier/issues/12)


### Bug Fixes

* **ci:** build fsp on Windows and accept older pins on the release PR ([#15](https://github.com/vaam-apps/fespalier/issues/15)) ([a998fbd](https://github.com/vaam-apps/fespalier/commit/a998fbd24631101dae47c7e8bdfca54a33a31050))
* **ci:** download staged release assets as files, not their metadata ([#17](https://github.com/vaam-apps/fespalier/issues/17)) ([65288bb](https://github.com/vaam-apps/fespalier/commit/65288bbb32c9d467e4d37435fcce73a0327b5301))
* correct README claims and error messages; currentLocation follows a push ([#18](https://github.com/vaam-apps/fespalier/issues/18)) ([28f86d7](https://github.com/vaam-apps/fespalier/commit/28f86d789c3cc639a24be040cf2ca5b62880eb59))


### Documentation

* **examples:** add a minimal starter example ([#11](https://github.com/vaam-apps/fespalier/issues/11)) ([8b63d46](https://github.com/vaam-apps/fespalier/commit/8b63d46829745ff2c9935ce787f3a3ed6bfdfefc))


### Build System

* adopt the vaam-apps CI, lint and repo conventions; stop publishing to pub.dev ([#16](https://github.com/vaam-apps/fespalier/issues/16)) ([862e819](https://github.com/vaam-apps/fespalier/commit/862e819a76724626dfa39d87378777fff0de0e7f))
* release through release-please, with fsp checksums pinned in the release PR ([#13](https://github.com/vaam-apps/fespalier/issues/13)) ([f5ea764](https://github.com/vaam-apps/fespalier/commit/f5ea76490b724a87679dcf485c7eff9c7b86b058))

## 0.3.0 — 2026-09-30

Function views, navigators and presented routes, localized paths, enum and typed catch-all
segments, `extra` beyond pages, URL → data lookup, and a much faster `fsp watch` on large apps.

### Upgrading from 0.2

* **Regenerate `lib/app.g.dart`** with `fsp` 0.3.0 (`fsp gen`, or `dart run fespalier gen`): the
  generated code relies on runtime additions from this release.
* **`prefetch` returns a `PrefetchHandle`.** A prefetch without `keepFor` now lives until you
  `close()` the handle (it used to lapse after 30 s); `prefetchKeepAlive` is removed.
* **A `transition.dart` at or above a layout now animates that layout's shell too.** `fsp init`
  writes one at the root, so most apps see it; switching tabs still doesn't re-animate the shell.
* **Generated `data()` providers keep Riverpod's automatic retry** unless `data_retry: none`.
* **`NotFoundScope`** (hand-written `nearestNotFound` scopes) takes a named `caseSensitive:`.
* **`RouteMatch`:** `package:fespalier/fespalier.dart` hides go_router's own `RouteMatch`.

### Localized paths

* **`route.dart` can give a folder more spellings per locale:** `const paths = {'fr': 'produits', 'de': 'produkte'};`
  in `products/route.dart` makes `/products` also answer `/produits` and `/produkte`, while the
  typed route, the page and its data stay single. It spells that folder's own static segment
  only; children below it resolve under every spelling, each level on its own. A `route.dart` may
  hold `paths` alone (no `caseSensitive` needed).
* **One `GoRoute`, not one per spelling.** The segment becomes a path parameter with an alternation,
  `:_l0(products|produits|produkte)` (go_router's `:name(pattern)`, which `patternToRegExp` supports in
  17.5 and 18.0), so nested routes, page keys (the same for every spelling), restoration ids and tab
  stacks see one route. Static routes still sort before dynamic siblings, dots in a spelling are
  escaped, and case follows the route's `caseSensitive`.
* **Typed locations:** `locationFor(locale)` on every typed route (`ProductRoute(id: 2).locationFor('fr')`
  is `/produits/2`; `.location` stays canonical), and `go`, `push` and `replace` take `locale:`. A level with
  no spelling for the locale keeps its canonical one, and `fr-CA` falls back to `fr`. No global locale:
  a route stays a value. **Regenerate `lib/app.g.dart`**: the generated `go`/`push`/`replace` overrides of a route
  with an `extra` now take `locale` too.
* **Every surface knows the spellings:** `AppRoutes.match`, `matchUrl` and `dataAt`, `RouteMatcher`,
  `nearestNotFound` (a `not_found.dart` in a localized folder covers all its spellings) and
  `AppManifest.of`. The manifest's `RouteInfo` has `paths` (`{'fr': '/produits/:id'}`) and `pathFor(locale)`;
  `path` and `byPath` stay canonical.
* **`fsp routes`** lists the spellings under a route's row, and `--json` has a `paths` object for a
  route that has them (other rows are unchanged). The route table in the header of `app.g.dart` shows them too.
* **Errors, with code frames:** `paths` on a `$dynamic`, `$$catch-all`, `(group)` or app folder; a
  value that is not one URL segment (no `/ ? # %`, whitespace, control characters or
  `: | ( ) ' " $ \`); a key that is not a string literal or a locale tag, or repeats; and a
  spelling that makes a URL another route serves (`fr: 'about'` beside a real `about/`, or two
  `not_found.dart` files) is reported at the entry and at the other file, even while the rest of the
  file has errors (an entry with an error is left out). The unreachable-route check knows the spellings.
* **Non-ASCII spellings** (`{'de': 'über', 'ru': 'продукты'}`): go_router matches `Uri.path`, which
  is percent-encoded however a location was typed, so the route's pattern has each spelling encoded
  (`%C3%BCber`), the matchers and not-found scopes compare decoded segments, and `locationFor` writes
  the spelling encoded. A deep link works raw, encoded or in lower-case hex. Case-insensitive
  matching of such letters is go_router's (hex and `A-Z` only).
* **Tabs:** go_router refuses a tab whose first route has a path parameter, which a localized
  segment is, so `fsp gen` writes that tab's `initialLocation` (the canonical one). A `tabOptions`
  `initialLocation` may name a spelling. A localized first route below a `:segment` is an error.
* `examples/features` has `help/` (`aide`, `hilfe`: a dynamic child, a nested localized child, a
  `not_found.dart`) and `examples/tabs` a Search tab that also answers `/recherche`, with widget tests.

### Faster on very large apps, and an incremental `fsp watch`

Measured on synthetic apps of 500, 2,000 and 5,000 routes (`cd cli && cargo test --release
bench -- --ignored --nocapture --test-threads=1`; numbers and method in README's
"Performance").

* **`fsp watch` skips work it has done.** A run that scans exactly the tree of the run before
  (a save that changed nothing, or a file under `lib/app/` that isn't a route file) reuses its
  diagnostics and generated code instead of resolving and rendering again: 424 ms → 77 ms at
  5,000 routes. With `format: true`, `dart format` runs only on generated code it hasn't
  formatted before, so a save that doesn't change the generated code (a `build` method, say)
  no longer waits for the formatter: 12.7 s → 0.27 s at 5,000 routes, 1.2 s → 0.03 s at 500.
  Writing only when the bytes differ was already so. Code that did change is still formatted
  in full. The first run, and every run that changes the tree, resolve and emit as before: a
  per-route cache was measured not to be worth it (a full resolve is 30 ms at 5,000 routes).
  The files outside the app folder that were read for enum declarations are part of what has to
  match, compared by content, and `watch` now also watches `lib/` (Dart files and folders), so
  editing `lib/models/category.dart` regenerates.
* **A cold `gen` and `check` parse on all cores** once a run has about 64 files to parse
  (std threads, no new dependency): 626 ms → 429 ms at 5,000 routes.
* **The route-order check is no longer quadratic.** "`/:slug` hides `/about`" compared every
  page with every earlier one; it is now indexed by first segment and gives the same answers
  (a differential test checks it against the old comparison): emit at 5,000 routes 277 ms →
  153 ms. The folder walk uses the file types `readdir` already returns instead of a `stat` each.
* New tests: `watch`'s incremental output equals a from-scratch `gen` after each of adding and
  removing a route, renaming folders, changing a data type, adding and removing layouts and
  touching group folders, and after random edits from fixed seeds, errors included.
  The benchmark (`cli/src/bench.rs`) replaces the old ignored one in `parse_cache.rs`.

### Enum segments, query parameters and catch-alls

* **A segment, a query parameter and a catch-all can be an app enum.** `Category category` for
  `$category`, `Sort? sort` and `List<Sort> sorts` for `?sort=`, and `List<Category> path` for
  `$$path`, in any file that asks for them (a page, `data.dart`, a guard, a layout, `loading.dart`,
  a provider's family argument). `/shop/shoes` is `Category.shoes`, read by name
  (`Category.values.byName`); a segment or catch-all part that names no value is a `BadSegment`,
  so the route shows `not_found.dart` like `/products/abc` does for an `int`, and a query
  parameter that names none is `null` (or left out of a list). Where the route's paths match in
  any case (`case_sensitive: false`, or a `route.dart`) the name does too; an exact match wins.
* **`.location` writes the `name`,** and the typed route's field has the enum's type
  (`ShopRoute(category: Category.hats, sort: Sort.price)`). `data.dart` can be keyed by an enum
  (it is hashable, so the provider family takes it as it is), and `AppRoutes.match` and `dataAt`
  parse it like the route does.
* **`fsp gen` reads the enum's declaration** to tell an enum from a class, with the tree-sitter
  Dart parser: in the file that names the type, or in a file it imports (relative, or `package:` of
  the app's own package, followed through `export`s), with an import prefix (`m.Category`)
  followed through its own import. The generated file imports the type the way it does a typed
  `extra` (`import '...' show Category;`). A type it finds no enum for is an error at the
  parameter that suggests taking a `String` and parsing it in the page; a private enum is an
  error too. Files must agree on the enum (two enums of one name don't agree), with the error the
  plain types give.
* **An optional nullable parameter of a type no enum is found for** in a page, layout or view is
  left to its default as before (it may be `Color? color`); a `data.dart`, `guard.dart` or
  `redirect.dart` parameter that can't be a segment or a query is the error.
* **The manifest and `fsp routes --json` show the type by name** (`Category`, `List<Category>`,
  `Sort?`), without the import prefix the file used.
* The runtime has `Segment.asEnum`, `Segment.asEnumRest`, `Query.asEnum` and `Query.asEnumList`;
  `withQuery`, `restPath` and `restKey` write an enum as its `name`. Regenerate `lib/app.g.dart`
  with the matching `fsp` if you use one.
* `examples/features` has `shop/$category` (an enum from `lib/models/`, a `Sort?` query parameter
  declared in the page's file, and `data.dart` keyed by the category) and `browse/$$categories`
  (a `List<Category>` through an import prefix), with widget tests, and `dataAt` / `match` tests.

### `extra` for layouts, guards and redirects, and an `extraCodec`

* **`layout.dart`, `guard.dart` and `redirect.dart` can take `extra`**, bound from
  `state.extra`: `const NotesLayout({super.key, required this.child, this.extra})` with
  `final Note? extra;`, or `GuardResult guard(ProviderContainer c, {Note? extra})`. A layout gets
  the extra of the location it is showing. Like a page's, the type must be nullable (an error at
  the parameter otherwise), and a guard or redirect takes it as a named parameter.
* **The types must agree, with an error at the parameter and a code frame.** A guard or layout
  must take `Object?` (or `dynamic`) or the type of the routes it covers; one above routes with
  different `extra` types must take `Object?`, or the error lists the routes that don't fit. A
  page's (or redirect's) own type decides for its route; where a route has none, the guards and
  layouts above it must agree with each other.
* **A wrong type reads as `null`, never a crash,** for a layout, a guard and a redirect (the new
  runtime function `extraOrNull<T>(state)`): they see extras meant for other routes. A page keeps
  its `extraOf`, which asserts in debug builds and reads as `null` in release.
* **A route without an `extra` of its own is typed by its guards and layouts:** when they ask for
  one concrete type (not `Object?`), the typed route's `go`, `push` and `replace` take it as
  `extra:`. A `redirect.dart` route gets a typed `extra:` like a page.
* **`lib/app/extra_codec.dart` restores `extra`.** A top-level `extraCodec` in a file of that
  name at the root of the app folder (a `const`, a `final` or a getter of a
  `Codec<Object?, Object?>`) is found by `fsp` (no config key; `extra-codec.dart` works too) and
  `AppRoutes.router()` passes it as `GoRouter(extraCodec: ...)`, so an `extra` survives the
  browser's history and state restoration. Without one, go_router saves only JSON: an object
  with `toJson()` came back as a `Map`. A missing `extraCodec` is an error, and the file in a
  subfolder is a warning.
* **`ExtraCodec` in the runtime package builds the codec** from a map of type to `toJson` and
  `fromJson`: `ExtraCodec({Note: (toJson: (Note n) => n.toJson(), fromJson: Note.fromJson)})`. It
  saves an object under its type's name, passes `null`, strings, numbers, bools and plain JSON
  through, and never throws: an unregistered type is saved as `null`, and data that no longer
  reads comes back as `null`. `names:` gives types a name that survives web minification, and
  `strict: true` throws for tests.
* `examples/tabs` passes a `ProfileDraft` to its edit page with a codec, and its restoration
  test restarts the app and finds the draft again (and shows what a router without the codec
  restores). `examples/features` has a layout and a guard that read a `Note?` extra.

### From a location to its data, and a prefetch handle (#8)

* **`AppRoutes.dataAt(Uri)`**: the providers of the data of the route at a location,
  **outermost first** (each section's `data.dart`, then the route's own), for an app's own
  prefetch queue or a test. It is built by the same parser the route uses, so
  `dataAt(Uri.parse('/products/42')).single == ProductRoute.data(42)`, and for a `data.dart` that
  selects a provider it is that provider. Query-keyed data is keyed by the query of the
  location, a catch-all by its path, and the mount point is stripped. `null` when no route fits
  or a segment doesn't parse (the `not_found.dart` rule), empty for a route without data. No
  guard runs and no widget is built.
* **`AppRoutes.match(Uri)`** (`AppManifest.match`, in the manifest library with
  `output_manifest:`) returns a `RouteMatch`: the `RouteInfo`, the parsed `params` by name, the
  typed `route` (`match.route.location`), and the same `data` list. `AppRoutes.matchUrl(uri)`
  is its manifest-free half (`UrlMatch`) and always in `app.g.dart`; routes are tried most
  specific first, like go_router. Regenerate `app.g.dart`.
* **Behaviour change: `prefetch` returns a `PrefetchHandle`, and keeps the provider until it is
  closed.** `ProductRoute(id: 2).prefetch(ref)` (and `ref.prefetchData(provider)`) used to hold
  the provider for 30 seconds with a timer; now `handle.close()` lets go, `keepFor:` is an
  optional auto-close, and a failed load closes its handle. Code that ignores the returned
  handle keeps the provider as long as the widget behind `ref` lives, not 30 seconds. New
  `ref.prefetchAll(providers)` closes several with one handle (`prefetchAll(AppRoutes.dataAt(uri) ??
  [])`). `prefetchKeepAlive` is removed.
* **`fespalier.dart` hides go_router's own `RouteMatch`** (an internal of its parser) to export
  fespalier's. `import 'package:go_router/go_router.dart'` if you use that one.

### Section data: query keys and a typed handle

* **A section's `data.dart` can be keyed by query parameters**
  (`Future<Report> data(Ref ref, {String? period})`; it used to be an error). The section's
  layout reads them from the URL, and every route below the section gets them as query
  parameters of its typed route (`MonthlyReportRoute(period: '2026-01')`), so the pages read
  the same provider the layout loaded.
* **Typed handle for a section:** `<Folder>Section` (`teams/$teamId` is `TeamsTeamIdSection`)
  with static `data`, `watch`, `read`, `prefetch` and `refresh`, taking the section's keys as
  named arguments. Two folders that would name the same class are an error, and a key can't be
  called `ref` or `keepFor`.

### Not-found, meta and `fsp new`

* **`not_found.dart` can take the segments of its own path**, as `String`s exactly as the URL
  spells them (a segment that failed to parse is often why it is shown, so they aren't typed;
  `int teamId` there is an error). `pathPart` is the runtime helper.
* `fsp new --not-found` (see below) writes the segments of the folder's path into the `not_found.dart` it scaffolds, class or function form.
* **`meta_unique: [code, slug]`** under `fespalier:`: a value that two routes' `meta.dart` give
  to the same *literal* named argument of `meta`'s constructor call is an error naming both
  files. Expressions and left-out arguments are skipped; a listed name that no `meta.dart`
  gives a literal is a warning.
* README "Design notes": why `ProductRoute(id: 2).watch(ref)` stays static (a `const` route can't
  have a late field, and an instance method would have to name the data type).

### Navigators and shells (#1, #2, #3)

* **`navigator.dart`: render a folder on the root navigator without moving its URL (#1).**
  `const navigator = RouteNavigator.root;` puts the folder's routes and every route below it
  above the tab bar and any layout, while the URL stays where it is (a deep link builds the tab
  page underneath, and back returns to it). Nearest declaration wins, like `transition.dart`; a
  page-less `(group)` can hold one. `fsp gen` emits `parentNavigatorKey: rootNavigatorKey` on
  the route and all its descendants, and marks them `(root)` in the route table. A `layout.dart`
  below a root folder becomes a shell on the root navigator (`ShellRoute(parentNavigatorKey: …)`),
  with the routes inside on its own navigator; `RouteNavigator.shell` is accepted there and is an
  error directly below a root route (go_router doesn't allow it). A root route that is the first
  route of a tab, or sits directly in a layout, is an error: go_router can only lift a route out of
  a shell from below another route. New runtime export: `RouteNavigator`.
* **The generated router owns the root navigator key.** `AppRoutes.rootNavigatorKey` is a
  `GlobalKey<NavigatorState>`; `router(navigatorKey:)` can supply one and `mount(at:, navigatorKey:)`
  takes the host `GoRouter`'s own key (stored like `at`). **Regenerate `app.g.dart`**: `router()`
  now passes the key to `GoRouter`, and `mount()` and `router()` have a new optional parameter.
* **`present.dart`: a `Page` of your own for one route (#2).** `Page<void> present(LocalKey key,
  Widget child)`, bound like `transition.dart` (`key`, `child`, `state`), builds the route's page and
  is used as it is (fespalier adds no scrim, handle or shape). It applies to its own folder only
  (folders below keep the nearest `transition.dart`) and implies the root navigator for the route
  and its descendants, so a sheet opens over a tab bar and a child of a sheet renders above it; a
  `navigator.dart` beside it overrides that. The route table marks it `(present, root)`.
  `examples/features` has an app-owned `SheetPage` and `/photos/share`.
* **Manifest and `fsp routes --json`: `presentation` has two new values.** `RoutePresentation.root`
  (`"root"`) for a page on the root navigator through `navigator.dart`, and `.custom` (`"custom"`) for
  a page a `present.dart` builds; `redirect` and `page` are as before. The tags in the route table
  and in `fsp routes --json` gain `present` and `root`.
* **A tab layout can export `container` (#3).** `Widget container(BuildContext context,
  StatefulNavigationShell shell, List<Widget> children)` makes the shell a `StatefulShellRoute(
  navigatorContainerBuilder: container, …)` instead of `.indexedStack(…)`, to cross-fade or slide
  between tabs. The parameters are positional with fixed types (a wrong type is an error at the
  parameter); without it, the output is unchanged. `examples/tabs` cross-fades.
* **Behaviour change: a layout's shell takes the nearest `transition.dart` as its page (#3).**
  The `ShellRoute` of a `layout.dart` and a tab layout's `StatefulShellRoute` used to get
  `layoutPage(...)`, a plain Material page. When a `transition.dart` is at or above the layout's folder,
  they now get its page under `ValueKey<String>('layout:<folder>/')`: the same stable id as before
  (restoration is unchanged), and a key that doesn't change while you switch routes inside the shell,
  so only entering or leaving the shell animates it, and it moves under a route on the root
  navigator like any page. `fsp init` writes a root `transition.dart`, so most apps' shells change:
  regenerate, and check the layouts' animation. A `transition()` that takes a `bool shell` (or
  `isShell`) is told whether it is building a shell (`true`) or a route (`false`). Without a
  `transition.dart`, layouts keep `layoutPage(...)`.
* `examples/tabs`: `/profile/edit` is full screen through `navigator.dart`, `/profile/security` is
  the nested route that stays in the tab, the tab layout has a cross-fading `container`, and its
  `transition.dart` is Cupertino (the shell moves aside under a root-level push).

### Typed catch-alls, and case per folder

* **A catch-all can be typed.** A parameter named after a `$$rest` or `$$$rest` can be a
  `List<int>`, `List<double>`, `List<num>`, `List<bool>` or `List<DateTime>` as well as the
  `List<String>` it always was. Each part is read like one segment of that type
  (`Segment.asIntRest`, `asDoubleRest`, `asNumRest`, `asBoolRest`, `asDateTimeRest`, built on
  `asRest`); a part that doesn't parse renders `not_found`, as an unparsable `int` segment
  does. The typed route's field takes the list, `.location` joins the encoded parts (a
  `DateTime` as ISO 8601), and `$$$rest` is `[]` when absent. `data.dart` can take the typed list:
  the provider is keyed by the path and `data()` gets the list back. The type must agree in
  every file that asks for it, or it is an error with a code frame in the style of the
  segment mismatch; other element types (`List<Object>`, `List<int?>`) are an error that lists
  what is accepted. `restPath` and `restKey` take any `Iterable<Object>`. `fsp new` keeps the
  type an existing catch-all has. Enums aren't supported (they aren't for ordinary segments
  either). `examples/features` has `compare/$$ids`, a `List<int>` with a `data.dart`.
* **`route.dart`, a per-folder `caseSensitive`.** A file `const caseSensitive = false;` (or
  `true`) in a folder makes that folder and everything below it match paths in any case (or
  exactly), the nearest one winning over the pubspec's `case_sensitive`. It is read from the
  source like `meta.dart`, never imported, and must be a `true` or `false` literal: anything
  else is an error. It is its own file because `meta.dart` is not inherited, `transition.dart`
  is a function and `layout.dart` only exists where there is a layout. The generated
  `caseSensitive: false` is now per `GoRoute`, and each `nearestNotFound` scope carries its
  folder's setting. `examples/features` keeps `files/` exact while the rest of the app is not.
* **Behaviour change in the runtime API:** `NotFoundScope` (what the generated `notFound`
  passes to `nearestNotFound`) has a third field, `caseSensitive`, so **regenerate
  `lib/app.g.dart`** with the matching `fsp`. A hand-written scope needs `caseSensitive: true`.
* **The requested case is kept, and documented.** go_router doesn't lowercase anything:
  navigating to `/Products/2` on a case-insensitive route leaves `GoRouterState.uri` and the
  router's location as `/Products/2` (only `matchedLocation` is spelled by the route). Typed
  routes' `.location` has no requested case and writes the folders' spelling. Tests in the
  package and in `examples/features` pin this on go_router 17.5 and 18.

### View files as functions, and `not-found.dart`

* **`page.dart`, `loading.dart`, `error.dart`, `layout.dart` and `not_found.dart` can export a
  function returning a `Widget`** in place of a widget class: `Widget page({required String
  orderId}) => CancelOrderScreen(orderId: orderId);`. Its parameters are bound exactly like a
  constructor's (segments, query, `data` by name or type, `child` or a shell, `error` and
  `retry`, `uri`). Many routes can now build one screen with different constants, and a screen
  can stay outside `lib/app/`. The function is named after the file (`notFound()` or
  `not_found()` for the not-found view); a file with a public widget class and the function is
  an error naming both. A function view can't use hooks or `ref`: put those in the widget it
  returns. The class form is unchanged.
* **Route names for function pages.** A page function takes the folder path, ignoring
  `(group)` folders: `(kyc)/shop/name` is `ShopNameRoute`. `const routeName = 'KycShopName';`
  in `page.dart` overrides it (and also renames a class page's route). A name clash is an
  error that suggests `routeName`.
* **`fsp new --function`** scaffolds the function form (`--name` writes `routeName`), and
  **`fsp new --not-found`** scaffolds a `not_found.dart`.
* **`not-found.dart` is accepted** as a spelling of `not_found.dart`, whatever the
  configuration says (any future multi-word kind gets the same rule). Both in one folder is an
  error with a code frame for each file. Diagnostics, the route table and `fsp routes --json`
  name a file as spelled on disk.
* **`file_style: snake | kebab`** (default `snake`) under `fespalier:` picks what `fsp init` and
  `fsp new` write. Existing projects are unchanged.
* `examples/features` gains two routes serving one `PlanScreen` with different constants
  (`(plans)/free`, `(plans)/pro`), with a widget test for each.

### IntelliJ IDEA and Android Studio plugin

* New `editors/intellij/`, a Kotlin plugin on top of `fsp check --json` (the counterpart of the
  VS Code extension). Files under the app folder (`fespalier: app_dir:`, `lib/app` by default)
  get the reported errors and warnings underlined in the editor, and saving one checks again;
  *Tools | fespalier: Generate* runs `fsp gen` and *Tools | fespalier: Check* checks on demand,
  each ending in a notification, which also says when `fsp` could not be run. Settings | Tools |
  fespalier chooses the runner (auto: `fsp` from `PATH`, else `dart run fespalier`) and the
  path to `fsp`. Platform 252 (2025.2) and later; built with JDK 21 and the IntelliJ Platform
  Gradle Plugin 2. Not on the JetBrains Marketplace yet: build it with `./gradlew buildPlugin`
  and install the zip from disk (README, "Editor support"). CI builds and tests it.

### Data refresh and retry

* **Behaviour change: generated `data()` providers no longer switch off Riverpod's retry.**
  0.1.1 gave them `retry: (retryCount, error) => null`, which overrode the app's
  `ProviderScope(retry: ...)`. Now the app's policy applies (Riverpod's default, 10 retries
  with backoff, when it sets none), so a failing `data.dart` is run again in the background.
  What the route shows is unchanged (see `keep_previous`), but the provider runs more than
  once, so a test that counts calls or ends with a pending timer will notice. To keep the old
  behaviour, add `data_retry: none` to the `fespalier:` section of `pubspec.yaml`, or give the
  app a retry policy of its own. Regenerate `app.g.dart`.
* **`DataView` keeps the old state on screen while `data.dart` reloads.** `loading.dart` is
  now only for the first load. A refresh or reload keeps rendering the old value (or error),
  and a provider that failed and is being retried keeps showing `error.dart` for the whole
  retry window, then the data once a retry succeeds. Before, a reload driven by a dependency
  and every retry blinked to `loading.dart`. A section's data reloading no longer shows loading
  for the whole section. `keep_previous: false` restores the loading view for every load.
  (`AsyncValue.when` with `skipLoadingOnReload` and `skipLoadingOnRefresh`.)
* New `fespalier:` config keys: `data_retry: inherit | none` (default `inherit`) and
  `keep_previous: true | false` (default `true`). The generated `DataView` gets a
  `keepPrevious:` argument.
* **`List` query parameters can key `data.dart`.** `data(Ref ref, {List<String> tags = const []})`
  is accepted, and `?tags=a&tags=b` is one provider whatever list instance the page builds:
  the generated key wraps the list in the new runtime `QueryList<T>`, a list with value
  equality. `data()` and the typed helpers still take a plain `List<T>`. It used to be an error.
* `pumpRouter` in `package:fespalier/testing.dart` takes `retry:` and defaults to no retries,
  so a failing `data.dart` shows `error.dart` at once and leaves no timer behind in a test.
  Pass `ProviderContainer.defaultRetry` (or `null`, Riverpod's default) to test retries.
* **`fsp watch` parses only what changed.** It keeps the parse results of every file between
  runs, keyed by the file's source, so a save re-parses the file you saved and nothing else.
  On a synthetic 1,000-route app a regeneration after a one-file edit takes about 32 ms
  instead of about 50 ms in a release build (the rest is scanning, resolving and emitting).
  `gen` and `check` are unchanged.
* **VS Code extension** (`editors/vscode/`, not published yet): `fsp check --json` on save
  becomes Problems panel diagnostics, plus `fespalier: generate`, `fespalier: check` and a
  status bar item. Runs `fsp`, or `dart run fespalier` when `fsp` isn't on `PATH`.
* **Homebrew and Scoop.** Each release attaches `fsp.rb` and `fsp.json`, rendered from the
  archives' checksums by `scripts/packaging.py`, and pushes them to a tap and bucket when
  the `PACKAGING_TOKEN` secret exists.
* **pub.dev.** `flutter pub publish --dry-run` is clean and checked in CI (the package gains
  a shorter description and `example/README.md`). New `Publish to pub.dev` workflow: publishes
  through GitHub OIDC automated publishing when run from the `v<version>` tag.

### `data.dart` can select a provider you already have

* **New third `data.dart` form: a selector.**
  `ProviderListenable<AsyncValue<ProductView>> data({required String productId}) => productProvider(productId);`
  is recognised by its return type (and no `Ref` parameter). Its named parameters are segments
  and query parameters exactly as in the function form (any other parameter is an error at
  it), and `T` from `AsyncValue<T>` is what a page's parameter is bound to by type. Nothing is
  wrapped: `XRoute.data` is the selected provider (`ProductDetailRoute.data('x') ==
  productProvider('x')`), `DataView` watches it directly, and `watch`, `read`, `prefetch` and
  `refresh` target it, so a `riverpod_generator` provider is fetched once per navigation, keeps
  its own `retry`, `keepAlive` and dependencies, and keeps the error it holds while it retries.
  `data_retry` doesn't apply to it. `refresh` and `error.dart`'s retry invalidate the selected
  provider (`refresh` also reads it, so it runs once) through new runtime helpers,
  `invalidateSelected`, `refreshSelected` and `readSelected` on `WidgetRef`, which check at
  run time that the listenable is a provider and throw a `StateError` naming the fix if not.
  Regenerate `app.g.dart` (the generated `DataView` calls `invalidateSelected` for selectors).
* `package:fespalier/fespalier.dart` re-exports `ProviderListenable`; `prefetchData` takes any
  `ProviderListenable<AsyncValue<…>>`.
* A selector can be keyed by a catch-all segment like the function form: the key is the
  encoded path (`restKey`) and the selector function gets the `List<String>` back (`restParts`).
* README: `data.dart` has three forms now, with when to use each.

### Paths

* **Catch-all segments.** A folder `$$rest` matches one or more remaining segments and
  `$$$rest` zero or more; the page takes them as a `List<String>`, each part decoded on
  its own. It is a go_router parameter with its own pattern (`docs/:rest(.+)`), so deep
  links, guards and redirects work as for any route; `$$$rest` is two routes with one builder
  (`/files` and `/files/:path(.+)`). The typed route is `DocsRoute(rest: ['a', 'b c'])`
  (`/docs/a/b%20c`, each part encoded). Siblings are ordered static, dynamic, then catch-all,
  and the unreachable-route check knows catch-alls. `data.dart` can be keyed by one (the
  provider takes the path as an encoded string: new `restKey` / `restParts`). Limits: last
  segment only, `List<String>` only, nothing below it, no `not_found.dart` in it.
  `fsp new 'docs/[...rest]'` and `'docs/[[...rest]]'` scaffold them. Runtime: `Segment.asRest`,
  `restPath`, `restKey`, `restParts`. `fsp routes` shows `/docs/*rest` and `/files/*path?`.
* **`case_sensitive: false`** under `fespalier:` in pubspec.yaml emits `caseSensitive: false` on
  every route, so `/Products` reaches `/products` (parameters keep their case). The
  nearest-`not_found.dart` lookup (`nearestNotFound(..., caseSensitive:)`) follows it. The default
  is unchanged.
* **Trailing slashes** need no option: go_router drops them before matching, so `/products/`
  and `/products/?page=2` reach `/products` (checked on go_router 17.5 and 18, and now tested).
* **Typed `extra`.** A page parameter called `extra` receives what `context.go(location,
  extra: obj)` passed, and the typed route takes it: `NoteRoute(id: 3).go(context, extra:
  note)` (also `push` and `replace`), checked at compile time. The parameter must be nullable:
  the URL alone can't produce it, so a deep link or a reload gets `null`. The generated file
  imports the type by name (`show`) from `page.dart`'s imports, the one place it names one of
  your types. Runtime: `extraOf<T>(state)`. New reserved name: `extra` can't be a segment.

### `dart run fespalier`: pinned checksums, offline, "generate, don't commit"

* **Checksums are pinned inside the package.** `lib/src/release_checksums.dart` holds the
  SHA-256 of every `fsp` archive of the package's own version, and `dart run fespalier`
  refuses a download that doesn't match (before, the `.sha256` came from the same release as
  the binary, so it caught corruption but not a tampered release). A package with no pins for
  its version (a development build from a branch) still checks the release's `.sha256` and
  prints one warning line.
* **Two-phase release.** The *Release* workflow (manual publish) builds the five targets, then
  commits the pins to `main` as `Pin fsp <version> checksums` (`scripts/pin_checksums.py`,
  tested by `scripts/test_pin_checksums.py`), and creates the `v<version>` tag and the Release
  at that commit, so a git dependency on the tag carries the pins. The binaries are built from
  the parent commit and differ only by that one file. Manual publish must now run on the
  default branch, and the workflow needs to be able to push to it. After a version bump, run
  `python3 scripts/pin_checksums.py --reset`; `cli/tests/versions.rs` checks that the file pins
  nothing or the pubspec's version.
* **Offline with an empty cache** stops with one line: `fespalier: fsp 0.3.0 isn't cached and
  the download failed (offline?); run once online or set FSP_BINARY`. A cached binary never
  touches the network.
* README: a "Generate, don't commit" mode (gitignore `lib/app.g.dart`, run
  `dart run fespalier gen` before `flutter analyze` in CI; the generator follows
  `pubspec.lock`), next to the committed mode with `fsp check`, which still writes nothing.

### Route manifest and metadata

* A generated route manifest: `AppRoutes.all`, `byType` (typed-route class) and `byPath` (path
  template), a `const` list of `RouteInfo`s (`AppManifest`) with each route's typed route,
  path, folder, `(group)` chain, layout chain, `page` or `redirect` presentation, segment and
  query parameters (name and Dart type), tab membership (`RouteTab`), `data.dart` keys and
  `meta`. `AppManifest.of(GoRouterState.of(context))` gives the route a layout is showing,
  e.g. for the web tab title with Flutter's `Title` (see the README; `examples/features`).
* `meta.dart` per folder: `const meta = <any const expression>;` is copied into the manifest
  by reference (`_iN.meta`), untyped. It belongs to its own route (not inherited), and a
  `meta` that isn't `const`, a `meta.dart` without one, or one declared twice is an error at the
  declaration. `fespalier: { meta: required }` makes a route without one an error naming its
  folder.
* `fespalier: { output_manifest: lib/app.routes.g.dart }` writes the manifest to a library
  of its own, importing `app.g.dart` for the typed routes, so production code that imports
  `app.g.dart` alone never imports a `meta.dart`. `gen`, `check` and `watch` handle both files,
  and the success line names both; `examples/tabs` uses it.
* `fsp routes --json` adds `folder`, `presentation`, `groups`, `layouts`, `tabs`, `data_keys` and
  `meta` (the route's meta.dart, or null) and `catch_all` to each object; the shape is documented and
  pinned by a test. A catch-all segment is a `List<String>` `RouteParam` with `catchAll: true`, and
  `AppManifest.of` finds the route for it (and for an optional catch-all's bare path).

### State restoration

* `AppRoutes.router(restorationScopeId: ...)` passes the id to `GoRouter`. Tab layouts and
  their branches (and plain layouts) get a stable `restorationScopeId` from their folder, and
  a layout's page is built by the runtime's new `layoutPage`, with a restoration id from the
  folder: go_router keys shell pages by the route's `hashCode`, which changes on every launch,
  so the tabs and their stacks were never found again. The selected tab, each visited tab's
  stack and a page's `RestorableProperty`s survive `tester.restartAndRestore()`
  (`examples/tabs/test/restoration_test.dart`).
* The pages `Transitions.*` build take their `restorationId` from the page key, so what a
  page keeps in a `RestorationMixin` is restored too. A `Page` you write in a `transition.dart`
  should pass `restorationId: key.value`.
* Layouts are now built as `pageBuilder` pages (`layoutPage`: a Material page, or a Cupertino
  one in a `CupertinoApp`) instead of `builder`. Regenerate `lib/app.g.dart`.

## 0.2.0 — 2026-09-30

### Guards and redirects

* `guard.dart` works in a folder without a `page.dart`, in a `(group)` and at the root, and
  guards every route at and below its folder. Guards run outermost first and the first
  location wins. Each page route's `redirect` chains the guards above it (`firstRedirect`).
  An inherited guard takes the segments at its own folder level and query parameters. A guard
  with no route at or below its folder is a warning.
* Guards can take `Uri uri`, the requested location, to build a return-to link:
  `LoginRoute(from: uri.toString()).location`. New `returnTo(from, fallback: '/')` in the
  runtime accepts only in-app locations.
* `redirect.dart` in place of `page.dart`: `String redirect({...})` makes a route that only
  redirects (`/old-products/:id` to `/products/:id`). It gets a typed route named after its
  path (`OldProductsIdRoute`) and takes part in route order checks.

### Navigation

* Nested tab layouts: a tab layout inside a branch of another one generates a nested
  `StatefulShellRoute.indexedStack`. Each level has its own `tabs`, and an inner tab keeps
  its state while you switch outer tabs. `examples/tabs` gets a Library tab with two inner
  tabs.
* Per-tab options: a `const tabOptions = {'search': TabOptions(preload: true), ...}` map in
  a tab layout sets each `StatefulShellBranch`'s `preload` and `initialLocation` (the mount
  point is added for you). Checked like `tabs`; an `initialLocation` must be a route inside
  its tab. A tab with an `initialLocation` may start with a dynamic route. `TabOptions` is a
  new runtime export.
* `Transitions.dialog`, `Transitions.sheet` and `Transitions.fullscreenDialog`: a
  `transition.dart` can make a route open as a dialog or bottom sheet over the previous page
  (`examples/features` has `/photos`, `/photos/:id`, `/photos/sort`, `/photos/upload`).
* `not_found.dart` in any folder. The nearest one covers unknown URLs under its folder
  (`AppRoutes.notFound(uri)`, used by the router's `errorBuilder`, backed by the new runtime
  `nearestNotFound`) and unparsable segments in the routes below it (a `(group)`'s too). It
  used to be an error outside the root.

### Route API and testing

* **Typed data helpers on routes.** A route with a `data.dart` gets `static watch(ref, {keys})`
  (an `AsyncValue<T>`), `static read(ref, {keys})` (a `Future<T>`, kept alive until it
  completes) and an instance `prefetch(ref, {keepFor})` that starts the load and keeps the result
  (30 s by default, `prefetchKeepAlive`) so the next page shows it at once. `T` is inferred from
  the provider, so the generated file still never names your types; that's why `watch` and
  `read` are static and not `ProductRoute(id: 2).watch(ref)`. They build on `readData` and
  `prefetchData`, new on `WidgetRef` (`DataRef`). New reserved names: `watch`, `read`,
  `prefetch`, `ref` and `keepFor` can't be segment names, and a query parameter can't be called
  like a member of the route class (`go`, `read`, `refresh`, ...). Regenerate `app.g.dart`.
* **Section data.** A `data.dart` in a folder that has a `layout.dart` and no `page.dart` (a
  page-less folder or a `(group)`) is the data of the whole section: the layout waits for it,
  showing the nearest `loading.dart` / `error.dart` (`SectionView`), and the layout and the
  pages below can take it by type or as a parameter called `data`. The layout and pages share
  one provider, so `data()` runs once. Two data.dart files yielding the same type for one
  parameter are an error. Segments only, no query parameters.
* **`package:fespalier/testing.dart`**: `pumpRouter(tester, router, {overrides, container,
  settle})` and `currentLocation(tester)`. `fespalier` now lists `flutter_test` (an SDK
  package) as a dependency; the main library doesn't import it.

### Tooling

* `dart run fespalier <command>`: runs the `fsp` release that matches the package's version,
  so nothing needs installing (Windows included). It downloads the release archive on first
  use, checks its SHA-256 and caches it; `FSP_BINARY` runs a binary of your own, and a matching
  `fsp` on PATH is used as is.
* `install.ps1`: installs `fsp.exe` on Windows from PowerShell, like `install.sh`
  (`FSP_VERSION`, `FSP_INSTALL_DIR`, SHA-256 check).
* `fsp routes` prints the route table (pattern, route class, file, tags); `--json` prints one
  object per route, with its parameters, for tools.
* `fsp gen --json` and `fsp check --json` print diagnostics to stdout as JSON lines (file, line,
  column, severity, message) instead of the code-frame rendering, for editors.
* `fsp gen --format`, or `format: true` under `fespalier:` in pubspec.yaml, runs `dart format` on
  the generated file (needs `dart` on PATH). Off by default, so committed output is unchanged.
* CI checks that the versions in `cli/Cargo.toml`, `packages/fespalier/pubspec.yaml`, `fsp init`'s
  `ref:` and the READMEs agree, and that `dart run fespalier` runs a freshly built `fsp`.

### Fixes

* Static routes now sort before dynamic siblings below a page-less folder
  (`shops/new` before `shops/$id`); before, both were kept in folder order and `shops/new`
  could be reported unreachable. Regenerate `app.g.dart`: routes may move.

## 0.1.1 — 2026-09-30

Fixes from first-use testing.

* Generated `data()` providers no longer use Riverpod 3's automatic retry (it took about
  38 s of backoff before `error.dart` showed). `error.dart` now shows at once, and its
  `retry` is the retry path. Providers you write yourself keep Riverpod's default unless
  you pass `retry:`. Regenerate `app.g.dart` to pick this up.
* `fsp watch` no longer regenerates in a loop while idle: it ignores access and metadata
  events and its own output, and stays quiet when a run changes nothing.
* A file the parser can't fully read is now a warning (the Dart compiler reports the exact
  error) instead of passing silently.
* Parameters bound by name (`uri`, `child`, `error`, `stackTrace`, `retry`, `shell`, and
  `transition`'s `key` and `state`) are type-checked.
* Clearer errors: a URL served by two pages is one error naming both files; unreachable
  route and tab-start errors carry a code frame; an invalid `page.dart` no longer also
  warns that its folder has no page.
* `fsp gen`, `fsp check` and `fsp new` print a success line. `fsp new` regenerates right
  away, skips `page.dart` for a `(group)` folder, takes `--no-page`, and lists the files it
  created if generation fails.
* Docs: `GuardResult`, optional `not_found.dart`, deleting the stale `test/widget_test.dart`
  after `fsp init`, tab layouts without a page, retries, and a Testing section.

## 0.1.0 — 2026-09-30

Initial version.

* File-tree routing for Flutter: routes are described by small files under `lib/app/`,
  built on go_router, Riverpod and flutter_hooks, with no build_runner.
* File kinds: `page`, `data`, `loading`, `error`, `layout`, `guard`, `transition` and
  `not_found`. `loading`, `error` and `transition` are inherited by subfolders; `layout`
  becomes a ShellRoute.
* Constructor-based binding: the generator reads each constructor and fills parameters by
  name, by type (the data, the error, the child, the `Uri`) or from the query string.
  There are no base classes or interfaces to implement.
* Path segments (`$id`) and query parameters, typed as `String`, `int`, `double` or `bool`.
  An unparsable segment goes to `not_found.dart`. Files that disagree on a type are an
  error.
* Typed routes (`ProductRoute(id: 42).go(context)`), with `.location` and query
  parameters as optional arguments. Each route with a `data.dart` exposes `XRoute.data`
  as a Riverpod provider, and `refresh(ref)`.
* `data.dart` as a function (`Future<T>`, `Stream<T>` or `T`, wrapped in an autoDispose
  provider) or as your own `FutureProvider`, `StreamProvider`, `AsyncNotifierProvider` or
  `StreamNotifierProvider`.
* `(group)` folders: a layout, loading and error view that apply to a set of routes
  without changing their URLs.
* Tab layouts: a `layout.dart` that asks for a `StatefulNavigationShell` becomes a
  `StatefulShellRoute.indexedStack`, with one branch per subfolder (order set by an
  optional `const tabs = [...]`).
* Route order is static-first (`/about` before `/:slug`). Duplicate URLs and unreachable
  routes are errors.
* `transition.dart`: sets how a folder's routes animate (nearest one wins), with ready-made
  `Transitions`: `fade`, `slide`, `none`, `material` and `cupertino`.
* `fsp` generator (Rust, tree-sitter based): `fsp gen`, `fsp check` (for CI; writes
  nothing), `fsp watch`, `fsp new` (scaffolds route files) and `fsp init` (sets up an
  existing Flutter project without overwriting anything). Errors point at the offending
  parameter or declaration, and `app.g.dart` is left untouched while there are any.
* Optional `fespalier:` section in `pubspec.yaml` to move the app folder (`app_dir`, default
  `lib/app`) and the generated file (`output`, default `lib/app.g.dart`).
* Works with go_router 17 and 18. On go_router 18 with Flutter's `MaterialApp`, routes
  without a `transition.dart` don't animate; see the README's Getting started.
* Output is a single readable `lib/app.g.dart` with `AppRoutes.router()` for a whole app
  and `AppRoutes.mount(at:)` to embed it in an existing GoRouter.
* Prebuilt `fsp` binaries for Linux, macOS and Windows on each GitHub Release, and an
  `install.sh` installer, so installing doesn't need Rust.
