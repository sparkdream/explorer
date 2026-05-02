# Stage 1: Build the Vue app
FROM node:22-alpine AS builder

WORKDIR /app

# Install dependencies first (layer caching)
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile

# Copy source and build
COPY . .
RUN yarn build-only

# Stage 2: Serve with nginx + SSH + Tailscale
# Use plain alpine — same base as the sentry nodes — so we get the same
# tailscale version and avoid TLS-upgrade incompatibilities with Headscale.
FROM alpine

# Install nginx, SSH, Tailscale, and socat (for TCP tunneling over Tailscale userspace networking)
RUN apk add --no-cache nginx openssh-server tailscale socat

# Configure SSHd for key-only login
RUN ssh-keygen -A && \
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config && \
    mkdir -p /var/run/sshd

# Create directory for Tailscale state (should be on persistent storage)
RUN mkdir -p /var/lib/tailscale

# Copy built assets
COPY --from=builder /app/dist /usr/share/nginx/html

# Copy nginx config for SPA routing + reverse proxy
COPY deploy/nginx.conf /etc/nginx/http.d/default.conf

# Copy entrypoint script
COPY deploy/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Environment variables for node endpoints (overridable at runtime)
# These are relative paths — nginx reverse-proxies them to the local socat tunnels
ENV NODE_API_ENDPOINT="/api"
ENV NODE_RPC_ENDPOINT="/rpc"

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
