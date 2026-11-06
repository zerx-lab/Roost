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
workspace = "temp"
[[workflow.input]]
name = "focus"
description = "关注点"
required = true
[[workflow.trigger]]
github = "issue_opened"
repos = ["acme/web"]
[[workflow.trigger]]
schedule = "cron"
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

local ROOST = '[relay]\nurl = "https://relay.test"\ntoken = "tok-0123456789abcdef"\n[github]\nidentity = "local"\n'
local LOCAL = '[github]\nidentity = "local"\n'

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
	for i, id in { "overview", "runs", "workflows", "events", "relay", "config", "files" } do
		eq(press(w, tostring(i)), if i == 1 then false else true, `key {i}`)
		eq(w.st.tab, id)
		local v = view(w)
		truthy(F.text(v.main) ~= "", `page {id} has content`)
	end
	w.st.tab = "workflows"
	local page = view(w)
	truthy(string.find(F.text(page.main), "新建自动化", 1, true), "new automation button")
	-- One card per workflow, keyed by id; the first is picked until another is.
	local function cards(v: any): { [string]: any }
		local out = {}
		F.walk(v.main, function(x)
			if x.k == "card" and x.p and x.p.role == "roost.workflow" then
				out[x.p.key] = x
			end
		end)
		return out
	end
	local by = cards(page)
	truthy(by.triage and by.plain, "a card per workflow")
	eq(by.triage.p.selected, false, "no card is picked until the user picks one")
	eq(by.plain.p.selected, false)
	eq(press(w, "r"), false, "r runs nothing without a pick")
	-- The head's controls are named by id: `end` must be the card's own child keyed "end".
	eq(by.triage.p["end"], "main.body.workflows.cards.triage.end")
	truthy(find(by.triage, function(x)
		return x.p and x.p.key == "end" and x.k == "row"
	end), "the card holds its end row")
	local info = find(by.triage, function(x)
		return x.k == "kv"
	end)
	local first = info.p.items[1]
	truthy(string.find(F.text({ k = "text", p = { spans = first[2] or first.v } }), "Issue 已打开", 1, true), "trigger line uses the kind label")
	eq(press(w, "j"), true, "j picks the first card")
	eq(cards(view(w)).triage.p.selected, true)
	eq(press(w, "j"), true, "then the next")
	eq(cards(view(w)).plain.p.selected, true)
	eq(press(w, "j"), false, "already the last")
	eq(press(w, "escape"), true, "escape clears the pick")
	eq(cards(view(w)).plain.p.selected, false)
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
	local relay_text = F.text(v.main)
	truthy(string.find(relay_text, "GitHub App", 1, true), "GitHub App card")
	eq(string.find(relay_text, "GitHub Webhook", 1, true), nil, "webhook card is gone")
	truthy(string.find(relay_text, "中继未连接", 1, true), "disconnected relay explains itself")
end

do -- manual run with a required input goes through the form; the log tails by appends
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL })
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
	-- Unwrapped, the terminal's frame is as wide as the widest line so far, measured across appends.
	local function width(): string?
		local frame = find(view(w).main, function(x)
			return x.k == "col" and x.p ~= nil and x.p.key == "term"
		end)
		return frame.p.min and frame.p.min.w
	end
	eq(width(), nil, "wraps by default")
	w.ui.event(w.st, { ev = "action", id = "main.body.runs.run.tools.wrap", act = "log-wrap" })
	local first = width()
	truthy(first and tonumber(string.match(first, "^(%d+)ch$")), "min width in cells")
	w.env.files[log] ..= "\27[2m" .. string.rep("宽", 60) .. "\27[0m\n"
	step(w, 2)
	eq(width(), "122ch", "a wider appended line widens it (60 wide characters + 2)")
	w.env.files[log] ..= "short\n"
	step(w, 2)
	eq(width(), "122ch", "a shorter line keeps the widest")
	eq(w.ui.save(w.st).log_wrap, false, "the choice is saved")
	w.ui.event(w.st, { ev = "action", id = "main.body.runs.run.tools.wrap", act = "log-wrap" })
	eq(width(), nil, "wraps again")
	-- Cancel from the detail pane's head.
	w.ui.event(w.st, { ev = "action", id = "main.body.runs.run.head.end.cancel", act = "cancel", value = run.id })
	eq(run.stop, "cancel", "cancel requested")
end

do -- deleting a run takes two clicks in a row; events show how their runs went and open them
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL })
	w.core.dispatch(w.c, "plain")
	local r = w.c.store.runs[1]
	r.state, r.finished_at = "success", T0
	w.st.tab = "runs"
	w.ui.event(w.st, { ev = "select", id = "main.body.runs.left.list.runs", item = r.id })
	local function delete_btn(): any
		return find(view(w).main, function(x)
			return x.p and x.p.key == "delete"
		end)
	end
	eq(F.text(delete_btn()), "删除")
	local click = { ev = "action", id = "main.body.runs.run.tools.delete", act = "confirm", value = `delete-run:{r.id}` }
	w.ui.event(w.st, click)
	truthy(w.c.store.by_id[r.id], "the first click only arms it")
	eq(F.text(delete_btn()), "确认删除")
	w.ui.event(w.st, { ev = "action", id = "main.body.runs.run.tools.log", act = "open-log", value = r.id })
	eq(F.text(delete_btn()), "删除", "another action disarms it")
	w.ui.event(w.st, click)
	w.ui.event(w.st, click)
	truthy(w.c.store.by_id[r.id], "a double click only arms it")
	step(w, 1)
	press(w, "j")
	eq(F.text(delete_btn()), "删除", "a key disarms it")
	w.ui.event(w.st, click)
	step(w, 6)
	w.ui.event(w.st, click)
	truthy(w.c.store.by_id[r.id], "a second click after the arm expired only arms again")
	step(w, 1)
	w.ui.event(w.st, click)
	eq(w.c.store.by_id[r.id], nil, "a second, separate click deletes")
	eq(w.st.run_id, nil, "and the detail pane lets go of it")
	step(w, 1)
	eq(w.env.tern.fs.exists(`{DATA}/runs/{r.id}`), false, "its directory is gone")

	w.core.on_events(w.c, {
		{ seq = 1, delivery = "dx", info = { event = "issues", action = "opened", repo = "acme/web", number = 3, title = "Bug", association = "OWNER" } },
	})
	local ev = w.c.events[1]
	eq(#ev.runs, 1, "the issue started triage")
	w.st.tab = "events"
	local row = find(view(w).main, function(x)
		return x.k == "table" and x.p and x.p.key == "table"
	end).p.rows[1]
	eq(row.id, "d:dx", "rows are keyed by delivery")
	truthy(string.find(F.text({ k = "text", p = { spans = row.cells[4].text } }), "Issue 分诊", 1, true), "result names the run's workflow")
	w.ui.event(w.st, { ev = "select", id = "main.body.events.table", item = "d:dx" })
	eq(w.st.tab, "runs", "selecting the event opens its run")
	eq(w.st.run_id, ev.runs[1])
end

do -- the step waterfall places bars by start offset; a step at the run's very end keeps a sliver
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL })
	w.core.dispatch(w.c, "plain")
	step(w, 2)
	local r = w.c.store.runs[1]
	r.started_at, r.finished_at = 100, 110
	r.steps[1].started_at, r.steps[1].finished_at = 110, 110
	w.st.tab = "runs"
	w.st.run_id = r.id
	local steps = find(view(w).main, function(x)
		return x.k == "table" and x.p and x.p.key == "steps"
	end)
	local parts = steps.p.rows[1].cells[3].meter.parts
	eq(parts[1].value, 0.99, "pulled back from the end")
	eq(parts[2].value, 0.01, "so a sliver still shows")
	r.steps[1].started_at, r.steps[1].finished_at = 102, 107
	parts = find(view(w).main, function(x)
		return x.k == "table" and x.p and x.p.key == "steps"
	end).p.rows[1].cells[3].meter.parts
	eq(parts[1].value, 0.2, "starts 2 s into a 10 s run")
	eq(parts[2].value, 0.5, "and lasts half of it")
end

do -- a queued run cancelled from the row menu; j/k move the selection
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL })
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
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL })
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
	local store = require("../lib/store")
	eq(store.prune(w.c.store, 0), 1, "the finished run is dropped")
	eq(w.env.tern.fs.exists(sdir), true, "its directory waits for the drain")
	local left = -1
	store.drain(w.c.store, 10, function(n)
		left = n
	end)
	w.env.drain()
	eq(left, 0, "drained")
	eq(w.env.tern.fs.exists(sdir), false, "session files pruned with the run")
	sidebar.close(st)
end

do -- the cost pair appears only when tokens are above zero
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL })
	w.core.dispatch(w.c, "plain")
	local r = w.c.store.runs[1]
	r.state = "success"
	r.started_at, r.finished_at = w.now, w.now
	local s = r.steps[1]
	s.state = "success"
	s.started_at, s.finished_at = w.now, w.now
	w.st.tab = "runs"
	w.st.run_id = r.id
	local function spans_text(v: any): string
		return F.text({ k = "text", p = { spans = v } })
	end
	local function cost_value(): any
		local facts = find(view(w).main, function(x)
			return x.k == "kv" and x.p and x.p.key == "facts"
		end)
		truthy(facts, "run facts")
		for _, item in facts.p.items do
			if item[1] == "费用" then
				return item[2]
			end
		end
		return nil
	end
	eq(cost_value(), nil, "no cost pair before a tally")
	s.cost = 0.42
	s.tokens = 0
	eq(cost_value(), nil, "zero tokens hides the pair")
	s.tokens = 128000
	local shown = spans_text(cost_value())
	truthy(string.find(shown, "$0.42", 1, true) ~= nil, shown)
	truthy(string.find(shown, "128k tokens", 1, true) ~= nil, shown)
	truthy(string.find(shown, "估算", 1, true) ~= nil, shown)
	local function row_state(): string
		local steps = find(view(w).main, function(x)
			return x.k == "table" and x.p and x.p.key == "steps"
		end)
		local text = steps.p.rows[1].cells[2].text
		if type(text) == "string" then
			return text
		end
		return spans_text(text)
	end
	eq(string.find(row_state(), "$", 1, true), nil, "a shell step does not show a tally")
	s.kind = "omp"
	local row = row_state()
	truthy(string.find(row, "$0.42", 1, true) ~= nil, row)
	truthy(string.find(row, "128k", 1, true) ~= nil, row)
end

do -- today's spend and a step condition show on the workflow card
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL })
	w.st.tab = "workflows"
	local function item(id: string, label: string): any
		local card = find(view(w).main, function(x)
			return x.k == "card" and x.p and x.p.role == "roost.workflow" and x.p.key == id
		end)
		local kv = find(card, function(x)
			return x.k == "kv" and x.p and x.p.key == "info"
		end)
		for _, it in kv.p.items do
			if it[1] == label then
				return it[2]
			end
		end
		return nil
	end
	local function spans_text(v: any): string
		return F.text({ k = "text", p = { spans = v } })
	end
	eq(item("plain", "今日费用"), nil, "no line without a budget or spend")
	eq(string.find(spans_text(item("plain", "步骤")), "条件", 1, true), nil)
	w.core.dispatch(w.c, "plain")
	local run = w.c.store.runs[1]
	run.steps[1].cost = 1.25
	run.steps[1].started_at = w.now
	local spent = spans_text(item("plain", "今日费用"))
	truthy(string.find(spent, "$1.25", 1, true) ~= nil, spent)
	eq(string.find(spent, "预算", 1, true), nil, "no budget suffix when unset")
	local triage = w.c.workflows.by_id.triage
	triage.daily_budget = 5
	triage.steps[1].when = { source = "out", key = "verify", negate = false }
	eq(spans_text(item("triage", "今日费用")), "$0.00 / 预算 $5.00")
	truthy(string.find(spans_text(item("triage", "步骤")), "条件 out.verify", 1, true) ~= nil, "positive when")
	triage.steps[1].when = { source = "input", key = "dry_run", negate = true }
	truthy(string.find(spans_text(item("triage", "步骤")), "条件 !input.dry_run", 1, true) ~= nil, "negated when")
end

local function btn_with(v: any, act: string): any
	return find(v, function(x)
		return x.k == "button" and x.p and x.p.actions and x.p.actions.click == act
	end)
end

-- Two real clicks of a confirm button, far enough apart to count.
local function confirm_click(w: World, what: string)
	w.ui.event(w.st, { ev = "action", act = "confirm", value = what })
	w.env.advance(1000)
	w.ui.event(w.st, { ev = "action", act = "confirm", value = what })
end

local function act(w: World, name: string, value: string?)
	w.ui.event(w.st, { ev = "action", act = name, value = value })
end

do -- the files page: libraries, their files, saving, and deleting with two clicks
	local w = world({
		[DATA .. "/workflows.toml"] = WORKFLOWS,
		[DATA .. "/roost.toml"] = LOCAL,
		[DATA .. "/library/kit/hello.sh"] = "echo hi\n",
		[DATA .. "/state/old/x"] = "1",
	})
	w.st.tab = "files"
	local v = view(w)
	local text = F.text(v.main)
	truthy(string.find(text, "kit", 1, true), "the library is listed")
	truthy(string.find(text, "未被使用", 1, true), "and its use")
	truthy(string.find(text, "old", 1, true), "a state directory is listed")

	act(w, "fp-lib", "kit")
	v = view(w)
	truthy(string.find(F.text(v.main), "hello.sh", 1, true), "the library's file is listed")
	local editor_node = find(v.main, function(x)
		return x.k == "editor" and x.p and x.p.lang == "bash"
	end)
	truthy(editor_node, "the file is edited in a multi-line editor with its language")
	eq(editor_node.p.text, "echo hi\n")

	-- Edit (two lines typed through the keys), save, and the file on disk changes.
	w.st.fp.focus = "edit"
	press(w, "end")
	press(w, "x", "x")
	press(w, "enter")
	press(w, "y", "y")
	eq(w.st.fp.fields.edit.text, "echo hi\nx\ny", "typing and Enter edit the open file")
	act(w, "tab", "files")
	act(w, "fp-save")
	eq(w.env.files[DATA .. "/library/kit/hello.sh"], w.st.fp.fields.edit.text, "saved to the library")

	-- A new file, then a rename that keeps the content.
	w.st.fp.fields.newfile = { text = "tools/scan.py", cursor = 13 }
	act(w, "fp-newfile")
	eq(w.env.files[DATA .. "/library/kit/tools/scan.py"], "", "new file created")
	eq(w.st.fp.sel, "tools/scan.py")
	w.st.fp.fields.edit = { text = "print(1)\n", cursor = 9, lines = true }
	w.st.fp.fields.ren = { text = "tools/go.py", cursor = 11 }
	act(w, "fp-ren")
	eq(w.env.files[DATA .. "/library/kit/tools/go.py"], "print(1)\n", "renamed with its edited content")
	eq(w.env.files[DATA .. "/library/kit/tools/scan.py"], nil)

	-- Unsaved edits block switching file instead of being lost.
	w.st.fp.fields.edit = { text = "changed", cursor = 7, lines = true }
	act(w, "fp-file", "hello.sh")
	eq(w.st.fp.sel, "tools/go.py", "stays on the dirty file")
	truthy(#w.cx.toasts > 0 and string.find(w.cx.toasts[#w.cx.toasts].text, "未保存", 1, true), "and says why")
	act(w, "fp-revert")
	eq(w.st.fp.fields.edit.text, "print(1)\n")

	-- Deleting needs two clicks.
	w.ui.event(w.st, { ev = "action", act = "confirm", value = "file-del:tools/go.py" })
	truthy(w.env.files[DATA .. "/library/kit/tools/go.py"], "one click deletes nothing")
	confirm_click(w, "file-del:tools/go.py")
	eq(w.env.files[DATA .. "/library/kit/tools/go.py"], nil, "second click deletes")

	-- State directories go the same way; a library goes when no workflow uses it.
	confirm_click(w, "state-del:old")
	w.env.advance(200)
	eq(w.env.files[DATA .. "/state/old/x"], nil, "state directory deleted on request")
	confirm_click(w, "lib-del:kit")
	w.env.advance(200)
	eq(w.env.tern.fs.exists(DATA .. "/library/kit"), false, "unused library deleted")
end

do -- a library in use refuses to go, and says by whom
	local lib_wf = '[[workflow]]\nid = "uses"\nlibs = ["kit"]\n[[workflow.step]]\nfile = "@kit/a.py"\n'
	local w = world({
		[DATA .. "/workflows.toml"] = lib_wf,
		[DATA .. "/roost.toml"] = LOCAL,
		[DATA .. "/library/kit/a.py"] = "print(1)\n",
	})
	w.st.tab = "files"
	truthy(string.find(F.text(view(w).main), "uses", 1, true), "the page names the workflow using the library")
	confirm_click(w, "lib-del:kit")
	w.env.advance(200)
	truthy(w.env.files[DATA .. "/library/kit/a.py"], "the library stays")
	truthy(string.find(w.cx.toasts[#w.cx.toasts].text, "uses", 1, true), "the refusal names the workflow")
end

do -- export copies the path; import previews and brings the workflow back disabled
	local w = world({
		[DATA .. "/workflows.toml"] = WORKFLOWS .. '\n[[workflow]]\nid = "scripted"\n[[workflow.step]]\nfile = "run.py"\n',
		[DATA .. "/roost.toml"] = LOCAL,
		[DATA .. "/workflows/scripted/files/run.py"] = "print('hi')\n",
	})
	w.st.tab = "workflows"
	truthy(btn_with(view(w).main, "export-all"), "export all in the toolbar")
	truthy(btn_with(view(w).main, "export=scripted"), "export on the card")
	act(w, "export", "scripted")
	eq(#w.cx.copied, 1, "the path was copied")
	local path = w.cx.copied[1]
	truthy(string.match(path, "/data/exports/.+scripted%.roost%.toml$"), path)
	truthy(w.env.files[path], "the export file exists")
	truthy(string.find(w.cx.toasts[#w.cx.toasts].text, "已导出", 1, true), "success toast")
	act(w, "export-all")
	eq(#w.cx.copied, 2)

	-- Import it into a fresh install.
	local t = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL, [path] = w.env.files[path] })
	t.st.tab = "workflows"
	act(t, "imp-open")
	local layer = view(t).layer
	truthy(layer, "the import overlay opens")
	local run_btn = btn_with(layer, "imp-run")
	truthy(run_btn and run_btn.p.disabled, "importing needs a preview first")
	t.st.imp.path = { text = path, cursor = #path }
	act(t, "imp-preview")
	layer = view(t).layer
	truthy(string.find(F.text(layer), "scripted", 1, true), "the preview lists the workflow")
	truthy(string.find(F.text(layer), "新增,导入后停用", 1, true), "and what importing does")
	act(t, "imp-run")
	eq(t.st.imp, nil, "the overlay closes on success")
	local imported = t.c.workflows.by_id.scripted
	truthy(imported, "the workflow is back")
	eq(imported.enabled, false, "disabled")
	eq(t.env.files[DATA .. "/workflows/scripted/files/run.py"], "print('hi')\n", "with its file")
	truthy(string.find(t.cx.toasts[#t.cx.toasts].text, "已导入", 1, true), "summary toast")

	-- The editor owns the layer: import does not open over it.
	act(t, "editor-new")
	act(t, "imp-open")
	eq(t.st.imp, nil)

	-- A broken path shows its error in the overlay, and nothing is written.
	local u = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL })
	act(u, "imp-open")
	u.st.imp.path = { text = "/nowhere.roost.toml", cursor = 19 }
	act(u, "imp-preview")
	truthy(string.find(F.text(view(u).layer), "无法读取", 1, true), "preview error shown")
end

do -- storage lists the new areas and clears exports with two clicks
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL })
	act(w, "export-all")
	eq(#w.c.store.runs, 0)
	w.st.tab = "config"
	local labels = ""
	F.walk(view(w).main, function(x)
		if x.k == "kv" and x.p and x.p.items then
			for _, item in x.p.items do
				labels ..= tostring(item[1] or item.k) .. "|"
			end
		end
	end)
	truthy(string.find(labels, "导出文件", 1, true) and string.find(labels, "脚本与文件", 1, true) and string.find(labels, "状态目录", 1, true), "storage rows: " .. labels)
	confirm_click(w, "clear-exports")
	w.env.advance(200)
	eq(#w.core.exports(w.c), 0, "exports cleared")
end

print("ok")
