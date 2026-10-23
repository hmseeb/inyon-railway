#!/bin/bash
# Boot order: password, then the hub on loopback, and only then Caddy on $PORT, so a green
# healthcheck means the hub itself answers (not just a proxy in front of nothing).
set -euo pipefail

: "${PORT:=8080}"
HUB_PORT=4777

# Railway mounts the volume root-owned with a lost+found, so HOME is a subdirectory of it.
if [ "$(id -u)" = 0 ]; then
  mkdir -p "$HOME"
  [ "$(stat -c %u "$HOME")" = 1000 ] || chown -R 1000:1000 "$HOME"
  chmod 700 "$HOME"
  exec setpriv --reuid=1000 --regid=1000 --init-groups -- "$0" "$@"
fi

export SHELL=/bin/bash USER=inyon
mkdir -p "$INYON_DATA_DIR"
git config --global init.defaultBranch main >/dev/null 2>&1 || true

# The hub refuses any Host it was not told about (DNS rebinding guard); Railway's prober
# sends Host: healthcheck.railway.app.
export INYON_ALLOWED_HOSTS="${INYON_ALLOWED_HOSTS:+$INYON_ALLOWED_HOSTS,}healthcheck.railway.app"

# INYON_PASSWORD becomes the hub's password whenever the variable changes: applied before the hub
# starts, with the hub's own reset-password (which signs everyone out). A change made in Settings
# stays until the variable is edited again. Only a salted hash of the last applied value is kept.
applied="$INYON_DATA_DIR/railway-password"
if [ -n "${INYON_PASSWORD:-}" ]; then
  salt=$(cut -d' ' -f1 "$applied" 2>/dev/null || true)
  [ -n "$salt" ] || salt=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
  sum=$(printf '%s%s' "$salt" "$INYON_PASSWORD" | sha256sum | cut -c1-64)
  if [ "$(cat "$applied" 2>/dev/null || true)" != "$salt $sum" ]; then
    # through the environment, so the password never shows in the process list
    if out=$(INYON_NEW_PASSWORD="$INYON_PASSWORD" inyon-engine hub reset-password 2>&1); then
      (umask 077; echo "$salt $sum" > "$applied")
      echo "==> password set from INYON_PASSWORD"
    else
      # keep the deploy healthy; the hub keeps the password it had
      echo "WARNING: INYON_PASSWORD was not applied: $out" >&2
    fi
  fi
fi

pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' TERM INT

# PORT and BIND are the hub's own names: scope them to the hub so Caddy keeps Railway's PORT.
PORT=$HUB_PORT BIND=127.0.0.1 inyon-engine hub &
pids+=($!)

session() { curl -fsS -m 3 "http://127.0.0.1:$HUB_PORT/api/session" 2>/dev/null; }
for _ in $(seq 1 120); do session >/dev/null && break; sleep 0.5; done
session >/dev/null || { echo "FATAL: hub did not answer on 127.0.0.1:$HUB_PORT within 60s" >&2; exit 1; }

caddy run --config /etc/inyon/Caddyfile --adapter caddyfile &
pids+=($!)

# Either process ending ends the container; Railway's restart policy brings both back.
wait -n "${pids[@]}"
status=$?
kill "${pids[@]}" 2>/dev/null || true
exit "$status"
