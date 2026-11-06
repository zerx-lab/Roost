--!strict
-- The console block on the fake tern: every page renders with unique sibling keys for realistic
-- state, page keys switch pages, the log of the selected run grows by appends, the manual-run
-- form collects inputs, and relay failures show the manual fallback.

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
local T0 = 1793880000

local WORKFLOWS = [==[
[repos."acme/web"]
path = "~/code/web"

[[workflow]]
id = "triage"
name = "Issue 分诊"
repos = ["acme/web"]
workspace = "temp"
[[workflow.input]]
name = "focus"
description = "关注点"
required = true
[[workflow.trigger]]
github = "issues"
actions = ["opened"]
[[workflow.trigger]]
cron = "0 9 * * 1-5"
[[workflow.step]]
name = "think"
omp = "Look at {{input.focus}}"

[[workflow]]
id = "plain"
workspace = "temp"
[[workflow.step]]
run = "echo plain"
]==]

local ROOST = '[relay]\nurl = "https://relay.test"\ntoken = "tok-0123456789abcdef"\n'

type World = { env: any, core: any, c: any, ui: any, st: any, cx: any, now: number }

local function world(files: { [string]: string }): World
	local env = F.new()
	harness.fresh(env)
	for k, v in files do
		env.files[k] = v
	end
	env.process = function(argv: { string }, _opts: any): any
		local script = argv[3] or ""
		if string.find(script, "set -m", 1, true) then
			env.files[argv[6]] = "4242"
			env.files[argv[5]] = (env.files[argv[5]] or "") .. "\27[32mstarted\27[0m\n"
			return false -- keeps running
		elseif argv[1] == "/bin/mkdir" then
			env.dirs[argv[2]] = true
			return { status = 0, stdout = "", stderr = "", timed_out = false }
		elseif string.find(script, "tail -c", 1, true) then
			local from = tonumber(argv[5]) :: number
			local text = env.files[argv[6]] or ""
			local limit = tonumber(argv[7]) :: number
			return { status = 0, stdout = string.sub(text, from, from + limit - 1), stderr = "", timed_out = false }
		end
		return env.append(argv) or { status = 0, stdout = "", stderr = "", timed_out = false }
	end
	env.fetch = function(_url: string, _o: any): any
		return { status = 0, headers = {}, body = "", error = "connection refused", timed_out = false }
	end
	local core = require("../lib/core")
	local w: World = { env = env, core = core, c = nil, ui = nil, st = nil, cx = nil, now = T0 }
	core.clock = function()
		return w.now
	end
	w.c = core.new(DATA)
	core.start(w.c)
	w.ui = require("../lib/ui")
	w.cx = env.cx(1)
	-- What host.luau does for the block.
	w.st = w.ui.new(w.c, w.cx, {}, nil)
	w.st.unsubscribe = core.subscribe(w.c, function()
		w.ui.refresh(w.st)
		w.cx:render()
	end)
	return w
end

local function view(w: World): any
	local v = w.ui.view(w.st)
	for _, region in { "main", "dock", "layer" } do
		if v[region] then
			F.check_keys(v[region])
		end
	end
	return v
end

local function press(w: World, name: string, text: string?, mods: { [string]: boolean }?): any
	local m: { [string]: boolean } = mods or {}
	return w.ui.key(w.st, { name = name, text = text, ctrl = m.ctrl == true, alt = m.alt == true, shift = m.shift == true, meta = m.meta == true })
end

local function step(w: World, seconds: number)
	for _ = 1, seconds do
		w.now += 1
		w.env.advance(1000)
	end
end

local function find(n: any, pred: (any) -> boolean): any
	local hit = nil
	F.walk(n, function(x)
		if hit == nil and pred(x) then
			hit = x
		end
	end)
	return hit
end

do -- the host block renders every page; keys switch pages
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = ROOST })
	step(w, 1)
	for i, id in { "overview", "runs", "workflows", "events", "relay", "config" } do
		eq(press(w, tostring(i)), if i == 1 then false else true, `key {i}`)
		eq(w.st.tab, id)
		local v = view(w)
		truthy(F.text(v.main) ~= "", `page {id} has content`)
	end
	eq(press(w, "x"), false, "unbound key changes nothing")
	-- The relay page shows the manual fallback while pushes fail.
	w.st.tab = "relay"
	local v = view(w)
	local code = find(v.main, function(x)
		return x.k == "code" and x.p and string.find(x.p.text or "", 'repos."acme/web"', 1, true) ~= nil
	end)
	truthy(code, "manual subscriptions.toml shown")
	truthy(string.find(code.p.text, 'events = ["issues"]', 1, true), "with the subscribed events")
	w.ui.event(w.st, { ev = "action", id = "main.body.relay.subs.manual.copy", act = "copy", value = "subs" })
	eq(w.cx.copied[1], code.p.text, "copy puts the same text on the clipboard")
end

do -- manual run with a required input goes through the form; the log tails by appends
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = "" })
	w.st.tab = "workflows"
	w.ui.event(w.st, { ev = "action", id = "main.body.workflows.triage.actions.run", act = "dispatch", value = "triage" })
	truthy(w.st.form, "form opened for a workflow with inputs")
	local v = view(w)
	truthy(v.layer and find(v.layer, function(x)
		return x.k == "overlay"
	end), "overlay in the layer")
	eq(w.cx.frames[#w.cx.frames][1][2], "layer.form.field1.input", "first field focused")
	press(w, "enter")
	truthy(w.st.form and w.st.form.error, "required input enforced")
	for _, ch in { "c", "r", "a", "s", "h" } do
		press(w, ch, ch)
	end
	press(w, "paste", " 首页\n")
	eq(w.st.form.fields[1].text, "crash 首页", "typed and pasted (newline dropped)")
	press(w, "enter")
	eq(w.st.form, nil, "form closed after submit")
	eq(w.st.tab, "runs", "switched to runs")
	local run = w.c.store.by_id[w.st.run_id]
	truthy(run, "new run selected")
	eq(run.inputs.focus, "crash 首页")
	step(w, 2)
	eq(run.state, "running")
	v = view(w)
	local ansi = find(v.main, function(x)
		return x.k == "ansi"
	end)
	truthy(ansi and string.find(ansi.p.text, "等待 Tern 窗口", 1, true), "log shown")
	local before = ansi.p.text
	local log = `{DATA}/runs/{run.id}/log.txt`
	w.env.files[log] = w.env.files[log] .. "more output\n"
	step(w, 2)
	v = view(w)
	ansi = find(v.main, function(x)
		return x.k == "ansi"
	end)
	eq(string.sub(ansi.p.text, 1, #before), before, "log grows by suffix (append frames)")
	truthy(string.find(ansi.p.text, "more output", 1, true), "new output appended")
	-- Cancel from the detail card.
	w.ui.event(w.st, { ev = "action", id = "main.body.runs.run.state.actions.cancel", act = "cancel", value = run.id })
	eq(run.stop, "cancel", "cancel requested")
end

do -- a queued run cancelled from the row menu; j/k move the selection
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = "" })
	w.core.dispatch(w.c, "plain")
	w.core.dispatch(w.c, "plain") -- queued behind the first (one run per workflow)
	local runs = w.c.store.runs
	eq(runs[2].state, "queued")
	w.st.tab = "runs"
	eq(press(w, "j"), true, "j selects the first row")
	eq(w.st.run_id, runs[2].id, "newest first")
	eq(press(w, "j"), true)
	eq(w.st.run_id, runs[1].id)
	eq(press(w, "j"), false, "already at the end")
	w.ui.event(w.st, { ev = "action", id = "main.body.runs.left.runs", act = "cancel", item = runs[2].id })
	eq(runs[2].state, "cancelled", "row menu cancel")
	view(w)
	w.ui.close(w.st)
	eq(w.st.closed, true)
end

do -- the sessions sidebar lists omp steps; its links show the live agent, then resume the saved one
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = "" })
	local win = w.env.window()
	w.env.wcx = win.cx
	local launcher = require("../lib/launcher")
	local L = launcher.new(DATA)
	local function tick(n: number)
		for _ = 1, n do
			step(w, 1)
			launcher.tick(L, win.cx)
			w.env.drain()
		end
	end
	local sidebar = require("../lib/sidebar")
	local cx = w.env.cx(2)
	local st = sidebar.new(w.c, cx, nil)
	eq(w.core.dispatch(w.c, "triage", { focus = "crash" }), nil)
	eq(w.core.dispatch(w.c, "plain"), nil)
	tick(2)
	local run = w.c.store.runs[1]
	local rows = sidebar.rows(w.c)
	eq(#rows, 1, "only omp steps are sessions")
	eq(rows[1].id, `{run.id}:1`)
	local v = sidebar.view(st)
	F.check_keys(v.main)
	local tbl = find(v.main, function(x)
		return x.k == "table"
	end)
	eq(tbl.p.rows[1].cells[2], "Issue 分诊 · think", "row names workflow and step")
	sidebar.event(st, { ev = "activate", id = "main.list", item = rows[1].id })
	local url = cx.opened[1]
	eq(url, `roost://session/{run.id}/1`)

	local pane = win.started[1].pane
	win.focused = 1
	eq(launcher.route(L, win.cx, url), true)
	eq(win.focused, pane, "a running session jumps to its agent")
	eq(win.shown, win.sessions[2].id, "in the Roost session")
	eq(win.sessions[2].name, "Roost")

	win.reply(pane, "ok")
	tick(3)
	eq(run.state, "success")
	launcher.route(L, win.cx, url)
	eq(win.toasts[1].text, "这一步没有保存的 omp 会话", "nothing to resume yet")
	local sdir = `{DATA}/runs/{run.id}/s1.session`
	w.env.files[`{sdir}/2026-11-06T01-00-00-000Z_b.jsonl`] = "{}\n"
	w.env.files[`{sdir}/2026-11-06T00-00-00-000Z_a.jsonl`] = "{}\n"
	w.env.files[`{sdir}/.2026-11-06T01-00-00-000Z_b.jsonl.lock.os`] = ""
	launcher.route(L, win.cx, url)
	local opened = win.opened[1]
	eq(opened.command, `omp --session-dir {sdir} --resume {sdir}/2026-11-06T01-00-00-000Z_b.jsonl`, "newest session resumed")
	eq(opened.cwd, "/home/test", "the temp workspace is gone: home instead")

	win.focused = 1
	eq(launcher.route(L, win.cx, "roost://sidebar"), true)
	eq(win.blocks[1].kind, "roost.sessions")
	eq(win.blocks[1].opts.dir, "left")
	eq(win.blocks[1].opts.target, 1, "beside the focused block")
	launcher.route(L, win.cx, "roost://sidebar")
	eq(win.closed[1], win.blocks[1].pane, "the same link closes this tab's sidebar")
	eq(launcher.route(L, win.cx, "https://example.com"), false, "other links pass through")

	-- Pruning a run removes its sessions with it.
	w.c.store.keep = 0
	require("../lib/store").prune(w.c.store)
	eq(w.env.tern.fs.exists(sdir), false, "session files pruned with the run")
	sidebar.close(st)
end

print("ok")
