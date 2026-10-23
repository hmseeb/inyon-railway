#!/bin/bash
# Boot order: hub on loopback first, claim it, and only then Caddy on $PORT, so a green
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

pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' TERM INT

# PORT and BIND are the hub's own names: scope them to the hub so Caddy keeps Railway's PORT.
PORT=$HUB_PORT BIND=127.0.0.1 inyon-engine hub &
pids+=($!)

session() { curl -fsS -m 3 "http://127.0.0.1:$HUB_PORT/api/session" 2>/dev/null; }
for _ in $(seq 1 120); do session >/dev/null && break; sleep 0.5; done
session >/dev/null || { echo "FATAL: hub did not answer on 127.0.0.1:$HUB_PORT within 60s" >&2; exit 1; }

# First boot only: set the password from INYON_PASSWORD with the hub's own one-time setup
# code, over loopback, so a fresh public URL is never left waiting for its first visitor.
if session | grep -q '"setup":true'; then
  code_file="$INYON_DATA_DIR/setup-code"
  if [ -n "${INYON_PASSWORD:-}" ] && [ -s "$code_file" ]; then
    pw=$(printf '%s' "$INYON_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')
    body=$(printf '{"password":"%s","code":"%s"}' "$pw" "$(tr -d '[:space:]' < "$code_file")")
    out=$(curl -sS -m 10 -X POST -H 'Content-Type: application/json' --data-binary "$body" \
            "http://127.0.0.1:$HUB_PORT/api/setup" 2>&1) || true
    case "$out" in
      *'"ok":true'*) echo "==> hub claimed: sign in with the password in INYON_PASSWORD" ;;
      # keep the deploy healthy: the hub falls back to its own first visit, which needs the setup code
      *) echo "WARNING: the hub refused INYON_PASSWORD ($out). Open the hub and choose a password (8 to 1024 characters) with the setup code above." >&2 ;;
    esac
  else
    echo "==> INYON_PASSWORD is empty: open the hub and use the setup code above to choose a password"
  fi
fi

caddy run --config /etc/inyon/Caddyfile --adapter caddyfile &
pids+=($!)

# Either process ending ends the container; Railway's restart policy brings both back.
wait -n "${pids[@]}"
status=$?
kill "${pids[@]}" 2>/dev/null || true
exit "$status"
