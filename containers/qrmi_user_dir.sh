#!/bin/bash
#
# (C) Copyright IBM 2026
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# qrmi_user_dir.sh - create the per-user QRMI credential directory (as root)
#
#   qrmi_user_dir.sh <user> [<user> ...]
#
# Creates <BASE>/<user> owned by <user>, group SLURM_GROUP, mode 2750:
#   * the user can create, edit and replace config.json at any time
#   * SlurmUser (slurmctld) can read it, through the group
#   * other users cannot even enter the directory
#   * setgid: files created inside get the group automatically
# BASE must match the user_config entry of the plugin config
# (default /shared/qrmi/%u/config.json) and be mounted on the controller
# and on the compute nodes.

set -euo pipefail

BASE=${QRMI_USER_BASE:-/shared/qrmi}
SLURM_GROUP=${SLURM_GROUP:-slurm}

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ $# -ge 1 ] || { echo "usage: $0 <user> [<user> ...]" >&2; exit 1; }

install -d -o root -g root -m 0755 "$BASE"

for user in "$@"; do
    id "$user" >/dev/null 2>&1 || { echo "no such user: $user" >&2; exit 1; }
    dir="$BASE/$user"
    install -d -o "$user" -g "$SLURM_GROUP" -m 2750 "$dir"
    if [ -e "$dir/config.json" ]; then
        chgrp "$SLURM_GROUP" "$dir/config.json"
        chmod g-w,o-rwx "$dir/config.json"
    fi
    echo "created $dir ($(stat -c '%U:%G %a' "$dir"))"
done

members=$(getent group "$SLURM_GROUP" | cut -d: -f4)
if [ -n "$members" ]; then
    echo "WARNING: group $SLURM_GROUP has members ($members); they can read every user's keys" >&2
fi
