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
    -e INYON_PASSWORD="$PW" -e INYON_ALLOWED_HOSTS="$HOST" \
    -e RAILWAY_SERVICE_ID=contract -e RAILWAY_PUBLIC_DOMAIN="$HOST" "$IMG" >/dev/null
  for _ in $(seq 1 60); do curl -fs -o /dev/null -H "Host: $HOST" "http://127.0.0.1:$PORT/api/session" && return; sleep 1; done
}
# What Railway's edge sends: XFF "<client>, <edge ip>" and X-Real-IP <client>
edge() { local c=${CLIENT:-203.0.113.7}; curl -s -H "Host: $HOST" -H "X-Forwarded-Proto: https" -H "X-Forwarded-For: $c, 100.64.0.${EDGE:-1}" -H "X-Real-IP: $c" "$@"; }
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

u=$(docker exec "$NAME" ps -o user= -C inyon,inyon-engine | head -1)
[ "$u" = inyon ] && ok "hub runs as the inyon user" || no "hub runs as '$u'"

docker exec "$NAME" sh -c 'command -v tmux git ssh' >/dev/null && ok "tmux, git, ssh present" || no "tools missing"

# agents install to ~/.local/bin; tmux panes are login shells, so it must survive /etc/profile
lp=$(docker exec -u inyon "$NAME" bash -lc 'echo $PATH')
[[ $lp == *"/data/home/.local/bin"* ]] && ok "login shells keep ~/.local/bin on PATH" || no "login PATH: $lp"

# /healthz is the hub's own answer under any Host (upstream deploy/hub's check)
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: anything.example.org" "http://127.0.0.1:$PORT/healthz")
[ "$code" = 200 ] && ok "/healthz answers under any Host" || no "/healthz got $code"

# INYON_PASSWORD never reaches the start script's or the hub's environment (tmux and agents inherit it)
env_of=$(docker exec "$NAME" sh -c 'for p in 1 $(pgrep -x inyon; pgrep -x inyon-engine); do tr "\0" "\n" < /proc/$p/environ; done')
[ -n "$env_of" ] && ! grep -q '^INYON_PASSWORD=' <<<"$env_of" && ok "INYON_PASSWORD is not in the boot or hub environment" || no "INYON_PASSWORD still in a process environment"

# The hub's own page must load through the proxy (web app embedded in the engine)
p=$(edge "http://127.0.0.1:$PORT/")
[[ $p == *'<div id="root"'* || $p == *'<script'* ]] && ok "web app served" || no "web app: ${p:0:200}"

# 0.26+ keeps the per-client sign-in limit on the volume, so these come from a client the 9 bad tries didn't lock out
login() { local pw=$1; shift; CLIENT=203.0.113.8 edge -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "Origin: https://$HOST" \
            --data "{\"password\":\"$pw\"}" "$@" "http://127.0.0.1:$PORT/api/login" 2>/dev/null; }
# same volume, new container: what a Railway redeploy (or a variable edit) does
redeploy() { docker rm -f "$NAME" >/dev/null; PW=$1 run; }

docker restart "$NAME" >/dev/null
for _ in $(seq 1 60); do curl -fs -o /dev/null -H "Host: $HOST" "http://127.0.0.1:$PORT/api/session" && break; sleep 1; done
[ "$(login "$PW")" = 200 ] && ok "password survives a restart (volume)" || no "after restart login failed"

# A password changed in Settings survives a redeploy while the variable is unchanged
# the cookie is Secure, so curl won't keep it over http: carry it by hand
ck=$(edge -D - -o /dev/null -X POST -H 'Content-Type: application/json' -H "Origin: https://$HOST" \
       --data "{\"password\":\"$PW\"}" "http://127.0.0.1:$PORT/api/login" | sed -n 's/^[Ss]et-[Cc]ookie: *\([^;]*\).*/\1/p')
edge -H "Cookie: $ck" -o /dev/null -X POST -H 'Content-Type: application/json' -H "Origin: https://$HOST" \
  --data "{\"current\":\"$PW\",\"next\":\"changed-in-settings\"}" "http://127.0.0.1:$PORT/api/password"
redeploy "$PW"
[ "$(login changed-in-settings)" = 200 ] && ok "Settings password kept while INYON_PASSWORD is unchanged" || no "Settings password lost on redeploy"

# Editing the variable replaces the password on the next deploy
redeploy edited-in-railway
[ "$(login edited-in-railway)" = 200 ] && [ "$(login changed-in-settings)" = 401 ] \
  && ok "an edited INYON_PASSWORD replaces the password" || no "variable edit not applied"

# A value the hub refuses keeps the deploy up and the old password working
redeploy short
[ "$(login edited-in-railway)" = 200 ] && docker logs "$NAME" 2>&1 | grep -q 'WARNING: INYON_PASSWORD was not applied' \
  && ok "a too-short INYON_PASSWORD is skipped with a warning" || no "short password: $(docker logs "$NAME" 2>&1 | tail -2)"

# A stop reaches the hub, which saves before it ends, instead of being killed by the timeout
docker stop -t 20 "$NAME" >/dev/null
e=$(docker inspect -f '{{.State.ExitCode}}' "$NAME")
[ "$e" != 137 ] && ok "a stop ends the hub cleanly (exit $e)" || no "hub killed on stop (exit $e)"

[ $fail = 0 ] && echo "all green" || { docker logs "$NAME" 2>&1 | tail -30; exit 1; }
