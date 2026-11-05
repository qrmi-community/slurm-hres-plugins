#!/usr/bin/env bash
set -e

if command -v podman >/dev/null 2>&1 && podman container exists c1 2>/dev/null; then
    engine=podman
elif command -v docker >/dev/null 2>&1; then
    engine=docker
else
    echo "Neither Docker nor Podman was found." >&2
    exit 1
fi

"$engine" exec -it c2 bash