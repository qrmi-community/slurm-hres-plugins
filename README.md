# Slurm HRES Plugin for QRMI

Last updated: 2026-10-29
Targets: Slurm master (26.11.0 planned, after the `51036-HRES-plugin` merge), QRMI 0.26.4 or later (main)

[![License](https://img.shields.io/github/license/qiskit-community/qrmi.svg?)](https://opensource.org/licenses/Apache-2.0) <!--- long-description-skip-begin -->
[![Current Release](https://img.shields.io/github/release/qrmi-community/slurm-hres-plugins.svg?)](https://github.com/qrmi-community/slurm-hres-plugins/releases)
![Platform](https://img.shields.io/badge/%F0%9F%92%BB_Platform-Linux-blue)
[![Lua 5.4+](https://img.shields.io/badge/lua-5.4%2B-blue.svg?logo=lua&logoColor=white)](https://www.lua.org/manual/5.4/)
[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.20650771.svg)](https://doi.org/10.5281/zenodo.20650771)

Slurm HRES Plugin for QRMI lets the Slurm workload manager schedule quantum processors (QPUs) alongside CPUs and GPUs. It is a plugin for the Hierarchical Resources (HRES) interface of Slurm (hres/lua, introduced in Slurm 26.11 and currently in beta), built on QRMI, the Quantum Resource Management Interface.

Each QPU backend is configured as an HRES resource that jobs request with --license. Slurm checks the backend's availability before it allocates nodes, so jobs wait in the queue instead of holding classical resources idle. The plugin acquires the QPU for the job, passes the session to the job through the same environment variables as the earlier SPANK-based plugin (spank_qrmi), and releases it after the job ends. Calls to the quantum service are kept out of the scheduler's critical path, and each user keeps their own API key in a file they manage.

This release contains the hres/lua plugin (qrmi_hres.lua), a TaskProlog, an administration tool for per-user credential directories, an optional job_submit/lua check, a container-based Slurm cluster for testing, and design and verification notes. It is intended as a reference implementation for integrating quantum resources with Slurm through HRES.

Requirements: Slurm 26.11 or later (HRES with hres/lua), QRMI 0.26.4 or later, Lua 5.4.

## Contents

**Set up and use**

- [0. Setup](#0-setup)\
  [0.1 Prepare the cluster](#01-prepare-the-cluster-admin-once) · [0.2 Add a user](#02-add-a-user-admin-once-per-user) · [0.3 Register your API key](#03-register-your-api-key-the-user) · [0.4 Submit and check jobs](#04-submit-and-check-jobs-the-user)

**Design**

- [1. Background](#1-background)\
  [1.1 Slurm HRES plugins](#11-slurm-hres-plugins) · [1.2 QRMI](#12-qrmi) · [1.3 spank_qrmi](#13-spank_qrmi-the-previous-approach)
- [2. Architecture](#2-architecture)
- [3. Deliverables](#3-deliverables)
- [4. resources.yaml](#4-resourcesyaml)\
  [4.1 Plugin config entries](#41-plugin-config-entries-qrmi_hreslua)
- [5. qrmi_hres.lua in detail](#5-qrmi_hreslua-in-detail)\
  [5.1 What each callback does](#51-what-each-callback-does) · [5.2 Admission check](#52-admission-check-may-the-job-run) · [5.3 Keeping network calls out of the job lock](#53-keeping-network-calls-out-of-the-job-lock) · [5.4 State files](#54-state-files-state_dir) · [5.5 How often acquire is called](#55-how-often-acquire-is-called) · [5.6 Keeping the token after the async pre-run](#56-keeping-the-token-after-the-async-pre-run) · [5.7 Job environment](#57-job-environment-same-names-as-spank_qrmi)
- [6. Container environment](#6-container-environment-dockerfile-additions)

**Status**

- [7. Verification results](#7-verification-results)\
  [7.1 Callback trace with hres_trace.lua](#71-callback-trace-with-hres_tracelua-2026-10-22) · [7.2 qrmi_hres.lua against the real backend](#72-qrmi_hreslua-against-the-real-backend-2026-10-24)
- [8. Open issues](#8-open-issues)\
  [8.1 node_job_epilog is skipped without an Epilog script](#81-node_job_epilog-is-skipped-without-an-epilog-script-resolved-with-a-workaround) · [8.2 Credentials](#82-credentials) · [8.3 Other](#83-other)

**Reference**

- [9. References](#9-references)

---

## 0. Setup

The example is the podman container cluster (slurmctld, slurmdbd, c1, c2, login). The steps are grouped by who does them.

| Step | Who | How often |
|---|---|---|
| 0.1 Prepare the cluster | Admin | Once |
| 0.2 Add a user | Admin | Once per user |
| 0.3 Register your API key | The user | At first, and when replacing the key |
| 0.4 Submit and check jobs | The user | Any time |

### 0.1 Prepare the cluster (admin, once)

**1. Build the image.** The Dockerfile builds QRMI and installs these files (details in section 6).

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

> **Note:** a bind mount of a macOS host directory (such as `/shared`) does not work. chown has no effect there and every file looks owned by root, so the owner check fails. Use a named volume. On a real cluster, a shared file system such as Lustre, GPFS or NFS works, as long as POSIX owners and permissions are enforced.

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

**5. Set the TaskProlog and an Epilog in `slurm.conf`.**

```
PrologFlags=Alloc
TaskProlog=/etc/slurm/hres_qrmi_taskprolog.sh
Epilog=/bin/true    # required: without an Epilog, slurmd skips node_job_epilog (8.1)
```

**6. Apply and check.** Restart compose (if slurm.conf changed) or run `scontrol reconfigure`. A line like this in slurmctld.log means the configuration was loaded:

```
hres_qrmi: ibm_kingston: QRMI resource ibm_kingston type=ibm-quantum-compute-service release=deferred
  user_credentials=required user_keys=QRMI_IBM_QCS_IAM_APIKEY,QRMI_IBM_QCS_SERVICE_CRN required=QRMI_IBM_QCS_IAM_APIKEY
```

The `type=` and `user_keys=` values are what users need for step 0.3.

If the log shows `hres_qrmi: <res>: ..., disabling the resource` instead, the plugin could not read the resource's definition, and jobs on it wait with reason `HRESDisabled`. Check that `qrmi_config.json` is owned by `root:slurm` with mode 640 (SlurmUser must be able to read it) and that it defines the resource, then run `scontrol reconfigure`.

### 0.2 Add a user (admin, once per user)

As root, create the user's directory:

```bash
QRMI_USER_BASE=/qrmi-creds qrmi_user_dir.sh alice bob
# created /qrmi-creds/alice (alice:slurm 2750)
```

| Path | Owner | Mode | Meaning |
|---|---|---|---|
| `/qrmi-creds/<user>/` | `<user>:slurm` | 2750 | The user can create and edit files. SlurmUser reads through the group. Other users cannot enter. setgid gives new files the slurm group automatically |
| `/qrmi-creds/<user>/config.json` | `<user>:slurm` | 640 | The user can write it. SlurmUser can read it |

- Never add users to the slurm group: they could read everyone's keys. The script warns if the group has members.
- `QRMI_USER_BASE` must match `user_config` in `resources.yaml`.
- Optional: to report a bad file at submit time, install `job_submit_qrmi.lua` as `/etc/slurm/job_submit.lua` and add `JobSubmitPlugins=lua` to `slurm.conf`. Set `QRMI_RESOURCES` and `USER_CONFIG` in it to match `resources.yaml`.

### 0.3 Register your API key (the user)

Ask the admin for the **resource name** and **type** of the backend you use (the values in the log of step 0.1-6). Write only your own keys, in the same format as `qrmi_config.json`:

```bash
umask 027
cat > /qrmi-creds/$(id -un)/config.json <<'EOF'
{
  "resources": [
    {
      "name": "ibm_kingston",
      "type": "ibm-quantum-compute-service",
      "environment": {
        "QRMI_IBM_QCS_IAM_APIKEY": "<your API key>"
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
sbatch --license=ibm_kingston:1 job.sh
squeue --me
```

| `squeue` reason | Meaning | What to do |
|---|---|---|
| `Resources` | The backend is busy, has no free slots, or the status is stale. With `cred_fail=pend`, also after a credential failure (`cred_retry` seconds) | Wait. For a credential failure, fix the file and wait |
| `BeginTime` | The job was requeued after a failure at start (e.g. a credential failure); it is scheduled again after the requeue delay (by default about 2 minutes) | Wait. With `cred_fail=hold`, the cause then appears as the reason |
| `hres_qrmi: <res> credentials: ...` | The job is held because of a credential failure (`cred_fail=hold`, the default). The message is the cause | Fix the file (see below), then `scancel` and resubmit. An admin can also `scontrol release` the job |
| `ReqNodeNotAvail, May be reserved for other job` | `count` is used up | Wait for other jobs to finish |
| `HRESDisabled` | The backend is not online (e.g. calibration) or `status()` fails | Wait; tell the admin if it persists |

Credential problems appear as the job's reason in `squeue` (with `cred_fail=hold`) and in slurmctld.log after `user credentials:`, with the cause (never the key values).

| Log message | Cause and fix |
|---|---|
| `... is missing or not readable by SlurmUser` | No file, the group is not slurm, or the mode is 600 |
| `... is not owned by the job's user` | The owner is not the user (also when chown has no effect on a bind mount) |
| `... is writable by group or others` | `chmod 640` |
| `... is a symbolic link` | Replace it with a regular file |
| `type of <res> is X, but the site defines it as Y` | Change `type` to the site's value |
| `... lacks QRMI_..._IAM_APIKEY for <res>` | Check the key names and `name` |
| Authentication error at acquire (401, 403, ...) | Wrong API key or CRN |
| `rejected by the backend: ...` | The backend refused the job's user without a user key (401 or 403), e.g. Warden (Pasqal Local): the user is not in `api.authorized_users`, or SlurmUser is not in `api.admin_users`. The admin fixes the cause. The reason shows the first 200 characters of the answer; slurmctld.log has all of it. A MUNGE error (e.g. Warden has another MUNGE key) is not held: the user's jobs stay pending (`Resources`) for `cred_retry` seconds, then try again |

After fixing the file, resubmit the held job. With `cred_fail=pend`, the job is retried automatically once `cred_retry` (default 300 s) has passed; to retry at once, the admin runs `rm /var/spool/slurmctld/hres_qrmi/credfail/<res>.<uid>` on slurmctld.

---


## 1. Background

### 1.1 Slurm HRES plugins

Slurm master gained a plugin interface for Hierarchical Resources (HRES, beta since 25.05). A plugin is enabled per resource and lets an external service take part in the lifecycle of the jobs that use that resource. The only implementation today is `hres/lua` (a Lua script).

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

- `config` (resources.yaml), `plugin_args` (`--license=x:1[k=v]`) and `payload` (the pre-run return value) travel to the nodes in the job credential, so **the job's user can read them**. Never put secrets in them.
- If the pre-run returns `ESLURM_HRES_REMOTE_FAIL`, the job stays pending. Any other error puts the job on hold.
- Callbacks that run under the job lock stall all of slurmctld. **No network calls there.**
- **HRES callbacks cannot set the job's environment** (tasks are started with `execve(..., step->env)`).

### 1.2 QRMI

Quantum Resource Management Interface. Written in Rust, with C, Python and Lua APIs. The Lua binding is loaded with `require("qrmi")`.

- `qrmi.load_config(path)` → `config:resource_def(name)` → `{name, type, environments}`
- `qrmi.new_from_config(id, type, env_table)` → a resource handle
- `resource:acquire()` → token, `resource:release([token])`, `resource:status()`
- `resource:detach()` (QRMI 0.26.4 or later) → the cached token, without releasing it
- `resource:free()` frees the handle. A handle releases the token it has cached when it is freed or garbage-collected; the plugin uses `detach()` to keep the token for the job (5.6).

### 1.3 spank_qrmi (the previous approach)

[spank_qrmi](https://github.com/qiskit-community/spank-plugins/tree/main/plugins/spank_qrmi) is the Slurm SPANK plugin for QRMI in [qiskit-community/spank-plugins](https://github.com/qiskit-community/spank-plugins), described in the [IBM Quantum Slurm plugin guide](https://quantum.cloud.ibm.com/docs/guides/slurm-plugin). It acquires the QPU when the job starts running, after its nodes are allocated, and exports the QRMI settings and the acquisition token to the job as environment variables.

This document refers to it as the baseline. `qrmi_hres.lua` exports the same environment variable names (5.7), so programs that read them keep working, but it checks QPU availability before nodes are allocated, and QPUs are requested with `--license`.

---

## 2. Architecture

[Presentation slide](./slurm_hres_qrmi.pdf)


**One HRES resource = one QRMI resource (backend).** Every backend is reachable from both c1 and c2, so a resource has a single layer covering `c[1-2]` rather than splitting nodes. Users pick a backend by resource name.

```
sbatch --license=ibm_kingston:1 job.sh
sbatch --license='ibm_kingston:1,ibm_other:1' job.sh   # AND (all required)
sbatch --license='ibm_kingston:1|ibm_other:1' job.sh   # OR ([...] and (...) not allowed)
```

---

## 3. Deliverables

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

## 4. resources.yaml

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

### 4.1 Plugin config entries (qrmi_hres.lua)

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
| `user_credentials` | `required` | `required`: per-user credentials (8.2) for types with user keys (`user_keys`, or the type's default); `pasqal-local` has none, as Warden identifies the job's user by MUNGE, so it needs no user file. `off`: the site key for every job (as spank_qrmi) |
| `user_config` | `/shared/qrmi/%u/config.json` | Path of the user's file. `%u` = user name, `%U` = uid |
| `user_keys` | Per-type default | Keys taken from the user's file (comma-separated). By default the API key and the service CRN |
| `user_required` | The `user_keys` ending in `APIKEY` or `AUTH_TOKEN` | Keys that must be in the user's file |
| `cred_retry` | `300` | Seconds a credential failure is remembered: within it, the next pre-run of the user's jobs holds them (`hold`) or keeps them pending (`pend`) |
| `cred_fail` | `hold` | After a credential failure: `hold` holds the job with the cause as its reason (shown by `squeue`); `pend` keeps the user's jobs pending (reason `Resources`) for `cred_retry` seconds |
| `release_give_up` | `86400` | Seconds after the first failed release after which a release that keeps failing is dropped (and logged) |

---

## 5. qrmi_hres.lua in detail

### 5.1 What each callback does

| Callback | Action |
|---|---|
| `create_context` | Create `state_dir` and check that the resource is defined in `qrmi_config.json`. If not, return `ESLURM_HRES_MAINTENANCE_DISABLE` (all layers disabled, slurmctld keeps running) |
| `maintenance` | ① Process the release queue (failures are retried next cycle) ② Delete revoke markers older than a day ③ Cache the result of `status()` ④ Enable or disable the layers |
| `prerun` | If a credential failure marker (`credfail/`) is newer than `cred_retry`, hold the job with the cause as its reason (`cred_fail=hold`: a Lua error whose message Slurm stores as the reason) or return `REMOTE_FAIL` (`cred_fail=pend`). Then the admission check against the status cache (5.2). If it fails, return `REMOTE_FAIL` (job stays pending) |
| `async_prerun` | Check the revoke marker → read the user's credential file → `acquire()` → save the token and the keys to files → check the revoke marker again (if the run was revoked or ended meanwhile, release the token) → return the token as the payload. A bad file or an authentication error is recorded in `credfail/` and returns `ERROR` (requeue); other failures return `REMOTE_FAIL` |
| `revoke` | Create a revoke marker and queue the token for release, if there is one (`tokens/` → `release/`) |
| `controller_epilog` | Same as `revoke`. Slurm also calls it when a job ends while the async pre-run is still acquiring (e.g. `scancel` while CONFIGURING); the marker makes the pre-run release the token it gets |
| `node_job_prolog` | Create the **per-job** directory `env_dir/job_<id>/` (0700, owned by the user) and write `<qpu>.env` (the token, the job's count of the resource, the job's time limit from `scontrol show job`, and the site settings without the user's keys), `<qpu>.type` and `<qpu>.user` (the path of the user's file and the key names to read) |
| `node_job_epilog` | Remove `env_dir/job_<id>/` |
| task callbacks | Nothing |

### 5.2 Admission check (may the job run?)

```
status == "online"
AND healthy in (true, nil)
AND busy in (false, nil)
AND requested_slots <= capacity.available_slots   (skipped when capacity is nil)
```

- `requested_slots` is the job's count of the resource (the sum of `prep.layers[].count`, or 1 if that is 0). Verified on the real system that this is populated at pre-run time.
- Slots taken by jobs admitted since the last `status()` are subtracted locally (in the controller Lua state).
- If the cache is missing or older than `status_max_age`, the job is held pending as a safe default.
- The reason is logged with `slurm.log_debug` (visible with `SlurmctldDebug=debug` or higher).

**Disabling the layer and holding the job are separate decisions.**

| Condition | Layer (`HRESDisabled`) | Job |
|---|---|---|
| status not online, or status() failed | Disabled | Pending |
| healthy == false | Disabled | Pending |
| busy == true | Stays enabled | Pending |
| Not enough free slots | Stays enabled | Pending |

### 5.3 Keeping network calls out of the job lock

| Operation | Where it runs | Why |
|---|---|---|
| `status()` | maintenance (no lock) → cached in a file | The pre-run only reads a local file |
| `acquire()` | async pre-run (separate thread) | Does not stall slurmctld |
| `release()` | maintenance by default (deferred) | Epilog and revoke only queue it |

The trade-off: the information used for admission can be up to `maintenance_cycle` seconds old, and releases can be delayed by the same amount. If a release has not happened yet and the next job's acquire fails, that job is requeued with `REMOTE_FAIL` and retried.

### 5.4 State files (`state_dir`)

| Path | Content |
|---|---|
| `tokens/<resource>.<jobid>.<sluid>` | Token of an acquired run |
| `revoked/<resource>.<jobid>.<sluid>` | The run was revoked or ended (the async pre-run checks it and gives up) |
| `release/<resource>.<jobid>.<sluid>` | Token waiting for release. Moved here from `tokens/` with a rename, so a token is queued once even when the async pre-run and a revoke or epilog race. Whoever releases it first moves it to `tmp/<key>.releasing`, so maintenance and an immediate release never both release it; a failed release moves it back. `<key>.since` records when maintenance first failed to release it, for `release_give_up` |
| `status/<resource>` | Status cache (`time=`, `status=`, `healthy=`, `busy=`, `available=`, `max=`, `reason=`) |
| `creds/<resource>.<jobid>.<sluid>` | The user's keys used for acquire; used for the release, then removed |
| `credfail/<resource>.<uid>` | Credential failure marker with the cause (no secrets); read by the next pre-run (`cred_fail`) |
| `tmp/` | Short-lived copy of the user's file for QRMI to parse (removed right after), and `<key>.releasing`: a token being released. Maintenance queues a `.releasing` file older than an hour again (slurmctld stopped while releasing) |

A run is identified by the `job_id` and `sluid` pair. A requeue changes the sluid, so it is treated as a new run.

**Operating notes**

- **Normal state:** with no job running and nothing waiting for release, only `status/` has files (and `revoked/` markers younger than a day). Anything left in `tokens/`, `creds/` or `release/` belongs to a running job or a release that keeps failing; the log says why (`release ... failed`).
- **Safe to delete:** `credfail/<res>.<uid>`, to let a user's jobs try again at once. `tmp/` holds copies of user files only for a moment; such a file left there after a crash can be deleted, but not a `*.releasing` file (a token).
- **Do not delete:** `tokens/`, `creds/` and `release/`. Without them the plugin cannot release the token, and it stays acquired on the backend. A release that keeps failing is dropped after `release_give_up` (default one day) and logged.
- **Secrets:** `creds/<key>` holds the user's API key in clear text from acquire until the release succeeds, and `tmp/` holds it for a moment while it is parsed. The directory is owned by SlurmUser, mode 0700, and the files 0600. Anyone who can read state_dir as root or SlurmUser, and any backup or copy of it (on the container cluster, the `var_spool_slurmctld` volume), can read those keys. So users manage their keys themselves, but the site also holds each key for the length of a job.

### 5.5 How often acquire is called

**Once per run of a job, per resource.** It does not depend on the number of nodes or steps. The count (`ibm_kingston:2`, etc.) does not change the number of calls either. A requeued job acquires again as a new run.

### 5.6 Keeping the token after the async pre-run

A QRMI handle releases its cached token when it is freed or garbage-collected. The async pre-run runs in its own Lua state, which is closed as soon as it returns, so the handle used for acquire would release the token right away, while the job still needs it.

`keep_token()` therefore calls `resource:detach()`, which hands back the cached token without releasing it, and then `free()`. Nothing leaks. The token is released later with `release(token)` on a new handle: by maintenance (`release=deferred`, the default) or in the epilog (`release=immediate`).

`detach()` was added to the QRMI Lua binding (`lua/lua_qrmi.c`) for this plugin and is available from **QRMI 0.26.4**. The Dockerfile builds QRMI from main, which has it. Only with QRMI 0.26.3 or older does the plugin fall back to removing the handle's metatable, which leaks a small native handle per acquire.

### 5.7 Job environment (same names as spank_qrmi)

```
<qpu>_QRMI_JOB_ACQUISITION_TOKEN
<qpu>_QRMI_JOB_QPU_SLOTS                            (the job's count of the resource; not in spank_qrmi, see below)
<qpu>_QRMI_JOB_TIMEOUT_SECONDS                       (the job's time limit; UNLIMITED = 4294967295)
<qpu>_<each key of environments in qrmi_config.json>     (site settings)
<qpu>_<each allowed key in the user's file>               (read by the TaskProlog as the user)
QRMI_JOB_QPU_RESOURCES / SLURM_JOB_QPU_RESOURCES
QRMI_JOB_QPU_TYPES     / SLURM_JOB_QPU_TYPES
QRMI_JOB_ID, QRMI_JOB_UID
```

`<qpu>_QRMI_JOB_QPU_SLOTS` is the count the job requested for that resource (`--license=ibm_kingston:2` → `ibm_kingston_QRMI_JOB_QPU_SLOTS=2`; 1 when no count is given), so each QRMI resource can read its own. QRMI cannot read Slurm's own `SLURM_JOB_LICENSES`, as it does not depend on a resource manager. spank_qrmi does not set it yet.

slurm.conf needs:

```
PrologFlags=Alloc
TaskProlog=/etc/slurm/hres_qrmi_taskprolog.sh
Epilog=/bin/true    # required: without an Epilog, slurmd skips node_job_epilog (8.1)
```

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

The named volume for the credentials (`qrmi_creds:/qrmi-creds`) is added in compose.yml (0.1).

Notes:

- `/etc/slurm` is a named volume (`etc_slurm`), so the volume must be recreated after the image changes.
- Enabling HRES itself requires no slurm.conf change; this plugin still needs the TaskProlog and Epilog lines (0.1, step 5). slurmctld reads `resources.yaml` automatically if it sits next to slurm.conf (a syntax error is fatal).
- `DebugFlags=License` helps with the initial checks.

---

## 7. Verification results

### 7.1 Callback trace with hres_trace.lua (2026-10-22)

| Item | Result |
|---|---|
| resources.yaml loaded | ✅ `LayerName=all Nodes=c[1-2] Mode=1` |
| create_context / maintenance (about every 10 s) | ✅ |
| prerun → async_prerun, payload hand-off | ✅ |
| `prep.layers` at pre-run time | ✅ `{{count=1, name="all", nodes="c1"}}` |
| plugin_args reach the controller and the nodes | ✅ `{foo="bar"}` |
| node_job_prolog, task prolog, user task prolog, task epilog | ✅ |
| user task prolog writing to stderr | ✅ |
| controller_epilog | ✅ |
| node_job_epilog | ✅ Only with an `Epilog` configured; skipped otherwise (8.1) |

### 7.2 qrmi_hres.lua against the real backend (2026-10-24)

| Item | Result |
|---|---|
| status() (site key), acquire(), release() | ✅ |
| `squeue` pending reasons | ✅ `count` used up → `ReqNodeNotAvail, May be reserved for other job`; calibration → `HRESDisabled`; admission failure and credential wait → `Resources` |
| Per-user credentials (`/qrmi-creds/<user>/config.json`, `user:slurm 640`) | ✅ acquire with the user's key → job runs → release with the user's key at the next maintenance. `release/` and `creds/` empty afterwards |
| Wrong API key | ✅ (2026-10-26) Held; `squeue` shows `hres_qrmi: ibm_kingston credentials: the backend rejected the API key in the user's file`. The first version requeued in a loop |
| Unreadable file (`chmod 600`) | ✅ (2026-10-26) Held after one requeue (about 3 minutes); `squeue` shows `... /qrmi-creds/user/config.json is missing or not readable by SlurmUser`. Fixed on the way: the reader exited with status 1 under bash as `sh`, so the message first read `cannot be read (exit 1)` |
| `<qpu>_QRMI_JOB_TIMEOUT_SECONDS` | ✅ (2026-10-26) `--time=30:00` → 1800, `--time=01:00:00` → 3600, no `--time` → the partition's limit (432000 = 5 days) |
| `type` mismatch (user file `ibm-quantum-system`, site `ibm-quantum-compute-service`) | ✅ Pending (the log said the key was missing). Now reported as a type mismatch (checked with mocks) |
| File on a bind mount (macOS host) | ❌ chown has no effect, so the owner check fails → moved to a named volume |

---

## 8. Open issues

### 8.1 node_job_epilog is skipped without an Epilog script (resolved with a workaround)

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

### 8.2 Credentials

**Current problem:** the node prolog writes **all** of `environments` into the user's `.env`, so the credentials in `qrmi_config.json` (API key, S3 keys) are visible to the job. This is the same as spank_qrmi.

**Requirements**

- S3 (`QRMI_IBM_QS_AWS_*` for ibm-quantum-system) is site-wide, but ideally should not be shown to users.
- Quantum API keys (`QRMI_IBM_QS_IAM_APIKEY` / `SERVICE_CRN`) belong to individuals and are **managed by the users themselves** (e.g., kept in their home directory).

**Constraints found in the QRMI source**

- For `ibm-quantum-system`, `IAM_APIKEY` and `SERVICE_CRN` are required when the handle is created, so even status needs a key.
- The S3 settings are optional, but required by `task_*` (the job side).
- No support for S3 temporary credentials (session token). `QRMI_WARDEN_URL` is only for Pasqal local.
- **Credentials used by the job process (running as the user) cannot be hidden from that user.**

**Options for the S3 keys**

| Option | Description | Assessment |
|---|---|---|
| 1 | Issue S3 keys per user, scoped to a bucket or prefix | Works with today's QRMI. Requires issuing and managing keys |
| 2 | Mint per-job STS temporary credentials in the async pre-run | Cleanest. Needs session-token support in QRMI and STS support in the S3 service |
| 3 | Delegate S3 access to a privileged service | Most secure, but needs a new service |

Plan: option 1 for now, option 2 longer term (to be proposed to QRMI). **Which S3 service is in use (IBM COS / MinIO / AWS) is not yet confirmed.**

**Options for the API keys (user-managed)**

| Option | Controller side (status, acquire, release) | Job side (task) | Notes |
|---|---|---|---|
| 1 | Site key | TaskProlog (as the user) reads `~/.qrmi/` | Simplest. **Need to verify that a task can be submitted with the user's key into a session acquired with the site key** |
| 2 | User key registered with `sudo qrmi-register` into a store (root:slurm 0640) | Same key | Users can update it themselves. Needs a registration script |
| 3 | Node prolog (root) reads the user's home and acquires | Same key | Token sharing across nodes, drain/requeue risks; not recommended |

All options **require the user home directories to be shared across containers** (the current compose.yml gives each container its own). `qrmi_config.json` should also be hidden from the login container (e.g., passed as a podman secret).

**Next step:** verify on the real system whether option 1 works.

#### Decision (2026-10-24): per-user credential files
Implemented and verified on the cluster (steps in 0.2 and 0.3).

- Each user keeps their API key in a file in the same format as `qrmi_config.json` (`user_config`, default `/shared/qrmi/<user>/config.json`; `/qrmi-creds/<user>/config.json` on the container cluster), and edits or replaces it themselves.
- The admin creates the directory once with `qrmi_user_dir.sh <user>` (`<user>:slurm 2750`). Only the user, SlurmUser (and root) can read the file.
- Only the keys in an allowlist (`user_keys`, by default `*_IAM_APIKEY` and `*_SERVICE_CRN`) are taken from the user's file; endpoints and everything else always come from the site. The site key is used only for status() and never reaches jobs or nodes.
- The `type` in the user's file must match the site definition. QRMI drops keys that do not belong to the type, so a mismatch is reported as such.
- The file is read in async_prerun (outside the job lock), through an open file descriptor that is checked: symlinks, the wrong owner and group/other-writable files are refused. Its content is never logged.
- The keys used for acquire are kept in `state_dir/creds/<key>` until the release; if the release fails with them (e.g. after a revoke), it is retried with the user's current file.
- On a bad file, async_prerun fails (Slurm requeues the job). When the job is scheduled again, prerun holds it with the cause as its reason, which `squeue` shows (`cred_fail=hold`, the default), or keeps that user's jobs pending for `cred_retry` seconds (`cred_fail=pend`). The optional `job_submit_qrmi.lua` gives a clear error at submit time.
- TaskProlog (as the user) reads the same file and exports `<resource>_<KEY>`, the names spank_qrmi used.
- `user_credentials=off` restores the old behaviour (the site key for every job).
- S3 keys remain site-wide (open).

### 8.3 Other

- Differences from spank_qrmi: overriding credentials through the job environment (`ibm_kingston_QRMI_..._APIKEY=... sbatch`) is replaced by the per-user credential file.
- slurmctld's `state_dir` (`/var/spool/slurmctld`) is lost when the container is recreated. Making it a named volume is recommended, so tokens waiting for release are not lost.
- Do not enable spank_qrmi at the same time; it would acquire twice.
- Pasqal Local: `acquire()` and `release()` run on slurmctld as SlurmUser (UID 990 in the containers), and Warden lets only the users in its `api.admin_users` open and revoke sessions for other users. Add SlurmUser's UID there, e.g. `admin_users: ["0", "990"]`. If Warden refuses the session (401 or 403), the job is held with Warden's answer as its reason, as for a credential failure; a MUNGE error keeps the user's jobs pending for `cred_retry` seconds instead.
- HRES as a whole is still beta, so the configuration format may change.
- Jobs submitted with `podman exec login` run as root (uid=0). Use `-u user` to submit as a regular user when checking permissions.

---

## 9. References

- [Slurm](https://github.com/SchedMD/slurm): `doc/html/hres.shtml`, `doc/man/man5/resources.yaml.5`, `src/plugins/hres/lua/hres_lua.c`, `src/interfaces/hres.c`, `src/slurmctld/licenses.c`
- [QRMI](https://github.com/qiskit-community/qrmi): `lua/lua_qrmi.c`, `docs/development/api_references/LUA_API.rst`, `src/ibm/quantum_system.rs`
- [spank-plugins](https://github.com/qiskit-community/spank-plugins): `plugins/spank_qrmi/spank_qrmi.c`
- [QRMI (PyPI)](https://pypi.org/project/qrmi/)
- [IBM Quantum: Slurm plugin](https://quantum.cloud.ibm.com/docs/guides/slurm-plugin)
