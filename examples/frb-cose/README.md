# frb-cose

A fespalier example whose network layer is a Rust core behind flutter_rust_bridge, the CrateStack client that seals every call.

## Screenshots

| Screen                                                                                                                                                                                                                                                       | What it shows                                                                                                                                    |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| ![The frb-cose example's Notes page in a web build with no Rust core: the device key line, The Rust core is not in this build, The core, No notes yet, and a New note field and an Add button, both disabled.](../../docs/images/examples/frb-cose/home.png) | In a web build there is no Rust core, so the page makes no call and keeps nothing: the field and the button are disabled, and the line says why. |
| ![The Rust core page in a web build: its title, and the line Not built for the web, which says there is no key, no registration and no journal.](../../docs/images/examples/frb-cose/core.png)                                                               | The core page of a web build: no key, no registration and no journal, and no request.                                                            |

A release web build in Chromium, 390 × 844 CSS pixels at 2× (`just example-screenshots frb-cose`). The web build has no Rust core (the build hook builds none for the web), so no call is made.
