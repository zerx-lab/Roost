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

local M = {}

type Run = store.Run
type Workflow = model.Workflow

-- The wrapper: `sh -c WRAPPER roost LOG PIDFILE EXITFILE CWD PROG ARGS...`. `set -m` gives the
-- command its own process group, so cancel can signal everything it started. The wrapper's own
-- pid goes to PIDFILE.w so a later VM can tell whether anyone is left to write the exit file.
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

export type Request = {
	trigger: { kind: string, detail: string, delivery: string? },
	repo: string?,
	ref: string?,
	inputs: { [string]: string },
	event: { [string]: any }?,
	payload: string?, -- raw JSON text of the webhook payload
	rerun_of: string?,
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

-- Appends `lines` (then the file at `tail`, when given) to a run's log.
local function append_log(r: Runner, id: string, lines: { string }, tail: string?)
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
		tern.process.run(argv, { timeout_ms = 5000 }, function(_res) end)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot append to log", err)
	end
end

local function live(r: Runner, id: string): Live
	local l = r.live[id]
	if not l then
		l = { spawned = {}, exited = {}, killed = {}, kill_at = {}, probe_at = {}, claim_at = {}, exit_bad = {} }
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
		return "worktree", `{r.env.data}/worktrees/{id}`, path, ref
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
	local steps: { store.StepRec } = {}
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
	end
	store.prune(r.env.store)
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
	return env
end

local check: (Runner, Run) -> ()
local next_step: (Runner, Run, Workflow) -> ()

-- The definition of user step `i` (prepare/cleanup have none), matched by name and kind.
local function definition(run: Run, wf: Workflow, i: number): model.Step?
	local offset = if run.steps[1] and run.steps[1].kind == "prepare" then 1 else 0
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

-- An agent step nobody else will finish: unclaimed when stopping, or claimed but never started.
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
		return
	end
	local t = now(r)
	local since = l.claim_at[i] or t
	l.claim_at[i] = since
	if t - since >= CLAIM_GRACE then
		pcall(tern.fs.write, f.exit, tostring(agent.CODE.lost))
	end
end

local function start_step(r: Runner, run: Run, wf: Workflow, i: number)
	local s = run.steps[i]
	local d = dir_of(r, run.id)
	local cfg = r.env.config().runner
	run.step = i
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
		if step.kind == "omp" and step.prompt then
			local args = table.clone(cfg.omp_args)
			for _, a in step.args do
				table.insert(args, a)
			end
			if step.model then
				table.insert(args, "--model")
				table.insert(args, step.model)
			end
			job = {
				run = run.id,
				step = i,
				cwd = cwd,
				omp = cfg.omp,
				command = agent.command(cfg.omp, agent.files(d, i).session, args),
				prompt = template.render(step.prompt, template_ctx(r, run, wf, uses_payload(step.prompt))),
				title = `{run.workflow_name} · {s.name}`,
				session = cfg.session,
			}
		else
			argv = { cfg.shell, "-c", step.script or "true" }
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
	local def = if s.kind == "prepare" or s.kind == "cleanup" then nil else definition(run, wf, run.step)
	if run.stop == "cancel" then
		run.final = run.final or "cancelled"
	elseif run.stop == "timeout" then
		run.final = run.final or "timed_out"
		run.reason = "超时"
	elseif code ~= 0 and s.kind ~= "cleanup" and not (def and def.continue_on_error) then
		if run.final == nil then
			run.final = "failed"
			run.reason = if s.agent then `{s.name}:{agent.describe(code)}` else `{s.name} 退出码 {code}`
		end
	end
	if s.agent then
		append_log(r, run.id, { `[roost] agent 结束:{agent.describe(code)}` }, agent.files(dir_of(r, run.id), run.step).reply)
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
			cb(nil, false)
		else
			cb(res.stdout, #res.stdout < limit)
		end
	end)
end

return M
