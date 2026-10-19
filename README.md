# dify-sf client

The Flutter client of dify-sf, a reimplementation of Dify 1.17.1's workflow studio whose collaboration never loses
an acknowledged edit. This branch holds the pure-Dart collaboration library (`packages/collab_client`) and the
Flutter app (`app/`, Linux desktop and web) that replicates Dify's workflow editor. The server lives on the `main`
branch.

<!-- features:begin -->
## Feature parity with Dify 1.17.1

289 features of Dify 1.17.1's workflow editor and the pages around it, tracked one by one in [docs/features.md](docs/features.md) (generated from `tool/features/features.yaml`):

| Status | Features |
|---|---|
| ported | 176 |
| partial | 47 |
| not ported | 36 |
| n/a | 17 |
| dify-sf only | 13 |

Per area, with the reason for everything not ported: [docs/features.md](docs/features.md).
<!-- features:end -->

## Documentation

* [`docs/features.md`](docs/features.md) - feature parity with Dify 1.17.1: what is ported, what is not, and why.
* [`docs/client.md`](docs/client.md) - architecture, how to build, run and test, results, known gaps.
* [`docs/protocol.md`](docs/protocol.md) - the collaboration protocol the client implements.
* [`docs/replica-plan.md`](docs/replica-plan.md) - how the Dify editor replica is built and verified.

## Updating the feature list

The list's source of truth is [`tool/features/features.yaml`](tool/features/features.yaml); `docs/features.md` and
the block above are generated from it. When a merge adds, completes or changes a feature, update its entry in the
same change (one entry per feature: `status`, `reason` / `deviation`, `evidence`, `ours`), then:

```sh
python3 tool/features/gen.py                       # regenerate docs/features.md and the README blocks
python3 tool/features/gen.py --check               # what CI / review runs: fails on a stale or invalid list
python3 tool/features/gen.py --check --dify <dify-src>   # also checks the Dify paths and the spec ledger's case list
```

The check fails when a feature lacks a required field, a non-ported feature has no reason, an id repeats, an
evidence path, visual case or spec does not exist, a Dify spec directory known to `tool/dify_spec/ledger.py`
(`tool/dify_spec/cases.txt`) is named by no feature, or a generated file is stale. When the server repository is
checked out next to this one (`../dify-sf`), its README's block is regenerated and checked too (or pass
`--readme <path>`).

## Design-system check

UI is built from `app/lib/src/design/` first. Run this next to `tool/features/gen.py --check` (CI / before merging):

```sh
python3 tool/design/check.py               # fails on a new literal colour, raw TextStyle, Material widget, ... outside design/
python3 tool/design/check.py --update      # after removing hits: tighten tool/design/allowlist.tsv (never raises a count)
```

Rules, exceptions and the reason vocabulary: [`tool/design/README.md`](tool/design/README.md).
