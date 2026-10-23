# Inyon hub for Railway: tmux + the Bun hub on loopback + Caddy on $PORT.
# Upstream ships release binaries only (no image), so this wraps v0.20.2 unmodified.
FROM caddy:2.10 AS caddy

FROM debian:bookworm-slim
ARG TARGETARCH
ARG INYON_VERSION=0.20.2
# sha256 from the release's minisign-signed SHA256SUMS; pins the exact bytes
ARG SUM_ENGINE_amd64=159abf7ad5bc9b66b23c563b67586a639f8fcab61ad3a41e22d429e04fbc23d2
ARG SUM_CLI_amd64=be86ebb8ddb9dabea3eead82b3823d8f8cee5ef8396bd76f29fc05ee33627373
ARG SUM_ENGINE_arm64=686b86ec1fba231857f55bec1d6c655a4d24c567169cda3a9bf3c61487bff07e
ARG SUM_CLI_arm64=0c91a29113cfe2415c8d8d9510d1102661d0cacd393616a8e317ab3c92621c11

# tmux is what Inyon drives; procps for the process tree it reads; git/ssh/curl so the
# in-app "set up this machine" and the agents' own installers work.
RUN apt-get update && apt-get install -y --no-install-recommends \
      tmux procps git openssh-client curl ca-certificates less nano xz-utils unzip \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "$TARGETARCH" in amd64) a=x64; se=$SUM_ENGINE_amd64; sc=$SUM_CLI_amd64;; \
                          arm64) a=arm64; se=$SUM_ENGINE_arm64; sc=$SUM_CLI_arm64;; \
                          *) echo "unsupported arch $TARGETARCH"; exit 1;; esac; \
    base=https://github.com/Abhash-Chakraborty/inyon/releases/download/v$INYON_VERSION; \
    curl -fsSL "$base/inyon-engine-linux-$a" -o /usr/local/bin/inyon-engine; \
    curl -fsSL "$base/inyon-linux-$a" -o /usr/local/bin/inyon; \
    echo "$se  /usr/local/bin/inyon-engine" | sha256sum -c -; \
    echo "$sc  /usr/local/bin/inyon" | sha256sum -c -; \
    chmod 755 /usr/local/bin/inyon-engine /usr/local/bin/inyon

COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /etc/inyon/Caddyfile
COPY boot.sh /usr/local/bin/inyon-boot

# Not root: Claude Code refuses --dangerously-skip-permissions as root, and the hub hands out
# a shell as this user. boot.sh starts as root only to chown the Railway volume, then drops.
RUN useradd -m -u 1000 -s /bin/bash inyon \
 # tmux panes run login shells, and Debian's /etc/profile resets PATH: keep the agents' installs on it
 && echo 'export PATH="$HOME/.local/bin:$HOME/.inyon/bin:$PATH"' > /etc/profile.d/inyon-path.sh
ENV HOME=/data/home \
    INYON_DATA_DIR=/data/home/.inyon \
    PATH=/data/home/.local/bin:/data/home/.inyon/bin:/usr/local/bin:/usr/bin:/bin \
    PORT=8080 \
    LANG=C.UTF-8

EXPOSE 8080
CMD ["/usr/local/bin/inyon-boot"]
