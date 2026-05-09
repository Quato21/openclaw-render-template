#!/bin/sh
# entrypoint.sh — Tailscale + AlphaClaw startup wrapper for Render
# - starts tailscaled in userspace mode (Render containers have no /dev/net/tun)
# - registers the container on the user's tailnet via TS_AUTHKEY
# - persists tailscale state under /data/tailscale so the node identity survives restarts
# - pins openclaw to 2026.5.7 (workaround for upstream alphaclaw 0.9.15 which pins 2026.5.6)
#   TODO: remove once @chrysb/alphaclaw ships a release pinned to 2026.5.7+
# - then exec's alphaclaw

set -e

# ---- 1. Pin OpenClaw 2026.5.7 (override alphaclaw's 0.9.15 transitive pin to 2026.5.6) ----
# alphaclaw 0.9.15 pins openclaw@2026.5.6 exactly. 2026.5.6 has a bug that streams
# intermediate-reasoning prose to Telegram DMs as separate sendMessage calls. 2026.5.7 fixes
# this. We override here so the fix is durable across redeploys.
echo "[entrypoint] installing openclaw@2026.5.7 override..."
cd /app
npm install openclaw@2026.5.7 --no-save --silent
echo "[entrypoint] openclaw version: $(node -p "require('/app/node_modules/openclaw/package.json').version")"

# ---- 2. Tailscale ----
mkdir -p /data/tailscale

if [ -n "$TS_AUTHKEY" ]; then
  echo "[entrypoint] starting tailscaled in userspace mode..."
  # --tun=userspace-networking: required in Render (no /dev/net/tun)
  # --statedir: persist node identity on the Render disk so we survive restarts cleanly
  /usr/sbin/tailscaled \
    --tun=userspace-networking \
    --socks5-server=localhost:1055 \
    --outbound-http-proxy-listen=localhost:1055 \
    --statedir=/data/tailscale \
    --state=/data/tailscale/tailscaled.state \
    > /var/log/tailscaled.log 2>&1 &

  # Wait for tailscaled socket
  for i in $(seq 1 15); do
    if [ -S /var/run/tailscale/tailscaled.sock ]; then
      break
    fi
    sleep 0.5
  done

  echo "[entrypoint] joining tailnet..."
  /usr/bin/tailscale up \
    --authkey="$TS_AUTHKEY" \
    --hostname="${TS_HOSTNAME:-alphaclaw-le9a}" \
    --accept-dns=false \
    --reset \
    || echo "[entrypoint] WARN: tailscale up failed; container will continue without tailnet"

  /usr/bin/tailscale status || true
else
  echo "[entrypoint] TS_AUTHKEY not set — skipping Tailscale join (gateway will run loopback-only)"
fi

# ---- 3. Hand off to alphaclaw ----
echo "[entrypoint] starting alphaclaw..."
exec alphaclaw start
