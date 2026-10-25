# Pending approval form file links

A form may wait longer than a storage URL's 300-second lifetime. The current image returns its saved Markdown when the form is reopened, so its signed image URL remains expired even though the form is still active. An isolated copy of the same immutable server image reproduced this after 362 real seconds: initial image 200 with exact PNG bytes; reopened definition 200, unchanged image URL, image 404.

Dify 1.17.1 at `8387590ace4a094de812b7847fc6a4c3a27cd52b` has the same stored-definition behavior by source inspection (`api/core/workflow/nodes/human_input/callback.py`, `api/core/repositories/human_input_repository.py`, `api/services/human_input_service.py`, `api/controllers/console/human_input_form.py`). We did not run the upstream six-minute experiment. Freshening is an intentional dify-sf presentation extension.

The candidate reuses `projectRuntimeFiles`, the existing workspace/public-visitor scope, durable file IDs and blob checks. For an active runtime form it renders a presentation copy using its own paused execution's variable pool. Authorized GET and both paused replay frame types share the helper. Saved form, decision, pool, token and deadlines are unchanged. An old URL still expires; a deleted or foreign file gets no usable URL. Literal external URLs and forms without a durable runtime pool remain unchanged. No remote URL is downloaded on read. Submitted and expired form checks remain in the existing routes.

The proxy work produces a review file only: one source IPv4, one tailnet destination IPv4, one port, intersected with existing safety rules. It does not edit or reload a live proxy. The three policy-generator tests and an isolated parse with the installed Squid image passed; these do not prove real endpoint connectivity or authorize activation. The private deployment receipt holds actual addresses and must be revalidated if routes, DNS or container addressing change.

Model availability was inventoried read-only. The installed DeepSeek plugin and server catalog declare vision for the selected deepseek-flash model; that declaration is not evidence of a successful image inference. No credential was decrypted or exposed, and no paid model was called.

## Validation

- The identical deployed-image fixture waited 362 real seconds, then reproduced definition 200 / unchanged signed image 404. The source regression also failed before the fix. An earlier malformed Start-variable fixture was excluded; a separate creation-status assertion was corrected from 200 to 201. Original failure logs remain preserved.
- Two real-Postgres file-route tests passed: fresh authorized GET and both paused frame representations, old URL expiry, unchanged persisted form/template/pool/deadline, console anonymity rejection, literal URL/no-pool/closed behavior, deleted blobs and foreign-public-visitor file scopes.
- Full server: **472 tests in 100 suites passed**, 489.166 seconds.
- An ordinary release build without `-enable-testing` completed. Executable SHA256 `a151387f2b12b628ec65240f67f90f8e07f609c44eac5b02429b87b418b069ad`, built from clean `9fabaa0a72a9125d4664ee5f53f0a674a6dc8c20`. Runtime/model resources are reused unchanged from the fixed deployed base; this is an executable-layer rebuild, not a new full Dockerfile.server build. Image `sha256:b9e80d2da6b836108917c7c9de301d740f5c07d97a60e230f93f7b811d82e4b4`.
- That immutable image reopened the **same original** >6-minute paused form using its original isolated database/uploads: fresh image 200 with exact PNG bytes, both replay forms fresh, old URL still 404, saved form unchanged on reads, anonymous console token 404, normal approve reaches succeeded, submitted form 412. Actual trial data were never used as a fixture.
- Three proxy-generator tests passed, installed Squid syntax parse passed, and ten isolated network-namespace checks passed (allow exact GET/CONNECT; reject other source, neighbor address/port, loopback, other private destinations, unsafe port and a forbidden redirect). These do not prove actual deployment connectivity or authorize an exception.
- The merged visual main was incorporated after verification; the server tree remains byte-for-byte identical to the tested server source. Only documentation records were added afterward.

## Deployment scope

The file-presentation fix may be merged and the trial backend updated after the announced verification. The proxy exception is a separate decision: it remains a proposal until explicit approval, with its private deployment receipt revalidated immediately before any activation. Frontend changes are not required for this server fix. Existing signing/encryption keys, database/uploads, user records, approval lifetimes and the disabled email setting must be preserved.
