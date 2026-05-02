#!/bin/sh
set -e

# 1. Unlock root account (Alpine locks it by default; sshd rejects locked accounts)
sed -i 's/^root:!:/root:*:/' /etc/shadow

# 2. Ensure host keys exist (regenerate if missing at runtime)
ssh-keygen -A 2>/dev/null

# 3. Inject the SSH public key from the environment variable
if [ -n "$SSH_PUBLIC_KEY" ]; then
    mkdir -p /root/.ssh
    echo "$SSH_PUBLIC_KEY" > /root/.ssh/authorized_keys
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys
    echo "SSH public key injected."
else
    echo "WARNING: SSH_PUBLIC_KEY not set. SSH will not be available."
fi

# 4. Start the SSH server in the background
echo "Starting sshd..."
/usr/sbin/sshd -e -p 2222 || echo "ERROR: sshd failed to start"

# 5. Start Tailscale daemon if HEADSCALE_URL and TS_AUTHKEY are set
if [ -n "$HEADSCALE_URL" ] && [ -n "$TS_AUTHKEY" ]; then
    echo "Starting Tailscale daemon (userspace networking)..."

    # Use persistent storage for Tailscale state if available
    TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
    mkdir -p "$TS_STATE_DIR"

    # Start tailscaled in userspace networking mode (no TUN device needed)
    TS_SOCKET="${TS_STATE_DIR}/tailscaled.sock"

    # Remove stale socket so tailscaled can bind cleanly, but preserve
    # tailscaled.state — that file holds the node identity and stable IP.
    rm -f "$TS_SOCKET"

    tailscaled \
        --tun=userspace-networking \
        --state="${TS_STATE_DIR}/tailscaled.state" \
        --socket="${TS_SOCKET}" \
        &>/var/log/tailscaled.log &
    TAILSCALED_PID=$!

    # Wait for daemon to be ready by testing the socket is alive, not just present.
    echo "Waiting for tailscaled..."
    for i in $(seq 1 30); do
        tailscale --socket="$TS_SOCKET" status &>/dev/null && break
        kill -0 $TAILSCALED_PID 2>/dev/null || { echo "ERROR: tailscaled exited. Check /var/log/tailscaled.log"; break; }
        sleep 1
    done

    # Join the Headscale network
    TS_HOSTNAME="${TS_HOSTNAME:-explorer}"
    tailscale --socket="$TS_SOCKET" up \
        --login-server="$HEADSCALE_URL" \
        --authkey="$TS_AUTHKEY" \
        --hostname="$TS_HOSTNAME" \
        --accept-dns=false \
        && echo "Tailscale connected as ${TS_HOSTNAME}" \
        || echo "WARNING: Tailscale failed to connect"

    # Show Tailscale IP for reference
    TS_IP=$(tailscale --socket="$TS_SOCKET" ip -4 2>/dev/null || echo "unknown")
    echo "Tailscale IP: ${TS_IP}"

    # 5b. Set up socat TCP tunnels for Tailscale userspace networking.
    # Akash containers lack NET_ADMIN, so tailscaled runs in userspace mode where
    # the Tailscale IP is not a real kernel interface. socat bridges this by
    # forwarding a local port through "tailscale nc" which uses the userspace stack.
    #
    # TS_TUNNEL_* env vars define tunnels as "local_port:remote_tailscale_ip:remote_port"
    # Example: TS_TUNNEL_1="11317:100.64.0.11:1317" forwards localhost:11317 to
    #          the sentry's REST API via Tailscale.
    for var in $(env | grep '^TS_TUNNEL_' | sort); do
        TUNNEL_SPEC="${var#*=}"
        LOCAL_PORT=$(echo "$TUNNEL_SPEC" | cut -d: -f1)
        REMOTE_IP=$(echo "$TUNNEL_SPEC" | cut -d: -f2)
        REMOTE_PORT=$(echo "$TUNNEL_SPEC" | cut -d: -f3)
        if [ -n "$LOCAL_PORT" ] && [ -n "$REMOTE_IP" ] && [ -n "$REMOTE_PORT" ]; then
            echo "Tailscale tunnel: localhost:${LOCAL_PORT} -> ${REMOTE_IP}:${REMOTE_PORT}"
            socat TCP-LISTEN:${LOCAL_PORT},fork,reuseaddr \
                EXEC:"tailscale --socket=${TS_SOCKET} nc ${REMOTE_IP} ${REMOTE_PORT}" &
        fi
    done
elif [ -n "$HEADSCALE_URL" ] || [ -n "$TS_AUTHKEY" ]; then
    echo "WARNING: Both HEADSCALE_URL and TS_AUTHKEY must be set for Tailscale. Skipping."
else
    echo "Tailscale not configured (HEADSCALE_URL and TS_AUTHKEY not set)."
fi

# 6. Patch node endpoints in bundled JS files.
# The chain config (sparkdream.json) is inlined at build time by Vite,
# so we sed-replace the compiled JS assets at container startup.
# The frontend runs in the user's browser, so endpoints must be reachable
# from the browser — use relative paths that nginx reverse-proxies to the
# local socat tunnels (see nginx.conf /api/ and /rpc/ locations).
API_DEFAULT="http://localhost:1317"
RPC_DEFAULT="http://localhost:26657"
NODE_API_ENDPOINT="${NODE_API_ENDPOINT:-/api}"
NODE_RPC_ENDPOINT="${NODE_RPC_ENDPOINT:-/rpc}"

echo "Patching endpoints in frontend assets:"
echo "  API: ${API_DEFAULT} -> ${NODE_API_ENDPOINT}"
echo "  RPC: ${RPC_DEFAULT} -> ${NODE_RPC_ENDPOINT}"

find /usr/share/nginx/html/assets -name '*.js' -exec sed -i \
    -e "s|${API_DEFAULT}|${NODE_API_ENDPOINT}|g" \
    -e "s|${RPC_DEFAULT}|${NODE_RPC_ENDPOINT}|g" \
    {} +

echo "Endpoints patched successfully."

# 7. Start nginx (or whatever CMD was passed)
echo "Starting: $@"
exec "$@"
