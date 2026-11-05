#!/usr/bin/env bash

set -e

# Use the engine that runs the slurmctld container (override with CONTAINER_ENGINE=...)
engine="${CONTAINER_ENGINE:-}"
if [ -z "$engine" ]; then
    if command -v podman >/dev/null 2>&1 && podman container exists slurmctld 2>/dev/null; then
        engine=podman
    elif command -v docker >/dev/null 2>&1; then
        engine=docker
    else
        engine=podman
    fi
fi

restart=false

for var in "$@"
do
    if [ "$var" = "slurmdbd.conf" ] || [ "$var" = "slurm.conf" ] || [ "$var" = "cgroup.conf" ] || [ "$var" = "gres.conf" ]
    then
        "$engine" exec -i slurmctld tee "/etc/slurm/$var" < "$var" >/dev/null
        restart=true
    fi
done
if $restart; then "$engine" compose restart; fi
