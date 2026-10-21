# M2a files acceptance

Build the server production image from docker/Dockerfile.server, then run:

    python3 e2e/files/http_restart.py --image dify-sf-server --dify-source /path/to/dify-1.17.1 --output /path/to/private-evidence

Use Dify commit 8387590ace4a094de812b7847fc6a4c3a27cd52b. The runner checks the original source digest and
executes its signing/verifying methods with import context replaced by the same generated configuration.
It creates an isolated capped Postgres container, private network, capped production server and private storage
directory. The signing secret and account password are generated inside the test and never printed.
Only the temporary secret file and containers/network are removed; byte/result evidence remains in --output.
The default loopback port is 19098 (override --port if occupied).

Checks include real multipart upload, UTF-8 preview, anonymous signed delivery, ranges/ETag/If-Range,
Dify-to-Swift and Swift-to-Dify signatures, expiry/type separation, SIGKILL plus a new process over the same
database/storage, and graceful shutdown plus a second restart. No shared development database is used.

Client UI: integration_test/files_flow_test.dart in the client checkout runs real Linux UI against a fresh
test server, with only the OS chooser substituted. Set DIFYSF_FILES_SERVER/EMAIL/PASSWORD and optionally
DIFYSF_FILES_EVIDENCE, then use xvfb-run flutter test integration_test/files_flow_test.dart -d linux.
