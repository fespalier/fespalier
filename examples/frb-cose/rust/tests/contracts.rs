//! The client of the example's schema and the server expand the same contracts (plan section 10). A drift between
//! the two macro expansions fails this test, not only the end-to-end one.

#![allow(clippy::expect_used, clippy::unwrap_used, reason = "tests may unwrap")]

use frb_cose_core::core::OPS;
use frb_cose_core::core::client::cratestack_schema;
use frb_cose_demo_server::{REGISTER_OP, cratestack_schema as server};

#[test]
fn the_client_and_the_server_expand_the_same_op_contracts() {
    assert_eq!(cratestack_schema::OP_CONTRACTS, server::OP_CONTRACTS);
}

#[test]
fn every_op_the_core_accepts_is_a_procedure_of_the_server() {
    for op in OPS {
        let key = format!("procedure.{op}");
        assert!(
            server::OP_CONTRACTS.iter().any(|(name, _)| *name == key),
            "{key} is not in the server's contracts"
        );
    }
}

#[test]
fn the_registration_is_plain_and_the_core_does_not_accept_it_as_an_op() {
    assert!(!frb_cose_demo_server::is_signed(REGISTER_OP));
    assert!(
        !OPS.iter()
            .any(|op| format!("procedure.{op}") == REGISTER_OP)
    );
}
