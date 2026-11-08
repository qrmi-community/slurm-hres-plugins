# Verification results

Results of checking `hres_trace.lua` and `qrmi_hres.lua` on the container cluster and the real backend. For setup, see the [README](../README.md).

## 1. Callback trace with hres_trace.lua (2026-10-22)

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
| node_job_epilog | ✅ Only with an `Epilog` configured; skipped otherwise ([README 7.1](../README.md#71-node_job_epilog-is-skipped-without-an-epilog-script-resolved-with-a-workaround)) |

## 2. qrmi_hres.lua against the real backend (2026-10-24)

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
