# QRMI plugin for Slurm HRES

Last updated: 2026-11-08
Targets: slurm-26-11-0-0rc1 (26.11.0 planned), QRMI 0.26.6 (main)

[![License](https://img.shields.io/github/license/qrmi-community/slurm-hres-plugins.svg?)](./LICENSE)
[![Current Release](https://img.shields.io/github/release/qrmi-community/slurm-hres-plugins.svg?)](https://github.com/qrmi-community/slurm-hres-plugins/releases)
![Platform](https://img.shields.io/badge/%F0%9F%92%BB_Platform-Linux-blue)
[![Lua 5.4+](https://img.shields.io/badge/lua-5.4%2B-blue.svg?logo=lua&logoColor=white)](https://www.lua.org/manual/5.4/)
[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.20650771.svg)](https://doi.org/10.5281/zenodo.20650771)

QRMI plugin for Slurm HRES lets the Slurm workload manager schedule quantum processors (QPUs) alongside CPUs and GPUs. It is a plugin for the Hierarchical Resources (HRES) interface of Slurm (hres/lua, introduced in Slurm 26.11 and currently in RC1), built on QRMI, the Quantum Resource Management Interface.

Each QPU backend is configured as an HRES resource that jobs request with --resources (or --licenses). Slurm checks the backend's availability before it allocates nodes, so jobs wait in the queue instead of holding classical resources idle. The plugin acquires the QPU for the job, passes the session to the job through the same environment variables as the earlier SPANK-based plugin (spank_qrmi), and releases it after the job ends. Calls to the quantum service are kept out of the scheduler's critical path, and each user keeps their own API key in a file they manage.

This release contains the hres/lua plugin (qrmi_hres.lua), a TaskProlog, an administration tool for per-user credential directories, an optional job_submit/lua check, a container-based Slurm cluster for testing, and design and verification notes. It is intended as a reference implementation for integrating quantum resources with Slurm through HRES.

Requirements: Slurm 26.11 or later (HRES with hres/lua), QRMI 0.26.4 or later (tested with 0.26.6), Lua 5.4.

## Contents

- [0. Setup](#0-setup)
  - [0.1 Prepare the cluster (admin, once)](#01-prepare-the-cluster-admin-once)
  - [0.2 Add a user (admin, once per user)](#02-add-a-user-admin-once-per-user)
  - [0.3 Register your API key (the user)](#03-register-your-api-key-the-user)
  - [0.4 Submit and check jobs (the user)](#04-submit-and-check-jobs-the-user)
- [1. Troubleshooting](#1-troubleshooting)
- [2. Background](#2-background)
- [3. Architecture](#3-architecture)
- [4. Deliverables](#4-deliverables)
- [5. resources.yaml](#5-resourcesyaml)
- [6. Container environment (Dockerfile additions)](#6-container-environment-dockerfile-additions)
- [7. Known issues and notes](#7-known-issues-and-notes)
- [8. Further documentation](#8-further-documentation)
- [9. References](#9-references)

---

## 0. Setup

The example is the container cluster (slurmctld, slurmdbd, c1, c2, login), run with Podman or Docker Compose; the commands below use podman, so use docker instead with Docker. The steps are grouped by who does them. For how to build and run this cluster for developing and testing the plugin, see [containers/docs/INSTALL.md](./containers/docs/INSTALL.md).

> [!NOTE]
> For more information about the Pasqal provider, please also refer to [this documentation](./docs/providers/pasqal/README.md).

| Step | Who | How often |
|---|---|---|
| 0.1 Prepare the cluster | Admin | Once |
| 0.2 Add a user | Admin | Once per user |
| 0.3 Register your API key | The user | At first, and when replacing the key |
| 0.4 Submit and check jobs | The user | Any time |

### 0.1 Prepare the cluster (admin, once)

**1. Build the image.** The Dockerfile builds QRMI and installs these files (details in [section 6](#6-container-environment-dockerfile-additions)).

| File | Location |
|---|---|
| `qrmi_hres.lua`, `hres_trace.lua`, `resources.yaml.example` | `/etc/slurm/` |
| `hres_qrmi_taskprolog.sh` | `/etc/slurm/` (0755) |
| `qrmi_user_dir.sh` | `/usr/local/sbin/` (0755) |
| `job_submit_qrmi.lua` (optional) | `/etc/slurm/job_submit_qrmi.lua.example` |

`/etc/slurm` is a named volume, so recreate the `etc_slurm` volume after updating the image.

**2. Add a volume for the credentials.** The user key files must be visible at the same path on slurmctld (read for acquire and release) and on c1 and c2 (read by the TaskProlog). If login can see it too, users can edit their own file. Add this to slurmctld, c1, c2 and login in compose.yml:

```yaml
services:
  slurmctld:
    volumes:
      - qrmi_creds:/qrmi-creds
  # add the same line to c1, c2 and login
volumes:
  qrmi_creds:
```

> [!NOTE]
> A bind mount of a macOS host directory (such as `/shared`) does not work. chown has no effect there and every file looks owned by root, so the owner check fails. Use a named volume. On a real cluster, a shared file system such as Lustre, GPFS or NFS works, as long as POSIX owners and permissions are enforced.

**3. Prepare `qrmi_config.json` (the site definitions).** Write `name`, `type`, the endpoints and so on for each backend. The site key in this file is used only for `status()` in maintenance and never reaches jobs or nodes.

```bash
cp /etc/slurm/qrmi_config.json.example /etc/slurm/qrmi_config.json
# after editing
chown root:slurm /etc/slurm/qrmi_config.json
chmod 640 /etc/slurm/qrmi_config.json
```

**4. Create `resources.yaml`.** Copy `resources.yaml.example` and set at least these two entries. Every backend listed in `resources.yaml` must be defined in `qrmi_config.json`; a backend without a definition keeps logging errors.

```yaml
      - name: path
        value: /etc/slurm/qrmi_hres.lua
      - name: user_config               # %u = user name, %U = uid
        value: /qrmi-creds/%u/config.json
```

slurmctld reads `resources.yaml` as SlurmUser, so SlurmUser must be able to read it. It holds no secrets, so 644 is fine too. Otherwise slurmctld exits with `fatal: Something wrong with reading resources.yaml: Unable to load file for reading` (`Permission denied` at debug level).

```bash
chown root:slurm /etc/slurm/resources.yaml
chmod 640 /etc/slurm/resources.yaml
```

**5. Set the TaskProlog and an Epilog in `slurm.conf`.**

```
PrologFlags=Alloc
TaskProlog=/etc/slurm/hres_qrmi_taskprolog.sh
Epilog=/bin/true    # required: without an Epilog, slurmd skips node_job_epilog (see 7.1)
```

> [!IMPORTANT]
> `Epilog` is required even if you have no epilog script. Without it, slurmd skips the plugin's node epilog and the job's files are left in `/run/hres_qrmi/` on the nodes ([7.1](#71-node_job_epilog-is-skipped-without-an-epilog-script-resolved-with-a-workaround)).

**6. Apply and check.** Restart compose (if slurm.conf changed) or run `scontrol reconfigure`. A line like this in slurmctld.log means the configuration was loaded:

```
hres_qrmi: ibm_kingston: QRMI resource ibm_kingston type=ibm-quantum-compute-service release=deferred
  user_credentials=required user_keys=QRMI_IBM_QCS_IAM_APIKEY,QRMI_IBM_QCS_SERVICE_CRN required=QRMI_IBM_QCS_IAM_APIKEY
```

The `type=` and `user_keys=` values are what users need for [step 0.3](#03-register-your-api-key-the-user).

If the log shows `hres_qrmi: <res>: ..., disabling the resource` instead, the plugin could not read the resource's definition, and jobs on it wait with reason `HRESDisabled`. Check that `qrmi_config.json` is owned by `root:slurm` with mode 640 (SlurmUser must be able to read it) and that it defines the resource, then run `scontrol reconfigure`.

### 0.2 Add a user (admin, once per user)

As root, create the user's directory:

```bash
QRMI_USER_BASE=/qrmi-creds qrmi_user_dir.sh alice bob
# created /qrmi-creds/alice (alice:slurm 2750)
# created /qrmi-creds/bob (alice:slurm 2750)
```

| Path | Owner | Mode | Meaning |
|---|---|---|---|
| `/qrmi-creds/<user>/` | `<user>:slurm` | 2750 | The user can create and edit files. SlurmUser reads through the group. Other users cannot enter. setgid gives new files the slurm group automatically |
| `/qrmi-creds/<user>/config.json` | `<user>:slurm` | 640 | The user can write it. SlurmUser can read it |

> [!WARNING]
> Never add users to the slurm group: they could read everyone's keys. The script warns if the group has members.

- `QRMI_USER_BASE` must match `user_config` in `resources.yaml` ([5.1](#51-plugin-config-entries-qrmi_hreslua)).
- Optional: to report a bad file at submit time, install `job_submit_qrmi.lua` as `/etc/slurm/job_submit.lua` and add `JobSubmitPlugins=lua` to `slurm.conf`. Set `QRMI_RESOURCES` and `USER_CONFIG` in it to match `resources.yaml`.

### 0.3 Register your API key (the user)

Ask the admin for the **resource name** and **type** of the backend you use (the values in the log of [step 0.1-6](#01-prepare-the-cluster-admin-once)). Write only your own keys, in the same format as `qrmi_config.json`:

```bash
umask 027
cat > /qrmi-creds/$(id -un)/config.json <<'EOF'
{
  "resources": [
    {
      "name": "ibm_kingston",
      "type": "ibm-quantum-compute-service",
      "environment": {
        "QRMI_IBM_QCS_IAM_APIKEY": "<your API key>",
        "QRMI_IBM_QCS_SERVICE_CRN": "<your instance>"
      }
    }
  ]
}
EOF
chmod 640 /qrmi-creds/$(id -un)/config.json
```

`$(id -un)` is your user name. `$USER` is not always set (for example in a shell opened with `podman exec`), and the file would then end up in `/qrmi-creds/config.json`, where the plugin does not look.

**Rules**

- `name` and `type` must match the site definition. With a different type QRMI drops the keys, so the plugin reports an error.
- Key names follow the type: `QRMI_IBM_QCS_*` for `ibm-quantum-compute-service`, `QRMI_IBM_QS_*` for `ibm-quantum-system`.
- Only the allowed keys are used (by default the API key and the service CRN). Endpoints and other entries are ignored; the site values are used.
- Owner: you. Group: slurm. Mode: 640. No symbolic links. With 600, SlurmUser cannot read the file.

**Check the structure without showing the keys**

```bash
ls -l /qrmi-creds/$(id -un)/config.json          # -rw-r----- <user> slurm
jq '.resources[] | {name, type, keys: (.environment|keys)}' /qrmi-creds/$(id -un)/config.json
```

**Replacing the key:** edit the file at any time. Jobs submitted afterwards use the new key. For running jobs, the controller keeps the key used for acquire until the release.

### 0.4 Submit and check jobs (the user)

```bash
sbatch --resources=ibm_kingston:1 job.sh
squeue --me
```

If the job does not start, look up its reason in [1. Troubleshooting](#1-troubleshooting).

---

## 1. Troubleshooting

### 1.1 Job states in `squeue`

| `squeue` reason | Meaning | What to do |
|---|---|---|
| `Resources` | The backend is busy, has no free slots, or the status is stale. With `cred_fail=pend`, also after a credential failure (`cred_retry` seconds) | Wait. For a credential failure, fix the file and wait |
| `BeginTime` | The job was requeued after a failure at start (e.g. a credential failure); it is scheduled again after the requeue delay (by default about 2 minutes) | Wait. With `cred_fail=hold`, the cause then appears as the reason |
| `hres_qrmi: <res> credentials: ...` | The job is held because of a credential failure (`cred_fail=hold`, the default). The message is the cause | Fix the file (see below), then `scancel` and resubmit. An admin can also `scontrol release` the job |
| `ReqNodeNotAvail, May be reserved for other job` | `count` is used up | Wait for other jobs to finish |
| `HRESDisabled` | The backend is not online (e.g. calibration) or `status()` fails | Wait; tell the admin if it persists |

### 1.2 Credential errors

Credential problems appear as the job's reason in `squeue` (with `cred_fail=hold`) and in slurmctld.log after `user credentials:`, with the cause (never the key values).

| Log message | Cause and fix |
|---|---|
| `... is missing or not readable by SlurmUser` | No file, the group is not slurm, or the mode is 600 |
| `... is not owned by the job's user` | The owner is not the user (also when chown has no effect on a bind mount) |
| `... is writable by group or others` | `chmod 640` |
| `... is a symbolic link` | Replace it with a regular file |
| `type of <res> is X, but the site defines it as Y` | Change `type` to the site's value |
| `... lacks QRMI_..._IAM_APIKEY for <res>` | Check `name` and the key names, which depend on the type (`QRMI_IBM_QS_...` for `ibm-quantum-system`, `QRMI_IBM_QCS_...` for `ibm-quantum-compute-service`) |
| Authentication error at acquire (401, 403, ...) | Wrong API key or CRN |
| `rejected by the backend: ...` | The backend refused the job's user without a user key (401 or 403), e.g. Warden (Pasqal Local): the user is not in `api.authorized_users`, or SlurmUser is not in `api.admin_users`. The admin fixes the cause. The reason shows the first 200 characters of the answer; slurmctld.log has all of it. A MUNGE error (e.g. Warden has another MUNGE key) is not held: the user's jobs stay pending (`Resources`) for `cred_retry` seconds, then try again |

### 1.3 After fixing the cause

After fixing the file, resubmit the held job. The hold is an admin hold, so only an admin can release it instead (`scontrol release <jobid>`). This is also the way after fixing the site's side (`resources.yaml` or `qrmi_config.json`): `scontrol reconfigure` loads the new settings but does not release held jobs. Once released, the job reads the user's file again at its next start; if the problem remains, it is held again with the new cause. With `cred_fail=pend`, the job is retried automatically once `cred_retry` (default 300 s) has passed; to retry at once, the admin runs `rm /var/spool/slurmctld/hres_qrmi/credfail/<res>.<uid>` on slurmctld.

---

## 2. Background

### 2.1 Slurm HRES plugins

slurm-26-11-0-0rc1 gained a plugin interface for Hierarchical Resources (HRES, beta since 25.05). A plugin is enabled per resource and lets an external service take part in the lifecycle of the jobs that use that resource. The only implementation today is `hres/lua` (a Lua script).

| Callback | Runs on | Typical use |
|---|---|---|
| `hres_create_context` / `hres_destroy_context` | slurmctld, when the configuration is read | Setup and teardown |
| `hres_maintenance` | slurmctld, every `maintenance_cycle` seconds | Monitor the external service, set `disable_layer` |
| `hres_controller_job_prerun` | slurmctld, **holding the job lock** | Synchronous check; may return a payload for the nodes |
| `hres_controller_job_async_prerun` (optional) | slurmctld, separate thread (job is CONFIGURING) | Slow reservation work |
| `hres_controller_job_revoke` | slurmctld, **holding the job lock** | Undo a pre-run |
| `hres_controller_job_epilog` | slurmctld, **holding the job lock** | Release after all node epilogs finish |
| `hres_node_job_prolog` / `epilog` | slurmd (root) | Node-side setup and cleanup |
| `hres_node_task_prolog` / `epilog` | slurmstepd (root) | Per-task work |
| `hres_node_user_task_prolog` | Inside the task process (as the user) | Per-task work |

Key points:

- `config` (resources.yaml), `plugin_args` (`--resources=x:1[k=v]`) and `payload` (the pre-run return value) travel to the nodes in the job credential, so **the job's user can read them**. Never put secrets in them.
- If the pre-run returns `ESLURM_HRES_REMOTE_FAIL`, the job stays pending. Any other error puts the job on hold.
- Callbacks that run under the job lock stall all of slurmctld. **No network calls there.**
- **HRES callbacks cannot set the job's environment** (tasks are started with `execve(..., step->env)`).

### 2.2 QRMI

Quantum Resource Management Interface. Written in Rust, with C, Python and Lua APIs. The Lua binding is loaded with `require("qrmi")`.

- `qrmi.load_config(path)` → `config:resource_def(name)` → `{name, type, environments}`
- `qrmi.new_from_config(id, type, env_table)` → a resource handle
- `resource:acquire()` → token, `resource:release([token])`, `resource:status()`
- `resource:detach()` (QRMI 0.26.4 or later) → the cached token, without releasing it
- `resource:free()` frees the handle. A handle releases the token it has cached when it is freed or garbage-collected; the plugin uses `detach()` to keep the token for the job ([design 1.6](./docs/design.md#16-keeping-the-token-after-the-async-pre-run)).

### 2.3 spank_qrmi (the previous approach)

[spank_qrmi](https://github.com/qiskit-community/spank-plugins/tree/main/plugins/spank_qrmi) is the Slurm SPANK plugin for QRMI in [qiskit-community/spank-plugins](https://github.com/qiskit-community/spank-plugins), described in the [IBM Quantum Slurm plugin guide](https://quantum.cloud.ibm.com/docs/guides/slurm-plugin). It acquires the QPU when the job starts running, after its nodes are allocated, and exports the QRMI settings and the acquisition token to the job as environment variables.

This document refers to it as the baseline. `qrmi_hres.lua` exports the same environment variable names ([design 1.7](./docs/design.md#17-job-environment-same-names-as-spank_qrmi)), so programs that read them keep working, but it checks QPU availability before nodes are allocated, and QPUs are requested with `--resources`.

---

## 3. Architecture

[Presentation slide](./slurm_hres_qrmi.pdf)


**One HRES resource = one QRMI resource (backend).** Every backend is reachable from both c1 and c2, so a resource has a single layer covering `c[1-2]` rather than splitting nodes. Users pick a backend by resource name.

```
sbatch --resources=ibm_kingston:1 job.sh
sbatch --resources='ibm_kingston:1,ibm_other:1' job.sh   # AND (all required)
sbatch --licenses='ibm_kingston:1|ibm_other:1' job.sh   # OR ([...] and (...) not allowed)
```

`--resources` is the HRES option of sbatch, srun and salloc. It only appends its value to the job's licenses, so `--licenses` (`-L`) requests the same thing; use `--licenses` on a Slurm without `--resources` (it was added to master in 2025-09), and for OR (`|`), which is a `--licenses` feature.

---

## 4. Deliverables

| File | Location | Role |
|---|---|---|
| `hres_trace.lua` | `/etc/slurm/` | Logs every callback with its arguments; for verification |
| `qrmi_hres.lua` | `/etc/slurm/` | The QRMI integration itself |
| `hres_qrmi_taskprolog.sh` | `/etc/slurm/` (0755) | TaskProlog that exports the `.env` files into the job environment |
| `resources.yaml.example` | `/etc/slurm/` | HRES definitions; copy to `resources.yaml` to enable |
| `qrmi_user_dir.sh` | `/usr/local/sbin/` (0755) | Creates the per-user credential directories (run as root) |
| `job_submit_qrmi.lua` | `/etc/slurm/job_submit_qrmi.lua.example` | Optional. Checks the credential file's presence and permissions at submit time (job_submit/lua) |
| `Dockerfile` | Build directory | Adds the QRMI build and installs the files above |

The Lua scripts must be at the same path on the controller and every node, **owned by root and writable only by root**.

---

## 5. resources.yaml

```yaml
- resource: ibm_kingston            # = QRMI resource name
  mode: MODE_1
  plugin:
    type: hres/lua
    config:
      - name: path
        value: /etc/slurm/qrmi_hres.lua      # hres_trace.lua for verification
      - name: qrmi_config
        value: /etc/slurm/qrmi_config.json
    maintenance_cycle: 10            # also drives deferred releases; keep it short
    maintenance_timeout: 10
  layers:
    - layer_name: all
      nodes: ["c[1-2]"]
      count: 1                       # -1 to let QRMI slots govern concurrency
```

### 5.1 Plugin config entries (qrmi_hres.lua)

| Entry | Default | Description |
|---|---|---|
| `path` | (required) | Path of the script |
| `qrmi_config` | `/etc/slurm/qrmi_config.json` | QRMI definitions; needed on the controller and the nodes |
| `qrmi_resource` | HRES resource name | QRMI resource name |
| `lua_cpath` | none | Set only if `qrmi.so` is not in a standard location |
| `state_dir` | `/var/spool/slurmctld/hres_qrmi` | Controller state directory (must be writable by SlurmUser) |
| `env_dir` | `/run/hres_qrmi` | Node-side directory for the `.env` files |
| `release` | `deferred` | `deferred`: maintenance performs releases. `immediate`: release inside epilog/revoke |
| `auto_disable` | `yes` | Toggle `disable_layer` from status (overrides a manual DisableLayer) |
| `admission` | `yes` | Run the admission check in the pre-run |
| `status_max_age` | `60` | Max age of the status cache in seconds; keep above `maintenance_cycle` |
| `user_credentials` | `required` | `required`: per-user credentials ([design 2](./docs/design.md#2-credentials)) for types with user keys (`user_keys`, or the type's default); `pasqal-local` and `pasqal-cloud` have none (Pasqal Local: Warden identifies the job's user by MUNGE; Pasqal Cloud: the job reads the user's Pasqal config file, see [7.2](#72-other-notes)), so they need no user file. `off`: the site key for every job (as spank_qrmi) |
| `user_config` | `/shared/qrmi/%u/config.json` | Path of the user's file. `%u` = user name, `%U` = uid |
| `user_keys` | Per-type default | Keys taken from the user's file (comma-separated). By default the API key and the service CRN |
| `user_required` | The `user_keys` ending in `APIKEY` or `AUTH_TOKEN` | Keys that must be in the user's file |
| `cred_retry` | `300` | Seconds a credential failure is remembered: within it, the next pre-run of the user's jobs holds them (`hold`) or keeps them pending (`pend`) |
| `cred_fail` | `hold` | After a credential failure: `hold` holds the job with the cause as its reason (shown by `squeue`); `pend` keeps the user's jobs pending (reason `Resources`) for `cred_retry` seconds |
| `release_give_up` | `86400` | Seconds after the first failed release after which a release that keeps failing is dropped (and logged) |

---

## 6. Container environment (Dockerfile additions)

The base is the spank-plugins demo Dockerfile (Rocky Linux 9, Slurm built from source, with `lua-devel`).

1. Build QRMI right after Slurm (`ARG QRMI_REF=main`).
   - `libqrmi.so` → `/usr/local/lib` (registered in `/etc/ld.so.conf.d/qrmi.conf` and ldconfig)
   - `qrmi.so` → `/usr/lib64/lua/5.4/` (the standard path for Rocky 9's Lua 5.4; built against the same Lua as Slurm)
   - The build checks that `require("qrmi")` works
2. Create `/var/spool/slurmctld/hres_qrmi` owned by the slurm user.
3. Copy `resources.yaml.example`, `hres_trace.lua`, `qrmi_hres.lua` and `hres_qrmi_taskprolog.sh` into `/etc/slurm`, owned by root.
4. Copy `qrmi_user_dir.sh` to `/usr/local/sbin/` and `job_submit_qrmi.lua` to `/etc/slurm/job_submit_qrmi.lua.example`.

The named volume for the credentials (`qrmi_creds:/qrmi-creds`) is added in compose.yml ([0.1](#01-prepare-the-cluster-admin-once)).

Notes:

- `/etc/slurm` is a named volume (`etc_slurm`), so the volume must be recreated after the image changes.
- Enabling HRES itself requires no slurm.conf change; this plugin still needs the TaskProlog and Epilog lines ([0.1, step 5](#01-prepare-the-cluster-admin-once)). slurmctld reads `resources.yaml` automatically if it sits next to slurm.conf (a syntax error is fatal).
- `DebugFlags=License` helps with the initial checks.

---

## 7. Known issues and notes

### 7.1 node_job_epilog is skipped without an Epilog script (resolved with a workaround)

**Symptom:** node_job_epilog never ran, so `/run/hres_qrmi/job_<id>/` was left on the nodes after every job. hres_trace.lua showed the node prolog but not the node epilog.

**Cause:** in `_rpc_terminate_job()` (`src/slurmd/slurmd/req.c`), slurmd takes a shortcut when no job step is still running, no `Epilog` is configured and no SPANK plugin has an epilog: it replies `ALREADY_COMPLETE` without calling `run_epilog()`. The condition does not look at HRES, so `hres_g_node_job_epilog()` is skipped as well. A batch job that ends normally takes this path. (`sent ALREADY_COMPLETE` is logged only at debug4.)

```c
if ((nsteps == 0) && !slurm_conf.epilog && !spank_has_epilog()) {
```

**Workaround (verified 2026-10-25):** configure any Epilog in slurm.conf, so the shortcut is not taken.

```
Epilog=/bin/true
```

slurmd.log then shows `completed epilog for JobId=...`, and `/run/hres_qrmi/` is empty after the job.

**Proper fix (to report to SchedMD):** also skip the shortcut when the job has HRES node callbacks, e.g. when the credential carries a `job_hres_list`.

### 7.2 Other notes

> [!WARNING]
> Do not enable spank_qrmi at the same time; it would acquire the QPU twice.

- Differences from spank_qrmi: overriding credentials through the job environment (`ibm_kingston_QRMI_..._APIKEY=... sbatch`) is replaced by the per-user credential file.
- slurmctld's `state_dir` (`/var/spool/slurmctld`) is lost when the container is recreated. Making it a named volume is recommended, so tokens waiting for release are not lost.
- Pasqal Cloud: the controller needs no credentials (`status()` uses a public endpoint; `acquire()` and `release()` do nothing for this type). The job's QRMI authenticates with the user's Pasqal config file (`username`/`password`, `client_id`/`client_secret` or `token`, and `project_id`), the first one found of:
  1. `$PASQAL_CONFIG_ROOT/.pasqal/config`, set by the user in the job's environment
  2. `$<qpu>_PASQAL_CONFIG_ROOT/.pasqal/config`: a site sets it with `PASQAL_CONFIG_ROOT` in the resource's `environment` in `qrmi_config.json`, which the TaskProlog exports with the resource prefix. `~` and `$VAR` are expanded in the job; use `$HOME/...` rather than `$USER`, which is not always set (e.g. jobs submitted from `podman exec`)
  3. `$HOME/.pasqal/config`, the default

  A root without a config file falls back to the next one without a warning, so check the path with `RUST_LOG=debug` (`Reading Pasqal config file: ...`). `$HOME` must be readable on the compute nodes. A missing or wrong config file shows as an authentication error in the job's output, not as a held job. To use per-user credential files ([design 2](./docs/design.md#2-credentials)) for Pasqal Cloud instead, set `user_keys` (e.g. `QRMI_PASQAL_CLOUD_AUTH_TOKEN,QRMI_PASQAL_CLOUD_PROJECT_ID`) in the resource's plugin config.
- Pasqal Local: `acquire()` and `release()` run on slurmctld as SlurmUser (UID 990 in the containers), and Warden lets only the users in its `api.admin_users` open and revoke sessions for other users. Add SlurmUser's UID there, e.g. `admin_users: ["0", "990"]`. If Warden refuses the session (401 or 403), the job is held with Warden's answer as its reason, as for a credential failure; a MUNGE error keeps the user's jobs pending for `cred_retry` seconds instead.
- For more information about the Pasqal provider, please also refer to [this documentation](./docs/providers/pasqal/README.md).
- HRES as a whole is still beta, so the configuration format may change.
- Jobs submitted with `podman exec login` run as root (uid=0). Use `-u user` to submit as a regular user when checking permissions.

---

## 8. Further documentation

| Document | Content |
|---|---|
| [docs/design.md](./docs/design.md) | How `qrmi_hres.lua` works (callbacks, admission check, state files, job environment) and the design of the per-user credentials |
| [docs/verification.md](./docs/verification.md) | Verification results on the container cluster and the real backend |
| [docs/providers/pasqal/README.md](./docs/providers/pasqal/README.md) | The Pasqal provider |

---

## 9. References

- [Slurm](https://github.com/SchedMD/slurm): `doc/html/hres.shtml`, `doc/man/man5/resources.yaml.5`, `src/plugins/hres/lua/hres_lua.c`, `src/interfaces/hres.c`, `src/slurmctld/licenses.c`
- [QRMI](https://github.com/qiskit-community/qrmi): `lua/lua_qrmi.c`, `docs/development/api_references/LUA_API.rst`, `src/ibm/quantum_system.rs`
- [spank-plugins](https://github.com/qiskit-community/spank-plugins): `plugins/spank_qrmi/spank_qrmi.c`
- [QRMI (PyPI)](https://pypi.org/project/qrmi/)
- [IBM Quantum: Slurm plugin](https://quantum.cloud.ibm.com/docs/guides/slurm-plugin)
