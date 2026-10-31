/// Hex-encoded SHA-256 of the `.cstack` schema source this client was
/// generated from (issue #178). Sent as `x-cratestack-schema-sha` on
/// every outgoing request so the server-side drift-detection middleware
/// (`cratestack-axum::schema_fingerprint`) can warn when a client and
/// server were generated from different copies of the schema — it never
/// rejects a request, only logs. `null` when the generator wasn't given
/// a schema hash (e.g. this crate used as a library directly, bypassing
/// `cratestack generate-dart`), in which case every runtime adapter
/// omits the header entirely rather than sending an empty value.
// The nullable type below is structurally correct across the space of
// possible generator configs (see the doc comment above) even though it's
// provably non-null for this one generated instance — narrowing it would
// break the no-hash case, which is a real, exercised code path.
// ignore: unnecessary_nullable_for_final_variable_declarations
const String? cratestackSchemaSha256 =
    'e6206303fa9ea2569ba0ec5fc3de6c770cdcd2836e50f393a93e4da7a96271eb';

/// Per-op contract digests (binding version 2, cratestack#1123): what a
/// signed request to each op binds into its COSE AAD, keyed like the Rust
/// client's `OP_CONTRACTS` (the RPC op id, or `<METHOD> <route template>` on
/// REST, plus `batch` for `transport rpc`), as lowercase hex. Computed by the
/// same `cratestack_core` function the Rust macros call, so the two cannot
/// disagree. The unsigned runtime does not read them; a sealer does.
const Map<String, String> cratestackOpContracts = <String, String>{
  'batch': '12c4cf4c616d25469b34c8fe9f554819afcabe2da84cdfc2fe13e4ffac749edf',
  'procedure.account':
      'f20965a59d0d3ba7fd2370926b42291806835ecce05e2cde54d6116120741eab',
  'procedure.beginEnrolment':
      '8ab2d7f3258450f6bfa386a7dc58400770f3124bc234b61422dc1c5f1aaf6188',
  'procedure.beginRenewal':
      'cd6e5940e155d7e22ace0cdad9577dde996ddebe8428c3e718b2b89b0fd9fadb',
  'procedure.confirmEnrolment':
      '140ffef01b377daa6c6b7924f5f438b2d23c0405134942891e30b66ebf55072f',
  'procedure.confirmRenewal':
      '1b1fec5dc3ac2ebf59b42e5580654c474751938f40ed6d366de3023c19f51e18',
  'procedure.getOrder':
      '1a09aa27f08042be5ed9695e03b2b64adfb85d82f371c22b8f17200ae0d0904d',
  'procedure.listOrders':
      '73441de797dde80eb377be51e687e5c34e97f30e0bcf6c14a622601cf2837655',
  'procedure.payOrder':
      '09f7d9fda0b4fbe24e1036d92649a332438ae8f6c4ef3f2aed3a6b8b84fd310b',
  'procedure.placeOrder':
      'ff1e2d297138d6297ae5da295eeffb244e8913ceaa27528b4f5813d9e9ed89d6',
  'procedure.revokeDevice':
      'c10fb1e4b628eb5ea0f207be8dfcad611ab6adc8714e3be611cc91289a442d9e',
};

/// Hex of the whole-contract digest: moves when any op's contract does.
const String cratestackClientContractSha256 =
    '12c4cf4c616d25469b34c8fe9f554819afcabe2da84cdfc2fe13e4ffac749edf';
