#!/usr/bin/env bash
set -e

# This script runs as root and handles UID/GID mapping before switching to regular user

# Check if Docker socket is mounted from host
# We always use the host Docker socket (no Docker-in-Docker daemon)
if [ -S /var/run/docker.sock ]; then
    # Docker socket exists - verify it's accessible
    if docker info >/dev/null 2>&1; then
        echo "✓ Docker socket is available and working"
    else
        echo "⚠ Docker socket exists but is not accessible yet (fixing permissions...)"
    fi
fi

# Fix Docker socket permissions if mounted from host
if [ -S /var/run/docker.sock ]; then
    DOCKER_SOCK_GID=$(stat -c '%g' /var/run/docker.sock)

    # Create or use existing group with matching GID
    if ! getent group "$DOCKER_SOCK_GID" >/dev/null 2>&1; then
        groupadd -g "$DOCKER_SOCK_GID" docker_host 2>/dev/null || true
    fi
 
    # Add regular user to the docker socket's group for access
    usermod -aG "$DOCKER_SOCK_GID" $USER_NAME 2>/dev/null || true
fi

# Get target UID/GID from environment (default to 1000)
TARGET_UID=${HOST_UID:-1000}
TARGET_GID=${HOST_GID:-1000}

# Get current regular user UID/GID
CURRENT_UID=$(id -u $USER_NAME)
CURRENT_GID=$(id -g $USER_NAME)

# Update UID/GID if they don't match
if [ "$TARGET_UID" != "$CURRENT_UID" ] || [ "$TARGET_GID" != "$CURRENT_GID" ]; then
    echo "Adjusting $USER_NAME user UID:GID from $CURRENT_UID:$CURRENT_GID to $TARGET_UID:$TARGET_GID"

    # Update group ID if needed
    if [ "$TARGET_GID" != "$CURRENT_GID" ]; then
        groupmod -g "$TARGET_GID" $USER_NAME 2>/dev/null || true
    fi
 
    # Update user ID if needed
    if [ "$TARGET_UID" != "$CURRENT_UID" ]; then
        usermod -u "$TARGET_UID" $USER_NAME 2>/dev/null || true
    fi
 
    # Fix ownership of home directory
    chown -R "$TARGET_UID:$TARGET_GID" /home/$USER_NAME 2>/dev/null || true
fi

# NOTE: We do NOT change ownership of /workspace
# The workspace is a host mount and should maintain host permissions
# OpenCode runs as the host user (via UID/GID mapping) so it already has the right permissions

# Switch to regular user and execute the command
exec setpriv --reuid="$TARGET_UID" --regid="$TARGET_GID" --init-groups \
  env HOME="/home/$USER_NAME" USER="$USER_NAME" LOGNAME="$USER_NAME" \
  bash -lic 'exec "$@"' -- "$@"
