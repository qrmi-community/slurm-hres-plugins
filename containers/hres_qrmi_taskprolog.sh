#!/bin/bash
#
# (C) Copyright IBM 2026
# (C) Copyright Pasqal SAS 2026
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

# hres_qrmi_taskprolog.sh - Slurm TaskProlog for qrmi_hres.lua
#
# Runs as the user before each task. Every "export NAME=value" line printed
# on stdout is added to the task environment. It exports what qrmi_hres.lua
# wrote for the job on this node, with the same names as spank_qrmi:
#
#   <qpu>_QRMI_JOB_ACQUISITION_TOKEN, <qpu>_QRMI_..., QRMI_JOB_QPU_RESOURCES,
#   QRMI_JOB_QPU_TYPES, QRMI_JOB_ID, QRMI_JOB_UID
#
# and <qpu>_QRMI_JOB_QPU_SLOTS, which spank_qrmi does not set: the count the
# job requested for the resource (--license=ibm_kingston:2 -> 2).
#
# With user credentials (user_credentials=required, the default), it also
# exports the user's own keys, read here as the user from the file named in
# <qpu>.user (line 1: path, line 2: comma-separated keys), e.g.
#   ibm_kingston_QRMI_IBM_QS_IAM_APIKEY, ibm_kingston_QRMI_IBM_QS_SERVICE_CRN
# Needs jq, or python3 as a fallback.
#
# slurm.conf:  TaskProlog=/etc/slurm/hres_qrmi_taskprolog.sh
# If a TaskProlog is already set, call this script from it instead.
#
# ENV_DIR must match the env_dir entry of the plugin config.

ENV_DIR=/run/hres_qrmi
dir="$ENV_DIR/job_${SLURM_JOB_ID}"

[ -d "$dir" ] || exit 0

# Print the value of key $3 of resource $2 from the QRMI config file $1.
user_value() {
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg n "$2" --arg k "$3" \
            '.resources[] | select(.name == $n) | .environment[$k] // empty' \
            "$1" 2>/dev/null | head -n 1
    else
        python3 -I -c '
import json, sys
f, n, k = sys.argv[1:4]
for r in json.load(open(f)).get("resources", []):
    if r.get("name") == n:
        v = r.get("environment", {}).get(k)
        if v is not None:
            print(v)
        break
' "$1" "$2" "$3" 2>/dev/null
    fi
}

export_user_keys() {
    local name="$1" cfg keys key value
    { IFS= read -r cfg; IFS= read -r keys; } < "$2"
    if [ ! -r "$cfg" ]; then
        echo "print hres_qrmi: cannot read $cfg for $name"
        return
    fi
    for key in ${keys//,/ }; do
        value=$(user_value "$cfg" "$name" "$key")
        [ -n "$value" ] && echo "export ${name}_${key}=${value}"
    done
}

resources=""
types=""
for env_file in "$dir"/*.env; do
    [ -e "$env_file" ] || continue
    name=$(basename "$env_file" .env)
    while IFS= read -r line; do
        [ -n "$line" ] && echo "export $line"
    done < "$env_file"
    if [ -r "$dir/$name.user" ]; then
        export_user_keys "$name" "$dir/$name.user"
    fi
    resources="${resources:+$resources,}$name"
    types="${types:+$types,}$(cat "$dir/$name.type" 2>/dev/null)"
done

[ -n "$resources" ] || exit 0

echo "export QRMI_JOB_QPU_RESOURCES=$resources"
echo "export QRMI_JOB_QPU_TYPES=$types"
echo "export QRMI_JOB_ID=$SLURM_JOB_ID"
echo "export QRMI_JOB_UID=$(id -u)"
