# Helper acceptance fixtures

These scripts operate on the explicitly prepared helper fixture, never on a trial deployment. Container labels and fixture metadata remain mandatory guards.

Pass `--fixture-root /path/to/helper-fixture` (or `DIFY_E2E_FIXTURE_ROOT`) to both scripts. The directory must contain the prepared `private-fixture` and `d/fixture.json` resources; scripts do not create or infer deployment configuration.

`index_boundaries.py` restarts its fixture container. Pass `--cleanup-lock /path/to/the/shared-machine-cleanup.lock` (or `DIFY_E2E_CLEANUP_LOCK`) using the same lock as other work on that machine. An absent lock argument is an error, so a developer's home directory is never assumed.

Both scripts also require their existing `--out` evidence directory. `--help` lists all arguments without accessing fixture data or Docker.
