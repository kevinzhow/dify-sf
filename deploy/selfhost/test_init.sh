#!/usr/bin/env sh
# Checks init.sh in a scratch directory: which addresses it refuses (writing nothing) and what it writes for the
# others. Prints the address fields it compares, never the generated keys.
#
#   deploy/selfhost/test_init.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$here/init.sh" "$work/"
failed=0

refuse() {
  rm -f "$work/.env"
  if "$work/init.sh" "$@" >/dev/null 2>&1; then status=0; else status=$?; fi
  if [ "$status" = 2 ] && [ ! -e "$work/.env" ] && [ -z "$(ls -A "$work" | grep -v '^init.sh$')" ]; then
    echo "ok      refuses $*"
  else
    echo "FAILED  refuses $* (exit $status, files: $(ls -A "$work" | tr '\n' ' '))"; failed=1
  fi
}

# accept ARGS... -- KEY=VALUE...: init.sh succeeds and .env has these values.
accept() {
  rm -f "$work/.env"
  args=""
  while [ "$1" != -- ]; do args="$args $1"; shift; done
  shift
  # shellcheck disable=SC2086
  if ! "$work/init.sh" $args >/dev/null 2>&1; then echo "FAILED  accepts$args (refused)"; failed=1; return; fi
  bad=""
  for kv in "$@"; do
    got=$(grep "^${kv%%=*}=" "$work/.env" | head -1)
    [ "$got" = "$kv" ] || bad="$bad [want $kv, got ${got:-nothing}]"
  done
  [ "$(stat -c %a "$work/.env")" = 600 ] || bad="$bad [mode $(stat -c %a "$work/.env")]"
  if grep -Eq '^(POSTGRES_PASSWORD|COLLAB_SECRETS_KEY|COLLAB_FILES_SIGNING_KEY|AGENT_SERVICE_KEY)=$' "$work/.env"; then
    bad="$bad [empty key]"
  fi
  if [ -z "$bad" ]; then echo "ok      accepts$args"; else echo "FAILED  accepts$args:$bad"; failed=1; fi
}

refuse
refuse http://
refuse https://
refuse http://dify.lan:65536
refuse http://dify.lan:99999999999
refuse "http://dify.lan?x=1"
refuse "http://dify.lan/?x=1"
refuse "http://dify.lan#top"
refuse http://dify.lan:
refuse http://dify.lan:0
refuse http://dify.lan:080
refuse http://dify.lan:http
refuse http://dify.lan/dify
refuse http://user@dify.lan
refuse http://user:secret@dify.lan
refuse "http://dify .lan"
refuse http://dify_lan
refuse http://-dify.lan
refuse http://dify..lan
refuse http://::1
refuse "http://[::1"
refuse http://[zz]:80
refuse "http://[1]"
refuse "http://[::::]"
refuse "http://[1:2:3:4:5:6:7:8:9]"
refuse "http://[1:2:3:4:5:6:7:8::]"
refuse "http://[1::2::3]"
refuse "http://[12345::]"
refuse "http://[g::1]"
refuse "http://[:1]"
refuse "http://[1:]"
refuse "http://[::1.2.3]"
refuse "http://[::1.2.3.256]"
refuse "http://[1.2.3.4::]"
refuse "http://[::1%eth0]"
refuse "http://[]"
refuse "http://192.168.1.999"
refuse "http://1.2.3"
refuse "http://123"
refuse "http://010.0.0.1"
refuse "http://0x7f.0.0.1"
refuse "http://dify.0x7f"
refuse "http://1.2.3.4.5"
refuse "http://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.lan"
refuse ftp://dify.lan
refuse dify.lan
refuse https://192.168.1.20
refuse https://[::1]
refuse https://dify.example.com:8443
refuse http://dify.lan --behind-proxy
refuse http://dify.lan you@example.com
refuse https://dify.example.com --behind-proxy you@example.com
refuse https://dify.example.com you@example
refuse https://dify.example.com "you@@example.com"
refuse https://dify.example.com --bogus
refuse https://dify.example.com extra

accept http://192.168.1.20 -- PUBLIC_URL=http://192.168.1.20 DIFYSF_SITE=:80 HTTP_PORT=80 \
  COMPOSE_FILE=docker-compose.yml ACME_EMAIL=
accept http://Dify.LAN:8080/ -- PUBLIC_URL=http://dify.lan:8080 DIFYSF_SITE=:80 HTTP_PORT=8080
accept http://dify.lan:80 -- PUBLIC_URL=http://dify.lan HTTP_PORT=80
accept http://localhost:65535 -- PUBLIC_URL=http://localhost:65535 HTTP_PORT=65535
accept "http://[::1]:8080" -- "PUBLIC_URL=http://[::1]:8080" HTTP_PORT=8080
accept "http://10.0.0.1" -- "PUBLIC_URL=http://10.0.0.1"
accept "http://node1.lan" -- "PUBLIC_URL=http://node1.lan"
accept "http://1.lan" -- "PUBLIC_URL=http://1.lan"
accept "http://[0:0:0:0:0:0:0:1]:8080" -- "PUBLIC_URL=http://[::1]:8080"
accept "http://[2001:DB8::0001]" -- "PUBLIC_URL=http://[2001:db8::1]"
accept "http://[::ffff:192.168.1.1]" -- "PUBLIC_URL=http://[::ffff:c0a8:101]"
accept "http://[1:0:0:2:0:0:0:3]" -- "PUBLIC_URL=http://[1:0:0:2::3]"
accept "http://[1:0:0:2:3:0:0:4]" -- "PUBLIC_URL=http://[1::2:3:0:0:4]"
accept "http://[1:2:3:4:5:6:7::]" -- "PUBLIC_URL=http://[1:2:3:4:5:6:7:0]"
accept "http://[::]" -- "PUBLIC_URL=http://[::]"
accept https://Dify.Example.com you@example.com -- PUBLIC_URL=https://dify.example.com DIFYSF_SITE=dify.example.com \
  ACME_EMAIL=you@example.com HTTP_PORT=80 COMPOSE_FILE=docker-compose.yml:https.yml
accept https://dify.example.com:443 -- PUBLIC_URL=https://dify.example.com DIFYSF_SITE=dify.example.com ACME_EMAIL=
accept https://dify.example.com:8443 --behind-proxy -- PUBLIC_URL=https://dify.example.com:8443 DIFYSF_SITE=:80 \
  HTTP_PORT=80 COMPOSE_FILE=docker-compose.yml

# An existing .env is kept as it is.
rm -f "$work/.env"
"$work/init.sh" http://dify.lan >/dev/null 2>&1
before=$(cksum < "$work/.env")
if "$work/init.sh" http://other.lan >/dev/null 2>&1; then status=0; else status=$?; fi
if [ "$status" = 1 ] && [ "$(cksum < "$work/.env")" = "$before" ]; then
  echo "ok      keeps an existing .env"
else
  echo "FAILED  keeps an existing .env (exit $status)"; failed=1
fi

[ "$failed" = 0 ] && echo "all passed" || { echo "some checks failed"; exit 1; }
