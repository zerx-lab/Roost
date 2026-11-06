--!strict
-- The local run engine. A run is a list of steps. A shell step is one child process started
-- through a small sh wrapper that puts the command in its own process group and records pids and
-- the exit code in files. An omp step is a native agent block that a window opens (see
-- lib/agent.luau): the host writes a job file and lists it in kv, the window records the pane and
-- the exit code. Either way progress is read from files, so a run survives a plugin reload: the
-- new VM finds the step still running (or finished) and carries on.
--
-- Concurrency: at most `max_concurrent` runs at once, one per workflow; per-workflow policy
-- queue | skip | replace. Every transition is saved to runs.json (a step start before its
-- process is spawned; other changes coalesced).

local model = require("./model")
local store = require("./store")
local template = require("./template")
local util = require("./util")
local match = require("./match")
local agent = require("./agent")
local stats = require("./stats")

local M = {}

type Run = store.Run
type Workflow = model.Workflow

-- The wrapper: `sh -c WRAPPER roost LOG PIDFILE EXITFILE CWD PROG ARGS...`. `set -m` gives the
-- command its own process group, so cancel can signal everything it started. The wrapper's own
-- pid goes to PIDFILE.w so a later VM can tell whether anyone is left to write the exit file.
-- Anything but a regular file at $ROOST_OUTPUT is removed before the exit file appears, so the
-- host's read of it can't block on a FIFO or device.
M.WRAPPER = [[
log=$1; pidf=$2; exitf=$3; cwd=$4; shift 4
echo "$$" >"$pidf.w"
[ -n "$ROOST_BANNER" ] && printf '%s\n' "$ROOST_BANNER" >>"$log"
cd "$cwd" 2>>"$log" || { echo "[roost] cannot enter $cwd" >>"$log"; echo 97 >"$exitf"; exit 97; }
set -m
"$@" </dev/null >>"$log" 2>&1 &
child=$!
echo "$child" >"$pidf"
wait "$child"
code=$?
if [ -n "$ROOST_OUTPUT" ] && { [ -e "$ROOST_OUTPUT" ] || [ -L "$ROOST_OUTPUT" ]; } && { [ -L "$ROOST_OUTPUT" ] || [ ! -f "$ROOST_OUTPUT" ]; }; then
	rm -rf -- "$ROOST_OUTPUT"
	echo "[roost] \$ROOST_OUTPUT is not a regular file: ignored" >>"$log"
fi
echo "$code" >"$exitf.tmp" && mv "$exitf.tmp" "$exitf"
exit "$code"
]]

M.PREPARE_WORKTREE = [[
set -e
echo "[roost] fetch origin $ROOST_FETCH_REF in $ROOST_REPO_PATH"
git -C "$ROOST_REPO_PATH" fetch --quiet origin "$ROOST_FETCH_REF"
git -C "$ROOST_REPO_PATH" worktree add --quiet --detach "$ROOST_WORKSPACE" FETCH_HEAD
echo "[roost] worktree $ROOST_WORKSPACE at $(git -C "$ROOST_WORKSPACE" rev-parse --short HEAD)"
]]

M.CLEANUP_WORKTREE = [[
git -C "$ROOST_REPO_PATH" worktree remove --force "$ROOST_WORKSPACE" 2>/dev/null || rm -rf "$ROOST_WORKSPACE"
git -C "$ROOST_REPO_PATH" worktree prune
echo "[roost] worktree removed"
]]

local MAX_QUEUE = 100
-- Between SIGTERM and SIGKILL for a stopping step.
local KILL_GRACE = 8
-- After the wrapper ended (or was found dead), how long we wait for its exit file.
local EXIT_GRACE = 3
-- How often a step nobody in this VM is waiting on is probed for liveness.
local PROBE_EVERY = 5
-- Extra process.run timeout beyond our own deadline (a backstop; our deadline kills first).
local BACKSTOP_MS = 120000
local MAX_PAYLOAD = 8 * 1024 * 1024
local SAVE_DELAY_MS = 250
-- How long a window may hold an agent step's claim without recording a pane.
local CLAIM_GRACE = 30
-- How often a working agent's session file is read into the run log, and how much at a time.
local TAIL_EVERY = 2
local TAIL_CHUNK = 512 * 1024
-- How long the relay gets to hand out a run's App token, and when a held one is renewed
-- (installation tokens live an hour).
local AUTH_TIMEOUT = 90
local TOKEN_RENEW = 900
local RENEW_RETRY = 60

-- What an agent step cost: every *.jsonl under its session dir (subagents are files one level
-- down), summing each usage record's `cost.total` and `totalTokens`. Text inside JSON strings has
-- its quotes escaped, so the patterns only meet real usage objects. Prints "COST TOKENS".
M.TALLY = [[
find "$1" -type f -name '*.jsonl' -exec cat {} + 2>/dev/null |
	grep -oE '"cost":\{[^}]*\}|"totalTokens":[0-9]+' |
	awk '/^"totalTokens"/ { split($0, a, ":"); t += a[2]; next }
		{ if (match($0, /"total":[-0-9.eE+]+/)) c += substr($0, RSTART + 8, RLENGTH - 8) }
		END { printf "%.6f %d\n", c, t }'
]]
local TALLY_TIMEOUT_MS = 20000
-- Most of $ROOST_OUTPUT read after a shell step, and most outputs a run keeps.
local MAX_OUTPUT_FILE = 64 * 1024
local MAX_OUTPUTS = 64
local MAX_OUTPUT_VALUE = 4096

-- `gh` for runs acting as the GitHub App, installed as <data>/bin/gh, which such runs put first on
-- PATH: reads the run's current token (renewed while the run lasts), then runs the next gh.
M.GH_SHIM = [[
#!/bin/sh
# Roost: gh as the GitHub App. Reads the run's current token, then runs the next gh on PATH.
if [ -n "$ROOST_GH_TOKEN_FILE" ]; then
	GH_TOKEN=$(cat "$ROOST_GH_TOKEN_FILE") || exit 4
	export GH_TOKEN
fi
self=$(dirname "$0")
set -f
IFS=:
for d in $PATH; do
	[ "$d" = "$self" ] && continue
	[ -x "$d/gh" ] && exec "$d/gh" "$@"
done
echo "roost: gh not found on PATH" >&2
exit 127
]]

-- `sh -c SAVE_TOKEN roost FILE SHIM SHIM_TEXT`, the token on stdin: owner-only, replaced whole.
-- The shim (shared by every App run) is replaced through a rename too, and only when it changed,
-- so a gh started meanwhile never runs a half-written script.
M.SAVE_TOKEN = [[
umask 077
cat >"$1.tmp" && mv "$1.tmp" "$1" || exit 1
mkdir -p "${2%/*}" || exit 1
if [ ! -x "$2" ] || [ "$(cat "$2" 2>/dev/null)" != "$(printf '%s' "$3")" ]; then
	printf '%s' "$3" >"$2.$$" && chmod 755 "$2.$$" && mv "$2.$$" "$2"
fi
]]

-- git's credential helper for github.com while acting as the App: the run's current token.
M.GIT_CREDENTIAL = '!f() { test "$1" = get || exit 0; echo username=x-access-token; echo "password=$(cat "$ROOST_GH_TOKEN_FILE")"; }; f'

export type Request = {
	trigger: { kind: string, detail: string, delivery: string? },
	repo: string?,
	ref: string?,
	inputs: { [string]: string },
	event: { [string]: any }?,
	payload: string?, -- raw JSON text of the webhook payload
	rerun_of: string?,
}

-- An installation token the relay handed out for one run (POST /api/v1/github/token).
export type AppToken = {
	token: string,
	expires_in: number,
	login: string,
	email: string,
	branch: string?,
	protection: string?,
	permissions: { [string]: any }?,
}

export type Env = {
	data: string,
	home: string?,
	path: string?, -- the daemon's PATH
	store: store.Store,
	config: () -> model.Config,
	workflows: () -> model.Workflows?,
	changed: () -> (),
	now: () -> number,
	-- Asks the relay for an App token for one repository (core.app_token).
	app_token: (repo: string, cb: (AppToken?, string?) -> ()) -> (),
}

-- Per-run state that isn't persisted.
type Live = {
	spawned: { [number]: boolean }, -- step index -> started by this VM (a callback will come)
	exited: { [number]: number }, -- step index -> when the wrapper was known to be gone
	killed: { [number]: string }, -- step index -> last signal sent
	kill_at: { [number]: number }, -- step index -> when SIGTERM went out
	probe_at: { [number]: number }, -- step index -> last liveness probe
	claim_at: { [number]: number }, -- step index -> when a claim without a pane was first seen
	exit_bad: { [number]: number }, -- step index -> when its exit file was first found unreadable
	tail_at: { [number]: number }, -- agent step -> last read of its session file
	tailing: { [number]: boolean }, -- agent step -> a read or its log append is in flight
	tail_done: { [number]: boolean }, -- agent step -> read to the end after its exit file appeared
	tally: { [number]: string }, -- agent step -> "running" | "done": its cost read from the session files
	note: { [number]: string }, -- step index -> why it failed, for the run's reason (auth steps)
	renewing: boolean?, -- the run's App token is being renewed
	renew_at: number?, -- last renewal attempt
	renew_failed: boolean?, -- a renewal failure was logged (said once until one succeeds)
}

export type Runner = {
	env: Env,
	live: { [string]: Live },
	seq: number,
	timer: any?,
	save_timer: any?,
	jobs_json: string?, -- what kv `agent_jobs` was last set to
}

local function now(r: Runner): number
	return r.env.now()
end

local function dir_of(r: Runner, id: string): string
	return store.run_dir(r.env.store, id)
end

local function token_path(r: Runner, id: string): string
	return `{dir_of(r, id)}/app-token`
end

local function bin_dir(r: Runner): string
	return `{r.env.data}/bin`
end

-- Lists the running agent steps for the windows (kv `agent_jobs`), when that list changed.
local function publish_jobs(r: Runner)
	local list: { agent.Active } = {}
	for _, run in r.env.store.runs do
		local s = if run.state == "running" then run.steps[run.step] else nil
		if s and s.agent and s.state == "running" then
			table.insert(list, { run = run.id, step = run.step, stop = run.stop ~= nil })
		end
	end
	local enc = tern.json.encode(tern.json.array(list))
	if enc ~= r.jobs_json then
		local ok, err = pcall(function(): string?
			tern.kv.set(agent.KV, list)
			return nil
		end)
		if ok then
			r.jobs_json = enc
		else
			tern.log.warn("roost: cannot publish agent jobs", err)
		end
	end
end

-- Saves runs.json: at once when `now_` (before spawning a step), else coalesced.
local function persist(r: Runner, now_: boolean?)
	if now_ then
		if r.save_timer then
			r.save_timer:cancel()
			r.save_timer = nil
		end
		store.save(r.env.store)
	elseif not r.save_timer then
		r.save_timer = tern.timer(SAVE_DELAY_MS, function()
			r.save_timer = nil
			store.save(r.env.store)
		end)
	end
	publish_jobs(r)
	r.env.changed()
end

-- Saves runs.json now (after the index changed outside a run, e.g. a cleanup).
function M.save(r: Runner)
	persist(r, true)
end

-- Appends `lines` (then the file at `tail`, when given) to a run's log; `done` runs once the
-- append finished (or could not start), so later appends keep their order.
local function append_log(r: Runner, id: string, lines: { string }, tail: string?, done: (() -> ())?)
	local argv = {
		"/bin/sh",
		"-c",
		'f=$1; t=$2; shift 2; printf "%s\\n" "$@" >>"$f"; if [ -n "$t" ] && [ -f "$t" ]; then cat "$t" >>"$f"; printf "\\n" >>"$f"; fi; exit 0',
		"roost",
		`{dir_of(r, id)}/log.txt`,
		tail or "",
	}
	for _, l in lines do
		table.insert(argv, l)
	end
	local ok, err = pcall(function(): string?
		tern.process.run(argv, { timeout_ms = 5000 }, function(_res)
			if done then
				done()
			end
		end)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot append to log", err)
		if done then
			done()
		end
	end
end

-- Reads up to `limit` bytes of `path` from `offset` (0-based) without loading the whole file;
-- nil when the read failed.
local function read_chunk(path: string, offset: number, limit: number, cb: (string?) -> ())
	local ok, err = pcall(function(): string?
		tern.process.run({
			"/bin/sh",
			"-c",
			'tail -c +"$1" "$2" | head -c "$3"',
			"roost",
			tostring(math.floor(offset) + 1),
			path,
			tostring(math.floor(limit)),
		}, { timeout_ms = 10000 }, function(res)
			if res.status ~= 0 or res.timed_out then
				cb(nil)
			else
				cb(res.stdout)
			end
		end)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot read", path, err)
		cb(nil)
	end
end

local function live(r: Runner, id: string): Live
	local l = r.live[id]
	if not l then
		l = {
			spawned = {},
			exited = {},
			killed = {},
			kill_at = {},
			probe_at = {},
			claim_at = {},
			exit_bad = {},
			tail_at = {},
			tailing = {},
			tail_done = {},
			tally = {},
			note = {},
		}
		r.live[id] = l
	end
	return l
end

function M.new(env: Env): Runner
	return { env = env, live = {}, seq = 0, timer = nil, save_timer = nil, jobs_json = nil }
end

local function new_id(r: Runner): string
	while true do
		r.seq = (r.seq + 1) % 0x10000
		local id = string.format("%010x%04x", math.floor(now(r)), (r.seq + math.random(0, 0xfff)) % 0x10000)
		if r.env.store.by_id[id] == nil then
			return id
		end
	end
end

local function busy(r: Runner, workflow: string): { Run }
	local out = {}
	for _, run in r.env.store.runs do
		if run.workflow == workflow and (run.state == "queued" or run.state == "running") then
			table.insert(out, run)
		end
	end
	return out
end

local function count(r: Runner, state: string): number
	local n = 0
	for _, run in r.env.store.runs do
		if run.state == state then
			n += 1
		end
	end
	return n
end

function M.active(r: Runner): (number, number)
	return count(r, "running"), count(r, "queued")
end

-- The run's workflow: the current definition, a stand-in when it was deleted (so cleanup can
-- still run), or nil when no valid workflows.toml has loaded yet (hold everything).
local function resolve(r: Runner, run: Run): (Workflow?, boolean)
	local wfs = r.env.workflows()
	if wfs == nil then
		return nil, false
	end
	local wf = wfs.by_id[run.workflow]
	if wf then
		return wf, false
	end
	local stub: Workflow = {
		id = run.workflow,
		name = run.workflow_name,
		enabled = false,
		manual = false,
		notify = false,
		concurrency = "queue",
		workspace = "temp",
		env = {},
		inputs = {},
		triggers = {},
		steps = {},
	}
	return stub, true
end

-- Where the run works: worktree (event ref in a temporary git worktree), repo (the checkout as
-- is), or temp (an empty directory).
local function workspace(r: Runner, wf: Workflow, req: Request, id: string): (string, string?, string?, string?)
	local wfs = r.env.workflows()
	local repo = if req.repo and wfs then wfs.repos[req.repo] else nil
	local path = if repo and repo.path then util.expand(repo.path, r.env.home) else nil
	local mode = wf.workspace
	if mode == "auto" then
		mode = if path and repo and repo.worktree then "worktree" elseif path then "repo" else "temp"
	end
	if (mode == "worktree" or mode == "repo") and not path then
		mode = "temp"
	end
	if mode == "worktree" then
		local ref = req.ref or (repo and repo.branch) or "HEAD"
		return "worktree", store.worktree_dir(r.env.store, id), path, ref
	elseif mode == "repo" then
		return "repo", path :: string, path, nil
	end
	return "temp", `{dir_of(r, id)}/work`, nil, nil
end

local function title_for(wf: Workflow, req: Request): string
	if req.event then
		return match.summary(req.event)
	elseif req.trigger.kind == "cron" then
		return `定时 {req.trigger.detail}`
	end
	return `{if req.trigger.kind == "rerun" then "重跑" else "手动"} {wf.name}`
end

-- The event without its long text fields; those stay in the run's info.json.
local function slim(e: { [string]: any }?): { [string]: any }?
	if e == nil then
		return nil
	end
	local out = table.clone(e)
	out.body = nil
	out.comment = nil
	return out
end

local function full_event(r: Runner, run: Run): { [string]: any }
	local ok, text = pcall(tern.fs.read, `{dir_of(r, run.id)}/info.json`, 1024 * 1024)
	if ok then
		local ok2, v = pcall(tern.json.decode, text :: string)
		if ok2 and type(v) == "table" then
			return v
		end
	end
	return run.event or {}
end

-- Queues a run of `wf` (or records it skipped, per the workflow's concurrency).
function M.submit(r: Runner, wf: Workflow, req: Request): (Run?, string?)
	if count(r, "queued") >= MAX_QUEUE then
		return nil, "队列已满"
	end
	local id = new_id(r)
	local mode, cwd, repo_path, fetch_ref = workspace(r, wf, req, id)
	local identity = wf.identity or r.env.config().github.identity
	local as_app = identity == "app" and req.repo ~= nil
	local steps: { store.StepRec } = {}
	if as_app then
		table.insert(steps, { name = "获取 App 令牌", kind = "auth", state = "pending" })
	end
	if mode == "worktree" then
		table.insert(steps, { name = "准备 worktree", kind = "prepare", state = "pending" })
	end
	for _, s in wf.steps do
		table.insert(steps, { name = s.name, kind = s.kind :: string, state = "pending" })
	end
	if mode == "worktree" then
		table.insert(steps, { name = "清理 worktree", kind = "cleanup", state = "pending" })
	end
	local run: Run = {
		id = id,
		workflow = wf.id,
		workflow_name = wf.name,
		title = title_for(wf, req),
		trigger = req.trigger,
		repo = req.repo,
		ref = req.ref,
		state = "queued",
		created_at = now(r),
		inputs = req.inputs,
		steps = steps,
		step = 0,
		workspace = mode,
		cwd = cwd,
		repo_path = repo_path,
		fetch_ref = fetch_ref,
		event = slim(req.event),
		rerun_of = req.rerun_of,
		identity = if as_app then "app" else nil,
	}
	local others = busy(r, wf.id)
	if #others > 0 and wf.concurrency == "skip" then
		run.state = "skipped"
		run.reason = "已有同一工作流的运行在排队或执行"
		run.finished_at = now(r)
	elseif #others > 0 and wf.concurrency == "replace" then
		for _, o in others do
			M.cancel(r, o.id, `被运行 {id} 取代`)
		end
	end
	store.add(r.env.store, run)
	do
		local d = dir_of(r, id)
		pcall(tern.fs.mkdir, d)
		if req.payload then
			pcall(tern.fs.write, `{d}/event.json`, req.payload)
		end
		if req.event then
			pcall(tern.fs.write, `{d}/info.json`, tern.json.encode(req.event))
		end
		if identity == "app" and not as_app and run.state ~= "skipped" then
			append_log(r, id, { "[roost] 这次运行没有关联仓库,GitHub 操作使用本机 gh 身份" })
		end
	end
	store.prune(r.env.store, now(r))
	-- Saved at once: the relay cursor moves past this event as soon as we return.
	persist(r, true)
	M.pump(r)
	return run, nil
end

-- The request a run was made from, for re-running it.
function M.request_of(r: Runner, run: Run): Request
	local payload: string? = nil
	local ok, text = pcall(tern.fs.read, `{dir_of(r, run.id)}/event.json`, MAX_PAYLOAD)
	if ok then
		payload = text
	end
	return {
		trigger = { kind = "rerun", detail = run.id },
		repo = run.repo,
		ref = run.ref,
		inputs = table.clone(run.inputs),
		event = if run.event then full_event(r, run) else nil,
		payload = payload,
		rerun_of = run.id,
	}
end

local function finish(r: Runner, run: Run, state: string, reason: string?)
	run.state = state
	run.reason = reason
	run.finished_at = now(r)
	run.stop = nil
	run.final = nil
	for _, s in run.steps do
		if s.state == "pending" or s.state == "running" then
			s.state = "skipped"
		end
	end
	if run.workspace == "temp" and run.cwd then
		pcall(tern.fs.remove, run.cwd)
	end
	if run.identity == "app" then
		pcall(tern.fs.remove, token_path(r, run.id))
	end
	r.live[run.id] = nil
end

local function read_pid(path: string): number?
	local ok, text = pcall(tern.fs.read, path, 64)
	local n = if ok then tonumber(util.trim(text :: string)) else nil
	return if n then math.floor(n) else nil
end

-- Signals the process group of `run`'s current step.
local function signal(r: Runner, run: Run, sig: string)
	local l = live(r, run.id)
	l.killed[run.step] = sig
	if sig == "TERM" then
		l.kill_at[run.step] = now(r)
	end
	local n = read_pid(`{dir_of(r, run.id)}/s{run.step}.pid`)
	if not n then
		return
	end
	local ok, err = pcall(function(): string?
		tern.process.run({
			"/bin/sh",
			"-c",
			'kill -s "$1" -- "-$2" 2>/dev/null; kill -s "$1" "$2" 2>/dev/null; exit 0',
			"roost",
			sig,
			tostring(n),
		}, { timeout_ms = 5000 }, function(_res) end)
		return nil
	end)
	if not ok then
		-- Retried on a later check.
		l.killed[run.step] = nil
		tern.log.warn("roost: cannot signal step", err)
	end
end

-- Cancels a queued or running run. Returns false when it isn't active.
function M.cancel(r: Runner, id: string, reason: string?): boolean
	local run = r.env.store.by_id[id]
	if not run then
		return false
	end
	if run.state == "queued" then
		finish(r, run, "cancelled", reason or "开始前被取消")
		persist(r, true)
		return true
	end
	if run.state ~= "running" or run.stop or run.final then
		return false
	end
	run.stop = "cancel"
	run.reason = reason or "已取消"
	local cur = run.steps[run.step]
	if cur and cur.kind ~= "cleanup" and not cur.agent and cur.state == "running" then
		signal(r, run, "TERM")
	end
	persist(r, true)
	M.schedule(r, 200)
	return true
end

local function uses_payload(t: template.Template): boolean
	for _, p in t.parts do
		if p.path and p.path[1] == "payload" then
			return true
		end
	end
	return false
end

local function template_ctx(r: Runner, run: Run, wf: Workflow, needs_payload: boolean): { [string]: any }
	local e = full_event(r, run)
	local payload: any = {}
	if needs_payload then
		local ok, text = pcall(tern.fs.read, `{dir_of(r, run.id)}/event.json`, MAX_PAYLOAD)
		if ok then
			local ok2, v = pcall(tern.json.decode, text :: string)
			if ok2 and type(v) == "table" then
				payload = v
			end
		end
	end
	return {
		repo = run.repo,
		event = e.event,
		action = e.action,
		number = e.number,
		title = e.title,
		body = e.body,
		url = e.url,
		ref = run.ref or run.fetch_ref,
		sha = e.sha,
		branch = e.branch,
		sender = e.sender,
		comment = e.comment,
		label = e.label,
		workflow = wf.id,
		run_id = run.id,
		trigger = run.trigger.kind,
		input = run.inputs,
		out = run.outputs or {},
		payload = payload,
	}
end

local function step_env(r: Runner, run: Run, wf: Workflow): { [string]: string }
	local cfg = r.env.config().runner
	local env: { [string]: string } = {}
	for k, v in cfg.env do
		env[k] = v
	end
	for k, v in wf.env do
		env[k] = v
	end
	local paths = {}
	for _, p in cfg.extra_path do
		table.insert(paths, util.expand(p, r.env.home))
	end
	if r.env.path then
		table.insert(paths, r.env.path)
	end
	if env.PATH == nil then
		env.PATH = table.concat(paths, ":")
	end
	local e: { [string]: any } = run.event or {}
	local function put(k: string, v: any)
		env[k] = if v == nil then "" else tostring(v)
	end
	put("ROOST_RUN_ID", run.id)
	put("ROOST_WORKFLOW", wf.id)
	put("ROOST_TRIGGER", run.trigger.kind)
	put("ROOST_REPO", run.repo)
	put("ROOST_REF", run.ref or run.fetch_ref)
	put("ROOST_FETCH_REF", run.fetch_ref)
	put("ROOST_REPO_PATH", run.repo_path)
	put("ROOST_WORKSPACE", run.cwd)
	put("ROOST_RUN_DIR", dir_of(r, run.id))
	put("ROOST_EVENT_PATH", `{dir_of(r, run.id)}/event.json`)
	put("ROOST_INFO_PATH", `{dir_of(r, run.id)}/info.json`)
	put("ROOST_EVENT", e.event)
	put("ROOST_ACTION", e.action)
	put("ROOST_NUMBER", e.number)
	put("ROOST_SHA", e.sha)
	put("ROOST_BRANCH", e.branch)
	put("ROOST_SENDER", e.sender)
	put("ROOST_URL", e.url)
	for k, v in run.inputs do
		env["ROOST_INPUT_" .. string.upper((string.gsub(k, "[^%w]", "_")))] = v
	end
	for k, v in run.outputs or ({} :: { [string]: string }) do
		env["ROOST_OUT_" .. string.upper(k)] = v
	end
	return env
end

-- What a step acting as the App runs with besides PATH and GH_TOKEN: the token file, git's
-- credentials for github.com (ssh remotes go over https) and the bot as commit author.
local function app_vars(r: Runner, run: Run): { [string]: string }
	local a = run.app :: { login: string, email: string, expires: number }
	local v: { [string]: string } = {
		ROOST_IDENTITY = "app",
		ROOST_GH_TOKEN_FILE = token_path(r, run.id),
		GIT_TERMINAL_PROMPT = "0",
		GIT_AUTHOR_NAME = a.login,
		GIT_AUTHOR_EMAIL = a.email,
		GIT_COMMITTER_NAME = a.login,
		GIT_COMMITTER_EMAIL = a.email,
	}
	local git = {
		-- The empty helper first drops the user's own (osxkeychain, gh) for github.com.
		{ "credential.https://github.com.helper", "" },
		{ "credential.https://github.com.helper", M.GIT_CREDENTIAL },
		{ "url.https://github.com/.insteadOf", "git@github.com:" },
		{ "url.https://github.com/.insteadOf", "ssh://git@github.com/" },
	}
	v.GIT_CONFIG_COUNT = tostring(#git)
	for i, kv in git do
		v[`GIT_CONFIG_KEY_{i - 1}`] = kv[1]
		v[`GIT_CONFIG_VALUE_{i - 1}`] = kv[2]
	end
	return v
end

-- Adds the App identity to a shell step's environment.
local function with_app(r: Runner, run: Run, env: { [string]: string })
	for k, v in app_vars(r, run) do
		env[k] = v
	end
	env.PATH = if env.PATH and env.PATH ~= "" then `{bin_dir(r)}:{env.PATH}` else bin_dir(r)
	local ok, tok = pcall(tern.fs.read, token_path(r, run.id), 8192)
	if ok then
		env.GH_TOKEN = util.trim(tok :: string)
	end
end

-- The file an omp step acting as the App sources (agent.with_env); the token stays in its own file.
local function app_script(r: Runner, run: Run): string
	local v = app_vars(r, run)
	local lines = { "# Roost: this step's GitHub App identity (the token itself stays in ROOST_GH_TOKEN_FILE)." }
	for _, k in util.keys(v) do
		table.insert(lines, `export {k}={util.shq(v[k])}`)
	end
	table.insert(lines, `export PATH={util.shq(bin_dir(r))}:"$PATH"`)
	-- No token, no start: an inherited GH_TOKEN would otherwise act as someone else.
	table.insert(lines, 'GH_TOKEN=$(cat "$ROOST_GH_TOKEN_FILE") || exit 97')
	table.insert(lines, "export GH_TOKEN")
	return table.concat(lines, "\n") .. "\n"
end

-- A run meant to act as the App whose identity or token is gone (a reload at the wrong moment, a
-- deleted file): its steps must fail rather than run as you.
local function app_missing(r: Runner, run: Run): boolean
	return run.identity == "app" and (run.app == nil or not tern.fs.exists(token_path(r, run.id)))
end

-- Asks the relay for an App token for `repo`; `cb` gets it or why not.
local function request_token(r: Runner, repo: string, cb: (AppToken?, string?) -> ())
	local ok, err = pcall(function(): string?
		r.env.app_token(repo, cb)
		return nil
	end)
	if not ok then
		cb(nil, tostring(err))
	end
end

-- Saves run `id`'s token (owner-only) and the gh shim; `cb` gets nil or what went wrong.
local function save_token(r: Runner, id: string, token: string, cb: (string?) -> ())
	local bin = bin_dir(r)
	local ok, err = pcall(function(): string?
		tern.process.run(
			{ "/bin/sh", "-c", M.SAVE_TOKEN, "roost", token_path(r, id), `{bin}/gh`, M.GH_SHIM },
			{ stdin = token, timeout_ms = 10000 },
			function(res)
				if res.status == 0 and not res.timed_out then
					cb(nil)
				else
					cb(`无法保存 App 令牌:{util.trim(res.stderr or "")}`)
				end
			end
		)
		return nil
	end)
	if not ok then
		cb(`无法保存 App 令牌:{err}`)
	end
end

local function token_lines(run: Run, tok: AppToken): { string }
	local perms: { string } = {}
	local p = tok.permissions or {}
	for _, k in util.keys(p) do
		table.insert(perms, `{k}:{tostring(p[k])}`)
	end
	local guard = if tok.protection == "created"
		then "中继刚为它加上了规则集"
		elseif tok.protection == "updated" then "中继重新启用了它的规则集"
		else "已有规则"
	return {
		`[roost] 以 GitHub App {tok.login} 的身份操作 {run.repo or "?"},令牌 {util.fmt_duration(tok.expires_in)} 后到期,运行期间自动续期`,
		`[roost] 默认分支 {tok.branch or "?"} 禁止强推与删除({guard})`,
		`[roost] 令牌权限:{if #perms > 0 then table.concat(perms, " ") else "—"}`,
	}
end

-- Renews a running App run's token shortly before it expires; failures are logged and retried.
local function renew(r: Runner, run: Run)
	local a = run.app
	local repo = run.repo
	if a == nil or repo == nil or now(r) < a.expires - TOKEN_RENEW then
		return
	end
	local l = live(r, run.id)
	if l.renewing or now(r) - (l.renew_at or -math.huge) < RENEW_RETRY then
		return
	end
	l.renewing, l.renew_at = true, now(r)
	local id = run.id
	local function still(): Run?
		local cur = r.env.store.by_id[id]
		return if cur and cur.state == "running" then cur else nil
	end
	request_token(r, repo, function(tok, err)
		if still() == nil then
			l.renewing = nil
			return
		end
		if tok == nil then
			l.renewing = nil
			-- Said once; retried every RENEW_RETRY until it works or the token runs out.
			if not l.renew_failed then
				l.renew_failed = true
				append_log(r, id, { `[roost] App 令牌续期失败,稍后重试:{err or "?"}` })
			end
			return
		end
		save_token(r, id, tok.token, function(serr)
			l.renewing = nil
			local cur = still()
			if cur == nil then
				pcall(tern.fs.remove, token_path(r, id))
				return
			end
			if serr then
				if not l.renew_failed then
					l.renew_failed = true
					append_log(r, id, { `[roost] App 令牌续期失败,稍后重试:{serr}` })
				end
				return
			end
			l.renew_failed = nil
			if cur.app then
				cur.app.expires = now(r) + tok.expires_in
			end
			persist(r)
			append_log(r, id, { `[roost] App 令牌已续期,{util.fmt_duration(tok.expires_in)} 后到期` })
		end)
	end)
end

local check: (Runner, Run) -> ()
local next_step: (Runner, Run, Workflow) -> ()

-- The definition of user step `i` (auth/prepare/cleanup have none), matched by name and kind.
local function definition(run: Run, wf: Workflow, i: number): model.Step?
	local offset = 0
	while run.steps[offset + 1] and (run.steps[offset + 1].kind == "auth" or run.steps[offset + 1].kind == "prepare") do
		offset += 1
	end
	local def = wf.steps[i - offset]
	if def and def.name == run.steps[i].name and def.kind == run.steps[i].kind then
		return def
	end
	return nil
end

-- Hands an omp step to the windows: the job file first, then kv `agent_jobs` (through persist).
local function start_agent(r: Runner, run: Run, i: number, job: agent.Job)
	local f = agent.files(dir_of(r, run.id), i)
	for _, p in { f.claim, f.pane, f.reply, f.job } do
		pcall(tern.fs.remove, p)
	end
	pcall(tern.fs.mkdir, f.session)
	run.steps[i].agent = true
	run.steps[i].opened, run.steps[i].tail_file, run.steps[i].tail, run.steps[i].replied = nil, nil, nil, nil
	local ok, err = pcall(function(): string?
		tern.fs.write(f.job, tern.json.encode(job))
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot write agent job", err)
		pcall(tern.fs.write, f.exit, tostring(agent.CODE.launch))
	end
	persist(r, true)
	append_log(r, run.id, {
		`\27[1;36m▶ {run.steps[i].name}\27[0m`,
		`[roost] 等待 Tern 窗口在会话「{job.session}」中打开 agent 标签页`,
	})
	M.schedule(r, 1000)
end

-- Logs what the agent did since the last look: "the tab is open" once, then each new entry of
-- its session file (agent.progress). One read and its append at a time, so lines keep their
-- order. `final` (the exit file is there) reads to the end, then checks the run again, so the
-- outcome line comes after the agent's last words.
local tail_agent: (Runner, Run, number, boolean) -> ()
function tail_agent(r: Runner, run: Run, i: number, final: boolean)
	local l = live(r, run.id)
	if l.tailing[i] then
		return
	end
	local t = now(r)
	if not final and t - (l.tail_at[i] or -math.huge) < TAIL_EVERY then
		return
	end
	l.tail_at[i] = t
	local s = run.steps[i]
	local id = run.id
	local f = agent.files(dir_of(r, id), i)
	local function done()
		l.tailing[i] = nil
		if final then
			l.tail_done[i] = true
			local cur = r.env.store.by_id[id]
			if cur and cur.state == "running" and cur.step == i then
				check(r, cur)
			end
		end
	end
	local head: { string } = {}
	if not s.opened and tern.fs.exists(f.pane) then
		s.opened = true
		table.insert(head, `[roost] agent 已在 Tern 标签页中运行(会话「{r.env.config().runner.session}」)`)
	end
	local file = agent.session_file(f.session)
	l.tailing[i] = true
	if not file then
		if #head > 0 then
			persist(r)
			append_log(r, id, head, nil, done)
		else
			done()
		end
		return
	end
	local name = string.match(file, "([^/]+)$")
	if s.tail_file ~= name then
		s.tail_file, s.tail = name, 0
	end
	read_chunk(file, s.tail or 0, TAIL_CHUNK, function(chunk)
		local cur = r.env.store.by_id[id]
		if not cur or cur.state ~= "running" or cur.step ~= i or chunk == nil then
			if #head > 0 then
				-- Not logged: say it with the next read.
				s.opened = nil
			end
			done()
			return
		end
		local text = chunk :: string
		local full = #text >= TAIL_CHUNK
		local p = agent.progress(text, full)
		s.tail = (s.tail or 0) + p.used
		if p.final then
			s.replied = true
		end
		for _, line in p.lines do
			table.insert(head, line)
		end
		if p.used > 0 or #head > 0 then
			persist(r)
		end
		local more = full and p.used > 0
		local function after()
			if final and more then
				l.tailing[i] = nil
				tail_agent(r, cur, i, true)
			else
				done()
			end
		end
		if #head > 0 then
			append_log(r, id, head, nil, after)
		else
			after()
		end
	end)
end

-- Reads what an ended agent step cost (M.TALLY over its session dir) into the step record, then
-- checks the run again. A failed read leaves the step without a cost.
local function tally_agent(r: Runner, run: Run, i: number)
	local l = live(r, run.id)
	if l.tally[i] == "running" then
		return
	end
	l.tally[i] = "running"
	local id = run.id
	local function done()
		l.tally[i] = "done"
		local cur = r.env.store.by_id[id]
		if cur and cur.state == "running" and cur.step == i then
			check(r, cur)
		end
	end
	local session = agent.files(dir_of(r, id), i).session
	local ok, err = pcall(function(): string?
		tern.process.run({ "/bin/sh", "-c", M.TALLY, "roost", session }, { timeout_ms = TALLY_TIMEOUT_MS }, function(res)
			local cur = r.env.store.by_id[id]
			local c, t = string.match(res.stdout or "", "^%s*([%d%.]+)%s+(%d+)")
			local s = if cur then cur.steps[i] else nil
			if s and c and t and res.status == 0 and not res.timed_out then
				s.cost, s.tokens = tonumber(c), tonumber(t)
				persist(r)
			end
			done()
		end)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot read agent usage", err)
		done()
	end
end

-- An agent step nobody else will finish: unclaimed when stopping, or claimed but never started.
-- Once its tab is open, follows the conversation into the log.
local function watch_agent(r: Runner, run: Run, i: number)
	local f = agent.files(dir_of(r, run.id), i)
	local l = live(r, run.id)
	if not tern.fs.exists(f.claim) then
		l.claim_at[i] = nil
		if run.stop then
			pcall(tern.fs.write, f.exit, tostring(agent.CODE.stopped))
		end
		return
	end
	if tern.fs.exists(f.pane) then
		-- The window that opened it stops it, and records how it ended.
		l.claim_at[i] = nil
		tail_agent(r, run, i, false)
		return
	end
	local t = now(r)
	local since = l.claim_at[i] or t
	l.claim_at[i] = since
	if t - since >= CLAIM_GRACE then
		pcall(tern.fs.write, f.exit, tostring(agent.CODE.lost))
	end
end

-- Gets the run's App token from the relay and saves it for the steps after it; the exit file
-- (written once the log says how it went) ends the step.
local function start_auth(r: Runner, run: Run, i: number)
	local s = run.steps[i]
	local d = dir_of(r, run.id)
	local id = run.id
	run.step_deadline = now(r) + AUTH_TIMEOUT
	s.state = "running"
	s.started_at = now(r)
	s.exit_code = nil
	pcall(tern.fs.mkdir, d)
	pcall(tern.fs.remove, `{d}/s{i}.exit`)
	persist(r, true)
	local l = live(r, id)
	l.spawned[i] = true
	l.note[i] = nil
	-- Nil once the run stopped or moved on (check then ends the step).
	local function current(): Run?
		local cur = r.env.store.by_id[id]
		return if cur and cur.state == "running" and cur.step == i and cur.stop == nil then cur else nil
	end
	local function done(code: number, lines: { string }, note: string?)
		if note then
			l.note[i] = note
		end
		table.insert(lines, 1, `\27[1;36m▶ {s.name}\27[0m`)
		append_log(r, id, lines, nil, function()
			pcall(tern.fs.write, `{d}/s{i}.exit`, tostring(code))
			local cur = r.env.store.by_id[id]
			if cur then
				check(r, cur)
			end
		end)
	end
	request_token(r, run.repo or "", function(tok, err)
		if current() == nil then
			return
		end
		if tok == nil then
			local why = err or "中继没有给出令牌"
			done(1, { `[roost] 无法获取 GitHub App 令牌:{why}` }, why)
			return
		end
		save_token(r, id, tok.token, function(serr)
			local cur = current()
			if cur == nil then
				pcall(tern.fs.remove, token_path(r, id))
				return
			end
			if serr then
				done(1, { `[roost] {serr}` }, serr)
				return
			end
			cur.app = { login = tok.login, email = tok.email, expires = now(r) + tok.expires_in }
			-- Saved before the exit file: after a reload the next step must still see the identity.
			persist(r, true)
			done(0, token_lines(cur, tok))
		end)
	end)
	M.schedule(r, 1000)
end

-- Why user step `step` doesn't start: its `when` is off (the run goes on), or it is an omp step
-- and the workflow already spent its daily budget today (true: the run ends as skipped).
local function held(r: Runner, run: Run, wf: Workflow, step: model.Step): (string?, boolean)
	local w = step.when
	if w then
		local v = if w.source == "out" then (run.outputs or {})[w.key] else run.inputs[w.key]
		if model.truthy(v) == w.negate then
			return `条件 when = "{if w.negate then "!" else ""}{w.source}.{w.key}" 不满足,跳过`, false
		end
	end
	local budget = wf.daily_budget
	if step.kind == "omp" and budget then
		local spent = stats.cost_since(r.env.store.runs, wf.id, stats.day_start(now(r)))
		if spent >= budget then
			return string.format("今日费用约 $%.2f,已达预算 $%.2f,不再运行 omp 步骤", spent, budget), true
		end
	end
	return nil, false
end

-- Merges the `key=value` lines step `i` appended to $ROOST_OUTPUT into the run's outputs;
-- returns the step's `stop` value (end the run as skipped) when it set one.
local function take_outputs(r: Runner, run: Run, i: number): string?
	local path = `{dir_of(r, run.id)}/s{i}.out`
	local ok, text = pcall(tern.fs.read, path, MAX_OUTPUT_FILE)
	if not ok or type(text) ~= "string" then
		if tern.fs.exists(path) then
			append_log(r, run.id, { `[roost] $ROOST_OUTPUT 读不出(超过 {MAX_OUTPUT_FILE // 1024} KiB?),本步骤的输出已忽略` })
		end
		return nil
	end
	local outs = run.outputs or {}
	local count = 0
	for _ in outs :: { [string]: string } do
		count += 1
	end
	local stop: string? = nil
	for line in string.gmatch(text, "[^\n]+") do
		local k, v = string.match(line, "^%s*([%w_]+)=(.*)$")
		if k and v and model.valid_output_key(k) then
			v = string.sub((string.gsub(v, "\r$", "")), 1, MAX_OUTPUT_VALUE)
			if outs[k] == nil then
				if count >= MAX_OUTPUTS then
					continue
				end
				count += 1
			end
			outs[k] = v
			if k == "stop" then
				stop = if model.truthy(v) then util.clip(util.trim(v), 200) else nil
			end
		end
	end
	run.outputs = if next(outs) then outs else nil
	return stop
end

local function start_step(r: Runner, run: Run, wf: Workflow, i: number)
	local s = run.steps[i]
	local d = dir_of(r, run.id)
	local cfg = r.env.config().runner
	run.step = i
	if s.kind == "auth" then
		start_auth(r, run, i)
		return
	end
	local argv: { string } = {}
	local job: agent.Job? = nil
	local cwd = run.cwd or d
	local def: model.Step? = nil
	if s.kind == "prepare" then
		argv = { cfg.shell, "-c", M.PREPARE_WORKTREE }
		cwd = run.repo_path or d
	elseif s.kind == "cleanup" then
		argv = { cfg.shell, "-c", M.CLEANUP_WORKTREE }
		cwd = run.repo_path or d
	else
		def = definition(run, wf, i)
		if def == nil then
			-- The workflow changed under this run: stop here, but still clean up.
			s.state = "failed"
			s.finished_at = now(r)
			run.final = run.final or "interrupted"
			run.reason = "工作流定义已变化,无法继续此运行"
			next_step(r, run, wf)
			return
		end
		local step = def :: model.Step
		local why, stop = held(r, run, wf, step)
		if why then
			s.state = "skipped"
			if stop then
				run.final = run.final or "skipped"
				run.reason = why
			end
			append_log(r, run.id, { `\27[2m▷ {s.name}:{why}\27[0m` })
			persist(r)
			next_step(r, run, wf)
			return
		end
		if step.kind == "omp" and step.prompt then
			local args = table.clone(cfg.omp_args)
			for _, a in step.args do
				table.insert(args, a)
			end
			if step.model then
				table.insert(args, "--model")
				table.insert(args, step.model)
			end
			local command: string? = if app_missing(r, run) then nil else agent.command(cfg.omp, agent.files(d, i).session, args)
			if command and run.app then
				-- cx.agents:start passes no environment: the identity goes through a sourced file.
				local envf = `{d}/s{i}.env`
				local ok = pcall(tern.fs.write, envf, app_script(r, run))
				command = if ok then agent.with_env(envf, command :: string) else nil
			end
			if command then
				job = {
					run = run.id,
					step = i,
					cwd = cwd,
					omp = cfg.omp,
					command = command,
					prompt = template.render(step.prompt, template_ctx(r, run, wf, uses_payload(step.prompt))),
					title = `{run.workflow_name} · {s.name}`,
					session = cfg.session,
				}
			else
				argv = { "/bin/sh", "-c", "echo '[roost] 没有可用的 App 令牌或身份文件,omp 步骤未启动' >&2; exit 1" }
			end
		else
			argv = if app_missing(r, run)
				then { "/bin/sh", "-c", "echo '[roost] 没有可用的 App 令牌,步骤未以 App 身份启动' >&2; exit 1" }
				else { cfg.shell, "-c", step.script or "true" }
		end
	end
	local deadline = run.deadline or (now(r) + cfg.default_timeout)
	if def and def.timeout then
		deadline = math.min(deadline, now(r) + def.timeout)
	end
	if s.kind == "cleanup" then
		deadline = now(r) + 120
	end
	run.step_deadline = deadline
	s.state = "running"
	s.started_at = now(r)
	s.exit_code = nil

	pcall(tern.fs.mkdir, d)
	if run.workspace == "temp" and run.cwd then
		pcall(tern.fs.mkdir, run.cwd)
	end
	pcall(tern.fs.remove, `{d}/s{i}.exit`)
	if job then
		start_agent(r, run, i, job)
		return
	end
	pcall(tern.fs.remove, `{d}/s{i}.pid`)
	pcall(tern.fs.remove, `{d}/s{i}.pid.w`)
	local log = `{d}/log.txt`
	local env = step_env(r, run, wf)
	if def then
		env.ROOST_OUTPUT = `{d}/s{i}.out`
		pcall(tern.fs.remove, env.ROOST_OUTPUT)
	end
	if run.app and s.kind ~= "prepare" and s.kind ~= "cleanup" then
		with_app(r, run, env)
	end
	env.ROOST_BANNER = `\27[1;36m▶ {s.name}\27[0m`
	local full = { cfg.shell, "-c", M.WRAPPER, "roost", log, `{d}/s{i}.pid`, `{d}/s{i}.exit`, cwd }
	for _, a in argv do
		table.insert(full, a)
	end
	-- Saved before the process exists, so a reload never restarts a step that already began.
	persist(r, true)
	local id = run.id
	live(r, id).spawned[i] = true
	local ok, err = pcall(function(): string?
		tern.process.run(full, {
			env = env,
			timeout_ms = math.max(1, deadline - now(r)) * 1000 + BACKSTOP_MS,
		}, function(_res)
			local cur = r.env.store.by_id[id]
			if cur and cur.state == "running" and cur.step == i then
				live(r, id).exited[i] = now(r)
				check(r, cur)
			end
		end)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot start step", err)
		pcall(tern.fs.write, `{d}/s{i}.exit`, "127")
	end
	M.schedule(r, 1000)
end

function next_step(r: Runner, run: Run, wf: Workflow)
	local i = run.step + 1
	if run.final then
		-- Stopped or failed: only the cleanup step still runs.
		while run.steps[i] and run.steps[i].kind ~= "cleanup" do
			run.steps[i].state = "skipped"
			i += 1
		end
	end
	if run.steps[i] then
		start_step(r, run, wf, i)
		return
	end
	local final = run.final
	local last = run.steps[#run.steps]
	finish(r, run, final or "success", if final then run.reason else nil)
	if last and last.kind == "cleanup" and last.state == "failed" and run.state == "success" then
		run.reason = "清理 worktree 失败"
	end
	persist(r)
	M.pump(r)
end

local function step_done(r: Runner, run: Run, wf: Workflow, code: number)
	local s = run.steps[run.step]
	s.exit_code = code
	s.finished_at = now(r)
	s.state = if code == 0 then "success" else "failed"
	local def = if s.kind == "prepare" or s.kind == "cleanup" or s.kind == "auth" then nil else definition(run, wf, run.step)
	if run.stop == "cancel" then
		run.final = run.final or "cancelled"
	elseif run.stop == "timeout" then
		run.final = run.final or "timed_out"
		run.reason = "超时"
	elseif code ~= 0 and s.kind ~= "cleanup" and not (def and def.continue_on_error) then
		if run.final == nil then
			run.final = "failed"
			run.reason = if s.agent
				then `{s.name}:{agent.describe(code)}`
				elseif s.kind == "auth" then `{s.name}:{live(r, run.id).note[run.step] or `退出码 {code}`}`
				else `{s.name} 退出码 {code}`
		end
	end
	if def and def.kind == "run" and code >= 0 then
		-- The wrapper wrote the exit file, so $ROOST_OUTPUT is a regular file or gone.
		local stop = take_outputs(r, run, run.step)
		if stop and code == 0 and run.final == nil then
			run.final = "skipped"
			run.reason = stop
			append_log(r, run.id, { `[roost] {s.name} 结束了这次运行:{stop}` })
		end
	end
	if s.agent then
		-- The final answer is already in the log when the session file held it.
		local reply = if s.replied then nil else agent.files(dir_of(r, run.id), run.step).reply
		local spent = if s.tokens and s.tokens > 0
			then string.format("(约 $%.4f,%d tokens)", s.cost or 0, s.tokens)
			else ""
		append_log(r, run.id, { `[roost] agent 结束:{agent.describe(code)}{spent}` }, reply)
	end
	run.stop = nil
	next_step(r, run, wf)
end

-- Liveness of a step's wrapper and process group; marks the step exited when both are gone.
local function probe(r: Runner, run: Run, i: number)
	local l = live(r, run.id)
	local t = now(r)
	if t - (l.probe_at[i] or -math.huge) < PROBE_EVERY then
		return
	end
	l.probe_at[i] = t
	local d = dir_of(r, run.id)
	local child = read_pid(`{d}/s{i}.pid`)
	local wrapper = read_pid(`{d}/s{i}.pid.w`)
	if child == nil and wrapper == nil then
		l.exited[i] = l.exited[i] or (t - EXIT_GRACE)
		return
	end
	local id = run.id
	local ok, err = pcall(function(): string?
		tern.process.run({
			"/bin/sh",
			"-c",
			'{ [ -n "$1" ] && kill -0 "$1" 2>/dev/null; } || { [ -n "$2" ] && kill -0 -- "-$2" 2>/dev/null; }',
			"roost",
			if wrapper then tostring(wrapper) else "",
			if child then tostring(child) else "",
		}, { timeout_ms = 5000 }, function(res)
			local cur = r.env.store.by_id[id]
			if not cur or cur.state ~= "running" or cur.step ~= i then
				return
			end
			if res.status ~= 0 and not res.timed_out then
				local lv = live(r, id)
				lv.exited[i] = lv.exited[i] or (now(r) - EXIT_GRACE)
			end
			check(r, cur)
		end)
		return nil
	end)
	if not ok then
		l.probe_at[i] = nil
		tern.log.warn("roost: cannot probe step", err)
	end
end

function check(r: Runner, run: Run)
	if run.state ~= "running" or run.step < 1 then
		return
	end
	-- Without a valid workflows.toml, deadlines and signals still apply; only advancing to the
	-- next step waits.
	local wf, deleted = resolve(r, run)
	local i = run.step
	local cur = run.steps[i]
	local d = dir_of(r, run.id)
	local l = live(r, run.id)
	local t = now(r)
	if deleted and run.final == nil then
		run.final = "interrupted"
		run.reason = "工作流已被删除"
		if cur.kind ~= "cleanup" then
			run.stop = "cancel"
		end
		persist(r)
	end
	local exitf = `{d}/s{i}.exit`
	if tern.fs.exists(exitf) then
		if wf then
			if cur.agent and not l.tail_done[i] then
				-- Log the agent's last entries first; the read's end checks again.
				tail_agent(r, run, i, true)
				return
			end
			if cur.agent and l.tally[i] ~= "done" then
				-- Then what it cost; the tally's end checks again.
				tally_agent(r, run, i)
				return
			end
			local code = agent.read_number(exitf)
			if code == nil then
				-- Still being written (agent exit files are written in place): give it a moment.
				local since = l.exit_bad[i] or t
				l.exit_bad[i] = since
				if t - since < EXIT_GRACE then
					return
				end
			end
			step_done(r, run, wf, code or -1)
		end
		return
	end
	if run.stop == nil and run.step_deadline and t >= run.step_deadline then
		run.stop = "timeout"
		persist(r)
	end
	if cur.kind == "auth" then
		if run.stop or not l.spawned[i] then
			-- Stopped, or begun by an earlier VM: its relay request died with it.
			if not run.stop then
				l.note[i] = "插件重载打断了令牌获取"
			end
			pcall(tern.fs.write, exitf, if run.stop then "130" else "1")
		end
		return
	end
	if cur.agent then
		watch_agent(r, run, i)
		return
	end
	if run.stop and cur.kind ~= "cleanup" then
		local sent = l.killed[i]
		if sent == nil then
			signal(r, run, "TERM")
		elseif sent == "TERM" and t - (l.kill_at[i] or t) >= KILL_GRACE then
			signal(r, run, "KILL")
		elseif sent == "KILL" then
			probe(r, run, i)
		end
	end
	if not l.spawned[i] then
		-- Started by an earlier VM: nobody calls back, so look for ourselves.
		probe(r, run, i)
	end
	local exited = l.exited[i]
	if wf and exited and t - exited >= EXIT_GRACE then
		-- The wrapper is gone without writing its exit file.
		step_done(r, run, wf, -1)
	end
end

-- Starts queued runs while capacity allows, oldest first, one per workflow.
function M.pump(r: Runner)
	if r.env.workflows() == nil then
		return
	end
	local max = r.env.config().runner.max_concurrent
	local running: { [string]: boolean } = {}
	local n = 0
	for _, run in r.env.store.runs do
		if run.state == "running" then
			running[run.workflow] = true
			n += 1
		end
	end
	for _, run in table.clone(r.env.store.runs) do
		if n >= max then
			break
		end
		if run.state == "queued" and not running[run.workflow] then
			local wf, deleted = resolve(r, run)
			if not wf then
				return
			end
			if deleted then
				finish(r, run, "interrupted", "工作流已被删除")
				persist(r)
				continue
			end
			local w = wf :: Workflow
			running[run.workflow] = true
			n += 1
			run.state = "running"
			run.started_at = now(r)
			run.deadline = now(r) + (w.timeout or r.env.config().runner.default_timeout)
			next_step(r, run, w)
		end
	end
end

-- Checks every running run; reschedules itself while any is active.
function M.tick(r: Runner)
	r.timer = nil
	local active = false
	for _, run in table.clone(r.env.store.runs) do
		if run.state == "running" then
			renew(r, run)
			check(r, run)
		end
	end
	for _, run in r.env.store.runs do
		if run.state == "running" or run.state == "queued" then
			active = true
			break
		end
	end
	if active then
		M.pump(r)
		M.schedule(r, 1000)
	end
end

function M.schedule(r: Runner, ms: number)
	if r.timer then
		return
	end
	r.timer = tern.timer(ms, function()
		M.tick(r)
	end)
end

-- After a reload: runs that were running are adopted; `check` probes their step's processes
-- (nobody in this VM gets their callback) and carries on or ends them.
function M.recover(r: Runner)
	for _, run in r.env.store.runs do
		if run.state == "running" and run.step < 1 then
			finish(r, run, "interrupted", "插件重载时尚未开始")
		end
	end
	persist(r)
	M.schedule(r, 500)
end

-- Reads up to `limit` bytes of a run's log from `offset` (0-based) without loading the whole file.
function M.read_log(r: Runner, id: string, offset: number, limit: number, cb: (string?, boolean) -> ())
	local path = `{dir_of(r, id)}/log.txt`
	if not tern.fs.exists(path) then
		cb("", true)
		return
	end
	read_chunk(path, offset, limit, function(text)
		if text == nil then
			cb(nil, false)
		else
			cb(text, #text < limit)
		end
	end)
end

return M
