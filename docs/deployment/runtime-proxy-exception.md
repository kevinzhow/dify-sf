# Preparing a single runtime destination exception

The default HTTP-node and sandbox proxy denies private destinations, including Tailscale's IPv4 `100.64.0.0/10` range.
Keep that default. A deployment that explicitly authorizes one internal service can prepare a narrowly scoped exception
with the existing Squid proxy; the application runtime does not bypass it.

`tool/prepare_runtime_proxy_allowlist.py` reads a known configuration and writes a **new review file**, never installs
or overwrites the live one. It requires the freshly inspected API-container source IPv4 address, one destination
Tailscale IPv4 address and one already-safe destination port. It refuses networks, hostnames, public destinations,
privileged unsafe ports, unknown policy ordering and accumulating prior exceptions.

The generated allow rule intersects all three ACLs: source `/32`, destination `/32` and exact port. It follows the
existing unsafe-port denial and precedes the CONNECT/private-destination denial. Thus HTTPS on an explicitly approved
nonstandard port does not add that port to `SSL_ports` for every destination. Other sources, addresses and ports keep
the existing policy. Squid evaluates a redirect's destination as another request through the proxy.

Before enabling an approved proposal:

1. Obtain the exact service address, port, HTTP/HTTPS scheme and intended health endpoint; keep existing tailnet access
   controls and certificate validation. Do not substitute a guessed endpoint.
2. Resolve the configured proxy hostname inside the API container, then inspect the interface used to reach that
   address and the mounted proxy configuration. Two containers can share several networks: do not select the first
   common network. Generate a diff and run Squid's syntax check on an isolated instance. Check that no unrelated ACL
   changed. Container recreation or a DNS/interface change can change the source; regenerate the rule
   rather than broadening to a subnet.
3. In an isolated proxy, verify the approved source/destination/port succeeds, neighboring address/port and another
   source fail, loopback and other private networks fail, and a redirect to those targets fails.
4. Apply only under that deployment's explicit authorization, retain its rollback configuration and receipt, and check
   reachability from the API container through the proxy. Preparing this file does not authorize applying it.

For slow services, submit work and poll by task ID. The supplied Squid configuration has a 120-second read timeout;
use a bounded poll (for example 90 seconds) and explicit node timeouts with margin. Give the workflow a bounded number
of rounds and preserve a still-pending job ID on exit. A transient HTTP error must not trigger a fresh costly job unless
the service's idempotency contract permits that retry. HTTP-node `body` is text: parse JSON explicitly before selecting
fields. Do not place access tokens in URLs or print them in request/response logs.

No live exception is installed by this change. A prepared rule and a syntax check do not prove connectivity to an
as-yet unspecified destination.

Run the proposal generator checks with `python3 tool/test_prepare_runtime_proxy_allowlist.py -v`. These checks cover
configuration structure and invalid arguments; the isolated network tests above remain required before activation.
