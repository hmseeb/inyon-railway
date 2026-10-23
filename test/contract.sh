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
# What Railway's edge sends: XFF "<client>, <edge ip>" and X-Real-IP <client>
edge() { curl -s -H "Host: $HOST" -H "X-Forwarded-Proto: https" -H "X-Forwarded-For: 203.0.113.7, 100.64.0.${EDGE:-1}" -H "X-Real-IP: 203.0.113.7" "$@"; }
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

# Sign-in limit counts the client, not the edge hop that varies per request
last=""
for i in $(seq 1 9); do
  last=$(EDGE=$i edge -X POST -H 'Content-Type: application/json' -H "Origin: https://$HOST" \
           --data '{"password":"wrong-password"}' "http://127.0.0.1:$PORT/api/login")
done
[[ $last == *'Too many'* ]] && ok "sign-in limit is per client across edge hops" || no "9th wrong password: $last"

u=$(docker exec "$NAME" ps -o user= -C inyon-engine | head -1)
[ "$u" = inyon ] && ok "hub runs as the inyon user" || no "hub runs as '$u'"

docker exec "$NAME" sh -c 'command -v tmux git ssh' >/dev/null && ok "tmux, git, ssh present" || no "tools missing"

# agents install to ~/.local/bin; tmux panes are login shells, so it must survive /etc/profile
lp=$(docker exec -u inyon "$NAME" bash -lc 'echo $PATH')
[[ $lp == *"/data/home/.local/bin"* ]] && ok "login shells keep ~/.local/bin on PATH" || no "login PATH: $lp"

# The hub's own page must load through the proxy (web app embedded in the engine)
p=$(edge "http://127.0.0.1:$PORT/")
[[ $p == *'<div id="root"'* || $p == *'<script'* ]] && ok "web app served" || no "web app: ${p:0:200}"

docker restart "$NAME" >/dev/null
for _ in $(seq 1 60); do curl -fs -o /dev/null -H "Host: $HOST" "http://127.0.0.1:$PORT/api/session" && break; sleep 1; done
c=$(edge -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "Origin: https://$HOST" \
      --data "{\"password\":\"$PW\"}" "http://127.0.0.1:$PORT/api/login")
[ "$c" = 200 ] && ok "password survives a restart (volume)" || no "after restart login got $c"

# A password the hub refuses must not fail the deploy: the hub stays up and waits for its first
# visit, which needs the setup code from the logs
docker run -d --name "$NAME-short" -p 127.0.0.1:18081:8080 -e INYON_PASSWORD=short -e INYON_ALLOWED_HOSTS="$HOST" "$IMG" >/dev/null
s=""; for _ in $(seq 1 60); do s=$(curl -fs -H "Host: $HOST" http://127.0.0.1:18081/api/session) && break; sleep 1; done
[[ $s == *'"setup":true'* ]] && docker logs "$NAME-short" 2>&1 | grep -q 'WARNING: the hub refused INYON_PASSWORD' \
  && ok "short password keeps the hub up, waiting for the setup code" || no "short password: $s $(docker logs "$NAME-short" 2>&1 | tail -2)"
docker rm -f "$NAME-short" >/dev/null 2>&1

[ $fail = 0 ] && echo "all green" || { docker logs "$NAME" 2>&1 | tail -30; exit 1; }
