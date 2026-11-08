#!/bin/bash
set -e

# JWT signing key for slurmctld/slurmdbd (AuthAltTypes=auth/jwt), used by
# slurmrestd and Slurm-web. Created once in the shared etc_slurm volume.
JWT_KEY=/etc/slurm/jwt_hs256.key
ensure_jwt_key() {
    if [ ! -s "$JWT_KEY" ]
    then
        echo "---> Creating the Slurm JWT signing key ($JWT_KEY) ..."
        tmp="$(mktemp /etc/slurm/.jwt_hs256.key.XXXXXX)"
        dd if=/dev/urandom of="$tmp" bs=32 count=1 status=none
        chown slurm:slurm "$tmp"
        chmod 0600 "$tmp"
        mv -n "$tmp" "$JWT_KEY" || true
        rm -f "$tmp"
    fi
}

if [ "$1" = "slurmdbd" ]
then
    ensure_jwt_key

    echo "---> Starting the MUNGE Authentication service (munged) ..."
    gosu munge /usr/sbin/munged

    echo "---> Starting the Slurm Database Daemon (slurmdbd) ..."

    {
        # shellcheck source=/dev/null
        . /etc/slurm/slurmdbd.conf
        # shellcheck disable=SC2154 # set by slurmdbd.conf
        until echo "SELECT 1" | mysql -h "$StorageHost" -u"$StorageUser" -p"$StoragePass" > /dev/null 2>&1
        do
            echo "-- Waiting for database to become active ..."
            sleep 2
        done
    }
    echo "-- Database is now active ..."

    exec gosu slurm /usr/sbin/slurmdbd -Dvvv
fi

if [ "$1" = "slurmctld" ]
then
    echo "---> Starting the MUNGE Authentication service (munged) ..."
    gosu munge /usr/sbin/munged

    echo "---> Waiting for slurmdbd to become active before starting slurmctld ..."

    until true 2>/dev/null >/dev/tcp/slurmdbd/6819
    do
        echo "-- slurmdbd is not available.  Sleeping ..."
        sleep 2
    done
    echo "-- slurmdbd is now active ..."
    ensure_jwt_key

    echo "---> Starting the Slurm Controller Daemon (slurmctld) ..."
    if /usr/sbin/slurmctld -V | grep -q '17.02' ; then
        exec gosu slurm /usr/sbin/slurmctld -Dvvv
    else
        exec gosu slurm /usr/sbin/slurmctld -i -Dvvv
    fi
fi

if [ "$1" = "slurmd" ]
then
    echo "---> Starting the MUNGE Authentication service (munged) ..."
    gosu munge /usr/sbin/munged

    echo "---> Waiting for slurmctld to become active before starting slurmd..."

    until true 2>/dev/null >/dev/tcp/slurmctld/6817
    do
        echo "-- slurmctld is not available.  Sleeping ..."
        sleep 2
    done
    echo "-- slurmctld is now active ..."

    echo "---> Starting the Slurm Node Daemon (slurmd) ..."
    exec /usr/sbin/slurmd -Dvvv
fi

if [ "$1" = "slurmrestd" ]
then
    echo "---> Waiting for slurmctld to become active before starting slurmrestd ..."

    until true 2>/dev/null >/dev/tcp/slurmctld/6817
    do
        echo "-- slurmctld is not available.  Sleeping ..."
        sleep 2
    done
    echo "-- slurmctld is now active ..."

    # slurmrestd refuses to run as root or as SlurmUser, so it runs as the
    # dedicated slurmrestd user. SLURM_JWT=daemon: forward each client's JWT
    # (X-SLURM-USER-TOKEN header) to slurmctld/slurmdbd.
    echo "---> Starting the Slurm REST API daemon (slurmrestd) on port 6820 ..."
    export SLURM_JWT=daemon
    exec gosu slurmrestd /usr/sbin/slurmrestd -v -a rest_auth/jwt 0.0.0.0:6820
fi

if [ "$1" = "login" ]
then
    echo "---> Starting the MUNGE Authentication service (munged) ..."
    gosu munge /usr/sbin/munged
    exec tail -f /dev/null
fi

exec "$@"
