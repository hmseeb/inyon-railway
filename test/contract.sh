#!/bin/bash
# Contract for the image: what Railway and a deployer rely on. Builds, runs with a volume,
# and drives the hub through Caddy the way Railway's edge does.
#   test/contract.sh [image]   (default: builds image/ as inyon-railway:test)
set -uo pipefail
cd "$(dirname "$0")/.."
IMG=${1:-inyon-railway:test}
[ -n "${1:-}" ] || docker build -q -t "$IMG" image >/dev/null || { echo "build failed"; exit 1; }

VOL=inyon-contract-$$; NAME=inyon-contract-$$; PORT=18080; HOST=inyon-test.up.railway.app
PW=correct-horse-battery-staple
fail=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fail=1; }
run() {
  docker run -d --name "$NAME" -p 127.0.0.1:$PORT:8080 -v "$VOL:/data" \
    -e INYON_PASSWORD="$PW" -e INYON_ALLOWED_HOSTS="$HOST" "$IMG" >/dev/null
  for _ in $(seq 1 60); do curl -fs -o /dev/null -H "Host: $HOST" "http://127.0.0.1:$PORT/api/session" && return; sleep 1; done
}
edge() { curl -s -H "Host: $HOST" -H "X-Forwarded-Proto: https" -H "X-Forwarded-For: 9.9.9.9, 203.0.113.7" "$@"; }
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1; docker volume rm "$VOL" >/dev/null 2>&1; }
trap cleanup EXIT

run
s=$(edge "http://127.0.0.1:$PORT/api/session")
[[ $s == *'"setup":false'* ]] && ok "first boot claims the hub from INYON_PASSWORD" || no "hub not claimed: $s"

code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: healthcheck.railway.app" "http://127.0.0.1:$PORT/api/session")
[ "$code" = 200 ] && ok "Railway healthcheck host answers 200" || no "healthcheck host got $code"

code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: evil.example.com" "http://127.0.0.1:$PORT/api/session")
[ "$code" != 200 ] && ok "unknown Host refused ($code)" || no "unknown Host answered 200"

h=$(edge -D - -o /dev/null -X POST -H 'Content-Type: application/json' -H "Origin: https://$HOST" \
      --data "{\"password\":\"$PW\"}" "http://127.0.0.1:$PORT/api/login")
grep -qi '^set-cookie:.*secure' <<<"$h" && ok "sign-in works and the cookie is Secure behind the edge" || no "login/cookie: $h"

c=$(edge -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "Origin: https://$HOST" \
      --data '{"password":"wrong-password"}' "http://127.0.0.1:$PORT/api/login")
[ "$c" = 401 ] && ok "wrong password refused" || no "wrong password got $c"

u=$(docker exec "$NAME" ps -o user= -C inyon-engine | head -1)
[ "$u" = inyon ] && ok "hub runs as the inyon user" || no "hub runs as '$u'"

docker exec "$NAME" sh -c 'command -v tmux git ssh' >/dev/null && ok "tmux, git, ssh present" || no "tools missing"

# The hub's own page must load through the proxy (web app embedded in the engine)
p=$(edge "http://127.0.0.1:$PORT/")
[[ $p == *'<div id="root"'* || $p == *'<script'* ]] && ok "web app served" || no "web app: ${p:0:200}"

docker restart "$NAME" >/dev/null
for _ in $(seq 1 60); do curl -fs -o /dev/null -H "Host: $HOST" "http://127.0.0.1:$PORT/api/session" && break; sleep 1; done
c=$(edge -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "Origin: https://$HOST" \
      --data "{\"password\":\"$PW\"}" "http://127.0.0.1:$PORT/api/login")
[ "$c" = 200 ] && ok "password survives a restart (volume)" || no "after restart login got $c"

[ $fail = 0 ] && echo "all green" || { docker logs "$NAME" 2>&1 | tail -30; exit 1; }
