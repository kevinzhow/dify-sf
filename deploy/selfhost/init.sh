#!/usr/bin/env sh
# Writes deploy/selfhost/.env for this server: the address people open, and fresh random keys and passwords. Run once;
# it never overwrites an existing .env (the keys in it decrypt what the server stored).
#
#   ./init.sh http://192.168.1.20                  plain HTTP (no certificate); a port is allowed: http://host:8080
#   ./init.sh https://dify.example.com you@example.com
#                                                  HTTPS with a certificate Caddy obtains for the domain (Let's
#                                                  Encrypt: DNS must point here, ports 80 and 443 reachable)
#   ./init.sh https://dify.example.com --behind-proxy
#                                                  HTTPS done by your own proxy, which forwards plain HTTP to port 80
#
# Whether to use HTTPS is your choice; plain HTTP sends passwords and data unencrypted, so keep it to networks you trust.
set -eu
cd "$(dirname "$0")"

fail() { echo "$*" >&2; exit 2; }

# A dotted-quad IPv4 address: four numbers from 0 to 255, without leading zeros.
ipv4() {
  printf '%s\n' "$1" | awk -F. 'NF != 4 { exit 1 }
    { for (i = 1; i <= 4; i++) if ($i !~ /^(0|[1-9][0-9]?[0-9]?)$/ || $i + 0 > 255) exit 1 }'
}

# Prints the IPv6 address $1 (without brackets) as browsers write it in an origin: lowercase hex without leading
# zeros, the first longest run of two or more zero groups as ::, an IPv4 tail as two hex groups. Fails for anything
# that is not an IPv6 address.
ipv6() {
  printf '%s\n' "$1" | awk '
    function hex(s,   i, v, c) {
      if (s == "" || length(s) > 4) return -1
      v = 0
      for (i = 1; i <= length(s); i++) {
        c = index("0123456789abcdef", substr(s, i, 1))
        if (!c) return -1
        v = v * 16 + c - 1
      }
      return v
    }
    # Appends the groups of s to g (an IPv4 address is allowed as the last group of the address); -1 if invalid.
    function groups(s, last,   n, p, i, q, j, v) {
      if (s == "") return 0
      n = split(s, p, ":")
      for (i = 1; i <= n; i++) {
        if (last && i == n && index(p[i], ".")) {
          if (split(p[i], q, ".") != 4) return -1
          for (j = 1; j <= 4; j++) if (q[j] !~ /^(0|[1-9][0-9]?[0-9]?)$/ || q[j] + 0 > 255) return -1
          g[++k] = q[1] * 256 + q[2]; g[++k] = q[3] * 256 + q[4]
        } else {
          if ((v = hex(p[i])) < 0) return -1
          g[++k] = v
        }
      }
      return 0
    }
    {
      s = $0; k = 0
      if (s ~ /[^0-9a-f:.]/) exit 1
      d = index(s, "::")
      if (d) {
        tail = substr(s, d + 2)
        if (index(tail, "::") || groups(substr(s, 1, d - 1), 0) < 0) exit 1
        nh = k
        if (groups(tail, 1) < 0 || k > 7) exit 1
        nt = k - nh
        for (i = 1; i <= nt; i++) t[i] = g[nh + i]
        for (i = nh + 1; i <= 8 - nt; i++) g[i] = 0
        for (i = 1; i <= nt; i++) g[8 - nt + i] = t[i]
      } else if (groups(s, 1) < 0 || k != 8) exit 1
      bs = 0; bl = 1
      for (i = 1; i <= 8; i++) if (g[i] == 0) {
        for (j = i; j <= 8 && g[j] == 0; j++) ;
        if (j - i > bl) { bs = i; bl = j - i }
        i = j
      }
      out = ""
      for (i = 1; i <= 8; i++) {
        if (i == bs) { out = out (i == 1 ? "::" : ":"); i += bl - 1; continue }
        out = out sprintf("%x", g[i]) (i < 8 ? ":" : "")
      }
      print out
    }'
}

url=${1:-}
[ -n "$url" ] || { sed -n '2,13p' "$0"; exit 2; }
shift
email=""
proxy=""
while [ $# -gt 0 ]; do
  case "$1" in
    --behind-proxy) proxy=yes ;;
    -*) fail "unknown option: $1" ;;
    *[!A-Za-z0-9._%+@-]*|*@*@*|@*|*@) fail "not an email address: $1" ;;
    *@*.*) email=$1 ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done

# The address must be an origin, scheme://host[:port], exactly as browsers send it in the Origin header: the server
# compares it with that header (CORS) and builds every link it hands out from it.
case "$url" in
  http://*|https://*) ;;
  *) fail "give the address people open, starting with http:// or https://" ;;
esac
scheme=${url%%://*}
origin=${url#*://}
origin=${origin%/}
case "$origin" in
  '') fail "the address has no host: $url" ;;
  */*|*\?*|*\#*) fail "the address is an origin only, without a path, query or fragment: $scheme://${origin%%[/?#]*}" ;;
  *@*) fail "the address cannot carry a user name or password: $url" ;;
  *[[:space:]]*) fail "the address contains spaces: $url" ;;
esac
host=$origin
port=""
case "$origin" in
  \[*\]:*) host=${origin%:*}; port=${origin##*:} ;;   # [IPv6]:port
  \[*\]) ;;
  *:*:*) fail "an IPv6 address goes in brackets: $scheme://[address]" ;;
  *:*) host=${origin%:*}; port=${origin##*:} ;;
esac
host=$(printf '%s' "$host" | tr 'A-Z' 'a-z')
case "$host" in
  \[*\])
    v6=${host#?}
    v6=$(ipv6 "${v6%?}") || fail "not an IPv6 address: $host"
    host="[$v6]" ;;
  *)
    { echo "$host" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$' \
        && [ "${#host}" -le 253 ] && ! echo "$host" | grep -Eq '[^.]{64}'; } \
      || fail "not a host name or IP address: $host"
    # A name whose last label is a number is an IPv4 address to browsers (they would rewrite 1.2.3 or 123).
    if echo "${host##*.}" | grep -Eq '^([0-9]+|0x[0-9a-f]*)$'; then
      ipv4 "$host" || fail "not an IPv4 address (four numbers from 0 to 255): $host"
    fi ;;
esac
if [ -n "$port" ] || [ "${origin%:}" != "$origin" ]; then
  case "$port" in
    ''|*[!0-9]*|0*) fail "the port must be a number from 1 to 65535: ${port:-(empty)}" ;;
  esac
  [ "${#port}" -le 5 ] && [ "$port" -le 65535 ] || fail "the port must be a number from 1 to 65535: $port"
fi
# Browsers leave the default port out of the origin.
if { [ "$scheme" = http ] && [ "$port" = 80 ]; } || { [ "$scheme" = https ] && [ "$port" = 443 ]; }; then port=""; fi
public="$scheme://$host${port:+:$port}"

compose_file=docker-compose.yml
http_port=80
if [ -n "$proxy" ]; then
  [ "$scheme" = https ] || fail "--behind-proxy is for an HTTPS address your own proxy serves: https://..."
  [ -z "$email" ] || fail "the email is for the certificate Caddy obtains; with --behind-proxy your proxy has the certificate"
  site=:80                                  # your proxy forwards plain HTTP to port 80
elif [ "$scheme" = http ]; then
  [ -z "$email" ] || fail "the email is for a certificate; plain HTTP has none (use https://domain for one)"
  site=:80                                  # plain HTTP for any host name or address
  http_port=${port:-80}
else
  if echo "$host" | grep -Eq '^[0-9.]+$|^\['; then
    fail "a certificate needs a domain name; for an IP address use http://${origin}"
  fi
  [ -z "$port" ] || fail "Caddy's certificate needs the standard ports (80 and 443): use https://$host, or --behind-proxy"
  site=$host
  compose_file=docker-compose.yml:https.yml   # also publish 443
fi

if [ -e .env ]; then
  echo ".env exists: keeping it (it holds the keys of this installation)." >&2
  exit 1
fi

key() { head -c "$1" /dev/urandom | base64 | tr -d '\n'; }       # base64 of N random bytes
word() { head -c 32 /dev/urandom | base64 | tr -d '\n/+=' | cut -c1-32; }  # a password without shell-special characters

docker_gid=$(stat -c %g /var/run/docker.sock 2>/dev/null || echo 999)

umask 077
tmp=.env.init.$$
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<EOF
# dify-sf ($(date -u +%Y-%m-%d)): generated by init.sh. Keep this file private and backed up: COLLAB_SECRETS_KEY decrypts
# the stored model credentials and secret variables, and nothing can recover them without it.

# Where people reach this installation (the web client, the apps' server address, file and mail links).
PUBLIC_URL=$public
# What Caddy serves: :80 = plain HTTP for any address; a domain = HTTPS with a certificate Caddy obtains.
DIFYSF_SITE=$site
ACME_EMAIL=$email
HTTP_PORT=$http_port
HTTPS_PORT=443
# Compose reads this: https.yml publishes port 443 when Caddy does HTTPS itself.
COMPOSE_FILE=$compose_file

# Keys and passwords (random).
POSTGRES_PASSWORD=$(word)
COLLAB_SECRETS_KEY=$(key 32)
COLLAB_FILES_SIGNING_KEY=$(key 48)
PLUGIN_DAEMON_KEY=$(word)
PLUGIN_INNER_API_KEY=$(word)
SANDBOX_KEY=$(word)
REDIS_PASSWORD=$(word)
AGENT_SERVICE_KEY=$(word)
AGENT_SANDBOX_SUPERVISOR_KEY=$(word)

# Outgoing mail (password reset, invitations, human input forms). Empty SMTP_HOST = no mail.
MAIL_FROM=
SMTP_HOST=
SMTP_PORT=587
SMTP_USERNAME=
SMTP_PASSWORD=
# starttls (port 587), ssl (465) or none
SMTP_TLS=starttls

# Agent v2 nodes: ./enable-agent.sh [--codex] sets these (the sandbox supervisor gets the Docker socket).
AGENT_ENABLED=false
DOCKER_GID=$docker_gid

# Check model provider credentials with the provider before saving (false for servers without internet).
COLLAB_MODELS_VALIDATE=true
# A Python package mirror for the sandbox and plugins (empty = PyPI).
PIP_MIRROR_URL=
EOF
# Every key must be there: a short read of /dev/urandom must not leave an .env that can never be regenerated.
if grep -Eq '^(POSTGRES_PASSWORD|COLLAB_SECRETS_KEY|COLLAB_FILES_SIGNING_KEY|PLUGIN_DAEMON_KEY|PLUGIN_INNER_API_KEY|SANDBOX_KEY|REDIS_PASSWORD|AGENT_SERVICE_KEY|AGENT_SANDBOX_SUPERVISOR_KEY)=$' "$tmp"; then
  fail "could not generate the keys; nothing written"
fi
mv "$tmp" .env
trap - EXIT
echo "Wrote $(pwd)/.env for $public. Next: docker compose up -d --build"
