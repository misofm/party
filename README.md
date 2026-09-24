# partyos

[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Move](https://img.shields.io/badge/Move-2024-black.svg)](https://docs.sui.io/concepts/sui-move-concepts)

> On-chain party identity for [Sui](https://sui.io).

`partyos` provides a reusable identity primitive for protocols that need to
represent people, groups, and organizations:

- **`Party`** — a named, capability-authorized identity that can represent an **individual** or a **group** of parties. Parties are extensible (other packages can attach data via dynamic fields) and own their lifecycle through a `PartyAdminCap`.

## Concepts

### Party

```move
let (party, cap) = party::new(party::new_individual_kind(), b"Ada".to_string(), ctx);
party.share(&cap); // make it a shared object
```

- Creation and sharing complete in one transaction. `new()` is silent; `share()` emits one `PartyCreatedEvent` from the final pre-share state.
- Individual or group (`new_individual_kind()` / `new_group_kind()`); groups hold member party IDs.
- All mutations, including naming and consent-based group membership, require the appropriate `PartyAdminCap`. Setting the name to its current value is a silent no-op.
- Extensible: holders of the cap can reach the party's `&mut UID` (`uid_mut`) to attach domain data.

### Events

Events carry only what an indexer cannot derive from the event type, the
transaction envelope, or earlier Party events:

| Event | Fields |
|---|---|
| `PartyCreatedEvent` | `party_id`, `name`, `is_group` |
| `PartyNameSetEvent` | `party_id`, `name` |
| `PartyGroupInviteCreatedEvent`, `…InviteDeclinedEvent`, `…InviteRevokedEvent` | `group_id`, `member_id` |
| `PartyGroupMembershipAcceptedEvent`, `…MembershipLeftEvent`, `…MembershipRemovedEvent` | `group_id`, `member_id` |

The admin cap's id is derived from the party id under `PartyAdminCapKey`; the
sender, epoch and creation time come from the transaction. Members that join before `share()`
appear as `PartyGroupMembershipAcceptedEvent`s in the same transaction, so a
party's name, kind, member set and pending invites are all replayable from
events alone.

## Install

```toml
[dependencies]
partyos = { git = "https://github.com/misofm/partyos.git", rev = "<commit-sha>" }
```

Pin `rev` to the exact commit reviewed by your application. Party profile and
presentation slices live in
[misofm/partyos-extensions](https://github.com/misofm/partyos-extensions).

## TypeScript SDK

Party bindings, reads, and composable transaction builders are included in
[`@misofm/protocol`](https://github.com/misofm/sdks) and are exposed through
`client.miso.party`. This repository no longer publishes a separate TypeScript
package.

## Build & test

```sh
sui move build
sui move test
```

## Contributing

Issues and pull requests are welcome. By contributing you agree that your contributions are licensed under the project's Apache 2.0 license.

## License

[Apache 2.0](LICENSE) © Miso Labs, Inc.
