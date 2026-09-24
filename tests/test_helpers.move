#[test_only]
module partyos::test_helpers;

use partyos::party::{Self, Party, PartyAdminCap, PartyKind};
use std::string::String;

/// An individual party named "Test Artist".
public fun individual(ctx: &mut TxContext): (Party, PartyAdminCap) {
    individual_named(b"Test Artist".to_string(), ctx)
}

/// An individual party with the given name.
public fun individual_named(name: String, ctx: &mut TxContext): (Party, PartyAdminCap) {
    new_party(party::new_individual_kind(), name, ctx)
}

/// An empty group party named "Test Group".
public fun group(ctx: &mut TxContext): (Party, PartyAdminCap) {
    new_party(party::new_group_kind(), b"Test Group".to_string(), ctx)
}

/// `len` bytes of 'A'.
public fun long_string(len: u64): String {
    let mut s = vector<u8>[];
    len.do!(|_| s.push_back(65));
    s.to_string()
}

fun new_party(kind: PartyKind, name: String, ctx: &mut TxContext): (Party, PartyAdminCap) {
    party::new(kind, name, ctx)
}
