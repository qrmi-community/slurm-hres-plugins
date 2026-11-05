#!/usr/bin/env bash
set -e

name="$1"

if command -v podman >/dev/null 2>&1 && podman container exists "$name" 2>/dev/null; then
    engine=podman
elif command -v docker >/dev/null 2>&1; then
    engine=docker
elif command -v podman >/dev/null 2>&1; then
    echo "Container '$name' was not found in Podman." >&2
    exit 1
else
    echo "Neither Docker nor Podman was found." >&2
    exit 1
fi

exec "$engine" exec -it "$name" bash
