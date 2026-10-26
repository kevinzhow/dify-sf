# Agent log and maintenance hardening

This is a dify-sf extension to the inline workflow adapter. It changes event
persistence and diagnostics; it does not introduce another model or tool loop.

Reasoning text is a logical stream across event boundaries. Before any event is
archived or broadcast, a per-operation writer masks complete environment values,
an incomplete matching suffix, and its continuation in later chunks. Unicode
scalars, overlapping secrets and one-scalar events are supported. An ambiguous
suffix is deliberately redacted even when later text disproves the match; public
records cannot be corrected after a secret has already been disclosed. The KMP
matcher and range marking remain linear per configured value. Object keys,
nested values and tool labels also pass through the existing projection filter.
The stream state advances only after the database accepts the event.

Only the immutable event insertion is retried: at most four attempts, with
100/200/400 ms delays inside the existing database operation deadline. Connection
failures, serialization/deadlock and selected temporary availability errors are
eligible. Permissions, disk-full, cancellation and ownership failures are not.
Each attempt checks the same owner/operation/generation and uses the same unique
event key, including after an uncertain commit. A database failure never enters
the HTTP reconnect handler or starts a second model/tool operation.

Previews retain the beginning and end of long logs, with a gap marker linking to
the complete member-authorized JSONL archive. The complete JSON/UTF-8 array stays
within 256 KiB. Reverse keyset paging bounds the tail lookup. Recovery catches an
individual remote orphan, expired execution or terminal cleanup failure and
continues with the other records; failed work remains eligible for a later pass.

`GET /v1/system-features` now returns a small `build` object beside the actual
capability switches. `COLLAB_BUILD_REVISION` supplies its immutable release commit;
only 12–40 hexadecimal characters are accepted, otherwise the public value is
`development`. Protocols and the client manifest path are included. Environment
values, paths, service URLs and credentials are never part of this object.

Validation uses a separate PostgreSQL instance and real HTTP endpoints:

- Every split of ASCII/CJK/emoji secrets, single-scalar chunks and overlapping
  prefixes; a 200,000-character repeated prefix; nested values, keys and labels.
- PostgreSQL triggers inject two serialization errors before a successful single
  row commit; persistent failures stop after four attempts, and SQLSTATE `53100`
  stops after one. A non-transactional sequence counts actual attempts.
- A failing first orphan cancellation does not prevent the next owned orphan's
  cancellation/cleanup; foreign identities remain untouched.
- 4,105 archived events exceed 8 MiB; both first and last logs survive in the
  bounded preview, the complete archive requires authorization, and duplicate
  event keys remain single rows.

The focused suite passes 19 tests across eight suites. Earlier restart/side-effect
acceptance remains separate evidence; this focused suite is not a substitute for
the final release's restart, upgrade and browser acceptance.
