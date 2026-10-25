--[[
hres_trace.lua - Slurm HRES plugin (hres/lua) trace script

Every callback logs that it was called, together with its arguments, and
returns success. Use it to see when and where each callback runs.

Where the logs go:
  controller callbacks -> slurmctld log
  node job prolog/epilog -> slurmd log
  task prolog/epilog     -> slurmd / slurmstepd log
  user task prolog       -> also prints one line to the job's stderr

resources.yaml example:

  - resource: qpu
    mode: MODE_1
    plugin:
      type: hres/lua
      config:
        - name: path
          value: /etc/slurm/hres_trace.lua
      maintenance_cycle: 60
    layers:
      - layer_name: qpu1
        nodes:
          - "node[01-16]"
        count: 1

Install: same path on the controller and every node, owned by root,
mode 0644 (readable by users, writable only by root).
]]

local TAG = "hres_trace"

-- Convert a table to a short single-line string (nested tables are expanded).
local function dump(v, depth)
    depth = depth or 0
    if type(v) ~= "table" then
        if type(v) == "string" then
            return string.format("%q", v)
        end
        return tostring(v)
    end
    if depth > 3 then
        return "{...}"
    end

    local keys = {}
    for k in pairs(v) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)

    local parts = {}
    for _, k in ipairs(keys) do
        local key = (type(k) == "number") and "" or (tostring(k) .. "=")
        parts[#parts + 1] = key .. dump(v[k], depth + 1)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function trace(fmt, ...)
    slurm.log_info("%s: " .. fmt, TAG, ...)
end

local function job_str(job)
    if not job then
        return "job=nil"
    end
    return string.format(
        "JobId=%s sluid=%s uid=%s nodes=%s",
        tostring(job.job_id),
        tostring(job.sluid),
        tostring(job.user_id),
        tostring(job.nodes)
    )
end

---------------------------------------------------------------------------
-- slurmctld
---------------------------------------------------------------------------

function hres_create_context(ctx, layers)
    trace("create_context resource=%s config=%s layers=%s", ctx.name, dump(ctx.config), dump(layers))
    return slurm.SUCCESS
end

function hres_destroy_context(ctx)
    trace("destroy_context resource=%s", ctx.name)
    return slurm.SUCCESS
end

-- Runs every maintenance_cycle seconds, in its own Lua state.
-- Setting layer.disable_layer = true/false here changes the layer's state.
function hres_maintenance(ctx, layers)
    for _, l in ipairs(layers) do
        trace(
            "maintenance resource=%s layer=%s nodes=%s used=%d/%d disable_layer=%s",
            ctx.name,
            l.name,
            tostring(l.nodes),
            l.used,
            l.total,
            tostring(l.disable_layer)
        )
    end
    return slurm.SUCCESS
end

-- Runs under the slurmctld job lock: keep it fast.
-- The second return value becomes prep.payload on the job's nodes.
-- The payload is readable by the job's user, so do not put secrets in it.
function hres_controller_job_prerun(ctx, job, prep)
    trace(
        "controller_job_prerun resource=%s %s plugin_args=%s layers=%s",
        ctx.name,
        job_str(job),
        dump(prep.plugin_args),
        dump(prep.layers)
    )
    local payload = string.format("traced_by=%s job=%s time=%d", TAG, tostring(job.job_id), os.time())
    return slurm.SUCCESS, payload
end

-- Optional: runs after the pre-run in a separate thread while the job is
-- CONFIGURING. Delete this function to disable the asynchronous pre-run.
function hres_controller_job_async_prerun(ctx, job, prep)
    trace("controller_job_async_prerun resource=%s %s payload=%s", ctx.name, job_str(job), tostring(prep.payload))
    -- Returning nothing keeps the payload from the pre-run.
    return slurm.SUCCESS
end

function hres_controller_job_revoke(ctx, job, prep)
    trace("controller_job_revoke resource=%s %s", ctx.name, job_str(job))
    return slurm.SUCCESS
end

function hres_controller_job_epilog(ctx, job, prep)
    trace("controller_job_epilog resource=%s %s", ctx.name, job_str(job))
    return slurm.SUCCESS
end

---------------------------------------------------------------------------
-- slurmd (each node of the job)
---------------------------------------------------------------------------

function hres_node_job_prolog(prep, job)
    trace(
        "node_job_prolog resource=%s %s payload=%s plugin_args=%s layers=%s",
        prep.name,
        job_str(job),
        tostring(prep.payload),
        dump(prep.plugin_args),
        dump(prep.layers)
    )
    return slurm.SUCCESS
end

function hres_node_job_epilog(prep, job)
    trace("node_job_epilog resource=%s %s", prep.name, job_str(job))
    return slurm.SUCCESS
end

---------------------------------------------------------------------------
-- slurmstepd (each task)
---------------------------------------------------------------------------

-- Runs as root, before the task starts.
function hres_node_task_prolog(prep, job, node_tid, global_tid)
    trace("node_task_prolog resource=%s %s node_tid=%d global_tid=%d", prep.name, job_str(job), node_tid, global_tid)
    return slurm.SUCCESS
end

-- Runs as the user, in the task process, just before it starts.
-- Output goes to the task's stdout/stderr; flush it before returning.
function hres_node_user_task_prolog(prep, job, node_tid, global_tid)
    trace(
        "node_user_task_prolog resource=%s %s node_tid=%d global_tid=%d",
        prep.name,
        job_str(job),
        node_tid,
        global_tid
    )
    io.stderr:write(
        string.format("[%s] task %d: resource=%s payload=%s\n", TAG, global_tid, prep.name, tostring(prep.payload))
    )
    io.stderr:flush()
    return slurm.SUCCESS
end

function hres_node_task_epilog(prep, job, node_tid, global_tid)
    trace("node_task_epilog resource=%s %s node_tid=%d global_tid=%d", prep.name, job_str(job), node_tid, global_tid)
    return slurm.SUCCESS
end
