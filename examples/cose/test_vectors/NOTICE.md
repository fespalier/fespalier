# Vendored test vectors

`unary.json` and `keys.json` are copied unchanged from the `cratestack-cose` crate, version 0.15.3
(`tests/vectors/`), <https://github.com/cratestack/cratestack>, MIT licence, copyright the
CrateStack contributors. They pin cratestack's COSE_Sign1 binding (external AAD version 2,
protected header layout, `kid`) byte for byte; `lib/src/cose/` is checked against them in
`test/cose/`.

The keys in `keys.json` are test keys published in that repository. Never use them outside tests.

Permission is granted, free of charge, to use, copy and distribute these files, subject to the MIT
licence conditions: this copyright notice and permission notice are kept in all copies or
substantial portions.
