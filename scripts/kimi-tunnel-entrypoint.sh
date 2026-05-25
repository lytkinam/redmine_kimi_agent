#!/bin/bash
set -e

# Start SSH tunnel to host kimi-web (localhost:5495)
nohup ssh -N \
  -o StrictHostKeyChecking=no \
  -o ServerAliveInterval=60 \
  -o ExitOnForwardFailure=yes \
  -i /home/redmine/.ssh/kimi_tunnel_key \
  -L 5495:127.0.0.1:5495 \
  user@172.17.0.1 \
  > /tmp/kimi-tunnel.log 2>&1 &

# Give ssh a moment to establish the tunnel
sleep 2

# Hand off to the original Redmine entrypoint
exec /docker-entrypoint.sh "$@"
