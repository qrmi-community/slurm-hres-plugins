--[[
  (C) Copyright IBM 2026
  (C) Copyright Pasqal SAS 2026

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
]]

--[[
qrmi_hres.lua - Slurm HRES plugin (hres/lua) script that drives QRMI

One HRES resource = one QRMI resource (backend). A job that requests
the resource gets the backend acquired for it, sees the same environment
variables as with spank_qrmi, and the backend is released at job end.

  sbatch --license=ibm_kingston:1 job.sh

Flow
  controller (slurmctld, as SlurmUser)
    create_context  check the resource exists in qrmi_config.json
    prerun          (under the job lock, no network, no shared FS)
                    admission check against the cached QRMI status
    async_prerun    read the user's credentials, QRMI acquire() -> token,
                    sent to the nodes as payload
    revoke          release the token (or mark the run as revoked)
    epilog          release the token
    maintenance     process deferred releases; call QRMI status() with the
                    site key, cache it, and disable the layers while the
                    backend is down
  node (slurmd, as root)
    job_prolog      write <env_dir>/job_<id>/<resource>.env for the user
    job_epilog      remove that directory
  TaskProlog (slurm.conf, runs as the user) exports the .env files and the
  user's own credentials. See hres_qrmi_taskprolog.sh.

Admission check (prerun), on the status cached by maintenance:
  status == "online"
  AND healthy in (true, nil)
  AND busy in (false, nil)
  AND requested_slots <= capacity.available_slots  (skipped if no capacity)
requested_slots is the job's count of the resource (ibm_kingston:2 -> 2).
Slots taken by jobs admitted since the last status() are subtracted.
If the check fails, or the cache is missing or older than status_max_age,
the pre-run returns ESLURM_HRES_REMOTE_FAIL: the job stays pending and is
tried again on the next scheduling pass.
The layers are disabled (pending reason HRESDisabled) only while
status ~= "online" or healthy == false; busy and slots only hold jobs.

User credentials (user_credentials = "required", the default)
  Each user keeps their own API key in a file in the same format as
  qrmi_config.json, by default /shared/qrmi/<user>/config.json:

    { "resources": [ { "name": "ibm_kingston", "type": "ibm-quantum-system",
        "environment": { "QRMI_IBM_QS_IAM_APIKEY": "...",
                         "QRMI_IBM_QS_SERVICE_CRN": "..." } } ] }

  * Only the keys in user_keys are taken from the user's file; everything
    else (endpoints, S3, ...) always comes from the site's qrmi_config.json.
    A user can therefore never redirect the site key to another endpoint.
  * The keys in user_required must be present, otherwise the job is not
    started. The site's values of user_keys are never used for jobs and
    never reach the nodes; the site key is only used for status().
  * The file is read in async_prerun (not under the job lock) through an
    open file descriptor: it must be a regular file, not a symlink, owned
    by the job's user and not writable by group or others. Its content is
    never logged.
  * The keys used for acquire() are kept in state_dir/creds/<key> (0600)
    until the release succeeds. If the release fails with them (e.g. the
    key was revoked), it is retried with the user's current file.
  * If the credentials are missing or invalid, or the backend rejects the
    user's key at acquire() (authentication error), async_prerun fails
    (Slurm requeues the job). When the job is scheduled again, the pre-run
    holds it with the cause as its reason (cred_fail = "hold"), or keeps
    the user's jobs pending for cred_retry seconds (cred_fail = "pend"),
    so the job does not loop.
  * TaskProlog, running as the user, exports the user's keys to the job as
    <resource>_<KEY>, the names spank_qrmi used.

plugin config entries (resources.yaml)
  path             this script (required by hres/lua)
  qrmi_config      qrmi_config.json, default /etc/slurm/qrmi_config.json
                   (must exist on the controller and on the nodes)
  qrmi_resource    QRMI resource name, default = HRES resource name
  lua_cpath        added to package.cpath to find qrmi.so,
                   e.g. /usr/local/lib/lua/5.4/?.so
  state_dir        controller state, default /var/spool/slurmctld/hres_qrmi
                   (writable by SlurmUser)
  env_dir          node side, default /run/hres_qrmi
  release          "deferred" (default): epilog/revoke only queue the
                   release and maintenance performs it, so slurmctld never
                   waits on the network under its job lock. Needs
                   maintenance_cycle > 0. "immediate": release inline.
  auto_disable     "yes" (default): maintenance sets disable_layer from
                   QRMI status(). This overrides a manual DisableLayer.
  admission        "yes" (default): the admission check above in prerun.
                   "no": admit every job (acquire may still fail).
  status_max_age   seconds after which the cached status is too old and
                   jobs are held, default 60. Keep it above
                   maintenance_cycle.
  user_credentials "required" (default): per-user credentials as above.
                   "off": the site's qrmi_config.json is used for every job
                   and exported to the nodes as is (spank_qrmi behaviour).
  user_config      path of the user's file, %u = user name, %U = uid,
                   default /shared/qrmi/%u/config.json
  user_keys        comma-separated keys taken from the user's file,
                   default by resource type (API key and service CRN)
  user_required    comma-separated keys that must be in the user's file,
                   default: the user_keys ending in APIKEY or AUTH_TOKEN
  cred_retry       seconds to keep a user's jobs pending after their
                   credentials failed, default 300
  cred_fail        what the next pre-run does after a credential failure:
                   "hold" (default): hold the job with the cause as its
                   reason, so squeue shows it; the user fixes the file and
                   resubmits (or an admin releases the job).
                   "pend": keep the job pending (reason Resources) for
                   cred_retry seconds, then try again.
  release_give_up  seconds after which a release that keeps failing is
                   dropped (and logged), default 86400

Notes
  * The token is in the job credential and the .env file, so the job's
    user can read it. spank_qrmi exposes it the same way.
  * qrmi.so must be built against the same Lua version as Slurm.
]]

local TAG = "hres_qrmi"

local DEFAULTS = {
    qrmi_config = "/etc/slurm/qrmi_config.json",
    state_dir = "/var/spool/slurmctld/hres_qrmi",
    env_dir = "/run/hres_qrmi",
    release = "deferred",
    auto_disable = "yes",
    admission = "yes",
    status_max_age = "60",
    user_credentials = "required",
    user_config = "/shared/qrmi/%u/config.json",
    cred_retry = "300",
    cred_fail = "hold",
    release_give_up = "86400",
}

-- Keys a user may (and, for the secret ones, must) provide, by type.
local USER_KEYS_BY_TYPE = {
    ["ibm-quantum-system"] = "QRMI_IBM_QS_IAM_APIKEY,QRMI_IBM_QS_SERVICE_CRN",
    ["ibm-quantum-compute-service"] = "QRMI_IBM_QCS_IAM_APIKEY,QRMI_IBM_QCS_SERVICE_CRN",
    ["qiskit-runtime-service"] = "QRMI_IBM_QRS_IAM_APIKEY,QRMI_IBM_QRS_SERVICE_CRN",
    ["pasqal-cloud"] = "QRMI_PASQAL_CLOUD_AUTH_TOKEN,QRMI_PASQAL_CLOUD_PROJECT_ID",
}

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function log(fmt, ...)
    slurm.log_info("%s: " .. fmt, TAG, ...)
end

local function log_err(fmt, ...)
    slurm.log_error("%s: " .. fmt, TAG, ...)
end

local function opt(config, key)
    local v = config and config[key]
    if v == nil or v == "" then
        return DEFAULTS[key]
    end
    return v
end

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function sh(cmd)
    local ok = os.execute(cmd .. " >/dev/null 2>&1")
    return ok == true or ok == 0
end

local function exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local s = f:read("*a")
    f:close()
    return s
end

-- Create the file 0600 first, so it is never readable by others.
local function write_file(path, content, mode)
    sh("umask 077 && : > " .. shq(path))
    local f, err = io.open(path, "w")
    if not f then
        return false, err
    end
    f:write(content)
    f:close()
    sh("chmod " .. (mode or "0600") .. " " .. shq(path))
    return true
end

-- An empty file, without a shell: revoke and epilog run under the job lock.
local function touch(path)
    local f = io.open(path, "w")
    if f then
        f:close()
    end
end

local function list_dir(dir)
    local out = {}
    local p = io.popen("ls -1 " .. shq(dir) .. " 2>/dev/null")
    if p then
        for name in p:lines() do
            out[#out + 1] = name
        end
        p:close()
    end
    return out
end

local function split_list(s)
    local out = {}
    for item in tostring(s or ""):gmatch("[^,%s]+") do
        out[#out + 1] = item
    end
    return out
end

local function file_age(path)
    local p = io.popen("stat -c %Y " .. shq(path) .. " 2>/dev/null")
    if not p then
        return nil
    end
    local m = tonumber(p:read("*l") or "")
    p:close()
    return m and (os.time() - m) or nil
end

local function qrmi_name(config, hres_name)
    return (config and config.qrmi_resource ~= "" and config.qrmi_resource) or hres_name
end

-- File names that identify one run of one job on one resource.
local function run_key(hres_name, job)
    return string.format("%s.%s.%s", hres_name, tostring(job.job_id), tostring(job.sluid))
end

local function user_creds_on(config)
    return opt(config, "user_credentials") ~= "off"
end

local function user_name(uid)
    local p = io.popen("getent passwd " .. tonumber(uid) .. " 2>/dev/null")
    if not p then
        return nil
    end
    local line = p:read("*l")
    p:close()
    return line and line:match("^([^:]+):") or nil
end

local function user_config_path(config, uid)
    local name = user_name(uid)
    if not name then
        return nil, "no passwd entry for uid " .. tostring(uid)
    end
    local path = opt(config, "user_config"):gsub("%%u", name):gsub("%%U", tostring(uid))
    return path
end

---------------------------------------------------------------------------
-- QRMI access
---------------------------------------------------------------------------

local qrmi_mod

local function load_qrmi(config)
    if qrmi_mod then
        return qrmi_mod
    end
    local cpath = config and config.lua_cpath
    if cpath and cpath ~= "" and not package.cpath:find(cpath, 1, true) then
        package.cpath = cpath .. ";" .. package.cpath
    end
    local ok, mod = pcall(require, "qrmi")
    if not ok then
        return nil, "cannot load the qrmi Lua module: " .. tostring(mod)
    end
    qrmi_mod = mod
    return mod
end

-- A resource definition from a qrmi_config.json style file:
-- { name, type, is_dynamic, environments = { QRMI_... = value } }
local function def_from_file(config, path, name)
    local qrmi, err = load_qrmi(config)
    if not qrmi then
        return nil, err
    end
    local cnf, cerr = qrmi.load_config(path)
    if not cnf then
        return nil, "load_config: " .. tostring(cerr)
    end
    local def, derr = cnf:resource_def(name)
    cnf:free()
    if not def then
        return nil, "no entry for " .. name .. ": " .. tostring(derr)
    end
    return def
end

local function resource_def(config, hres_name)
    local path = opt(config, "qrmi_config")
    local name = qrmi_name(config, hres_name)
    local def, err = def_from_file(config, path, name)
    if not def then
        return nil, string.format("%s (%s)", err, path)
    end
    return def
end

local function user_keys(config, def)
    local allowed =
        split_list(config and config.user_keys ~= "" and config.user_keys or USER_KEYS_BY_TYPE[def.type] or "")
    local required
    if config and config.user_required and config.user_required ~= "" then
        required = split_list(config.user_required)
    else
        required = {}
        for _, k in ipairs(allowed) do
            if k:match("APIKEY$") or k:match("AUTH_TOKEN$") then
                required[#required + 1] = k
            end
        end
    end
    return allowed, required
end

-- Site environment with every user key removed, then the user's values.
local function merged_env(config, def, user_env)
    local env = {}
    for k, v in pairs(def.environments or {}) do
        env[k] = v
    end
    if user_creds_on(config) then
        local allowed = user_keys(config, def)
        for _, k in ipairs(allowed) do
            env[k] = nil
        end
        for k, v in pairs(user_env or {}) do
            env[k] = v
        end
    end
    return env
end

-- user_env: nil = site credentials (status), table = the user's keys.
-- pasqal-local requires QRMI_JOB_UID and QRMI_JOB_ID: acquire() opens the
-- Warden session for the job's user. Other types ignore them, and
-- status()/release() do not use them, so 0 stands in when there is no job.
local function open_resource(config, hres_name, user_env, job)
    local def, err = resource_def(config, hres_name)
    if not def then
        return nil, err
    end
    local env
    if user_env then
        env = merged_env(config, def, user_env)
    else
        env = {}
        for k, v in pairs(def.environments or {}) do
            env[k] = v
        end
    end
    env.QRMI_JOB_UID = tostring(job and job.user_id or 0)
    env.QRMI_JOB_ID = tostring(job and job.job_id or 0)
    local res, rerr = qrmi_mod.new_from_config(def.name, def.type, env)
    if not res then
        return nil, string.format("new_from_config(%s): %s", def.name, tostring(rerr))
    end
    return res, def
end

-- The QRMI handle releases its cached token when it is freed or garbage
-- collected, and the Lua state of the async pre-run is closed as soon as
-- it returns. The token must outlive it (it is released in the epilog), so
-- hand the token over to the caller and free the handle.
--   resource:detach() forgets the cached token without releasing it.
--   Older QRMI without detach(): drop the handle's metatable instead, so
--   neither __gc nor free() runs; the native handle is then leaked.
local function keep_token(res)
    if res.detach then
        res:detach()
        res:free()
    else
        debug.setmetatable(res, nil)
    end
end

local function release_token(config, hres_name, token, user_env, job)
    local res, err = open_resource(config, hres_name, user_env, job)
    if not res then
        return false, err
    end
    local ok, rerr = res:release(token)
    res:free()
    if not ok then
        return false, tostring(rerr)
    end
    return true
end

---------------------------------------------------------------------------
-- user credentials
---------------------------------------------------------------------------

-- Open the user's file once, check what was opened (not the path), then
-- print it. Exit codes: 10 missing/unreadable, 11 symlink, 12 wrong owner,
-- 13 group/other writable, 14 not a regular file.
local SECURE_READ = [=[
p="$1"; uid="$2"
d=$(realpath -e "$(dirname "$p")" 2>/dev/null) || exit 10
p="$d/$(basename "$p")"
[ -L "$p" ] && exit 11
[ -e "$p" ] || exit 10
# A failed redirection on exec makes a POSIX shell exit at once (status 1
# with bash as sh), before "|| exit 10" runs: check readability first.
[ -r "$p" ] || exit 10
exec 3<"$p" 2>/dev/null || exit 10
[ "$(readlink /proc/$$/fd/3)" = "$p" ] || exit 11
info=$(stat -L -c '%u:%a:%F' /proc/$$/fd/3 2>/dev/null) || exit 10
case "$info" in *":regular file") ;; *) exit 14 ;; esac
owner=${info%%:*}; rest=${info#*:}; mode=${rest%%:*}
[ "$owner" = "$uid" ] || exit 12
[ $((0$mode & 022)) -eq 0 ] || exit 13
cat <&3
]=]

local READ_ERRORS = {
    [10] = "is missing or not readable by SlurmUser",
    [11] = "is a symbolic link",
    [12] = "is not owned by the job's user",
    [13] = "is writable by group or others",
    [14] = "is not a regular file",
}

local function secure_read(path, uid)
    local p = io.popen("sh -c " .. shq(SECURE_READ) .. " qrmi " .. shq(path) .. " " .. tonumber(uid) .. " 2>/dev/null")
    if not p then
        return nil, "cannot run the reader"
    end
    local data = p:read("*a")
    local ok, _, code = p:close()
    if type(ok) == "number" then -- Lua 5.1
        code = ok
    end
    if ok == true or code == 0 then
        return data
    end
    return nil, READ_ERRORS[code] or ("cannot be read (exit " .. tostring(code) .. ")")
end

-- Returns a table of the user's allowed keys, or nil and a message that
-- never contains any part of the file.
local function load_user_env(config, hres_name, uid, scratch)
    local def, err = resource_def(config, hres_name)
    if not def then
        return nil, err
    end
    local path, perr = user_config_path(config, uid)
    if not path then
        return nil, perr
    end
    local data, rerr = secure_read(path, uid)
    if not data then
        return nil, path .. " " .. rerr
    end
    write_file(scratch, data)
    local udef, uerr = def_from_file(config, scratch, def.name)
    os.remove(scratch)
    if not udef then
        if uerr:match("^no entry") then
            return nil, path .. " has no entry for " .. def.name
        end
        return nil, path .. " is not a valid QRMI config file"
    end
    -- QRMI keeps only the keys that belong to the type, so a different type
    -- would silently drop the user's keys: say so instead.
    if udef.type and def.type and udef.type ~= def.type then
        return nil,
            string.format(
                "%s: type of %s is %s, but the site defines it as %s",
                path,
                def.name,
                tostring(udef.type),
                tostring(def.type)
            )
    end
    local allowed, required = user_keys(config, def)
    local env, ignored = {}, {}
    local allow = {}
    for _, k in ipairs(allowed) do
        allow[k] = true
    end
    for k, v in pairs(udef.environments or {}) do
        if allow[k] then
            if tostring(v):find("[\r\n]") then
                return nil, path .. ": " .. k .. " contains a newline"
            end
            env[k] = v
        else
            ignored[#ignored + 1] = k
        end
    end
    for _, k in ipairs(required) do
        if not env[k] or env[k] == "" then
            return nil, path .. " lacks " .. k .. " for " .. def.name
        end
    end
    if #ignored > 0 then
        table.sort(ignored)
        log("%s: ignored keys not allowed for users in %s: %s", def.name, path, table.concat(ignored, ","))
    end
    return env
end

local function env_to_text(uid, env)
    local lines = { "#uid=" .. tostring(uid) }
    local keys = {}
    for k in pairs(env) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        lines[#lines + 1] = k .. "=" .. env[k]
    end
    return table.concat(lines, "\n") .. "\n"
end

local function text_to_env(s)
    if not s then
        return nil
    end
    local env, uid = {}, nil
    for line in s:gmatch("[^\n]+") do
        local u = line:match("^#uid=(%d+)$")
        if u then
            uid = tonumber(u)
        else
            local k, v = line:match("^([%w_]+)=(.*)$")
            if k then
                env[k] = v
            end
        end
    end
    return env, uid
end

---------------------------------------------------------------------------
-- controller state
--   <state_dir>/tokens/<key>    token of an acquired run
--   <state_dir>/revoked/<key>   run revoked or ended (async pre-run must give up)
--   <state_dir>/release/<key>   token waiting for a deferred release
--   <state_dir>/creds/<key>     user keys used for acquire, until released
--   <state_dir>/credfail/<res>.<uid>  last credential failure (no secrets)
--   <state_dir>/status/<res>    backend status cache
---------------------------------------------------------------------------

local function state_path(config, sub, key)
    return string.format("%s/%s/%s", opt(config, "state_dir"), sub, key)
end

local function ensure_state_dirs(config)
    local dir = opt(config, "state_dir")
    local subs = {}
    for _, s in ipairs({ "tokens", "revoked", "release", "status", "creds", "credfail", "tmp" }) do
        subs[#subs + 1] = shq(dir .. "/" .. s)
    end
    return sh("umask 077 && mkdir -p " .. table.concat(subs, " ") .. " && chmod 0700 " .. shq(dir))
end

-- Status cache <state_dir>/status/<hres_name>, written by maintenance and
-- read by the pre-run: "name=value" lines. st is nil when status() failed.
local function write_status(config, hres_name, st, why)
    local cap = st and st.capacity
    local lines = {
        "time=" .. os.time(),
        "status=" .. (st and tostring(st.status) or "error"),
        "healthy=" .. (st and st.healthy ~= nil and tostring(st.healthy) or ""),
        "busy=" .. (st and st.busy ~= nil and tostring(st.busy) or ""),
        "available=" .. (cap and tostring(cap.available_slots) or ""),
        "max=" .. (cap and tostring(cap.max_slots) or ""),
        "reason=" .. (tostring(why or ""):gsub("\n", " ")),
    }
    local path = state_path(config, "status", hres_name)
    write_file(path .. ".tmp", table.concat(lines, "\n") .. "\n")
    os.rename(path .. ".tmp", path)
end

local function read_status(config, hres_name)
    local s = read_file(state_path(config, "status", hres_name))
    if not s then
        return nil
    end
    local kv = {}
    for k, v in s:gmatch("([%w_]+)=([^\n]*)") do
        kv[k] = v
    end
    local function bool(v)
        if v == "true" then
            return true
        end
        if v == "false" then
            return false
        end
        return nil
    end
    return {
        time = tonumber(kv.time) or 0,
        status = kv.status,
        healthy = bool(kv.healthy),
        busy = bool(kv.busy),
        available = tonumber(kv.available),
        reason = kv.reason,
    }
end

-- Release with the keys used for acquire; if that fails and they were a
-- user's keys, retry with the user's current file (the key may have been
-- replaced after a revoke).
local function release_run(config, hres_name, key, token)
    local cpath = state_path(config, "creds", key)
    local env, uid = text_to_env(read_file(cpath))
    local job = { user_id = uid or 0, job_id = tonumber(key:sub(#hres_name + 2):match("^(%d+)")) or 0 }
    local ok, err = release_token(config, hres_name, token, env, job)
    if not ok and uid and user_creds_on(config) then
        local fresh = load_user_env(config, hres_name, uid, state_path(config, "tmp", key .. ".release"))
        if fresh then
            ok, err = release_token(config, hres_name, token, fresh, job)
        end
    end
    if ok then
        os.remove(cpath)
    end
    return ok, err
end

-- Queue the run's token for release: tokens/<key> moves to release/<key>.
-- The rename is atomic, so when the async pre-run and revoke or epilog race,
-- only one of them queues the token and it is released once. Maintenance
-- performs the release, or the caller at once with release=immediate.
local function queue_release(config, key)
    return os.rename(state_path(config, "tokens", key), state_path(config, "release", key))
end

local function release_now(config, hres_name, key)
    local path = state_path(config, "release", key)
    local ok, err = release_run(config, hres_name, key, read_file(path))
    if ok then
        os.remove(path)
        log("released %s", key)
    else
        log_err("release %s failed, maintenance retries it: %s", key, err)
    end
end

-- Under the job lock (revoke, epilog). The marker makes an async pre-run
-- still acquiring for this run queue its token itself.
local function end_run(config, hres_name, key)
    touch(state_path(config, "revoked", key))
    if not queue_release(config, key) then
        return
    end
    if opt(config, "release") == "immediate" then
        release_now(config, hres_name, key)
    else
        log("queued release of %s", key)
    end
end

-- Authentication failures reported by the backend for the key in use.
local AUTH_PATTERNS = {
    "authenticat",
    "unauthori",
    "forbidden",
    "invalid api",
    "api key",
    "apikey",
    "%f[%d]401%f[%D]",
    "%f[%d]403%f[%D]",
}

local function is_auth_error(err)
    local e = tostring(err or ""):lower()
    for _, pat in ipairs(AUTH_PATTERNS) do
        if e:find(pat) then
            return true
        end
    end
    return false
end

local function credfail_path(config, hres_name, uid)
    return state_path(config, "credfail", hres_name .. "." .. tostring(uid))
end

---------------------------------------------------------------------------
-- slurmctld callbacks
---------------------------------------------------------------------------

function hres_create_context(ctx, layers)
    if not ensure_state_dirs(ctx.config) then
        log_err("%s: cannot create %s", ctx.name, opt(ctx.config, "state_dir"))
    end
    local def, err = resource_def(ctx.config, ctx.name)
    if not def then
        log_err("%s: %s, disabling the resource", ctx.name, err)
        return slurm.ESLURM_HRES_MAINTENANCE_DISABLE
    end
    local allowed, required = user_keys(ctx.config, def)
    log(
        "%s: QRMI resource %s type=%s release=%s user_credentials=%s user_keys=%s required=%s",
        ctx.name,
        def.name,
        tostring(def.type),
        opt(ctx.config, "release"),
        opt(ctx.config, "user_credentials"),
        table.concat(allowed, ","),
        table.concat(required, ",")
    )
    if user_creds_on(ctx.config) and #required == 0 then
        log_err(
            "%s: user_credentials is on but no required user key is known for type %s; set user_keys/user_required",
            ctx.name,
            tostring(def.type)
        )
    end
    return slurm.SUCCESS
end

function hres_destroy_context(ctx)
    return slurm.SUCCESS
end

function hres_maintenance(ctx, layers)
    -- 1. deferred releases of this resource
    local prefix = ctx.name .. "."
    local rdir = opt(ctx.config, "state_dir") .. "/release"
    local give_up = tonumber(opt(ctx.config, "release_give_up"))
    for _, key in ipairs(list_dir(rdir)) do
        if key:sub(1, #prefix) == prefix then
            local path = rdir .. "/" .. key
            local ok, err = release_run(ctx.config, ctx.name, key, read_file(path))
            if ok then
                os.remove(path)
                log("released %s", key)
            elseif (file_age(path) or 0) > give_up then
                log_err("release %s failed for %ds, giving up: %s", key, give_up, err)
                os.remove(path)
                os.remove(state_path(ctx.config, "creds", key))
            else
                -- kept, retried on the next cycle
                log_err("release %s failed: %s", key, err)
            end
        end
    end

    -- 2. forget revoke markers older than a day
    sh(string.format("find %s -type f -mtime +1 -delete", shq(opt(ctx.config, "state_dir") .. "/revoked")))

    -- 3. backend status with the site key: cache it for the admission check
    local st, why
    local res, err = open_resource(ctx.config, ctx.name, nil, nil)
    if not res then
        why = err
    else
        local serr
        st, serr = res:status()
        res:free()
        if not st then
            why = tostring(serr)
        else
            why = st.status .. (st.status_reason and (" (" .. st.status_reason .. ")") or "")
        end
    end
    write_status(ctx.config, ctx.name, st, why)

    -- 4. layer state: down while not online or not healthy
    if opt(ctx.config, "auto_disable") ~= "yes" then
        return slurm.SUCCESS
    end
    local disable = not st or st.status ~= "online" or st.healthy == false
    if st and st.healthy == false then
        why = why .. ", unhealthy"
    end
    for _, layer in ipairs(layers) do
        if layer.disable_layer ~= disable then
            log("%s layer %s: %s -> disable_layer=%s", ctx.name, layer.name, why, tostring(disable))
            layer.disable_layer = disable
        end
    end
    return slurm.SUCCESS
end

-- Slots taken by the jobs admitted since the last status(), per resource:
-- [hres_name] = { stamp = <status time>, slots = <n> }. Kept in the
-- controller Lua state; a script reload only makes the check less strict
-- until the next status().
local admitted = {}

local function requested_slots(prep)
    local n = 0
    for _, layer in ipairs(prep and prep.layers or {}) do
        n = n + (tonumber(layer.count) or 0)
    end
    return (n > 0) and n or 1
end

-- Returns nil when the job may run, or the reason to hold it.
local function admission_check(ctx, prep)
    local st = read_status(ctx.config, ctx.name)
    if not st then
        return "no QRMI status yet (is maintenance_cycle set?)"
    end
    local age = os.time() - st.time
    if age > tonumber(opt(ctx.config, "status_max_age")) then
        return string.format("QRMI status is %ds old", age)
    end
    if st.status ~= "online" then
        return "status " .. tostring(st.status) .. " " .. (st.reason or "")
    end
    if st.healthy == false then
        return "not healthy"
    end
    if st.busy == true then
        return "busy"
    end
    if st.available then
        local a = admitted[ctx.name]
        if not a or a.stamp ~= st.time then
            a = { stamp = st.time, slots = 0 }
            admitted[ctx.name] = a
        end
        local want = requested_slots(prep)
        local free = st.available - a.slots
        if want > free then
            return string.format("requested %d slots, %d available", want, free)
        end
        a.slots = a.slots + want
    end
    return nil
end

-- Under the slurmctld job lock: no network and no shared file system here,
-- only local files under state_dir. acquire is in the asynchronous pre-run.
function hres_controller_job_prerun(ctx, job, prep)
    if user_creds_on(ctx.config) then
        local fpath = credfail_path(ctx.config, ctx.name, job.user_id)
        local s = read_file(fpath)
        if s then
            local t = tonumber(s:match("time=(%d+)")) or 0
            local msg = s:match("msg=([^\n]*)") or "invalid"
            local fresh = os.time() - t < tonumber(opt(ctx.config, "cred_retry"))
            if fresh and opt(ctx.config, "cred_fail") == "hold" then
                -- An error with a message holds the job, and Slurm
                -- shows the message as its reason in squeue. The
                -- hold stops the loop, so the next job (or this one,
                -- once released) reads the user's file again.
                os.remove(fpath)
                log("JobId=%d %s held: credentials: %s", job.job_id, ctx.name, msg)
                error(string.format("%s: %s credentials: %s", TAG, ctx.name, msg), 0)
            end
            if fresh then
                slurm.log_debug("%s: JobId=%d %s held: credentials: %s", TAG, job.job_id, ctx.name, msg)
                return slurm.ESLURM_HRES_REMOTE_FAIL
            end
        end
    end
    if opt(ctx.config, "admission") ~= "yes" then
        return slurm.SUCCESS
    end
    local why = admission_check(ctx, prep)
    if why then
        -- Pending, tried again on the next scheduling pass.
        slurm.log_debug("%s: JobId=%d %s held: %s", TAG, job.job_id, ctx.name, why)
        return slurm.ESLURM_HRES_REMOTE_FAIL
    end
    return slurm.SUCCESS
end

-- Separate thread, the job is CONFIGURING. The returned token becomes
-- prep.payload on the nodes.
function hres_controller_job_async_prerun(ctx, job, prep)
    local key = run_key(ctx.name, job)
    if exists(state_path(ctx.config, "revoked", key)) then
        return slurm.ESLURM_HRES_REMOTE_FAIL
    end

    local user_env
    if user_creds_on(ctx.config) then
        local uerr
        user_env, uerr = load_user_env(ctx.config, ctx.name, job.user_id, state_path(ctx.config, "tmp", key))
        local fpath = credfail_path(ctx.config, ctx.name, job.user_id)
        if not user_env then
            log_err("JobId=%d %s: user credentials: %s", job.job_id, ctx.name, uerr)
            write_file(fpath, string.format("time=%d\nmsg=%s\n", os.time(), (uerr:gsub("\n", " "))))
            -- Slurm requeues the job; prerun keeps it pending for
            -- cred_retry seconds so it does not loop.
            return slurm.ERROR
        end
        os.remove(fpath)
        write_file(state_path(ctx.config, "creds", key), env_to_text(job.user_id, user_env))
    end

    local res, err = open_resource(ctx.config, ctx.name, user_env, job)
    if not res then
        log_err("JobId=%d %s: %s", job.job_id, ctx.name, err)
        os.remove(state_path(ctx.config, "creds", key))
        return slurm.ESLURM_HRES_REMOTE_FAIL
    end
    local token, aerr = res:acquire()
    if not token then
        res:free()
        log_err("JobId=%d %s: acquire failed: %s", job.job_id, ctx.name, tostring(aerr))
        os.remove(state_path(ctx.config, "creds", key))
        -- A rejected user key will not get better by retrying: treat it
        -- like a bad credential file, so the user's jobs wait cred_retry.
        if user_env and is_auth_error(aerr) then
            write_file(
                credfail_path(ctx.config, ctx.name, job.user_id),
                string.format("time=%d\nmsg=%s\n", os.time(), "the backend rejected the API key in the user's file")
            )
            return slurm.ERROR
        end
        return slurm.ESLURM_HRES_REMOTE_FAIL
    end
    keep_token(res)
    write_file(state_path(ctx.config, "tokens", key), token)

    -- The run was revoked or ended while acquiring (e.g. scancel while
    -- CONFIGURING): release the token here, network calls are fine.
    if exists(state_path(ctx.config, "revoked", key)) then
        if queue_release(ctx.config, key) then
            log("JobId=%d %s: revoked while acquiring, releasing", job.job_id, ctx.name)
            release_now(ctx.config, ctx.name, key)
        end
        return slurm.ESLURM_HRES_REMOTE_FAIL
    end

    log("JobId=%d %s: acquired%s", job.job_id, ctx.name, user_env and " with the user's credentials" or "")
    return slurm.SUCCESS, token
end

-- Under the job lock. The run did not start.
function hres_controller_job_revoke(ctx, job, prep)
    end_run(ctx.config, ctx.name, run_key(ctx.name, job))
    return slurm.SUCCESS
end

-- Under the job lock, after the node epilogs. Also called when the job ends
-- while the async pre-run is still acquiring, which is why it marks the run.
function hres_controller_job_epilog(ctx, job, prep)
    end_run(ctx.config, ctx.name, run_key(ctx.name, job))
    return slurm.SUCCESS
end

---------------------------------------------------------------------------
-- slurmd callbacks (root)
---------------------------------------------------------------------------

local function job_env_dir(config, job)
    return string.format("%s/job_%d", opt(config, "env_dir"), job.job_id)
end

-- The job's time limit in seconds, as spank_qrmi passes it in
-- <name>_QRMI_JOB_TIMEOUT_SECONDS. hres_job_t has no time limit, so ask
-- slurmctld once per job and node, as spank_qrmi did with
-- slurm_load_job(). UNLIMITED becomes 4294967295 (UINT32_MAX), as in
-- spank_qrmi. Returns nil if the limit cannot be read.
local UINT32_MAX = 4294967295
local timeout_cache = {}

local function parse_time_limit(s)
    if s == "UNLIMITED" then
        return UINT32_MAX
    end
    local d, h, m, sec = s:match("^(%d+)%-(%d+):(%d+):(%d+)$")
    if not d then
        d = 0
        h, m, sec = s:match("^(%d+):(%d+):(%d+)$")
    end
    if not h then
        h = 0
        m, sec = s:match("^(%d+):(%d+)$")
    end
    if not m then
        return nil
    end
    return ((tonumber(d) * 24 + tonumber(h)) * 60 + tonumber(m)) * 60 + tonumber(sec)
end

local function job_timeout_seconds(job_id)
    if timeout_cache[job_id] then
        return timeout_cache[job_id]
    end
    local p = io.popen(string.format("scontrol -o show job %d 2>/dev/null", job_id))
    local out = p and p:read("*a") or ""
    if p then
        p:close()
    end
    local limit = out:match("%f[%S]TimeLimit=(%S+)")
    local secs = limit and parse_time_limit(limit)
    if secs then
        timeout_cache = { [job_id] = secs }
    end
    return secs, limit
end

-- Same variables as spank_qrmi, one file per resource:
--   <name>_QRMI_JOB_ACQUISITION_TOKEN, <name>_QRMI_JOB_TIMEOUT_SECONDS,
--   <name>_<each site environment entry>
-- and <name>_QRMI_JOB_QPU_SLOTS (not set by spank_qrmi): the job's count of
-- the resource (ibm_kingston:2 -> 2).
-- plus <name>.type for QRMI_JOB_QPU_TYPES. With user credentials the
-- site's values of user_keys are left out, and <name>.user tells the
-- TaskProlog (running as the user) which file and keys to export.
function hres_node_job_prolog(prep, job)
    local def, err = resource_def(prep.config, prep.name)
    if not def then
        log_err("JobId=%d %s: %s", job.job_id, prep.name, err)
        return slurm.ERROR
    end
    if not prep.payload or prep.payload == "" then
        log_err("JobId=%d %s: no acquisition token", job.job_id, prep.name)
        return slurm.ERROR
    end

    local base = opt(prep.config, "env_dir")
    local dir = job_env_dir(prep.config, job)
    if
        not sh(
            string.format(
                "mkdir -p %s && chmod 0755 %s && mkdir -p %s && chmod 0700 %s && chown %d %s",
                shq(base),
                shq(base),
                shq(dir),
                shq(dir),
                job.user_id,
                shq(dir)
            )
        )
    then
        log_err("JobId=%d: cannot create %s", job.job_id, dir)
        return slurm.ERROR
    end

    local name = def.name
    local env = merged_env(prep.config, def, nil)
    local lines = {
        string.format("%s_QRMI_JOB_ACQUISITION_TOKEN=%s", name, prep.payload),
        string.format("%s_QRMI_JOB_QPU_SLOTS=%d", name, requested_slots(prep)),
    }
    local timeout, limit = job_timeout_seconds(job.job_id)
    if timeout then
        lines[#lines + 1] = string.format("%s_QRMI_JOB_TIMEOUT_SECONDS=%d", name, timeout)
    else
        -- Not fatal: a failed node prolog would drain the node.
        log_err(
            "JobId=%d %s: cannot read the time limit (%s); %s_QRMI_JOB_TIMEOUT_SECONDS not set",
            job.job_id,
            name,
            tostring(limit),
            name
        )
    end
    local keys = {}
    for k in pairs(env) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        lines[#lines + 1] = string.format("%s_%s=%s", name, k, env[k])
    end

    local files = {
        [string.format("%s/%s.env", dir, name)] = table.concat(lines, "\n") .. "\n",
        [string.format("%s/%s.type", dir, name)] = tostring(def.type) .. "\n",
    }
    if user_creds_on(prep.config) then
        local upath = user_config_path(prep.config, job.user_id)
        local allowed = user_keys(prep.config, def)
        if upath then
            files[string.format("%s/%s.user", dir, name)] = upath .. "\n" .. table.concat(allowed, ",") .. "\n"
        end
    end
    for path, content in pairs(files) do
        if not write_file(path, content) then
            log_err("JobId=%d: cannot write %s", job.job_id, path)
            return slurm.ERROR
        end
        sh(string.format("chown %d %s", job.user_id, shq(path)))
    end
    return slurm.SUCCESS
end

function hres_node_job_epilog(prep, job)
    sh("rm -rf " .. shq(job_env_dir(prep.config, job)))
    return slurm.SUCCESS
end

---------------------------------------------------------------------------
-- slurmstepd callbacks: nothing to do, TaskProlog sets the environment
---------------------------------------------------------------------------

function hres_node_task_prolog(prep, job, node_tid, global_tid)
    return slurm.SUCCESS
end

function hres_node_user_task_prolog(prep, job, node_tid, global_tid)
    return slurm.SUCCESS
end

function hres_node_task_epilog(prep, job, node_tid, global_tid)
    return slurm.SUCCESS
end
