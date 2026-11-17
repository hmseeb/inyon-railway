# Inyon hub for Railway: tmux + the hub (built into the release's inyon) on loopback + Caddy on $PORT.
# boot.sh and Caddyfile are upstream's deploy/hub copies (MIT, derived from this image) as of v0.26.1;
# this Dockerfile keeps the release binary pinned by hand to its sha256, which upstream checks by minisign.
FROM caddy:2.10 AS caddy

FROM debian:bookworm-slim
ARG TARGETARCH
ARG INYON_VERSION=0.26.1
# sha256 of inyon-linux-* from the release's minisign-signed SHA256SUMS; pins the exact bytes.
# Since 0.2x the hub is built into inyon (inyon-engine-* is a byte-identical copy).
ARG SUM_amd64=ac200b43b1dbeb0f40f7b9b37686a0d1c19609c90aaa136ced86b9ade394fd1f
ARG SUM_arm64=70938acb61487fd4667524f9b8bf82a46c9bba99e25465074cd6bbbdc7c43337

# tmux is what Inyon drives; procps for the process tree it reads; git/ssh/curl so the
# in-app "set up this machine" and the agents' own installers work.
RUN apt-get update && apt-get install -y --no-install-recommends \
      tmux procps git openssh-client curl ca-certificates less nano xz-utils unzip \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "$TARGETARCH" in amd64) a=x64; sum=$SUM_amd64;; \
                          arm64) a=arm64; sum=$SUM_arm64;; \
                          *) echo "unsupported arch $TARGETARCH"; exit 1;; esac; \
    base=https://github.com/Abhash-Chakraborty/inyon/releases/download/v$INYON_VERSION; \
    curl -fsSL --retry 3 "$base/inyon-linux-$a" -o /usr/local/bin/inyon; \
    echo "$sum  /usr/local/bin/inyon" | sha256sum -c -; \
    chmod 755 /usr/local/bin/inyon; \
    [ "$(/usr/local/bin/inyon --version)" = "inyon $INYON_VERSION" ]; \
    # older images ran the hub as inyon-engine; keep the name for anything that still calls it
    ln -s inyon /usr/local/bin/inyon-engine

COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /etc/inyon/Caddyfile
COPY boot.sh /usr/local/bin/inyon-boot

# Not root: Claude Code refuses --dangerously-skip-permissions as root, and the hub hands out
# a shell as this user. boot.sh starts as root only to chown the Railway volume, then drops.
RUN useradd -m -u 1000 -s /bin/bash inyon \
 # tmux panes run login shells, and Debian's /etc/profile resets PATH: keep the agents' installs on it
 && echo 'export PATH="$HOME/.local/bin:$HOME/.inyon/bin:$PATH"' > /etc/profile.d/inyon-path.sh
# INYON_HUB_IMPL=rust keeps the hub in inyon even if a hub.env on an older volume asks for the Bun one.
ENV HOME=/data/home \
    INYON_DATA_DIR=/data/home/.inyon \
    INYON_HUB_IMPL=rust \
    PATH=/data/home/.local/bin:/data/home/.inyon/bin:/usr/local/bin:/usr/bin:/bin \
    PORT=8080 \
    LANG=C.UTF-8

EXPOSE 8080
CMD ["/usr/local/bin/inyon-boot"]
