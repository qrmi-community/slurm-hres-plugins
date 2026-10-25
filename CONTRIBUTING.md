# Contributing

Thank you for helping with the Slurm HRES plugin for QRMI. This guide covers how to set up, check and submit a change.

## What is in this repository

| Path | What it is |
|---|---|
| `containers/qrmi_hres.lua` | The hres/lua plugin that connects Slurm HRES to QRMI |
| `containers/hres_trace.lua` | An hres/lua plugin that only logs every callback, for checking a cluster |
| `containers/job_submit_qrmi.lua.example` | Optional job_submit/lua check of the user's credential file |
| `containers/hres_qrmi_taskprolog.sh`, `containers/qrmi_user_dir.sh` | TaskProlog and the admin tool for per-user credential directories |
| `containers/` (the rest) | A container cluster (slurmctld, slurmdbd, c1, c2, login) for testing |
| `README.md` | Setup, design and verification notes |

## Set up a test cluster

Follow section 0 of [README.md](README.md). Changes to the plugin can be tested without rebuilding the image: copy the file into `/etc/slurm/` in the slurmctld container and run `scontrol reconfigure`.

Submit test jobs as a regular user (`podman exec -u user login ...`), not as root, so permissions are checked the way they are in production.

## Code style

- Lua and shell scripts use 4 spaces, no tabs. `.editorconfig`-aware editors pick this up.
- Lua is formatted with [StyLua](https://github.com/JohnnyMorganz/StyLua) (`stylua.toml`) and checked with [luacheck](https://github.com/lunarmodules/luacheck) (`.luacheckrc`).
- Shell scripts should pass [ShellCheck](https://www.shellcheck.net/).

Install the tools once:

```bash
cargo install stylua          # or: brew install stylua
luarocks install luacheck     # or: brew install luacheck
```

Before opening a pull request, run from the repository root:

```bash
stylua containers/ containers/job_submit_qrmi.lua.example    # formats in place; --check only reports
luacheck containers/ containers/job_submit_qrmi.lua.example
shellcheck containers/*.sh
```

`job_submit_qrmi.lua.example` is named explicitly because both tools only pick up `*.lua` files from a directory.

## Rules for the plugin

These keep slurmctld responsive and users' keys safe. Please keep them in any change:

- **No network calls and no shared file system access under the slurmctld job lock** (`hres_controller_job_prerun`, `hres_controller_job_revoke`, `hres_controller_job_epilog`). Only local files under `state_dir` are allowed there. Network calls belong in `hres_maintenance` or `hres_controller_job_async_prerun`.
- **Never log or return secrets.** API keys must not appear in logs, error messages, job reasons or the payload.
- **Keep spank_qrmi's environment variable names** for anything exported to jobs, so existing programs keep working.
- **Document new plugin config entries** in the header comment of `qrmi_hres.lua`, in `resources.yaml.example` and in README.md.

## Submitting a change

1. Open an issue first for larger changes, so the design can be agreed.
2. Make the change on a branch, with the checks above passing.
3. In the pull request, say what you changed, why, and how you tested it (cluster, backend, user or root).
4. Never commit real credentials. `qrmi_config.json.example` holds only placeholders and the local simulator's values.

Contributions are accepted under the [Apache License 2.0](LICENSE).
