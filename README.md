# inyon-railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/inyon)

Container image for the [Inyon](https://github.com/Abhash-Chakraborty/inyon) hub on Railway:
tmux, the unmodified v0.26.1 `inyon` release binary (sha256-pinned), and Caddy in front of the hub.

- `image/` - Dockerfile, `boot.sh`, Caddyfile. `boot.sh` and the Caddyfile are copies of upstream's `deploy/hub` (MIT, Abhash Chakraborty), which upstream based on this image
- `test/contract.sh` - contract test, run in CI before every push to `ghcr.io/hmseeb/inyon-railway`

Inyon is MIT licensed by Abhash Chakraborty. This wrapper is MIT too.
