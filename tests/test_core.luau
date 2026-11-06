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
local T0 = 1793880000 -- 2026-11-05T12:00:00Z, a Thursday; minute-aligned
-- The runner flows below act as the local gh; the App identity has its own scenarios.
local LOCAL = '[github]\nidentity = "local"\n'

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
	elseif string.find(script, "umask 077", 1, true) then
		p.kind = "token"
	elseif string.find(script, 'find "$1"', 1, true) then
		p.kind = "tally"
	elseif string.find(script, "UserShell", 1, true) then
		p.kind = "login"
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
	-- What the usage tally of an ended agent step prints ("COST TOKENS").
	tally: string,
	-- A fake Tern window running lib/launcher.luau, once `window(s)` attached one.
	win: any,
	L: any,
	-- What the login-shell capture prints (lib/loginenv.luau), or false while it hasn't answered.
	login: string | false,
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
		tally = "0.000000 0\n",
		win = nil :: any,
		L = nil :: any,
		login = if o.login ~= nil
			then o.login
			else "motd noise__ROOST_LOGIN_ENV__PATH=/login/bin:/usr/bin\0FROM_FISH=yes\0GITHUB_TOKEN=mine\0PWD=/x\0__ROOST_LOGIN_ENV__",
	}
	env.process = function(argv: { string }, popts: any): any
		local p = classify(argv)
		p.opts = popts
		if p.kind == "login" then
			-- Infrastructure, not one of the runner's processes: kept out of `procs`.
			if s.login == false then
				return false
			end
			return { status = 0, stdout = s.login, stderr = "/opt/homebrew/bin/fish", timed_out = false }
		end
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
			-- `tail -c +FROM PATH | head -c LIMIT`
			local from = tonumber(argv[5]) :: number
			local text = env.files[argv[6]] or ""
			local limit = tonumber(argv[7]) :: number
			return { status = 0, stdout = string.sub(text, from, from + limit - 1), stderr = "", timed_out = false }
		elseif p.kind == "mkdir" then
			-- Atomic like mkdir(1): fails when the directory exists.
			if env.tern.fs.exists(argv[2]) then
				return { status = 1, stdout = "", stderr = "File exists", timed_out = false }
			end
			env.dirs[argv[2]] = true
			return { status = 0, stdout = "", stderr = "", timed_out = false }
		elseif p.kind == "token" then
			-- `sh -c SAVE_TOKEN roost FILE SHIM SHIM_TEXT` with the token on stdin.
			env.files[argv[5]] = popts.stdin
			env.files[argv[6]] = argv[7]
			return { status = 0, stdout = "", stderr = "", timed_out = false }
		elseif p.kind == "tally" then
			return { status = 0, stdout = s.tally, stderr = "", timed_out = false }
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
schedule = "cron"
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
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_CRON, [DATA .. "/roost.toml"] = LOCAL })
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

local WF_SHELL = [==[
[[workflow]]
id = "sh"
workspace = "temp"
[[workflow.step]]
name = "say"
run = "echo hi"
]==]
local RUNNER_ENV = LOCAL .. '[runner]\nenv = { FROM_FISH = "roost" }\n'

do -- shell steps inherit the login shell's environment; runs start only once it has been read
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_SHELL, [DATA .. "/roost.toml"] = RUNNER_ENV }, {
		login = "fish greeting__ROOST_LOGIN_ENV__PATH=/login/bin\0FROM_FISH=yes\0ONLY_FISH=a=b\nc\0PWD=/x\0__ROOST_LOGIN_ENV__\nbye",
	})
	s.core.start(s.c)
	eq(s.core.dispatch(s.c, "sh"), nil)
	eq(last_run(s).state, "queued", "the run waits for the login environment")
	eq(#s.procs, 0, "nothing started before it")
	step(s, 2)
	local say = s.procs[1]
	eq(say.kind, "wrapper")
	local e = say.opts.env
	eq(e.ONLY_FISH, "a=b\nc", "login variables reach shell steps, values whole")
	eq(e.FROM_FISH, "roost", "[runner] env wins over the login shell")
	eq(e.PWD, nil, "the capturing shell's PWD is dropped")
	eq(string.find(e.PATH, "/home/test/.local/bin:", 1, true), 1, "extra_path first")
	eq(string.sub(e.PATH, -#":/login/bin"), ":/login/bin", "then the login shell's PATH")
	eq(last_run(s).state, "success")
end

do -- a failed capture is reported and runs go on with the daemon's environment
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_SHELL, [DATA .. "/roost.toml"] = RUNNER_ENV }, { login = "no marks" })
	s.core.start(s.c)
	eq(s.core.dispatch(s.c, "sh"), nil)
	step(s, 2)
	eq(last_run(s).state, "success", "the run still ran")
	eq(s.procs[1].opts.env.ONLY_FISH, nil)
	truthy(string.find(s.c.notices[1].text, "读取登录 shell 的环境变量失败", 1, true), "failure noticed: " .. s.c.notices[1].text)
end

local WF_SOLO = [==[
[[workflow]]
id = "solo"
workspace = "temp"
[[workflow.step]]
name = "think"
omp = "Do it"
]==]

do -- a working agent's session file is followed into the log; its final answer ends the step's lines
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_SOLO, [DATA .. "/roost.toml"] = LOCAL })
	local w = window(s)
	s.core.start(s.c)
	eq(s.core.dispatch(s.c, "solo"), nil)
	step(s, 2)
	local run = last_run(s)
	local dir = `{DATA}/runs/{run.id}`
	local pane = w.started[1].pane
	local sfile = `{dir}/s1.session/2026-11-06T04-00-00-000Z_x.jsonl`
	local call = '{"type":"message","message":{"role":"assistant","stopReason":"toolUse","content":['
		.. '{"type":"text","text":"先读任务"},{"type":"toolCall","name":"read","arguments":{"path":"TASK.md","i":"Reading the task"}}]}}\n'
	local fail = '{"type":"message","message":{"role":"toolResult","toolName":"bash","isError":true,"content":[{"type":"text","text":"boom\\nmore"}]}}\n'
	s.env.files[sfile] = '{"type":"session","id":"x"}\n' .. call .. string.sub(fail, 1, 20)
	step(s, 3)
	local log = s.env.files[`{dir}/log.txt`] or ""
	truthy(string.find(log, "agent 已在 Tern 标签页中运行(会话「Roost」)", 1, true), "opened tab logged")
	truthy(string.find(log, "先读任务", 1, true), "assistant text logged while it works")
	truthy(string.find(log, "› read  Reading the task", 1, true), "tool call logged by its intent")
	eq(string.find(log, "boom", 1, true), nil, "a half-written line waits")
	local final = '{"type":"message","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"全部完成"}]}}\n'
	s.env.files[sfile] ..= string.sub(fail, 21) .. final
	-- The window's transcript lags behind the session file: its reply is an older message.
	w.reply(pane, "先读任务")
	step(s, 6)
	eq(run.state, "success", "turn finished")
	log = s.env.files[`{dir}/log.txt`] or ""
	truthy(string.find(log, "✗ bash  boom", 1, true), "failed tool logged with its first line")
	local _, opened_n = string.gsub(log, "agent 已在 Tern 标签页中运行", "")
	eq(opened_n, 1, "opened line logged once")
	local _, read_n = string.gsub(log, "先读任务", "")
	eq(read_n, 1, "the stale reply is not appended again")
	local at_final = string.find(log, "全部完成", 1, true)
	local at_end = string.find(log, "agent 结束:完成", 1, true)
	truthy(at_final and at_end and at_final < at_end, "final answer before the outcome line")
	eq(run.steps[1].tail, #s.env.files[sfile], "whole session file consumed")
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
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TWO, [DATA .. "/roost.toml"] = LOCAL })
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
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TWO, [DATA .. "/roost.toml"] = LOCAL })
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
concurrency = "replace"
[[workflow.trigger]]
github = "comment"
repos = ["acme/web"]
comment = "/roost"
[[workflow.step]]
name = "work"
omp = "Fix #{{number}}: {{payload.comment.body}}"
]==]

do -- cancel while an agent works in a worktree: the window closes it, cleanup still runs
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TREE, [DATA .. "/roost.toml"] = LOCAL })
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

do -- a manual run works in the repo the workflow's schedule names, not a temp dir
	local wf = [==[
[repos."acme/web"]
path = "~/code/web"
branch = "main"

[repos."acme/api"]
path = "~/code/api"

[[workflow]]
id = "sync"
workspace = "worktree"
[[workflow.trigger]]
schedule = "daily"
time = "06:00"
repo = "acme/web"
[[workflow.step]]
run = "true"

[[workflow]]
id = "loose"
workspace = "worktree"
[[workflow.step]]
run = "true"
]==]
	local s = scenario({ [DATA .. "/workflows.toml"] = wf, [DATA .. "/roost.toml"] = LOCAL })
	s.core.start(s.c)
	eq(s.core.dispatch(s.c, "sync"), nil, "manual dispatch accepted")
	local run = last_run(s)
	eq(run.workspace, "worktree")
	eq(run.repo, "acme/web")
	eq(run.repo_path, "/home/test/code/web")
	eq(run.fetch_ref, "main")
	local err = s.core.dispatch(s.c, "loose")
	truthy(err and string.find(err, "无法确定用哪个仓库", 1, true), "worktree run without a repo is refused")
	eq(last_run(s).id, run.id, "nothing queued for the refused run")
end

do -- a PR workflow run by hand on one PR: gh reads it, the run sees it as a PR event on the PR head
	local wf = [==[
[repos."acme/web"]
path = "~/code/web"
branch = "main"

[[workflow]]
id = "review"
[[workflow.trigger]]
github = "pr_opened"
repos = ["acme/web", "acme/api"]
[[workflow.step]]
name = "看"
omp = "Review {{repo}}#{{number}} {{title}} ({{action}}) {{sha}} {{payload.pull_request.user.login}}"
]==]
	local s = scenario({ [DATA .. "/workflows.toml"] = wf, [DATA .. "/roost.toml"] = LOCAL })
	local w = window(s)
	local gh: { { string } } = {}
	local answer: (string, string) -> any = function(_repo, _n)
		return { status = 0, stdout = "", stderr = "", timed_out = false }
	end
	local base = s.env.process
	s.env.process = function(argv: { string }, popts: any): any
		if string.find(argv[3] or "", "gh api", 1, true) then
			table.insert(gh, argv)
			truthy(popts.timeout_ms, "gh has a deadline")
			return answer(argv[5], argv[6])
		end
		return base(argv, popts)
	end
	s.core.start(s.c)
	local PR = '{"number":7,"title":"Fix it","body":"b","html_url":"https://github.com/acme/web/pull/7",'
		.. '"user":{"login":"ann"},"base":{"ref":"main","repo":{"full_name":"acme/web","default_branch":"main"}},'
		.. '"head":{"sha":"abc","repo":{"full_name":"ann/web"}},"labels":[{"name":"bug"}],"draft":false}'
	answer = function(repo, n)
		eq(`{repo}#{n}`, "acme/web#7", "gh asked for the named PR")
		return { status = 0, stdout = PR, stderr = "", timed_out = false }
	end
	local got: { string | false } = {}
	local function done(err: string?)
		table.insert(got, err or false)
	end
	s.core.dispatch_pr(s.c, "review", nil, "7", done)
	truthy(got[1] and string.find(got[1] :: string, "不只一个仓库", 1, true), "a bare number needs the repo when the workflow has several")
	s.core.dispatch_pr(s.c, "review", nil, "acme/web#x", done)
	truthy(got[2] and string.find(got[2] :: string, "无法识别", 1, true), "not a PR reference")
	eq(#gh, 0, "gh not asked for a bad reference")
	s.core.dispatch_pr(s.c, "review", nil, "https://github.com/acme/web/pull/7/files", done, function()
		return false
	end)
	s.env.drain()
	eq(got[3], "已取消", "cancelled while gh ran")
	eq(#s.c.store.runs, 0, "a cancelled PR run queues nothing")
	s.core.dispatch_pr(s.c, "review", nil, "https://github.com/acme/web/pull/7/files", done)
	s.env.drain()
	eq(got[4], false, "queued")
	local run = last_run(s)
	eq(run.trigger.kind, "manual")
	eq(run.repo, "acme/web")
	eq(run.workspace, "worktree", "the declared checkout is used")
	eq(run.fetch_ref, "refs/pull/7/head", "the PR head is checked out")
	eq(run.event.from_fork, true, "fork head recorded")
	eq(run.title, "pull_request.manual #7 Fix it")
	step(s, 3)
	eq(#w.started, 1, "agent opened")
	eq(w.started[1].opts.prompt, "Review acme/web#7 Fix it (manual) abc ann", "templates see the PR")
	answer = function()
		return { status = 1, stdout = "", stderr = "HTTP 404: Not Found\nmore", timed_out = false }
	end
	s.core.dispatch_pr(s.c, "review", nil, "acme/web#8", done)
	s.env.drain()
	eq(got[5], "gh 读取 acme/web#8 失败:HTTP 404: Not Found", "gh's error surfaces")
end

do -- recovery: a step still alive after a reload keeps running; a dead one ends the run
	for _, alive in { true, false } do
		local s = scenario({ [DATA .. "/workflows.toml"] = WF_TWO, [DATA .. "/roost.toml"] = LOCAL }, { alive = alive })
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
[github]
identity = "local"
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
	local backfills: { string } = {}
	s.http = function(method, path, body)
		if method == "PUT" and path == "/api/v1/subscriptions" then
			pushed = body
			return 200, { revision = "r1", changed = true }
		elseif method == "GET" and string.find(path, "payload=false", 1, true) then
			-- First contact: the newest stored events, for display only.
			table.insert(backfills, path)
			local old = comment_event(9, "/roost old", "OWNER")
			old.payload = nil
			old.received_at = "2026-11-05T11:00:00Z"
			return 200, { store_id = "S", head = 10, oldest = 1, gap = false, events = { old } }
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
	eq(#backfills, 1, "stored events fetched once on first contact")
	truthy(string.find(backfills[1], "after=0", 1, true), "the newest few: " .. backfills[1])
	eq(#s.c.events, 1, "history row listed")
	eq(s.c.events[1].history, true)
	eq(s.c.events[1].at, T0 - 3600, "dated when the relay received it")
	eq(#s.c.events[1].runs, 0, "history never runs, even when it matches")
	eq(#s.c.store.runs, 0)

	queue = { comment_event(11, "/roost please", "MEMBER"), comment_event(12, "/roost x", "NONE") }
	s.behave = function(_p)
		return "exit:0"
	end
	step(s, 4)
	eq(s.env.kv.cursor.seq, 12, "cursor advanced")
	eq(#s.c.events, 3, "both events listed above the history row")
	local member, outsider = s.c.events[2], s.c.events[1]
	eq(#member.runs, 1, "member comment launched a run")
	truthy(outsider.reasons.fix and string.find(outsider.reasons.fix, "NONE", 1, true), "outsider rejected by association")
	local run = s.c.store.by_id[member.runs[1]]
	eq(run.fetch_ref, "refs/pull/7/head", "event ref checked out")
	step(s, 2)
	local job = F.decode(s.env.files[`{DATA}/runs/{run.id}/s2.job.json`])
	eq(job.prompt, "Fix #7: /roost please", "payload template rendered")

	-- A reload keeps the events page, and a redelivered event is still recognized.
	local s2 = scenario(table.clone(s.env.files))
	s2.env.kv.cursor = { url = "https://relay.test", store_id = "S", seq = 10 }
	s2.http = function(method, path, _body)
		if method == "GET" and string.sub(path, 1, 15) == "/api/v1/events?" then
			return 200, { store_id = "S", head = 12, oldest = 1, gap = false, events = { comment_event(11, "/roost please", "MEMBER") } }
		end
		return 200, { revision = "r1" }
	end
	s2.now = s.now
	s2.core.start(s2.c)
	eq(#s2.c.events, 3, "events.json restored")
	eq(s2.c.events[2].delivery, "d11")
	eq(s2.c.events[2].runs[1], member.runs[1], "with the runs they started")
	step(s2, 2)
	eq(#s2.c.events, 3, "a delivery already listed is not handled again")
	eq(#s2.c.store.runs, #s.c.store.runs, "and starts no second run")

	-- Even with the events page cleared, the run it started still marks the delivery as handled.
	s2.core.clear_events(s2.c)
	local s3 = scenario(table.clone(s2.env.files))
	s3.env.kv.cursor = { url = "https://relay.test", store_id = "S", seq = 10 }
	s3.http = s2.http
	s3.now = s2.now
	s3.core.start(s3.c)
	step(s3, 2)
	eq(#s3.c.store.runs, #s.c.store.runs, "a redelivery after clear + reload starts nothing")
end

do -- no events.json yet (an upgrade): events already read are listed once; newer ones still run
	local earlier = { id = "0e", workflow = "fix", workflow_name = "fix", title = "t", trigger = { kind = "github", detail = "", delivery = "d11" }, state = "success", created_at = T0 - 60, finished_at = T0 - 30, inputs = {}, steps = {}, step = 0 }
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TREE, [DATA .. "/roost.toml"] = ROOST, [DATA .. "/runs.json"] = F.encode({ earlier }) })
	s.env.kv.cursor = { url = "https://relay.test", store_id = "S", seq = 11 }
	local fetched = 0
	s.http = function(_method, path, _body)
		if string.find(path, "payload=false", 1, true) then
			fetched += 1
			return 200, { store_id = "S", head = 12, oldest = 1, gap = false, events = { comment_event(11, "/roost a", "OWNER"), comment_event(12, "/roost b", "OWNER") } }
		elseif string.sub(path, 1, 15) == "/api/v1/events?" then
			local evs = if string.find(path, "after=11", 1, true) then { comment_event(12, "/roost b", "OWNER") } else {}
			return 200, { store_id = "S", head = 12, oldest = 1, gap = false, events = evs }
		end
		return 200, { revision = "r" }
	end
	s.behave = function(_p)
		return "exit:0"
	end
	s.core.start(s.c)
	step(s, 3)
	eq(fetched, 1, "history looked up once")
	eq(#s.c.events, 2)
	local by: { [string]: any } = {}
	for _, e in s.c.events do
		by[e.delivery] = e
	end
	eq(by.d11.history, true, "the event already read is history")
	eq(by.d11.runs[1], "0e", "linked to the run it started before the upgrade")
	eq(#s.c.store.runs, 2, "but not run again")
	eq(by.d12.history, nil, "the one ahead of the cursor is handled live")
	eq(#by.d12.runs, 1, "and runs")
	truthy(s.env.files[DATA .. "/events.json"], "saved, so the next start won't look again")
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

do -- an unchanged push is confirmed against the relay's status; the button still pushes
	local model = require("../lib/model")
	local relay = require("../lib/relay")
	local wf = model.parse_workflows(WF_TREE)
	local fp = relay.fingerprint(model.subscriptions(assert(wf)))
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TREE, [DATA .. "/roost.toml"] = ROOST })
	s.env.kv.subs = { url = "https://relay.test", rev = "r1", fp = fp, at = T0 - 600 }
	local remote_rev = "r1"
	local puts: { any } = {}
	s.http = function(method, path, body)
		if method == "PUT" and path == "/api/v1/subscriptions" then
			table.insert(puts, body)
			return 200, { revision = remote_rev, changed = false }
		elseif path == "/api/v1/status" then
			return 200, { boot_id = "b1", subscriptions = { revision = remote_rev, repos = 1 } }
		end
		return 200, { store_id = "S", head = 0, oldest = 1, gap = false, events = {} }
	end
	s.core.start(s.c)
	step(s, 1)
	eq(#puts, 0, "nothing to push")
	eq(s.c.relay.state.sync.state, "ok", "the relay runs the pushed revision: in sync, not pending")
	eq(s.c.relay.state.sync.revision, "r1")
	eq(s.c.relay.state.sync.at, T0 - 600, "dated by the last push")

	s.core.push_subscriptions(s.c, false)
	step(s, 1)
	eq(#puts, 1, "an explicit push is sent even when unchanged")
	eq(puts[1].base_revision, "r1")
	eq(s.c.relay.state.sync.state, "ok")

	-- The relay's subscriptions change behind our back: no longer confirmed, pushed again.
	remote_rev = "hand"
	step(s, 21)
	eq(#puts, 2, "a different relay revision is pushed over")
end

do -- adopting the remote revision is reported as such, and survives a reload until local edits
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TREE, [DATA .. "/roost.toml"] = ROOST })
	s.env.kv.subs = { url = "https://relay.test", rev = "old", fp = "stale" }
	local puts = 0
	s.http = function(method, path, _body)
		if method == "PUT" and path == "/api/v1/subscriptions" then
			puts += 1
			return 409, { error = "conflict", revision = "hand", text = "[repos.\"x/y\"]\n" }
		elseif path == "/api/v1/status" then
			return 200, { boot_id = "b1", subscriptions = { revision = "hand", repos = 1 } }
		end
		return 200, { store_id = "S", head = 0, oldest = 1, gap = false, events = {} }
	end
	s.core.start(s.c)
	step(s, 1)
	eq(s.c.relay.state.sync.state, "conflict")
	s.core.adopt_remote(s.c)
	eq(s.c.relay.state.sync.state, "adopted", "kept the server copy, not shown as in sync")
	eq(s.env.kv.subs.rev, "hand")
	local before = puts
	step(s, 21)
	eq(puts, before, "no push while adopted")
	eq(s.c.relay.state.sync.state, "adopted")

	local s2 = scenario(table.clone(s.env.files))
	s2.env.kv.subs = s.env.kv.subs
	s2.http = s.http
	s2.core.start(s2.c)
	step(s2, 1)
	eq(s2.c.relay.state.sync.state, "adopted", "still adopted after a reload")
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
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_CRON, [DATA .. "/roost.toml"] = LOCAL })
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
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TWO, [DATA .. "/roost.toml"] = LOCAL })
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
	local s = scenario({ [DATA .. "/workflows.toml"] = long, [DATA .. "/roost.toml"] = LOCAL }, { alive = true })
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
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TREE, [DATA .. "/roost.toml"] = LOCAL })
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

do -- after a reload the first poll with a saved cursor returns at once, then long-polls resume
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TREE, [DATA .. "/roost.toml"] = ROOST })
	s.env.kv.cursor = { url = "https://relay.test", store_id = "S", seq = 5 }
	local waits: { string } = {}
	s.http = function(method, path, _body)
		if string.sub(path, 1, 15) == "/api/v1/events?" and not string.find(path, "payload=false", 1, true) then
			table.insert(waits, string.match(path, "wait=(%d+)") or "none")
			return 200, { store_id = "S", head = 5, oldest = 1, gap = false, events = {} }
		elseif method == "PUT" then
			return 200, { revision = "r" }
		end
		return 200, { boot_id = "b1", version = "0.1.0" }
	end
	s.core.start(s.c)
	step(s, 5)
	eq(waits[1], "0", "disconnected poll does not block, so the panel shows the connection at once")
	truthy(s.c.relay.state.connected, "connected after the first poll")
	eq(waits[2], "25", "connected polls long-poll again")
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
	local edited = string.gsub(string.gsub(WF_TREE, 'github = "comment"', 'github = "issue_opened"'), '\ncomment = "/roost"', "")
	s.env.files[DATA .. "/workflows.toml"] = edited
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
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_AGENT, [DATA .. "/roost.toml"] = LOCAL })
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

local WF_ONCE = [==[
[[workflow]]
id = "once"
workspace = "temp"
[[workflow.trigger]]
schedule = "once"
at = "2026-11-05 12:03"
tz = "UTC"
[[workflow.step]]
run = "echo once"
]==]

do -- a once schedule fires at its minute and never again
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_ONCE, [DATA .. "/roost.toml"] = LOCAL })
	s.core.start(s.c)
	eq(s.c.crons[1].next, T0 + 180, "next fire is the set time")
	step(s, 179)
	eq(#s.c.store.runs, 0, "nothing before the minute")
	step(s, 3)
	eq(#s.c.store.runs, 1, "fired at 12:03")
	step(s, 600)
	eq(#s.c.store.runs, 1, "once means once")
	eq(s.c.crons[1].next, nil, "a past once has no next fire")
end

do -- the editor's save path: validates, writes with a backup, reloads; delete removes the block
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TWO, [DATA .. "/roost.toml"] = LOCAL })
	s.core.start(s.c)
	local raw = s.core.workflow_raw(s.c, "w") :: { [string]: any }
	raw.name = "改名"
	raw.trigger = { { github = "pr_opened" } }
	local issues = s.core.check_workflow(s.c, "w", raw)
	eq(#issues, 1, "only this workflow's problem")
	truthy(string.find(issues[1].message, "至少添加一个筛选器", 1, true), issues[1].message)
	eq(#(s.core.save_workflow(s.c, "w", raw) or {}), 1, "invalid edit refused")
	eq(s.env.files[DATA .. "/workflows.toml"], WF_TWO, "file untouched")
	raw.trigger[1].repos = { "acme/web" }
	eq(s.core.save_workflow(s.c, "w", raw), nil, "valid edit saved")
	eq(s.env.files[DATA .. "/workflows.toml.bak"], WF_TWO, "previous file kept")
	eq((s.c.workflows :: any).by_id.w.name, "改名", "reloaded at once")
	eq((s.c.workflows :: any).by_id.w.timeout, 10, "keys the edit didn't touch survive")
	eq(s.core.save_workflow(s.c, nil, { name = "Nightly Build", step = { { run = "true" } } }), nil)
	truthy((s.c.workflows :: any).by_id["nightly-build"], "new workflow id from its name")
	eq(s.core.delete_workflow(s.c, "w"), nil)
	eq((s.c.workflows :: any).by_id.w, nil, "deleted")
	eq(#(s.c.workflows :: any).list, 1)

	-- An unreadable file is never treated as empty: saving would drop every other workflow.
	local huge = (s.env.files[DATA .. "/workflows.toml"] :: string) .. "\n#" .. string.rep("x", 1024 * 1024)
	s.env.files[DATA .. "/workflows.toml"] = huge
	local refused = s.core.save_workflow(s.c, nil, { name = "x", step = { { run = "true" } } }) :: { any }
	truthy(refused and string.find(refused[1].message, "无法读取", 1, true), "save refused")
	eq(s.env.files[DATA .. "/workflows.toml"], huge, "file untouched")
	truthy(s.core.delete_workflow(s.c, "nightly-build"), "delete refused too")
end

do -- runtime checks: a past once time; @me without a known login once the relay status is in
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_TWO, [DATA .. "/roost.toml"] = ROOST })
	s.http = function(_method, path)
		if path == "/api/v1/status" then
			return 200, { boot_id = "b", github = { app = { slug = "r", owner = "acme", owner_type = "Organization" } } }
		end
		return 200, { store_id = "S", head = 0, events = {} }
	end
	s.core.start(s.c)
	step(s, 1)
	local raw: { [string]: any } = { name = "x", step = { { run = "true" } }, trigger = {
		{ schedule = "once", at = "2020-01-01 09:00" } :: any,
		{ github = "comment", authors = { "@me" } },
	} }
	local msgs: { string } = {}
	for _, i in s.core.check_workflow(s.c, nil, raw) do
		table.insert(msgs, i.message)
	end
	local all = table.concat(msgs, "\n")
	truthy(string.find(all, "已经过去", 1, true), all)
	truthy(string.find(all, "[github] login", 1, true), "org App: @me unknown\n" .. all)
end

do -- any repo can trigger (undeclared ones run in a temp dir); @me is roost.toml's [github] login
	local wf = table.concat({
		"[[workflow]]",
		'id = "mine"',
		"[[workflow.trigger]]",
		'github = "comment"',
		'repos = ["other/*"]',
		'authors = ["@me"]',
		"[[workflow.step]]",
		'run = "true"',
	}, "\n")
	local s = scenario({ [DATA .. "/workflows.toml"] = wf, [DATA .. "/roost.toml"] = '[github]\nlogin = "zero"\nidentity = "local"\n' })
	s.core.start(s.c)
	local function event(seq: number, sender: string): any
		local info = { event = "issue_comment", action = "created", repo = "other/x", sender = sender, author = sender, association = "OWNER" }
		return { seq = seq, delivery = `d{seq}`, info = info }
	end
	s.core.on_events(s.c, { event(1, "Zero"), event(2, "someone") })
	eq(#s.c.events[2].runs, 1, "my own comment fires because I named myself")
	truthy(string.find(s.c.events[1].reasons.mine or "", "作者", 1, true), "others filtered by author")
	step(s, 2)
	local run = s.c.store.by_id[s.c.events[2].runs[1]]
	eq(run.repo, "other/x")
	eq(run.workspace, "temp", "no local checkout: temporary directory")
	step(s, 2)
	local done = s.env.kv.status.done
	eq(done[1].id, run.id, "finished run published for the notification toast")
	eq(done[1].state, "success")
end

do -- retention: finished runs past the age go with their directories, orphans too; manual cleanup
	local DAY = 86400
	local function rec(id: string, state: string, finished: number?): any
		return { id = id, workflow = "solo", workflow_name = "solo", title = id, trigger = { kind = "manual", detail = "" }, state = state, created_at = (finished or T0) - 60, finished_at = finished, inputs = {}, steps = {}, step = 0 }
	end
	local runs = { rec("0a", "success", T0 - 3 * DAY), rec("0b", "failed", T0 - 3600), rec("0c", "success", T0 - 60) }
	local files: { [string]: string } = {
		[DATA .. "/workflows.toml"] = WF_SOLO,
		[DATA .. "/roost.toml"] = '[retention]\nrun_age = "2d"\nevents = 10\nevent_age = "1d"\n',
		[DATA .. "/runs.json"] = F.encode(runs),
		[DATA .. "/events.json"] = F.encode({
			{ seq = 2, delivery = "new", at = T0 - 60, event = "push", summary = "push", runs = {}, reasons = {} },
			{ seq = 1, delivery = "old", at = T0 - 2 * DAY, event = "push", summary = "push", runs = {}, reasons = {} },
		}),
	}
	for _, id in { "0a", "0b", "0c", "dead" } do
		files[`{DATA}/runs/{id}/log.txt`] = "log"
	end
	files[`{DATA}/runs/0a/s1.session/x.jsonl`] = "{}"
	files[`{DATA}/worktrees/0b/README`] = "leftover"
	local s = scenario(files)
	s.core.start(s.c)
	eq(s.c.store.by_id["0a"], nil, "finished past run_age: dropped")
	truthy(s.c.store.by_id["0b"] and s.c.store.by_id["0c"], "recent runs kept")
	eq(#s.c.events, 1, "event past event_age dropped")
	eq(s.c.events[1].delivery, "new")
	eq(s.c.cleanup.runs, 1)
	eq(s.c.cleanup.events, 1)
	eq(s.c.cleanup.orphans, 2, "an unknown run directory and a finished run's worktree")
	step(s, 1)
	eq(s.env.tern.fs.exists(`{DATA}/runs/0a`), false, "its log and omp sessions deleted")
	eq(s.env.tern.fs.exists(`{DATA}/runs/dead`), false, "orphan directory deleted")
	eq(s.env.tern.fs.exists(`{DATA}/worktrees/0b`), false, "leftover worktree deleted")
	eq(s.env.tern.fs.exists(`{DATA}/runs/0b/log.txt`), true, "kept runs keep their files")
	eq(#F.decode(s.env.files[DATA .. "/runs.json"]), 2, "runs.json saved without it")
	eq(#F.decode(s.env.files[DATA .. "/events.json"]), 1, "events.json saved without it")

	-- Manual: one run, then every finished one; active runs refuse.
	eq(s.core.delete_run(s.c, "0b"), nil)
	eq(s.c.store.by_id["0b"], nil)
	step(s, 1)
	eq(s.env.tern.fs.exists(`{DATA}/runs/0b`), false, "deleted run's directory gone")
	local busy = rec("0d", "running", nil)
	require("../lib/store").add(s.c.store, busy)
	truthy(s.core.delete_run(s.c, "0d"), "a running run can't be deleted")
	eq(s.core.clear_runs(s.c), 1, "only the finished one")
	eq(#s.c.store.runs, 1)
	eq(s.c.store.runs[1].id, "0d", "the running run stays")
	eq(s.core.clear_events(s.c), 1)
	eq(#F.decode(s.env.files[DATA .. "/events.json"]), 0, "events.json emptied")
end

do -- roost.toml [retention]: defaults, bounds, and ages too short to be meant
	local model = require("../lib/model")
	local cfg = model.parse_config("") :: any
	eq(cfg.retention.runs, 200)
	eq(cfg.retention.run_age, 30 * 86400)
	eq(cfg.retention.events, 200)
	local off = model.parse_config('[retention]\nrun_age = "0"\nevent_age = "7d"\n') :: any
	eq(off.retention.run_age, 0, '"0" keeps runs regardless of age')
	eq(off.retention.event_age, 7 * 86400)
	local bad, issues = model.parse_config('[retention]\nrun_age = "30"\n')
	eq(bad, nil, "30 seconds is rejected")
	eq(issues[1].path, "retention.run_age")
	local _, moved = model.parse_config("[runner]\nkeep_runs = 50\n")
	eq(moved[1].path, "runner.keep_runs", "keep_runs is no longer a runner key")
	truthy(string.find(moved[1].message, "[retention] runs", 1, true), "and the error says where it went")
end

do -- with no valid roost.toml yet, nothing is cleaned under the default policy
	local DAY = 86400
	local old = { id = "0a", workflow = "solo", workflow_name = "solo", title = "t", trigger = { kind = "manual", detail = "" }, state = "success", created_at = T0 - 90 * DAY, finished_at = T0 - 90 * DAY, inputs = {}, steps = {}, step = 0 }
	local s = scenario({
		[DATA .. "/workflows.toml"] = WF_SOLO,
		[DATA .. "/roost.toml"] = "[runner]\nkeep_runs = 500\n",
		[DATA .. "/runs.json"] = F.encode({ old }),
		[DATA .. "/runs/0a/log.txt"] = "old",
	})
	s.core.start(s.c)
	step(s, 1)
	truthy(s.c.store.by_id["0a"], "a 90-day-old run survives while roost.toml is invalid")
	s.core.housekeep(s.c, true)
	truthy(string.find(s.c.notices[1].text, "保留策略还没有生效", 1, true), "manual cleanup refuses and says why")
	s.env.files[DATA .. "/roost.toml"] = '[retention]\nrun_age = "30d"\n'
	step(s, 4)
	eq(s.c.store.by_id["0a"], nil, "once roost.toml is valid its policy applies at once")
	step(s, 1)
	eq(s.env.tern.fs.exists(`{DATA}/runs/0a`), false, "files included")
end

do -- an unreadable runs.json never makes every run directory look orphaned
	local s = scenario({
		[DATA .. "/workflows.toml"] = WF_SOLO,
		[DATA .. "/roost.toml"] = LOCAL,
		[DATA .. "/runs.json"] = "{not json",
		[DATA .. "/runs/0a/log.txt"] = "precious",
	})
	s.core.start(s.c)
	step(s, 1)
	eq(s.c.cleanup.orphans, 0, "nothing queued")
	eq(s.env.files[DATA .. "/runs/0a/log.txt"], "precious", "the old run's files stay")
	truthy(s.env.files[DATA .. "/runs.json.unreadable"], "the bad index kept aside")
	-- Still off on the next start, though a save has written a fresh runs.json by then.
	s.env.files[DATA .. "/runs.json"] = "[]"
	local s2 = scenario(table.clone(s.env.files))
	s2.core.start(s2.c)
	step(s2, 1)
	eq(s2.env.files[DATA .. "/runs/0a/log.txt"], "precious", "kept while runs.json.unreadable exists")
end

-- ---------------------------------------------------------------------------------------------
-- Acting as the GitHub App (roost.toml [github] identity defaults to "app")

local ROOST_APP = '[relay]\nurl = "https://relay.test"\ntoken = "tok-0123456789abcdef"\n'

local WF_APP = [==[
[repos."acme/web"]
path = "~/code/web"
branch = "main"

# A second declared repo: a workflow whose triggers name none runs without one.
[repos."acme/api"]
path = "~/code/api"

[[workflow]]
id = "ship"
[[workflow.trigger]]
github = "comment"
repos = ["acme/web"]
comment = "/roost"
[[workflow.step]]
name = "comment"
run = "gh pr comment 1 --body hi"
[[workflow.step]]
name = "work"
omp = "Push the fix"

[[workflow]]
id = "mine"
identity = "local"
[[workflow.trigger]]
github = "comment"
repos = ["acme/web"]
comment = "/roost"
[[workflow.step]]
run = "true"

[[workflow]]
id = "loose"
workspace = "temp"
[[workflow.step]]
run = "true"
]==]

local APP_TOKEN = {
	token = "run-tok",
	expires_in = 3600,
	login = "roost-x[bot]",
	email = "9+roost-x[bot]@users.noreply.github.com",
	branch = "main",
	protection = "created",
	permissions = { contents = "write", issues = "write" },
}

-- A relay that hands out App tokens through `answer`; returns the token requests' bodies.
local function app_relay(s: Scenario, answer: (any) -> (number, any)): { any }
	local asked: { any } = {}
	s.http = function(method, path, body)
		if method == "POST" and path == "/api/v1/github/token" then
			table.insert(asked, body)
			return answer(body)
		elseif method == "PUT" and path == "/api/v1/subscriptions" then
			return 200, { revision = "r1", changed = true }
		elseif method == "GET" and string.sub(path, 1, 15) == "/api/v1/events?" then
			return 200, { store_id = "S", head = 0, oldest = 1, gap = false, events = {} }
		elseif path == "/api/v1/status" then
			return 200, { boot_id = "b1", version = "0.1.0" }
		end
		return 404, { error = "nope" }
	end
	return asked
end

local function wrapper_for(s: Scenario, step_no: number): Proc?
	for _, p in s.procs do
		if p.kind == "wrapper" and p.step == step_no then
			return p
		end
	end
	return nil
end

do -- a run as the App: token first, gh/git as the bot in shell and omp steps, the token gone after
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_APP, [DATA .. "/roost.toml"] = ROOST_APP })
	local asked = app_relay(s, function(_b)
		return 200, APP_TOKEN
	end)
	local w = window(s)
	s.core.start(s.c)
	step(s, 1)
	eq(s.core.dispatch(s.c, "ship"), nil)
	step(s, 6)
	local run = last_run(s)
	eq(run.identity, "app")
	eq(run.steps[1].kind, "auth")
	eq(run.steps[1].state, "success", "token step done")
	eq(run.steps[2].kind, "prepare", "then the worktree")
	eq(#asked, 1)
	eq(asked[1].repo, "acme/web", "a token for the run's repository")
	local tokf = `{DATA}/runs/{run.id}/app-token`
	eq(s.env.files[tokf], "run-tok", "token saved for the steps")
	for _, p in s.procs do
		if p.kind == "token" then
			eq(p.opts.stdin, "run-tok", "the token goes in on stdin")
			truthy(not table.find(p.argv, "run-tok"), "never on a command line")
		end
	end
	truthy(string.find(s.env.files[DATA .. "/bin/gh"] or "", "ROOST_GH_TOKEN_FILE", 1, true), "gh shim installed")
	eq(run.app.login, "roost-x[bot]")

	local prep = wrapper_for(s, 2) :: Proc
	eq(prep.opts.env.GH_TOKEN, nil, "the worktree is prepared with your own git")
	local e = (wrapper_for(s, 3) :: Proc).opts.env
	eq(e.GH_TOKEN, "run-tok")
	eq(e.ROOST_GH_TOKEN_FILE, tokf)
	eq(e.GITHUB_TOKEN, nil, "the login shell's GitHub token stays out of App runs")
	eq(prep.opts.env.GITHUB_TOKEN, "mine", "while your own steps keep it")
	eq(string.sub(e.PATH, 1, #DATA + 5), DATA .. "/bin:", "the gh shim comes first on PATH")
	eq(e.GIT_CONFIG_COUNT, "4")
	eq(e.GIT_CONFIG_KEY_0, "credential.https://github.com.helper")
	eq(e.GIT_CONFIG_VALUE_0, "", "your own credential helpers are dropped for github.com")
	eq(e.GIT_CONFIG_VALUE_2, "git@github.com:", "ssh remotes go over https")
	eq(e.GIT_AUTHOR_NAME, "roost-x[bot]")
	eq(e.GIT_COMMITTER_EMAIL, APP_TOKEN.email)

	eq(#w.started, 1, "omp step opened")
	local cmd: string = w.started[1].opts.command
	eq(string.find(cmd, "/bin/sh -c", 1, true), 1, cmd)
	local envf = `{DATA}/runs/{run.id}/s4.env`
	truthy(string.find(cmd, envf, 1, true), "omp sources the step's identity file: " .. cmd)
	local script = s.env.files[envf] or ""
	truthy(string.find(script, "export GIT_AUTHOR_NAME='roost-x[bot]'", 1, true), script)
	truthy(not string.find(script, "run-tok", 1, true), "the token stays out of the env file")
	truthy(string.find(script, "unset GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN\n", 1, true), "Tern's own GitHub tokens are unset: " .. script)
	local log = s.env.files[`{DATA}/runs/{run.id}/log.txt`] or ""
	truthy(string.find(log, "以 GitHub App roost-x[bot] 的身份操作 acme/web", 1, true), log)
	truthy(string.find(log, "默认分支 main 禁止强推与删除", 1, true), log)

	eq(s.core.cancel(s.c, run.id), nil)
	step(s, 4)
	eq(run.state, "cancelled")
	eq(s.env.files[tokf], nil, "token removed when the run ends")

	-- identity = "local" in the workflow, and a run with no repository: no token, your own gh.
	eq(s.core.dispatch(s.c, "mine"), nil)
	eq(s.core.dispatch(s.c, "loose"), nil)
	step(s, 4)
	eq(#asked, 1, "no further token asked for")
	for _, r in s.c.store.runs do
		if r.workflow == "mine" or r.workflow == "loose" then
			eq(r.identity, nil, r.workflow)
			truthy(r.steps[1].kind ~= "auth", r.workflow)
		end
	end
	local loose = last_run(s)
	eq(loose.workflow, "loose")
	truthy(string.find(s.env.files[`{DATA}/runs/{loose.id}/log.txt`] or "", "没有关联仓库", 1, true), "says it runs as you")
end

do -- no token, no steps: a repository whose default branch the relay can't guard stops the run
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_APP, [DATA .. "/roost.toml"] = ROOST_APP })
	app_relay(s, function(_b)
		return 409, { error = "acme/web 的默认分支 main 仍可被强推或删除" }
	end)
	s.core.start(s.c)
	step(s, 1)
	eq(s.core.dispatch(s.c, "ship"), nil)
	step(s, 5)
	local run = last_run(s)
	eq(run.state, "failed")
	truthy(string.find(run.reason or "", "仍可被强推", 1, true), run.reason or "no reason")
	eq(run.steps[2].state, "skipped", "no worktree")
	eq(run.steps[3].state, "skipped", "no user step")
	eq(wrapper_for(s, 3), nil, "the shell step never started")
	eq(s.env.files[`{DATA}/runs/{run.id}/app-token`], nil)
end

do -- an App run whose token is gone fails its steps instead of running them as you
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_APP, [DATA .. "/roost.toml"] = ROOST_APP })
	app_relay(s, function(_b)
		return 200, APP_TOKEN
	end)
	s.behave = function(p)
		return if p.step == 2 then "hang" else "exit:0"
	end
	s.core.start(s.c)
	step(s, 1)
	eq(s.core.dispatch(s.c, "ship"), nil)
	step(s, 4)
	local run = last_run(s)
	eq(run.step, 2, "preparing the worktree")
	local d = `{DATA}/runs/{run.id}`
	s.env.files[d .. "/app-token"] = nil
	s.env.files[d .. "/s2.exit"] = "0\n"
	step(s, 3)
	local shell = wrapper_for(s, 3) :: Proc
	truthy(string.find(shell.cmd[3] or "", "没有可用的 App 令牌", 1, true), "the step refuses: " .. tostring(shell.cmd[3]))
	eq(shell.opts.env.GH_TOKEN, nil, "and gets no token")
end

do -- the token is renewed shortly before it expires, while the run lasts
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_APP, [DATA .. "/roost.toml"] = ROOST_APP })
	local n = 0
	local asked = app_relay(s, function(_b)
		n += 1
		local t = table.clone(APP_TOKEN)
		t.token = `tok-{n}`
		t.expires_in = if n == 1 then 905 else 3600
		return 200, t
	end)
	s.behave = function(p)
		return if p.step == 3 then "hang" else "exit:0"
	end
	s.core.start(s.c)
	step(s, 1)
	eq(s.core.dispatch(s.c, "ship"), nil)
	step(s, 4)
	local run = last_run(s)
	eq(#asked, 1)
	step(s, 10)
	eq(#asked, 2, "renewed once inside the margin")
	eq(s.env.files[`{DATA}/runs/{run.id}/app-token`], "tok-2", "steps read the new token")
	truthy(run.app.expires >= s.now + 3000, "and its expiry moved")
	truthy(string.find(s.env.files[`{DATA}/runs/{run.id}/log.txt`] or "", "App 令牌已续期", 1, true), "renewal logged")
	eq(s.core.cancel(s.c, run.id), nil)
	step(s, 4)
	eq(run.state, "cancelled")
end

local WF_FLOW = [==[
[[workflow]]
id = "flow"
workspace = "temp"
[[workflow.step]]
name = "scan"
run = "scan"
[[workflow.step]]
name = "verify"
when = "out.verify"
run = "verify"
[[workflow.step]]
name = "idle"
when = "!out.count"
run = "idle"
[[workflow.step]]
name = "apply"
run = "apply"
[[workflow.step]]
name = "after"
run = "after"
]==]

do -- step outputs: later steps see them, `when` skips a step, `stop` ends the run as skipped
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_FLOW, [DATA .. "/roost.toml"] = LOCAL })
	local seen: { [string]: any } = {}
	s.behave = function(p)
		local env = p.opts.env
		seen[p.cmd[3]] = env
		if p.cmd[3] == "scan" then
			s.env.files[env.ROOST_OUTPUT] = "count=3\nverify=yes\nbad key=x\n_ok=1\r\n"
		elseif p.cmd[3] == "apply" then
			s.env.files[env.ROOST_OUTPUT] = "stop=没有更多 issue\n"
		end
		return "exit:0"
	end
	s.core.start(s.c)
	eq(s.core.dispatch(s.c, "flow"), nil)
	step(s, 10)
	local run = last_run(s)
	eq(seen.scan.ROOST_OUTPUT, `{DATA}/runs/{run.id}/s1.out`, "each shell step gets its own output file")
	eq(seen.verify.ROOST_OUT_COUNT, "3", "outputs reach later steps as ROOST_OUT_*")
	eq(seen.idle, nil, "a false `when` never starts the step")
	eq(run.steps[3].state, "skipped")
	eq(run.steps[2].state, "success", "a true `when` runs it")
	eq(run.steps[4].state, "success")
	eq(seen.after, nil, "stop ends the run after its step")
	eq(run.steps[5].state, "skipped")
	eq(run.state, "skipped", "a stopped run counts as skipped")
	eq(run.reason, "没有更多 issue")
	eq(run.outputs.count, "3")
	eq(run.outputs._ok, "1", "a trailing CR is dropped")
	eq(run.outputs["bad key"], nil, "malformed names are ignored")
	local done = (s.env.kv.status or {}).done or {}
	eq(#done, 0, "a skipped run raises no toast")
end

local WF_BUDGET = [==[
[[workflow]]
id = "spend"
workspace = "temp"
daily_budget = 0.2
[[workflow.step]]
name = "count"
run = "count"
[[workflow.step]]
name = "think"
omp = "处理 {{out.n}} 条"
]==]

do -- an agent step's cost is read from its session files; the daily budget holds back omp steps
	local s = scenario({ [DATA .. "/workflows.toml"] = WF_BUDGET, [DATA .. "/roost.toml"] = LOCAL })
	local w = window(s)
	s.behave = function(p)
		s.env.files[p.opts.env.ROOST_OUTPUT] = "n=7\n"
		return "exit:0"
	end
	s.tally = "0.250000 1200\n"
	s.core.start(s.c)
	eq(s.core.dispatch(s.c, "spend"), nil)
	step(s, 3)
	eq(#w.started, 1)
	eq(w.started[1].opts.prompt, "处理 7 条", "outputs render in prompts")
	w.reply(w.started[1].pane, "完成")
	step(s, 6)
	local first = last_run(s)
	eq(first.state, "success")
	eq(first.steps[2].cost, 0.25, "cost from the tally")
	eq(first.steps[2].tokens, 1200)
	truthy(string.find(s.env.files[`{DATA}/runs/{first.id}/log.txt`] or "", "约 $0.2500,1200 tokens", 1, true), "cost logged")

	eq(s.core.dispatch(s.c, "spend"), nil)
	step(s, 6)
	local second = last_run(s)
	eq(#w.started, 1, "over budget: no second agent")
	eq(second.steps[1].state, "success", "shell steps still run")
	eq(second.steps[2].state, "skipped")
	eq(second.state, "skipped")
	truthy(string.find(second.reason or "", "已达预算 $0.20", 1, true), tostring(second.reason))

	-- A new local day starts with a fresh budget.
	s.now = require("../lib/stats").day_start(s.now) + 86400 + 3600
	eq(s.core.dispatch(s.c, "spend"), nil)
	step(s, 3)
	eq(#w.started, 2, "the next day the omp step runs again")
end

print("ok")
