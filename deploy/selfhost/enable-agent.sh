#!/usr/bin/env sh
# Turns on Agent v2 nodes in deploy/selfhost/.env (run ./init.sh first), then `docker compose up -d --build`.
#
#   ./enable-agent.sh            Agent nodes with Dify SF's own agent loop (harness `dify`) and a shell sandbox
#   ./enable-agent.sh --codex    also the official Codex CLI, for nodes with `harness_style: codex` (x86_64 hosts)
#
# The sandbox supervisor gets the Docker socket and starts one container per agent execution: enable this only where
# that is acceptable. With --codex the script downloads the Codex release the agent service pins (from GitHub, or the
# archive in CODEX_ARCHIVE for a machine without internet access), checks its SHA-256 and puts it in ./codex/<version>/.
set -eu
# A relative CODEX_ARCHIVE is relative to where the script was started.
case "${CODEX_ARCHIVE:-}" in ''|/*) ;; *) CODEX_ARCHIVE=$(pwd)/$CODEX_ARCHIVE ;; esac
cd "$(dirname "$0")"
fail() { echo "$*" >&2; exit 2; }

codex=""
for a in "$@"; do
  case "$a" in
    --codex) codex=yes ;;
    *) fail "unknown argument: $a (use --codex or nothing)" ;;
  esac
done
[ -f .env ] || fail "no .env here: run ./init.sh first"

# Must match SANDBOX_IMAGE in docker-compose.yml.
sandbox_image=langgenius/dify-agent-local-sandbox:1.17.1@sha256:f4d404c9dcdf80bd72f65e84c3f2bbd1f3404fd4b363db837176da8aaf771b1d

# Sets KEY=VALUE in .env (replacing the line, or appending it).
set_env() {
  if grep -q "^$1=" .env; then
    sed -i "s|^$1=.*|$1=$2|" .env
  else
    printf '%s=%s\n' "$1" "$2" >> .env
  fi
}

echo "Pulling the sandbox image (the supervisor never pulls)..."
docker pull -q "$sandbox_image" >/dev/null

if [ -n "$codex" ]; then
  [ "$(uname -m)" = x86_64 ] || fail "the pinned Codex build is x86_64 Linux; this machine is $(uname -m)"
  # The release the agent service checks for (version and SHA-256 of the binary).
  pin=../../agent_service/lib/src/harness/codex/official.dart
  version=$(sed -n "s/^const officialCodexVersion = '\([0-9.]*\)';/\1/p" "$pin")
  sha=$(grep -A1 '^const officialCodexSha256' "$pin" | grep -o "[0-9a-f]\{64\}")
  [ -n "$version" ] && [ -n "$sha" ] || fail "cannot read the Codex pin from $pin"
  dir=$(pwd)/codex/$version
  if [ -x "$dir/codex" ] && echo "$sha  $dir/codex" | sha256sum -c --status; then
    echo "Codex $version is already in $dir."
  else
    work=$(mktemp -d "$(pwd)/.codex-download.XXXXXX")
    trap 'rm -rf "$work"' EXIT
    archive=${CODEX_ARCHIVE:-}
    if [ -z "$archive" ]; then
      url=https://github.com/openai/codex/releases/download/rust-v$version/codex-x86_64-unknown-linux-musl.tar.gz
      echo "Downloading Codex $version from $url ..."
      archive=$work/codex.tar.gz
      curl -fL --retry 3 -o "$archive" "$url" || fail "download failed; on a machine without internet access, set CODEX_ARCHIVE to the downloaded file"
    fi
    tar -xzf "$archive" -C "$work" codex-x86_64-unknown-linux-musl || fail "$archive is not the Codex release archive"
    echo "$sha  $work/codex-x86_64-unknown-linux-musl" | sha256sum -c --status \
      || fail "the Codex binary does not match the pinned SHA-256 $sha: not installed"
    mkdir -p "$dir"
    chmod 755 codex "$dir"
    install -m 755 "$work/codex-x86_64-unknown-linux-musl" "$dir/codex"
    echo "Codex $version checked and installed in $dir."
  fi
  case "$dir" in *[!A-Za-z0-9/._-]*) fail "the kit's path has characters a mount cannot take: $dir" ;; esac

  # The default executor profile: the sandbox image with Codex mounted read-only (docs/agent-v2.md, "Executor profiles").
  cat > executor-profiles.json.tmp <<EOF
{"version": 1,
 "profiles": {
   "default": {"description": "Shell sandbox with the official Codex CLI",
               "image": "$sandbox_image",
               "mounts": [{"source": "$dir", "target": "/opt/codex"}],
               "limits": {"cpus": 1, "memory_mb": 2048, "pids": 1024, "workspace_mb": 512, "home_mb": 256}}}}
EOF
  mv executor-profiles.json.tmp executor-profiles.json
  compose=$(sed -n 's/^COMPOSE_FILE=//p' .env)
  case ":$compose:" in *:codex.yml:*) ;; *) set_env COMPOSE_FILE "${compose:-docker-compose.yml}:codex.yml" ;; esac
fi

set_env AGENT_ENABLED true
set_env COMPOSE_PROFILES agent
echo "Agent v2 nodes enabled${codex:+ (with Codex)}. Next: docker compose up -d --build"
