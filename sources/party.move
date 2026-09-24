// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Parties (individuals or groups) that participate in on-chain activities.
///
/// A `Party` is a named, shared identity. Every mutation is gated by its
/// `PartyAdminCap`; `uid_mut` is the extension surface through which other
/// packages attach data as dynamic fields.
///
/// Group membership is consent-based: the group's cap invites, the member's
/// own cap accepts. Pending invites and memberships are dynamic fields on both
/// parties under module-private keys, so no extension can forge or scrub them.
module partyos::party;

use std::string::String;
use sui::derived_object::claim;
use sui::dynamic_field as df;
use sui::event::emit;
use sui::vec_set::{Self, VecSet};

// === Structs ===

/// A party: an individual or a group of individual parties.
public struct Party has key {
    id: UID,
    kind: PartyKind,
    /// Human-readable and unverified; verification is an application concern.
    name: String,
}

/// Authorizes every mutation of one party. Its address is derived from the
/// party under `PartyAdminCapKey`.
public struct PartyAdminCap has key, store {
    id: UID,
    party_id: ID,
}

/// Derivation key for `PartyAdminCap`, holding the party's ID.
public struct PartyAdminCapKey(ID) has copy, drop, store;

// === Dynamic-Field Keys ===

/// On the GROUP: a pending invite to the member with this ID.
public struct PendingInviteKey(ID) has copy, drop, store;

/// On the MEMBER: a pending invite from the group with this ID — the
/// member-facing inbox, discoverable without scanning groups.
public struct PendingMembershipKey(ID) has copy, drop, store;

/// On the MEMBER: membership of the group with this ID. Mirrors the group's
/// member set; the two are always written together.
public struct MembershipKey(ID) has copy, drop, store;

// === Enums ===

/// An individual, or a group holding the IDs of its individual members.
public enum PartyKind has drop, store {
    Individual,
    Group(VecSet<ID>),
}

// === Events ===

/// Emitted once, when a new party is shared, with its final same-transaction
/// name and kind. Members joined before sharing appear as
/// `PartyGroupMembershipAcceptedEvent`s in the same transaction.
public struct PartyCreatedEvent has copy, drop {
    party_id: ID,
    name: String,
    /// 0 for an individual, 1 for a group.
    kind: u8,
}

/// Emitted when the name changes.
public struct PartyNameSetEvent has copy, drop {
    party_id: ID,
    name: String,
}

/// Emitted when a group invites a party.
public struct PartyGroupInviteCreatedEvent has copy, drop {
    group_id: ID,
    member_id: ID,
}

/// Emitted when the invited party accepts and joins.
public struct PartyGroupMembershipAcceptedEvent has copy, drop {
    group_id: ID,
    member_id: ID,
}

/// Emitted when the invited party declines.
public struct PartyGroupInviteDeclinedEvent has copy, drop {
    group_id: ID,
    member_id: ID,
}

/// Emitted when the group revokes a pending invite.
public struct PartyGroupInviteRevokedEvent has copy, drop {
    group_id: ID,
    member_id: ID,
}

/// Emitted when a member leaves with its own cap.
public struct PartyGroupMembershipLeftEvent has copy, drop {
    group_id: ID,
    member_id: ID,
}

/// Emitted when the group evicts a member.
public struct PartyGroupMembershipRemovedEvent has copy, drop {
    group_id: ID,
    member_id: ID,
}

// === Constants ===

/// Maximum number of members in a group.
const MAX_GROUP_MEMBERS: u64 = 200;
/// Maximum party name length in bytes.
const MAX_NAME_LENGTH: u64 = 200;

// === Errors ===

// Authorization errors (0-9)
/// The admin capability does not match this party.
const EUnauthorized: u64 = 0;

// State errors (10-19)
/// Operation requires an individual party.
const ENotIndividualKind: u64 = 10;
/// Operation requires a group party.
const ENotGroupKind: u64 = 11;

// Constraint errors (30-39)
/// Group is full.
const EMaxGroupMembersExceeded: u64 = 30;
/// Name exceeds maximum length.
const EMaxNameLengthExceeded: u64 = 31;
/// Name must not be empty.
const EEmptyString: u64 = 32;

// Conflict errors (40-49)
/// The party is already a member of the group.
const EDuplicateParty: u64 = 40;
/// The party already has a pending invite to this group.
const EAlreadyInvited: u64 = 42;

// Reference errors (50-59)
/// The party is not a member of the group.
const ENotGroupMember: u64 = 50;
/// No pending invite exists for the party in this group.
const ENoPendingInvite: u64 = 51;

// === Public Functions ===

/// Creates a party and its admin cap. The party is `key`-only, so it must be
/// shared in the same transaction.
public fun new(
    kind: PartyKind,
    name: String,
    ctx: &mut TxContext,
): (Party, PartyAdminCap) {
    assert!(!name.is_empty(), EEmptyString);
    assert!(name.length() <= MAX_NAME_LENGTH, EMaxNameLengthExceeded);

    let mut party = Party {
        id: object::new(ctx),
        kind,
        name,
    };
    let party_id = object::id(&party);
    let cap = PartyAdminCap {
        id: claim(&mut party.id, PartyAdminCapKey(party_id)),
        party_id,
    };
    (party, cap)
}

/// Shares the party and emits `PartyCreatedEvent` from its final state.
public fun share(self: Party, cap: &PartyAdminCap) {
    self.authorize(cap);
    emit(PartyCreatedEvent {
        party_id: object::id(&self),
        name: self.name,
        kind: if (self.is_group_kind()) 1 else 0,
    });
    transfer::share_object(self);
}

/// Renames the party. Setting the current name is a no-op: nothing is
/// written and nothing is emitted.
public fun set_name(self: &mut Party, cap: &PartyAdminCap, name: String) {
    self.authorize(cap);
    assert!(!name.is_empty(), EEmptyString);
    assert!(name.length() <= MAX_NAME_LENGTH, EMaxNameLengthExceeded);
    if (self.name == name) return;
    self.name = name;
    emit(PartyNameSetEvent { party_id: object::id(self), name });
}

/// Invites an individual party to a group (group's cap). Writes matching
/// pending markers on both parties; the member joins only through
/// `accept_invite` with its own cap, so no party becomes a member without
/// consent.
public fun invite_party(group: &mut Party, member: &mut Party, group_cap: &PartyAdminCap) {
    group.authorize(group_cap);
    let group_id = object::id(group);
    let member_id = object::id(member);
    let members = group.group_members();
    assert!(member.is_individual_kind(), ENotIndividualKind);
    assert!(!members.contains(&member_id), EDuplicateParty);
    assert!(members.length() < MAX_GROUP_MEMBERS, EMaxGroupMembersExceeded);
    assert!(!df::exists(&group.id, PendingInviteKey(member_id)), EAlreadyInvited);

    df::add(&mut group.id, PendingInviteKey(member_id), true);
    df::add(&mut member.id, PendingMembershipKey(group_id), true);
    emit(PartyGroupInviteCreatedEvent { group_id, member_id });
}

/// Accepts a pending invite (member's own cap): consumes the invite, adds the
/// member to the group's set and records the membership on the member.
public fun accept_invite(group: &mut Party, member: &mut Party, member_cap: &PartyAdminCap) {
    member.authorize(member_cap);
    assert!(group.is_group_kind(), ENotGroupKind);
    let group_id = object::id(group);
    let member_id = object::id(member);
    consume_invite(group, member);

    let members = group.members_mut();
    assert!(members.length() < MAX_GROUP_MEMBERS, EMaxGroupMembersExceeded);
    members.insert(member_id);
    df::add(&mut member.id, MembershipKey(group_id), true);
    emit(PartyGroupMembershipAcceptedEvent { group_id, member_id });
}

/// Declines a pending invite (member's own cap), clearing both markers.
public fun decline_invite(group: &mut Party, member: &mut Party, member_cap: &PartyAdminCap) {
    member.authorize(member_cap);
    consume_invite(group, member);
    emit(PartyGroupInviteDeclinedEvent {
        group_id: object::id(group),
        member_id: object::id(member),
    });
}

/// Revokes a pending invite (group's cap), clearing both markers.
public fun revoke_invite(group: &mut Party, member: &mut Party, group_cap: &PartyAdminCap) {
    group.authorize(group_cap);
    consume_invite(group, member);
    emit(PartyGroupInviteRevokedEvent {
        group_id: object::id(group),
        member_id: object::id(member),
    });
}

/// Leaves a group (member's own cap): the member's unconditional exit.
public fun leave(group: &mut Party, member: &mut Party, member_cap: &PartyAdminCap) {
    member.authorize(member_cap);
    remove_membership(group, member);
    emit(PartyGroupMembershipLeftEvent {
        group_id: object::id(group),
        member_id: object::id(member),
    });
}

/// Evicts a member (group's cap). Scrubs the member's record for this group
/// only; nothing else on the member is reachable without its cap.
public fun remove_member(group: &mut Party, group_cap: &PartyAdminCap, member: &mut Party) {
    group.authorize(group_cap);
    remove_membership(group, member);
    emit(PartyGroupMembershipRemovedEvent {
        group_id: object::id(group),
        member_id: object::id(member),
    });
}

/// An individual party kind.
public fun new_individual_kind(): PartyKind {
    PartyKind::Individual
}

/// A group party kind with no members.
public fun new_group_kind(): PartyKind {
    PartyKind::Group(vec_set::empty())
}

// === Public View Functions ===

public fun name(self: &Party): String {
    self.name
}

public fun is_individual_kind(self: &Party): bool {
    !self.is_group_kind()
}

public fun is_group_kind(self: &Party): bool {
    match (&self.kind) {
        PartyKind::Group(_) => true,
        _ => false,
    }
}

/// The group's member set. Aborts if not a group.
public fun group_members(self: &Party): &VecSet<ID> {
    match (&self.kind) {
        PartyKind::Group(members) => members,
        _ => abort ENotGroupKind,
    }
}

/// Whether `member` holds a membership record for `group_id`. Reads the
/// member side only, so it is the member-gated authorization primitive for
/// extensions.
public fun is_member(member: &Party, group_id: ID): bool {
    df::exists(&member.id, MembershipKey(group_id))
}

/// Whether the group has a pending invite for `member_id`.
public fun has_pending_invite(group: &Party, member_id: ID): bool {
    df::exists(&group.id, PendingInviteKey(member_id))
}

/// Whether the member has a pending invite from `group_id`.
public fun has_pending_membership(member: &Party, group_id: ID): bool {
    df::exists(&member.id, PendingMembershipKey(group_id))
}

// === UID Functions ===

/// The party's UID, for reading dynamic fields.
public fun uid(self: &Party): &UID {
    &self.id
}

/// The party's UID for dynamic-field writes: the extension surface. Requires
/// the admin cap.
public fun uid_mut(self: &mut Party, cap: &PartyAdminCap): &mut UID {
    self.authorize(cap);
    &mut self.id
}

// === Private Functions ===

fun authorize(self: &Party, cap: &PartyAdminCap) {
    assert!(cap.party_id == object::id(self), EUnauthorized);
}

/// The group's mutable member set. Aborts if not a group.
fun members_mut(self: &mut Party): &mut VecSet<ID> {
    match (&mut self.kind) {
        PartyKind::Group(members) => members,
        _ => abort ENotGroupKind,
    }
}

/// Removes a pending invite from both sides. Aborts if none exists.
fun consume_invite(group: &mut Party, member: &mut Party) {
    let group_id = object::id(group);
    let member_id = object::id(member);
    assert!(df::exists(&group.id, PendingInviteKey(member_id)), ENoPendingInvite);
    let _: bool = df::remove(&mut group.id, PendingInviteKey(member_id));
    let _: bool = df::remove(&mut member.id, PendingMembershipKey(group_id));
}

/// Removes a membership from both sides. Aborts if not a member.
fun remove_membership(group: &mut Party, member: &mut Party) {
    let group_id = object::id(group);
    let member_id = object::id(member);
    let members = group.members_mut();
    assert!(members.contains(&member_id), ENotGroupMember);
    members.remove(&member_id);
    let _: bool = df::remove(&mut member.id, MembershipKey(group_id));
}

// === Test Only ===

#[test_only]
public fun created_event_fields(event: PartyCreatedEvent): (ID, String, u8) {
    let PartyCreatedEvent { party_id, name, kind } = event;
    (party_id, name, kind)
}

/// A group pre-filled with `n` fake member IDs.
#[test_only]
public fun new_group_with_n_members_for_testing(
    n: u64,
    ctx: &mut TxContext,
): (Party, PartyAdminCap) {
    let mut members = vec_set::empty();
    n.do!(|_| members.insert(ctx.fresh_object_address().to_id()));
    new(PartyKind::Group(members), b"Test Group".to_string(), ctx)
}
