//! The `CrateStack` client of the example's schema.
//!
//! `include_client_schema!` reads `server/schema.cstack`, the schema the server is built from. The procedures,
//! their argument types and `OP_CONTRACTS` come from the same macro on both sides, so a change to the schema
//! moves the client and the server together.

cratestack::include_client_schema!("../server/schema.cstack");
