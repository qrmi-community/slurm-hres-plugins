-- Luacheck configuration: https://luacheck.readthedocs.io/
-- Run from the repository root:  luacheck containers/
--
-- The scripts run inside Slurm (hres/lua and job_submit/lua), built
-- against Lua 5.4 on Rocky Linux 9.

std = "lua54"
max_line_length = 120

-- Callback signatures are fixed by Slurm; not every callback uses every
-- argument.
unused_args = false

-- Provided by Slurm to every Lua plugin.
read_globals = {
    slurm = { other_fields = true },
}

-- Functions Slurm's hres/lua plugin calls by name.
local hres_callbacks = {
    "hres_create_context",
    "hres_destroy_context",
    "hres_maintenance",
    "hres_controller_job_prerun",
    "hres_controller_job_async_prerun",
    "hres_controller_job_revoke",
    "hres_controller_job_epilog",
    "hres_node_job_prolog",
    "hres_node_job_epilog",
    "hres_node_task_prolog",
    "hres_node_task_epilog",
    "hres_node_user_task_prolog",
}

files["containers/qrmi_hres.lua"] = { globals = hres_callbacks }
files["containers/hres_trace.lua"] = { globals = hres_callbacks }

-- Functions Slurm's job_submit/lua plugin calls by name; qrmi_check() is
-- exported so a site's own job_submit.lua can call it.
files["containers/job_submit_qrmi.lua*"] = {
    globals = { "slurm_job_submit", "slurm_job_modify", "qrmi_check" },
}
