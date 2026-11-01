# Run dify-sf on your own server

`deploy/selfhost` starts everything a team needs on one machine, behind one address:

| service | what it does |
|---|---|
| `gateway` | Caddy: serves the web client and passes `/v1` and `/files` to the server; for HTTPS on a domain, obtains and renews the certificate |
| `server` | the dify-sf server (collaborative editing, accounts, runs, published apps, files) |
| `postgres` | its database (and the plugin daemon's) |
| `plugin_daemon`, `redis` | Dify's plugin daemon: model providers and tools |
| `sandbox`, `ssrf_proxy` | Dify's code sandbox for code and template nodes; its only way out is a proxy that refuses private addresses |
| `agent_service`, `sandbox_supervisor`, `agent_sandbox_proxy`, `codex_gateway` | optional (`./enable-agent.sh`): Agent v2 nodes and their shell sandboxes; `codex_gateway` only with Codex |

Only the gateway's ports are published. The web client, the Linux desktop app and the Android app all talk to the same
address.

## What you need

* A Linux machine with Docker Engine and Docker Compose v2. 2 CPUs and 4 GB of memory run a small team; building the
  images once needs about 6 GB of memory and 15 GB of disk, and takes 20 to 40 minutes.
* Internet access during the build and for installing model provider plugins.
* For HTTPS with a certificate from Let's Encrypt (optional): a domain name whose DNS record points at the machine, and
  ports 80 and 443 reachable from the internet.

## Install

```sh
git clone https://github.com/kevinzhow/dify-sf.git
cd dify-sf/deploy/selfhost
./init.sh http://192.168.1.20      # the address people will open; writes .env with fresh random keys
docker compose up -d --build
```

Open the address. The first visit asks for the owner account (email, name, password); after that, people sign in or
are invited from **Settings → Members**. Add model providers in **Settings → Model Provider** (the bundled providers
install from there) and start building.

Whether to use HTTPS is your choice; `init.sh` takes the address people open:

| address | what you get |
|---|---|
| `http://192.168.1.20`, `http://dify.lan:8080` | plain HTTP on that port, for any host name or IP address; no certificate. Passwords and data travel unencrypted: keep it to networks you trust (a LAN, a VPN). |
| `https://dify.example.com you@example.com` | HTTPS: Caddy obtains and renews a certificate from Let's Encrypt (the email, optional, gets expiry notices). Needs the domain's DNS record and ports 80 and 443. |
| `https://dify.example.com --behind-proxy` | your own reverse proxy does HTTPS and forwards plain HTTP to this machine's port 80 (`HTTP_PORT` in `.env`). It must not buffer responses: editing and runs stream their events. Links the server hands out use the address you gave `init.sh`. |

## Clients

* **Browser**: open the address. The web client talks to the server on the same origin.
* **Android and Linux desktop apps**: enter the same address (`http://192.168.1.20` or `https://dify.example.com`) as
  the server.

## Settings

Everything lives in `deploy/selfhost/.env` (see `.env.example`); after a change, `docker compose up -d`.

* **Mail** (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_TLS`, `MAIL_FROM`): password reset,
  invitations by mail and mailed human-input forms. Without it, invitations give you a link to pass on yourself.
* **Agent v2 nodes**: see the next section.
* `PIP_MIRROR_URL`: a Python package mirror for plugins and the sandbox. `COLLAB_MODELS_VALIDATE=false` for a machine
  without internet access to the model providers.

## Agent v2 nodes (optional)

```sh
./enable-agent.sh            # or ./enable-agent.sh --codex
docker compose up -d --build
```

`enable-agent.sh` pulls the sandbox image and sets `AGENT_ENABLED=true` and `COMPOSE_PROFILES=agent` in `.env`. That
starts the agent service, the sandbox supervisor and the package proxy, and gives Agent nodes a shell: one sandbox
container per agent execution, which the supervisor creates through the Docker socket. Enable it only where that is
acceptable. `DOCKER_GID` is the socket's group (`init.sh` fills it in); the sandboxes' networks come from
`AGENT_SANDBOX_SUBNET_POOL` (default `10.213.0.0/16`), which must not overlap networks the machine reaches.

An Agent node runs one of two harnesses (the Soul's `harness_style`, see [Agents](agents.md)):

| harness | what it needs |
|---|---|
| `dify` (default) | `./enable-agent.sh` and a tool-capable model of the workspace. |
| `codex` (the official Codex CLI) | `./enable-agent.sh --codex` on an x86_64 machine, and a model on the Responses wire: OpenAI, DeepSeek, or an OpenAI-API-compatible model whose API Type is Responses. The script downloads the Codex release the agent service pins from GitHub, checks its SHA-256, writes `executor-profiles.json` (the default profile mounts Codex read-only) and adds `codex.yml` to `COMPOSE_FILE`. Without internet access, download the release archive (`codex-x86_64-unknown-linux-musl.tar.gz` of the pinned version) elsewhere and pass it: `CODEX_ARCHIVE=/path/to/archive ./enable-agent.sh --codex`. |

Sandboxes reach only PyPI and npm, through `agent_sandbox_proxy` (`docker/agent_sandbox_proxy/allowlist.txt`), with or
without Codex. Codex's model calls go to `codex_gateway`, which passes only the Codex route to the server; the provider
keys stay in the server. They use the HTTP transport, for every provider: each model call sends the whole conversation
again, and a request may carry at most 128 MiB (96 MiB of files) through the gateway and the server; providers may
accept less. Long sessions with large images can reach that limit. The Responses WebSocket transport, which sends only
the new input after the first call (official OpenAI endpoint, [Agents](agents.md) 6.10), is not part of the kit yet.

To turn Agent nodes off: in `.env` set `AGENT_ENABLED=false`, empty `COMPOSE_PROFILES` and drop `:codex.yml` from
`COMPOSE_FILE`; then `docker compose --profile agent rm -sf agent_service sandbox_supervisor agent_sandbox_proxy
codex_gateway` and `docker compose up -d`.

## Update

```sh
git pull
docker compose up -d --build
```

The server migrates its database on start. Read the release notes before updating across versions.

## Back up and restore

Back up `.env` together with the data: `COLLAB_SECRETS_KEY` decrypts the stored model credentials and secret
variables, and without it they cannot be recovered.

```sh
docker compose exec -T postgres pg_dumpall -U collab > backup.sql          # accounts, workflows, runs, plugin state
docker run --rm -v dify-sf_file_uploads:/data -v "$PWD":/out alpine tar czf /out/files.tgz -C /data .
docker run --rm -v dify-sf_plugin_storage:/data -v "$PWD":/out alpine tar czf /out/plugins.tgz -C /data .
```

To restore on a new machine: the same `.env`, `docker compose up -d postgres`, `docker compose exec -T postgres psql
-U collab -d postgres < backup.sql`, the two archives back into their volumes, then `docker compose up -d`.

## When something is wrong

* `docker compose ps` shows each service's health; `docker compose logs -f server gateway` the details.
* No certificate: the DNS record must point at this machine and ports 80 and 443 must be reachable from the internet
  (`docker compose logs gateway` names the problem).
* Code nodes fail: `docker compose logs sandbox ssrf_proxy`. Model nodes fail: the provider's plugin must be installed
  and its credentials saved (Settings → Model Provider).
