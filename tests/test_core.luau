--!strict
-- Runtime flows on the fake tern: config loading, cron firing, the run engine's step machine
-- (through the pid/exit-file wrapper protocol for shell steps, and the agent job protocol with a
-- fake window for omp steps), cancellation, timeouts, recovery after a reload, relayed events
-- turning into runs, and subscription sync with the relay.

local F = require("./fake_tern")
local harness = require("./harness")

local function eq(a: any, b: any, msg: string?)
	if a ~= b then
		error(`{msg or "eq"}: expected {tostring(b)}, got {tostring(a)}`, 2)
	end
end

local function truthy(v: any, msg: string)
	if not v then
		error(msg, 2)
	end
end

local DATA = "/data"
local T0 = 1793880000 -- 2026-11-05T08:00:00Z, a Thursday; minute-aligned

type Proc = { argv: { string }, opts: any, kind: string, run: string?, step: number?, cmd: { string } }

-- Classifies a process call the way the runner issues them.
local function classify(argv: { string }): Proc
	local p: Proc = { argv = argv, opts = nil, kind = "other", cmd = {} }
	local script = argv[3] or ""
	if string.find(script, "set -m", 1, true) then
		p.kind = "wrapper"
		p.run, p.step = string.match(argv[7], "/runs/([%x]+)/s(%d+)%.exit$") :: any, nil
		p.step = tonumber(string.match(argv[7], "/s(%d+)%.exit$") or "")
		for i = 9, #argv do
			table.insert(p.cmd, argv[i])
		end
	elseif string.find(script, "kill -s", 1, true) then
		p.kind = "kill"
	elseif string.find(script, "kill -0", 1, true) then
		p.kind = "alive"
	elseif string.find(script, "tail -c", 1, true) then
		p.kind = "tail"
	elseif argv[1] == "/bin/mkdir" then
		p.kind = "mkdir"
	end
	return p
end

type Scenario = {
	env: any,
	core: any,
	c: any,
	procs: { Proc },
	-- What a started wrapper does: "exit:<code>" finishes at once, "hang" keeps running.
	behave: (Proc) -> string,
	http: ((method: string, path: string, body: any) -> ...any)?,
	now: number,
	-- Whether probed processes are alive; whether SIGTERM is ignored by hanging steps.
	alive: boolean,
	ignore_term: boolean,
	-- A fake Tern window running lib/launcher.luau, once `window(s)` attached one.
	win: any,
	L: any,
}

local function scenario(files: { [string]: string }, opts: { [string]: any }?): Scenario
	local o: any = opts or {}
	local env = F.new()
	harness.fresh(env)
	for k, v in files do
		env.files[k] = v
	end
	local s: Scenario = {
		env = env,
		core = nil,
		c = nil,
		procs = {},
		behave = function(_p)
			return "exit:0"
		end,
		http = nil :: any,
		now = T0,
		alive = o.alive == true,
		ignore_term = false,
		win = nil :: any,
		L = nil :: any,
	}
	env.process = function(argv: { string }, popts: any): any
		local p = classify(argv)
		p.opts = popts
		table.insert(s.procs, p)
		if p.kind == "wrapper" then
			env.files[argv[6]] = "4242"
			env.files[argv[6] .. ".w"] = "4241"
			local log = argv[5]
			env.files[log] = (env.files[log] or "") .. (popts.env.ROOST_BANNER or "") .. "\n" .. table.concat(p.cmd, " ") .. "\n"
			local b = s.behave(p)
			local code = string.match(b, "^exit:(%-?%d+)$")
			if code then
				env.files[argv[7]] = code .. "\n"
				return { status = tonumber(code), stdout = "", stderr = "", timed_out = false }
			end
			return false -- still running: no callback yet
		elseif p.kind == "kill" then
			if p.argv[5] == "TERM" and s.ignore_term then
				return { status = 0, stdout = "", stderr = "", timed_out = false }
			end
			-- The wrapper sees its child die and records 143 (137 for KILL).
			for _, q in s.procs do
				if q.kind == "wrapper" and not env.files[q.argv[7]] then
					env.files[q.argv[7]] = (if p.argv[5] == "KILL" then "137" else "143") .. "\n"
				end
			end
			return { status = 0, stdout = "", stderr = "", timed_out = false }
		elseif p.kind == "alive" then
			return { status = if s.alive then 0 else 1, stdout = "", stderr = "", timed_out = false }
		elseif p.kind == "tail" then
			return { status = 0, stdout = "", stderr = "", timed_out = false }
		elseif p.kind == "mkdir" then
			-- Atomic like mkdir(1): fails when the directory exists.
			if env.tern.fs.exists(argv[2]) then
				return { status = 1, stdout = "", stderr = "File exists", timed_out = false }
			end
			env.dirs[argv[2]] = true
			return { status = 0, stdout = "", stderr = "", timed_out = false }
		end
		return env.append(argv) or { status = 0, stdout = "", stderr = "", timed_out = false }
	end
	env.fetch = function(url: string, fopts: any): any
		local path = string.match(url, "^https?://[^/]+(.*)$") or url
		local body = if fopts.body then F.decode(fopts.body) else nil
		local handler = s.http
		if not handler then
			return false
		end
		local res = { handler(fopts.method or "GET", path, body) }
		if res[1] == nil or res[1] == false then
			return false -- not answered (yet): lands in env.deferred
		end
		return { status = res[1], headers = {}, body = F.encode(res[2]), error = nil, timed_out = false }
	end
	local core = require("../lib/core")
	core.clock = function()
		return s.now
	end
	s.core = core
	s.c = core.new(DATA)
	return s
end

-- Attaches a fake window that runs the agent launcher on every scenario second.
local function window(s: Scenario): any
	local w = s.env.window()
	s.env.wcx = w.cx
	s.win = w
	s.L = require("../lib/launcher").new(DATA)
	return w
end

local function step(s: Scenario, seconds: number)
	-- Advance wall clock and the fake timer clock together, one second at a time; the window's
	-- launcher ticks after the host each second.
	for _ = 1, seconds do
		s.now += 1
		s.env.advance(1000)
		if s.L then
			require("../lib/launcher").tick(s.L, s.win.cx)
			s.env.drain()
		end
	end
end

local function last_run(s: Scenario): any
	local runs = s.c.store.runs
	return runs[#runs]
end

local WF_CRON = [==[
[[workflow]]
id = "tick"
workspace = "temp"
[[workflow.trigger]]
cron = "*/5 * * * *"
tz = "UTC"
[[workflow.step]]
name = "say"
run = "echo hi"
[[workflow.step]]
name = "think"
omp = "Summarize {{trigger}} run {{run_id}}"
]==]

do -- defaults are written on first start and parse cleanly
	local s = scenario({})
	s.core.start(s.c)
	truthy(s.env.files[DATA .. "/roost.toml"], "roost.toml created")
	truthy(s.env.files[DATA .. "/workflows.toml"], "workflows.toml created")
	eq(#s.c.config_issues, 0, "default roost.toml valid")
	eq(#s.c.workflow_issues, 0, "default workflows.toml valid")
	truthy(s.c.workflows and s.c.workflows.by_id.hello, "example workflow loaded")
	eq(s.c.relay.state.configured, false, "relay unconfigured by default")
end

do -- cron fires once per matching minute; the omp step runs as an agent tab in the Roost session
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_CRON, [DATA .. "/roost.toml"] = "" })
	local w = window(s)
	s.core.start(s.c)
	eq(#s.c.crons, 1, "one cron row")
	eq(s.c.crons[1].next, T0 + 300, "next fire is the next */5 minute")
	step(s, 299)
	eq(#s.c.store.runs, 0, "nothing before the minute")
	step(s, 5)
	eq(#s.c.store.runs, 1, "fired at the */5 minute")
	local run = last_run(s)
	local say = s.procs[1]
	eq(say.kind, "wrapper", "shell step runs through the wrapper")
	eq(say.opts.env.ROOST_TRIGGER, "cron")
	truthy(string.find(say.opts.env.PATH, "/home/test/.local/bin", 1, true), "extra_path expanded into PATH")
	step(s, 2)
	eq(run.steps[1].state, "success")
	eq(run.steps[2].state, "running", "omp step waits for its agent")
	eq(#w.started, 1, "the window opened one agent")
	local started = w.started[1]
	local dir = `{DATA}/runs/{run.id}`
	eq(started.opts.command, `omp --session-dir {dir}/s2.session --approval-mode yolo`, "omp keeps its session in the run")
	eq(started.opts.prompt, `Summarize cron run {run.id}`, "prompt rendered")
	eq(started.opts.cwd, `{dir}/work`)
	eq(started.opts.how, "tab")
	eq(#w.sessions, 2, "Roost session created")
	eq(w.sessions[2].name, "Roost")
	eq(w.shown, 1, "the shown session is back to what it was")
	eq(w.moved[1].session, w.sessions[2].id, "agent moved into the Roost session")
	eq(w.moved[1].reveal.focus, false)
	eq(w.named[w.panes[started.pane].tab], "tick · think", "tab named after the step")
	eq(w.focused, 1, "focus restored")
	eq(s.env.files[`{dir}/s2.pane`], tostring(started.pane), "pane recorded")
	step(s, 5)
	eq(run.state, "running", "still working")
	w.reply(started.pane, "总结完毕")
	step(s, 4)
	eq(run.state, "success", "turn finished: run succeeded")
	eq(run.steps[2].exit_code, 0)
	eq(w.stopped[1], started.pane, "agent tab closed")
	eq(#s.env.kv.agent_jobs, 0, "no agent jobs left")
	local log = s.env.files[`{dir}/log.txt`] or ""
	truthy(string.find(log, "总结完毕", 1, true), "reply appended to the log")
	truthy(string.find(log, "agent 结束:完成", 1, true), "outcome logged")
	step(s, 60)
	eq(#s.c.store.runs, 1, "no second fire within the same 5 minutes")
	eq(#w.started, 1, "a finished step is never reopened")
	truthy(s.env.files[DATA .. "/runs.json"] and s.env.files[DATA .. "/runs.json.bak"], "history saved twice")
end

local WF_TWO = [==[
[[workflow]]
id = "w"
workspace = "temp"
timeout = "10s"
[[workflow.step]]
name = "first"
run = "exit 3"
[[workflow.step]]
name = "second"
run = "echo never"
]==]

do -- a failing step stops the run; later steps are skipped
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TWO, [DATA .. "/roost.toml"] = "" })
	s.core.start(s.c)
	s.behave = function(p)
		return if p.cmd[3] == "exit 3" then "exit:3" else "exit:0"
	end
	eq(s.core.dispatch(s.c, "w"), nil, "manual dispatch accepted")
	step(s, 2)
	local run = last_run(s)
	eq(run.state, "failed")
	eq(run.reason, "first 退出码 3")
	eq(run.steps[2].state, "skipped")
end

do -- timeout: SIGTERM to the group, step recorded failed, run timed_out
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TWO, [DATA .. "/roost.toml"] = "" })
	s.core.start(s.c)
	s.behave = function(_p)
		return "hang"
	end
	s.core.dispatch(s.c, "w")
	step(s, 5)
	eq(last_run(s).state, "running", "still running before the deadline")
	step(s, 8)
	local run = last_run(s)
	eq(run.state, "timed_out", "deadline enforced")
	local killed = false
	for _, p in s.procs do
		if p.kind == "kill" and p.argv[5] == "TERM" and p.argv[6] == "4242" then
			killed = true
		end
	end
	truthy(killed, "process group signalled with TERM")
end

local WF_TREE = [==[
[repos."acme/web"]
path = "~/code/web"
branch = "main"

[[workflow]]
id = "fix"
repos = ["acme/web"]
concurrency = "replace"
[[workflow.trigger]]
github = "issue_comment"
comment = "/roost"
[[workflow.step]]
name = "work"
omp = "Fix #{{number}}: {{payload.comment.body}}"
]==]

do -- cancel while an agent works in a worktree: the window closes it, cleanup still runs
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TREE, [DATA .. "/roost.toml"] = "" })
	local w = window(s)
	s.core.start(s.c)
	s.core.dispatch(s.c, "fix")
	step(s, 2)
	local run = last_run(s)
	eq(run.workspace, "worktree")
	eq(run.fetch_ref, "main", "manual run checks out the repo branch")
	eq(run.repo_path, "/home/test/code/web")
	eq(run.steps[1].kind, "prepare")
	eq(run.steps[2].state, "running")
	eq(#w.started, 1, "agent opened")
	eq(w.started[1].opts.cwd, `{DATA}/worktrees/{run.id}`, "agent works in the worktree")
	eq(s.core.cancel(s.c, run.id), nil, "cancel accepted")
	eq(s.env.kv.agent_jobs[1].stop, true, "stop published to the windows")
	step(s, 3)
	eq(w.stopped[1], w.started[1].pane, "window closed the agent")
	eq(run.state, "cancelled")
	eq(run.steps[2].exit_code, 143)
	eq(run.steps[3].kind, "cleanup")
	eq(run.steps[3].state, "success", "cleanup ran after cancel")
end

do -- recovery: a step still alive after a reload keeps running; a dead one ends the run
	for _, alive in { true, false } do
		local s = scenario({ [DATA .. "/workflows.toml"] = WF_TWO, [DATA .. "/roost.toml"] = "" }, { alive = alive })
		s.core.start(s.c)
		s.behave = function(_p)
			return "hang"
		end
		s.core.dispatch(s.c, "w")
		step(s, 1)
		local id = last_run(s).id
		local saved = s.env.files[DATA .. "/runs.json"]
		-- New VM: same files, fresh modules.
		local files = table.clone(s.env.files)
		local s2 = scenario(files, { alive = alive })
		s2.env.files[DATA .. "/runs.json"] = saved
		s2.now = s.now
		s2.core.start(s2.c)
		step(s2, 1)
		local run = s2.c.store.by_id[id]
		if alive then
			eq(run.state, "running", "adopted a live step")
			s2.env.files[`{DATA}/runs/{id}/s1.exit`] = "0\n"
			s2.behave = function(_p)
				return "exit:0"
			end
			step(s2, 2)
			eq(run.state, "success", "continued after the adopted step finished")
		else
			step(s2, 4)
			eq(run.state, "failed", "dead step ends the run")
			eq(run.steps[1].exit_code, -1)
		end
	end
end

local ROOST = [==[
[relay]
url = "https://relay.test"
token = "tok-0123456789abcdef"
]==]

local function comment_event(seq: number, body: string, assoc: string): any
	return {
		seq = seq,
		delivery = `d{seq}`,
		event = "issue_comment",
		repo = "acme/web",
		info = {
			event = "issue_comment",
			action = "created",
			repo = "acme/web",
			number = 7,
			title = "Crash",
			comment = body,
			association = assoc,
			fetch_ref = "refs/pull/7/head",
			is_pr = true,
		},
		payload = { comment = { body = body } },
	}
end

do -- relayed events: cursor, matching, run with payload template, subscriptions pushed
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TREE, [DATA .. "/roost.toml"] = ROOST })
	local pushed: any = nil
	local polls = 0
	local queue: { any } = {}
	local head = 10
	s.http = function(method, path, body)
		if method == "PUT" and path == "/api/v1/subscriptions" then
			pushed = body
			return 200, { revision = "r1", changed = true }
		elseif method == "GET" and string.sub(path, 1, 15) == "/api/v1/events?" then
			polls += 1
			if polls == 1 then
				truthy(not string.find(path, "after=", 1, true), "first poll has no cursor")
				return 200, { store_id = "S", head = 10, oldest = 1, gap = false, events = {} }
			end
			truthy(string.find(path, "after=10", 1, true) or string.find(path, "after=12", 1, true), "cursor sent: " .. path)
			if #queue > 0 then
				local evs = queue
				queue = {}
				head = 12
				return 200, { store_id = "S", head = head, oldest = 1, gap = false, events = evs }
			end
			return 200, { store_id = "S", head = head, oldest = 1, gap = false, events = {} }
		elseif path == "/api/v1/status" then
			return 200, { boot_id = "b1", version = "0.1.0" }
		end
		return 404, { error = "nope" }
	end
	s.core.start(s.c)
	step(s, 1)
	truthy(pushed, "subscriptions pushed on load")
	eq(pushed.repos["acme/web"].events[1], "issue_comment")
	eq(pushed.base_revision, nil, "first push has no base revision")
	eq(s.env.kv.subs.rev, "r1")
	eq(s.env.kv.subs.url, "https://relay.test", "push state is per relay URL")
	truthy(s.c.relay.state.connected, "connected after first poll")
	eq(s.env.kv.cursor.seq, 10, "cursor starts at head")

	queue = { comment_event(11, "/roost please", "MEMBER"), comment_event(12, "/roost x", "NONE") }
	s.behave = function(_p)
		return "exit:0"
	end
	step(s, 4)
	eq(s.env.kv.cursor.seq, 12, "cursor advanced")
	eq(#s.c.events, 2, "both events listed")
	local member, outsider = s.c.events[2], s.c.events[1]
	eq(#member.runs, 1, "member comment launched a run")
	truthy(outsider.reasons.fix and string.find(outsider.reasons.fix, "NONE", 1, true), "outsider rejected by association")
	local run = s.c.store.by_id[member.runs[1]]
	eq(run.fetch_ref, "refs/pull/7/head", "event ref checked out")
	step(s, 2)
	local job = F.decode(s.env.files[`{DATA}/runs/{run.id}/s2.job.json`])
	eq(job.prompt, "Fix #7: /roost please", "payload template rendered")
end

do -- a server-side edit makes the push conflict; adopting the remote revision clears it
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TREE, [DATA .. "/roost.toml"] = ROOST })
	s.env.kv.subs = { url = "https://relay.test", rev = "old", fp = "stale" }
	s.http = function(method, path, body)
		if method == "PUT" and path == "/api/v1/subscriptions" then
			if body.base_revision == "old" then
				return 409, { error = "conflict", revision = "hand", text = "[repos.\"x/y\"]\n" }
			end
			return 200, { revision = "forced" }
		elseif path == "/api/v1/status" then
			return 200, { boot_id = "b1" }
		end
		return nil
	end
	s.core.start(s.c)
	step(s, 1)
	eq(s.c.relay.state.sync.state, "conflict")
	eq(s.c.relay.state.sync.remote_text, "[repos.\"x/y\"]\n")
	s.core.push_subscriptions(s.c, true)
	step(s, 1)
	eq(s.c.relay.state.sync.state, "ok", "force push overwrote the server copy")
	eq(s.env.kv.subs.rev, "forced")
end

do -- unreachable relay: offline sync state keeps the manual fallback available
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TREE, [DATA .. "/roost.toml"] = ROOST })
	s.env.fetch = function(_url, _o)
		return { status = 0, headers = {}, body = "", error = "connection refused", timed_out = false }
	end
	s.core.start(s.c)
	step(s, 1)
	eq(s.c.relay.state.sync.state, "offline")
	truthy(string.find(s.c.relay.state.sync.error, "connection refused", 1, true), "error kept")
	local model = require("../lib/model")
	local text = model.subscriptions_toml(model.subscriptions(s.c.workflows))
	truthy(string.find(text, '[repos."acme/web"]', 1, true), "manual file has the repo")
	truthy(string.find(text, 'events = ["issue_comment"]', 1, true), "manual file has the events")
end

do -- remote restart waits for a new boot id
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TREE, [DATA .. "/roost.toml"] = ROOST })
	local boot = "b1"
	s.http = function(method, path, _body)
		if path == "/api/v1/status" then
			return 200, { boot_id = boot }
		elseif method == "POST" and path == "/api/v1/restart" then
			boot = "b2"
			return 202, { ok = true, boot_id = "b1", restart = true }
		elseif method == "PUT" then
			return 200, { revision = "r" }
		end
		return nil
	end
	s.core.start(s.c)
	step(s, 1)
	s.core.remote_restart(s.c)
	step(s, 1)
	truthy(s.c.relay.state.restarting, "restarting flagged")
	step(s, 4)
	eq(s.c.relay.state.restarting, nil, "cleared once the new boot id shows up")
	eq(s.c.relay.state.agent.boot_id, "b2")
end

do -- invalid workflows keep the last good version and report issues with lines
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_CRON, [DATA .. "/roost.toml"] = "" })
	s.core.start(s.c)
	s.env.files[DATA .. "/workflows.toml"] = WF_CRON .. '\n[[workflow]]\nid = "Bad"\n'
	step(s, 4)
	truthy(s.c.workflows.by_id.tick, "last good workflows kept")
	truthy(#s.c.workflow_issues >= 1, "issues reported")
	local any_line = false
	for _, i in s.c.workflow_issues do
		if i.line then
			any_line = true
		end
	end
	truthy(any_line, "issues carry line numbers")
end

do -- cancel escalates to SIGKILL when the step ignores SIGTERM
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TWO, [DATA .. "/roost.toml"] = "" })
	s.core.start(s.c)
	s.ignore_term = true
	s.behave = function(_p)
		return "hang"
	end
	s.core.dispatch(s.c, "w")
	step(s, 1)
	local run = last_run(s)
	s.core.cancel(s.c, run.id)
	step(s, 5)
	eq(run.state, "running", "TERM ignored, still waiting out the grace")
	step(s, 5)
	eq(run.state, "cancelled", "KILL after the grace period")
	eq(run.steps[1].exit_code, 137)
end

do -- an adopted step whose processes die later is noticed by probing
	local long = (string.gsub(WF_TWO, 'timeout = "10s"', 'timeout = "10m"'))
	local s = scenario({ [DATA .. "/workflows.toml"] = long, [DATA .. "/roost.toml"] = "" }, { alive = true })
	s.core.start(s.c)
	s.behave = function(_p)
		return "hang"
	end
	s.core.dispatch(s.c, "w")
	step(s, 1)
	local id = last_run(s).id
	local s2 = scenario(table.clone(s.env.files), { alive = true })
	s2.now = s.now
	s2.core.start(s2.c)
	step(s2, 6)
	eq(s2.c.store.by_id[id].state, "running", "alive: adopted")
	s2.alive = false -- the wrapper and its group vanish without an exit file
	step(s2, 12)
	eq(s2.c.store.by_id[id].state, "failed", "probe noticed the dead step")
end

do -- deleting a workflow mid-run stops the step and still removes the worktree
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TREE, [DATA .. "/roost.toml"] = "" })
	s.core.start(s.c)
	s.behave = function(p)
		return if p.cmd[1] == "omp" then "hang" else "exit:0"
	end
	s.core.dispatch(s.c, "fix")
	step(s, 2)
	local run = last_run(s)
	eq(run.steps[2].state, "running")
	s.env.files[DATA .. "/workflows.toml"] = '[[workflow]]\nid = "other"\n[[workflow.step]]\nrun = "true"\n'
	step(s, 6)
	eq(run.state, "interrupted")
	eq(run.reason, "工作流已被删除")
	eq(run.steps[3].kind, "cleanup")
	eq(run.steps[3].state, "success", "cleanup ran")
end

do -- invalid workflows at startup: runs and relay events are held, not destroyed
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TWO, [DATA .. "/roost.toml"] = ROOST })
	local polled = 0
	s.http = function(method, path, _body)
		if string.sub(path, 1, 15) == "/api/v1/events?" then
			polled += 1
			return 200, { store_id = "S", head = 0, oldest = 1, gap = false, events = {} }
		elseif method == "PUT" then
			return 200, { revision = "r" }
		end
		return 200, {}
	end
	s.core.start(s.c)
	s.behave = function(_p)
		return "hang"
	end
	s.core.dispatch(s.c, "w")
	step(s, 1)
	local id = last_run(s).id
	local files = table.clone(s.env.files)
	files[DATA .. "/workflows.toml"] = "[[workflow]]\nid = 'broken"
	local s2 = scenario(files, { alive = true })
	s2.now = s.now
	local polls2 = 0
	s2.http = function(_m, path, _b)
		if string.sub(path, 1, 15) == "/api/v1/events?" then
			polls2 += 1
		end
		return 200, { store_id = "S", head = 0, oldest = 1, gap = false, events = {} }
	end
	s2.core.start(s2.c)
	step(s2, 10)
	eq(s2.c.store.by_id[id].state, "running", "run held while workflows.toml is invalid")
	eq(polls2, 0, "relay events not consumed without valid workflows")
	truthy(s2.c.relay.state.waiting, "relay shows it is waiting")
	truthy(#s2.c.notices > 0 and string.find(s2.c.notices[1].text, "不会运行", 1, true), "notice explains the hold")
	truthy(polled > 0, "first VM polled")
end

do -- a wiped relay store restarts the cursor at 0 and delivers its events
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TREE, [DATA .. "/roost.toml"] = ROOST })
	s.env.kv.cursor = { url = "https://relay.test", store_id = "OLD", seq = 50 }
	local seen_after: { string } = {}
	s.http = function(method, path, _body)
		if string.sub(path, 1, 15) == "/api/v1/events?" then
			local after = string.match(path, "after=(%d+)")
			table.insert(seen_after, after or "none")
			if after == "0" then
				return 200, { store_id = "NEW", head = 1, oldest = 1, gap = false, events = { comment_event(1, "/roost go", "OWNER") } }
			end
			return 200, { store_id = "NEW", head = 1, oldest = 1, gap = false, events = {} }
		elseif method == "PUT" then
			return 200, { revision = "r" }
		end
		return 200, {}
	end
	s.behave = function(_p)
		return "exit:0"
	end
	s.core.start(s.c)
	step(s, 2)
	eq(seen_after[1], "50")
	eq(seen_after[2], "0", "cursor reset to the start of the new store")
	truthy(s.c.relay.state.reset_at, "reset noted")
	eq(#s.c.events, 1, "event from the new store delivered")
	eq(#s.c.events[1].runs, 1, "and it launched a run")
end

do -- an edit during a push is pushed right after it; offline pushes retry on reconnect
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TREE, [DATA .. "/roost.toml"] = ROOST })
	local puts: { any } = {}
	s.http = function(method, path, body)
		if method == "PUT" then
			table.insert(puts, body)
			if #puts == 1 then
				return false -- held open
			end
			return 200, { revision = `r{#puts}` }
		elseif string.sub(path, 1, 15) == "/api/v1/events?" then
			return 200, { store_id = "S", head = 0, oldest = 1, gap = false, events = {} }
		end
		return 200, {}
	end
	s.core.start(s.c)
	step(s, 1)
	eq(#puts, 1, "first push in flight")
	s.env.files[DATA .. "/workflows.toml"] = string.gsub(WF_TREE, 'github = "issue_comment"', 'github = "issues"')
	step(s, 4)
	eq(#puts, 1, "second push waits for the first")
	local d = table.remove(s.env.deferred, 1)
	d.cb({ status = 200, headers = {}, body = F.encode({ revision = "r1" }), timed_out = false })
	step(s, 1)
	eq(#puts, 2, "queued push sent after the first finished")
	eq(puts[2].repos["acme/web"].events[1], "issues", "with the edited subscriptions")
	eq(s.c.relay.state.sync.state, "ok")
end

local WF_AGENT = [==[
[[workflow]]
id = "a"
workspace = "temp"
timeout = "1m"
[[workflow.step]]
name = "ask"
omp = "hello"
args = ["--model", "x/y"]
]==]

local function agent_run(with_window: boolean): (Scenario, any)
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_AGENT, [DATA .. "/roost.toml"] = "" })
	if with_window then
		window(s)
	end
	s.core.start(s.c)
	s.core.dispatch(s.c, "a")
	return s, last_run(s)
end

do -- no window: the step waits, then times out; the host records the stop itself
	local s, run = agent_run(false)
	step(s, 30)
	eq(run.state, "running", "waiting for a window")
	eq(#s.env.kv.agent_jobs, 1, "job listed for the windows")
	step(s, 35)
	eq(run.state, "timed_out")
	eq(run.steps[1].exit_code, 143)
	eq(#s.env.kv.agent_jobs, 0)
end

do -- a claim that never got a pane (window died mid-launch) is given up after the grace
	local s, run = agent_run(false)
	step(s, 1)
	s.env.dirs[`{DATA}/runs/{run.id}/s1.claim`] = true
	step(s, 20)
	eq(run.state, "running", "within the grace")
	step(s, 15)
	eq(run.state, "failed")
	eq(run.steps[1].exit_code, 137)
	truthy(string.find(run.reason, "丢失", 1, true), "reason explains: " .. run.reason)
end

do -- an agent tab closed by hand fails the step; a reported failure fails it too
	local s, run = agent_run(true)
	local w = s.win
	step(s, 2)
	local pane = w.started[1].pane
	truthy(string.find(w.started[1].opts.command, "--model x/y", 1, true), "step args passed to omp")
	w.agents[pane] = nil -- the user closed it
	step(s, 5)
	eq(run.state, "failed")
	eq(run.steps[1].exit_code, 130)
	truthy(string.find(run.reason, "手动关闭", 1, true), run.reason)

	local s2, run2 = agent_run(true)
	step(s2, 2)
	local launcher = require("../lib/launcher")
	launcher.on_finished(s2.L, { pane = s2.win.started[1].pane, result = "failed" }, s2.win.cx)
	step(s2, 2)
	eq(run2.state, "failed")
	eq(run2.steps[1].exit_code, 1)
	eq(#s2.win.stopped, 1, "failed agents are closed too")
end

do -- a reloaded window adopts the agent from s<i>.pane; a second window never opens a duplicate
	local s, run = agent_run(true)
	local launcher = require("../lib/launcher")
	local w2 = s.env.window()
	w2.agents = s.win.agents -- every window sees the same agent blocks
	local L2 = launcher.new(DATA)
	for _ = 1, 3 do
		step(s, 1)
		launcher.tick(L2, w2.cx)
		s.env.drain()
	end
	eq(#s.win.started + #w2.started, 1, "exactly one window opened the agent")
	local pane = s.win.started[1].pane
	s.L = launcher.new(DATA) -- the first window's VM restarts
	step(s, 2)
	eq(#s.win.started, 1, "not reopened after the reload")
	s.win.reply(pane, "done")
	step(s, 4)
	eq(run.state, "success", "the new VM saw the turn end")
end

do -- a window showing another machine leaves the job for later
	local s, run = agent_run(true)
	s.win.host_kind = "remote"
	step(s, 3)
	eq(#s.win.started, 0, "not opened on a remote host")
	eq(s.env.tern.fs.exists(`{DATA}/runs/{run.id}/s1.claim`), false, "claim released")
	s.win.host_kind = "local"
	step(s, 2)
	eq(#s.win.started, 1, "opened once the window is local")
end

do -- an exit file caught mid-write is read again instead of failing the step
	local s, run = agent_run(true)
	step(s, 2)
	local exitf = `{DATA}/runs/{run.id}/s1.exit`
	s.env.files[exitf] = ""
	step(s, 1)
	eq(run.state, "running", "empty exit file: wait")
	s.env.files[exitf] = "0"
	step(s, 2)
	eq(run.state, "success")
	eq(run.steps[1].exit_code, 0)
end

do -- a cancel between the claim and the launch opens nothing
	local s, run = agent_run(true)
	local launcher = require("../lib/launcher")
	s.env.advance(1000) -- host publishes the job; the window has not looked yet
	launcher.tick(s.L, s.win.cx) -- claims (mkdir answer still queued)
	s.core.cancel(s.c, run.id)
	s.env.drain() -- mkdir answers: the job is already stopping
	eq(#s.win.started, 0, "no agent opened")
	step(s, 2)
	eq(run.state, "cancelled")
	eq(run.steps[1].exit_code, 143)
end

do -- an omp step that was running headless before the upgrade keeps the process path
	local s, run = agent_run(false)
	step(s, 1)
	-- Rewrite history as the old engine left it: a running omp step with wrapper pid files.
	run.steps[1].agent = nil
	local dir = `{DATA}/runs/{run.id}`
	s.env.files[`{dir}/s1.pid`] = "4242"
	s.env.files[`{dir}/s1.pid.w`] = "4241"
	s.env.files[`{dir}/s1.job.json`] = nil
	require("../lib/store").save(s.c.store)
	local s2 = scenario(table.clone(s.env.files), { alive = true })
	s2.now = s.now
	window(s2)
	s2.core.start(s2.c)
	step(s2, 3)
	local old = s2.c.store.by_id[run.id]
	eq(old.state, "running", "adopted")
	eq(#s2.env.kv.agent_jobs, 0, "not handed to the windows")
	eq(#s2.win.started, 0)
	s2.core.cancel(s2.c, run.id)
	step(s2, 2)
	local termed = false
	for _, p in s2.procs do
		if p.kind == "kill" and p.argv[6] == "4242" then
			termed = true
		end
	end
	truthy(termed, "cancel still signals the old process group")
	s2.env.files[`{dir}/s1.exit`] = "143\n" -- the old wrapper records its child's death
	step(s2, 2)
	eq(old.state, "cancelled")
end

print("ok")
