#!/bin/bash
set -e

# Mirror dashboard-ref-only's startup: create every directory hermes expects
# and seed a default config.yaml if the volume is empty. Without these,
# `hermes dashboard` endpoints that hit logs/, sessions/, cron/, etc. can fail
# with opaque errors even though no auth is actually involved.
mkdir -p /data/.hermes/cron /data/.hermes/sessions /data/.hermes/logs \
         /data/.hermes/memories /data/.hermes/skills /data/.hermes/pairing \
         /data/.hermes/hooks /data/.hermes/image_cache /data/.hermes/audio_cache \
         /data/.hermes/workspace /data/.hermes/skins /data/.hermes/plans \
         /data/.hermes/home

# Stamp the install method as "docker" so hermes treats this as an immutable
# container image, not a pip checkout. hermes's detect_install_method() reads
# $HERMES_HOME/.install_method FIRST (before any .git / pip fallback). Without
# this stamp the template falls through to "pip" — because the Dockerfile strips
# /opt/hermes-agent/.git — and the dashboard's "Update Hermes" button then runs
# a real `hermes update` (PyPI pip-upgrade) INSIDE the running container. That
# upgrade is ephemeral (reverts on the next redeploy) and can desync the Python
# package from the image's pre-built web_dist/ui-tui bundles. Stamping "docker"
# makes that button correctly refuse with "pull a fresh image / redeploy", which
# matches the real upgrade path here (bump HERMES_REF in Railway + redeploy).
# Written unconditionally each boot so it stays correct and self-heals.
printf 'docker\n' > /data/.hermes/.install_method

if [ ! -f /data/.hermes/config.yaml ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example /data/.hermes/config.yaml
fi

[ ! -f /data/.hermes/.env ] && touch /data/.hermes/.env

# Bootstrap OAuth tokens from env var (e.g. xAI Grok SuperGrok).
# Set HERMES_AUTH_JSON_BOOTSTRAP to the contents of a locally-generated
# ~/.hermes/auth.json. Written only once — subsequent token refreshes update
# the file in place on the persistent volume.
if [ ! -f /data/.hermes/auth.json ] && [ -n "${HERMES_AUTH_JSON_BOOTSTRAP}" ]; then
  printf '%s' "${HERMES_AUTH_JSON_BOOTSTRAP}" > /data/.hermes/auth.json
  chmod 600 /data/.hermes/auth.json
fi

# Clear any stale gateway PID file left over from the previous container.
# `hermes gateway` writes /data/.hermes/gateway.pid on start but does not
# remove it on SIGTERM. Since /data is a persistent volume, the file
# survives container restarts and causes every subsequent boot to exit with
# "ERROR gateway.run: PID file race lost to another gateway instance".
# No hermes process can be running at this point (we're pre-exec in a fresh
# container), so removing the file unconditionally is safe.
rm -f /data/.hermes/gateway.pid

# --- MCP-over-HTTP bridge (additive; does NOT touch the gateway) -------------
# Expose `hermes mcp serve` (stdio) as a Streamable-HTTP MCP endpoint on an
# internal loopback port. server.py reverse-proxies /mcp -> this port with
# Bearer-token auth (MCP_BEARER_TOKEN). Reads the SAME /data/.hermes volume as
# the gateway, so the MCP tools see this agent's real Discord/Telegram
# conversations. Started in the background; the gateway+dashboard (server.py)
# remain PID 1's foreground child exactly as before.
#
# Only start the bridge when a token is configured — no token means the /mcp
# proxy route in server.py refuses all requests anyway, so launching the
# backend would just waste a port.
MCP_BRIDGE_PORT="${MCP_BRIDGE_PORT:-9300}"
if [ -n "${MCP_BEARER_TOKEN}" ]; then
  echo "[start] launching MCP bridge (supergateway) on 127.0.0.1:${MCP_BRIDGE_PORT}" >&2
  # SSE transport: supergateway's streamableHttp output crashes with
  # "No connection established for request ID" under the official MCP client's
  # handshake (a known supergateway/SDK bug). The older SSE transport is
  # battle-tested and works cleanly behind our reverse proxy. SSE uses two
  # paths under /mcp: the event stream (/mcp/sse) and the POST channel
  # (/mcp/message); both are covered by the /mcp/{path} proxy route in
  # server.py.
  supergateway \
      --stdio "hermes mcp serve" \
      --outputTransport sse \
      --host 127.0.0.1 \
      --port "${MCP_BRIDGE_PORT}" \
      --ssePath /mcp/sse \
      --messagePath /mcp/message \
      --healthEndpoint /healthz \
      --logLevel info &
else
  echo "[start] MCP_BEARER_TOKEN unset — MCP bridge not started" >&2
fi
# ---------------------------------------------------------------------------

exec python /app/server.py
