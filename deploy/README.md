# Deploying Spark Dream Explorer

## Files

- **Dockerfile** — Multi-stage build (Node 18 + nginx). Includes SSH server and Tailscale for mesh VPN access.
- **nginx.conf** — Nginx config with SPA routing and static asset caching.
- **entrypoint.sh** — Starts sshd, joins Headscale mesh, sets up socat tunnels, patches node endpoints, then starts nginx.
- **deploy.yaml** — Akash SDL for deployment with Headscale integration.

## Configuration

### Node Endpoints

| Variable | Default | Description |
|---|---|---|
| `NODE_API_ENDPOINT` | `http://localhost:1317` | Cosmos REST/LCD API endpoint |
| `NODE_RPC_ENDPOINT` | `http://localhost:26657` | Tendermint RPC endpoint |

### SSH Access

| Variable | Description |
|---|---|
| `SSH_PUBLIC_KEY` | Ed25519 public key for root SSH access (port 2222) |

### Headscale / Tailscale Mesh

| Variable | Default | Description |
|---|---|---|
| `HEADSCALE_URL` | — | Headscale server URL (both required to enable) |
| `TS_AUTHKEY` | — | Pre-auth key from Headscale |
| `TS_HOSTNAME` | `explorer` | Hostname on the Tailscale mesh |
| `TS_STATE_DIR` | `/var/lib/tailscale` | Tailscale state directory (use persistent storage) |
| `TS_TUNNEL_*` | — | Socat tunnels: `local_port:remote_tailscale_ip:remote_port` |

## Build the Docker Image

From the project root:

```bash
docker build -f deploy/Dockerfile -t sparkdream-explorer:latest .
```

## Run Locally

```bash
docker run -p 8080:80 \
  -e NODE_API_ENDPOINT=http://your-node:1317 \
  -e NODE_RPC_ENDPOINT=http://your-node:26657 \
  sparkdream-explorer:latest
```

Then open http://localhost:8080 in your browser.

## Deploy to Akash with Headscale

The explorer joins your Headscale mesh and reaches the sentry node's API/RPC ports through socat tunnels over Tailscale userspace networking. This keeps the sentry's API ports private to the mesh.

### 1. Prepare a Headscale pre-auth key

```bash
# Note the numeric user ID from:
headscale users list

# Explorer key (replace <USER_ID> with the numeric ID from above)
headscale preauthkeys create --user <USER_ID> --reusable --expiration 8760h
```

### 2. Build and push the image

```bash
docker build -f deploy/Dockerfile -t sparkdreamnft/sparkdream-explorer:latest .
docker push sparkdreamnft/sparkdream-explorer:latest
```

### 3. Edit `deploy.yaml`

- Set `SSH_PUBLIC_KEY` to your Ed25519 public key.
- Set `HEADSCALE_URL` to your Headscale provider URL.
- Set `TS_AUTHKEY` to the pre-auth key from step 1.
- Set `TS_TUNNEL_1` and `TS_TUNNEL_2` to point at your sentry's Tailscale IP:
  - `TS_TUNNEL_1=11317:<SENTRY_TS_IP>:1317` (REST API)
  - `TS_TUNNEL_2=26657:<SENTRY_TS_IP>:26657` (RPC)
- `NODE_API_ENDPOINT` and `NODE_RPC_ENDPOINT` should reference the local tunnel ports (`127.0.0.1:11317` and `127.0.0.1:26657`).

### 4. Deploy

```bash
akash tx deployment create deploy.yaml --from your-wallet --node https://rpc.akash.network:443 --chain-id akashnet-2
```

### 5. Verify

SSH into the explorer container:

```bash
ssh -p <forwarded_2222_port> root@<akash-provider>
```

Check Tailscale status and tunnel connectivity:

```bash
tailscale --socket=/data/tailscale/tailscaled.sock status
curl http://127.0.0.1:11317/cosmos/base/tendermint/v1beta1/node_info
```

## Network Architecture

```
Public Internet
    |
Explorer (Akash Provider C)
  - HTTP :80 (public — serves the explorer UI)
  - SSH :2222 (public — management)
  - socat tunnels (localhost:11317 -> sentry:1317, localhost:26657 -> sentry:26657)
    | (Tailscale mesh)
Sentry Node (Akash Provider B)
  - P2P :26656 (public)
  - RPC :26657 (mesh only, or public)
  - REST :1317 (mesh only)
    | (Tailscale mesh)
Validator Node (Akash Provider A)
  - Private: only Tailscale connectivity
```
