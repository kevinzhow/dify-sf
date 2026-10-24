# Tailnet HTTPS trial

Trial devices connect to Tailscale first, then open the machine's `https://<machine>.<tailnet>.ts.net/` directly in the browser. Tailscale Serve terminates HTTPS and forwards to a loopback-only nginx gateway. The gateway serves a frozen Web build and proxies `/v1/` to the existing API, including event streams and signed file downloads. Fresh Web clients use that same origin by default; a saved server or explicit `server` query still takes precedence. Native clients keep their existing default.

This is Serve within the tailnet. Do not enable Funnel. Access from devices outside the tailnet requires a separate explicit decision.

## Set up

1. Build and verify the complete release Web package (`--wasm --no-web-resources-cdn`), including the repository's bootstrap policy. Freeze the output in a versioned directory and retain the previous directory.
2. Render the nginx configuration:

   ```sh
   python3 tool/tailscale_gateway.py --api-origin http://127.0.0.1:19097 \
     --listen-port 19197 --output /path/to/nginx.conf
   ```

   Use the API's actual listening address. It need not be loopback; the gateway itself binds only loopback. The generated config requires the standard nginx MIME table.
3. Run a pinned nginx image with host networking, a read-only config mounted at `/etc/nginx/nginx.conf`, and the frozen build mounted at `/srv/web`. Use a non-root UID, drop all capabilities, enable `no-new-privileges`, cap memory/CPU/PIDs, and supply a bounded writable `/tmp` tmpfs. All nginx temporary paths are below `/tmp`. Set `--restart unless-stopped`.
4. An authorized machine operator runs once:

   ```sh
   sudo tailscale serve --bg --https=443 http://127.0.0.1:19197
   ```

   Read `tailscale serve status --json` and confirm port 443 forwards to the intended loopback port. Confirm no `AllowFunnel` entry is enabled. HTTPS issuance may take a short time; verify without bypassing certificate validation.
5. Open the HTTPS address directly, without the old `server=http://...` query. A fresh origin should use HTTPS for `/v1/` requests, streams, and files. If this device deliberately saved an old HTTP backend, change its server setting to the HTTPS origin.

## Acceptance and recovery

Verify certificate validation, anonymous authorization refusal, `/healthz`, deep-link fallback, correct Wasm MIME type, and asset hashes. Against an isolated backend, test login, a live event stream, multipart upload and signed download through the same rendered proxy configuration. Stop/restart the gateway and recheck service health and frontend hashes. Keep real user accounts and stored workflows out of test fixtures.

Persist both Docker and Tailscale services across reboot. Updating the frozen Web mount does not require changing Serve configuration. Save the exact image digest, launch arguments, config hash and frozen-directory manifest with each deployment.

Rollback by replacing only the gateway's image/config/frozen mount with the previously recorded launch arguments, on the same loopback port. Preserve the existing API container, database, uploads, application encryption keys and file signing keys. A frontend rollback never restores an old database over newer user writes. Verify HTTPS health and asset hashes again. The earlier HTTP trial may remain available during this transition; it is unsuitable for Safari performance acceptance.

## Safari performance

Use a direct HTTPS navigation for iOS Web performance comparisons. A script navigation from an HTTP page may retain an existing enhanced-security process. The browser reporting a secure context alone does not prove that JIT acceleration is enabled. Record actual renderer and operating system alongside timing evidence; simulator results are not physical-device frame rates. See [the client deployment notes](../client.md) for the recorded investigation.
