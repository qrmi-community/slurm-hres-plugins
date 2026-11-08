# qrmi_hres.lua design

This document describes how `qrmi_hres.lua` works and how the per-user credentials were designed. For setup and operation, see the [README](../README.md).

- [1. qrmi_hres.lua in detail](#1-qrmi_hreslua-in-detail)
- [2. Credentials](#2-credentials)

---

## 1. qrmi_hres.lua in detail

### 1.1 What each callback does

| Callback | Action |
|---|---|
| `create_context` | Create `state_dir` and check that the resource is defined in `qrmi_config.json`. If not, return `ESLURM_HRES_MAINTENANCE_DISABLE` (all layers disabled, slurmctld keeps running) |
| `maintenance` | ① Process the release queue (failures are retried next cycle) ② Delete revoke markers older than a day ③ Cache the result of `status()` ④ Enable or disable the layers |
| `prerun` | If a credential failure marker (`credfail/`) is newer than `cred_retry`, hold the job with the cause as its reason (`cred_fail=hold`: a Lua error whose message Slurm stores as the reason) or return `REMOTE_FAIL` (`cred_fail=pend`). Then the admission check against the status cache ([1.2](#12-admission-check-may-the-job-run)). If it fails, return `REMOTE_FAIL` (job stays pending) |
| `async_prerun` | Check the revoke marker → read the user's credential file → `acquire()` → save the token and the keys to files → check the revoke marker again (if the run was revoked or ended meanwhile, release the token) → return the token as the payload. A bad file or an authentication error is recorded in `credfail/` and returns `ERROR` (requeue); other failures return `REMOTE_FAIL` |
| `revoke` | Create a revoke marker and queue the token for release, if there is one (`tokens/` → `release/`) |
| `controller_epilog` | Same as `revoke`. Slurm also calls it when a job ends while the async pre-run is still acquiring (e.g. `scancel` while CONFIGURING); the marker makes the pre-run release the token it gets |
| `node_job_prolog` | Create the **per-job** directory `env_dir/job_<id>/` (0700, owned by the user) and write `<qpu>.env` (the token, the job's count of the resource, the job's time limit from `scontrol show job`, and the site settings without the user's keys), `<qpu>.type` and `<qpu>.user` (the path of the user's file and the key names to read) |
| `node_job_epilog` | Remove `env_dir/job_<id>/` |
| task callbacks | Nothing |

### 1.2 Admission check (may the job run?)

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

### 1.3 Keeping network calls out of the job lock

| Operation | Where it runs | Why |
|---|---|---|
| `status()` | maintenance (no lock) → cached in a file | The pre-run only reads a local file |
| `acquire()` | async pre-run (separate thread) | Does not stall slurmctld |
| `release()` | maintenance by default (deferred) | Epilog and revoke only queue it |

The trade-off: the information used for admission can be up to `maintenance_cycle` seconds old, and releases can be delayed by the same amount. If a release has not happened yet and the next job's acquire fails, that job is requeued with `REMOTE_FAIL` and retried.

### 1.4 State files (`state_dir`)

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
- **Secrets:** `creds/<key>` holds the user's API key in clear text from acquire until the release succeeds, and `tmp/` holds it for a moment while it is parsed. The directory is owned by SlurmUser, mode 0700, and the files 0600. Anyone who can read state_dir as root or SlurmUser, and any backup or copy of it (on the container cluster, the `var_spool_slurmctld` volume), can read those keys. So users manage their keys themselves, but the site also holds each key for the length of a job.

> [!CAUTION]
> Do not delete `tokens/`, `creds/` and `release/`. Without them the plugin cannot release the token, and it stays acquired on the backend. A release that keeps failing is dropped after `release_give_up` (default one day) and logged.

### 1.5 How often acquire is called

**Once per run of a job, per resource.** It does not depend on the number of nodes or steps. The count (`ibm_kingston:2`, etc.) does not change the number of calls either. A requeued job acquires again as a new run.

### 1.6 Keeping the token after the async pre-run

A QRMI handle releases its cached token when it is freed or garbage-collected. The async pre-run runs in its own Lua state, which is closed as soon as it returns, so the handle used for acquire would release the token right away, while the job still needs it.

`keep_token()` therefore calls `resource:detach()`, which hands back the cached token without releasing it, and then `free()`. Nothing leaks. The token is released later with `release(token)` on a new handle: by maintenance (`release=deferred`, the default) or in the epilog (`release=immediate`).

`detach()` was added to the QRMI Lua binding (`lua/lua_qrmi.c`) for this plugin and is available from **QRMI 0.26.4**. The Dockerfile builds QRMI from main, which has it. Only with QRMI 0.26.3 or older does the plugin fall back to removing the handle's metatable, which leaks a small native handle per acquire.

### 1.7 Job environment (same names as spank_qrmi)

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

`<qpu>_QRMI_JOB_QPU_SLOTS` is the count the job requested for that resource (`--resources=ibm_kingston:2` → `ibm_kingston_QRMI_JOB_QPU_SLOTS=2`; 1 when no count is given), so each QRMI resource can read its own. QRMI cannot read Slurm's own `SLURM_JOB_LICENSES`, as it does not depend on a resource manager. spank_qrmi does not set it yet.

The TaskProlog that exports these variables is set in slurm.conf ([README 0.1, step 5](../README.md#01-prepare-the-cluster-admin-once)).

---

## 2. Credentials

### 2.1 Decision (2026-10-24): per-user credential files
Implemented and verified on the cluster (steps in [0.2](../README.md#02-add-a-user-admin-once-per-user) and [0.3](../README.md#03-register-your-api-key-the-user) of the README).

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

### 2.2 Options considered

<details>
<summary>Problem, requirements and the options compared before the decision</summary>

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

</details>
