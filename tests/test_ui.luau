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

-- The world's block becomes a settings block (on `view`, else its first page).
local function as_settings(w: World, view: string?)
	w.ui.close(w.st)
	w.st = w.ui.new(w.c, w.cx, { view }, nil, "settings")
end

do -- the host blocks render every page; keys switch pages, the switch picks a page's view
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = ROOST })
	step(w, 1)
	for i, id in { "overview", "workflows", "runs" } do
		eq(press(w, tostring(i)), if i == 1 then false else true, `key {i}`)
		eq(w.st.tab, id)
		local v = view(w)
		truthy(F.text(v.main) ~= "", `page {id} has content`)
	end
	eq(press(w, "4"), false, "the console has three pages")
	w.ui.event(w.st, { ev = "select", id = "main.body.runs.left.bar.start.sub", item = "events" })
	eq(w.st.tab, "events", "the switch shows the page's other view")
	truthy(F.text(view(w).main) ~= "", "events page has content")
	eq(press(w, "2"), true)
	w.ui.event(w.st, { ev = "select", id = "main.body.workflows.bar.start.sub", item = "files" })
	eq(w.st.tab, "files")
	truthy(F.text(view(w).main) ~= "", "files page has content")
	w.ui.event(w.st, { ev = "select", id = "main.body.files.bar.start.sub", item = "relay" })
	eq(w.st.tab, "files", "a view of the settings block is not one of the console's")
	eq(press(w, "3"), true)
	eq(w.st.tab, "events", "a page reopens on the view it last showed")
	eq(press(w, "2"), true)
	eq(w.st.tab, "files")
	eq(w.ui.new(w.c, w.cx, {}, w.ui.save(w.st)).last.activity, "events", "the last views are saved")
	-- The header's settings button names the page; the window opens the block on it.
	w.ui.event(w.st, { ev = "action", id = "main.head.end.settings", act = "settings", value = "config" })
	eq(w.cx.opened[#w.cx.opened], "roost://settings/config")
	local s = w.ui.new(w.c, w.cx, {}, nil, "settings")
	w.ui.event(w.st, { ev = "action", id = "main.head.end.relay", act = "settings", value = "relay" })
	eq(s.tab, "relay", "an open settings block turns to the page")
	w.ui.close(s)
	as_settings(w, "github")
	eq(w.st.tab, "github", "a new settings block opens on the page it was opened for")
	for i, id in { "config", "relay", "github", "storage" } do
		press(w, tostring(i))
		eq(w.st.tab, id)
		truthy(F.text(view(w).main) ~= "", `settings page {id} has content`)
	end
	eq(w.ui.title(w.st), "Roost 设置")
	w.ui.close(w.st)
	w.st = w.ui.new(w.c, w.cx, {}, nil)
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
	as_settings(w, "relay")
	local v = view(w)
	local code = find(v.main, function(x)
		return x.k == "code" and x.p and string.find(x.p.text or "", 'repos."acme/web"', 1, true) ~= nil
	end)
	truthy(code, "manual subscriptions.toml shown")
	truthy(string.find(code.p.text, 'events = ["issues"]', 1, true), "with the subscribed events")
	w.ui.event(w.st, { ev = "action", id = "main.body.relay.subs.manual.copy", act = "copy", value = "subs" })
	eq(w.cx.copied[1], code.p.text, "copy puts the same text on the clipboard")
	eq(string.find(F.text(v.main), "GitHub Webhook", 1, true), nil, "webhook card is gone")
	w.st.tab = "github"
	local app_text = F.text(view(w).main)
	truthy(string.find(app_text, "GitHub App", 1, true), "GitHub App card")
	truthy(string.find(app_text, "中继未连接", 1, true), "disconnected relay explains itself")
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

do -- an agent step opens its session beside the console or where it lives; live agent, then the saved one
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
	eq(w.core.dispatch(w.c, "triage", { focus = "crash" }), nil)
	eq(w.core.dispatch(w.c, "plain"), nil)
	tick(2)
	local run, plain = w.c.store.runs[1], w.c.store.runs[2]
	eq(run.steps[1].agent, true, "triage's first step is an agent")
	w.st.tab = "runs"
	local function steps_rows(id: string): any
		w.st.run_id = id
		local tbl = find(view(w).main, function(x)
			return x.k == "table" and x.p and x.p.key == "steps"
		end)
		return tbl.p.rows
	end
	eq(steps_rows(plain.id)[1].menu, nil, "a shell step has no session")
	w.ui.event(w.st, { ev = "activate", id = "main.body.runs.detail.steps", item = "s1" })
	eq(#w.cx.opened, 0, "double-clicking a shell step opens nothing")
	eq(table.concat(steps_rows(run.id)[1].menu, "|"), "分屏打开|在 Roost 会话中打开", "a working step offers both ways")
	w.ui.event(w.st, { ev = "activate", id = "main.body.runs.detail.steps", item = "s1" })
	local url = w.cx.opened[1]
	eq(url, `roost://session/{run.id}/1/split`, "double-click opens it beside the console")
	w.ui.event(w.st, { ev = "action", id = "main.body.runs.detail.steps", act = "在 Roost 会话中打开", item = "s1" })
	local home = w.cx.opened[2]
	eq(home, `roost://session/{run.id}/1/tab`, "the row menu can open it where it lives")
	local menu = find(view(w).main, function(x)
		return x.k == "menu" and x.p and x.p.key == "how"
	end)
	eq(menu.p.items[1].id, `sess-split:{run.id}:1`)
	w.ui.event(w.st, { ev = "action", id = "main.body.runs.detail.tools.session.how", act = menu.p.items[2].id })
	eq(w.cx.opened[3], home, "the detail's menu names the same ways")

	local pane = win.started[1].pane
	win.focused = 1
	local function link(u: string): any
		return { url = u, pane = 1, mods = { cmd = false, alt = false, shift = false, ctrl = false } }
	end
	local sdir = `{DATA}/runs/{run.id}/s1.session`
	local agent_tab = win.panes[pane].tab
	eq(launcher.route(L, win.cx, link(url)), true)
	eq(win.toasts[#win.toasts].text, "还不能只读查看", "no session file yet: nothing to follow")
	eq(win.focused, pane, "so the agent is shown where it lives")
	eq(win.shown, win.sessions[2].id, "in the Roost session")
	eq(win.sessions[2].name, "Roost")
	local live = `{sdir}/2026-11-05T00-00-00-000Z_01a1-live.jsonl`
	w.env.files[live] = "{}\n"
	win.focused = 1
	launcher.route(L, win.cx, link(url))
	local viewer = win.opened[#win.opened]
	truthy(string.find(viewer.command, "collab list --json", 1, true), viewer.command)
	truthy(string.find(viewer.command, "roost 01a1-live omp", 1, true), "it follows this step's session: " .. viewer.command)
	local vpane = win.focused
	eq(win.panes[vpane].split.target, 1, "split: a viewer beside the console")
	eq(win.panes[pane].tab, agent_tab, "the agent itself stays in its tab")
	win.cx.layout:close(vpane)
	tick(1)
	eq(run.state, "running", "closing the viewer leaves the step running")
	launcher.route(L, win.cx, link(home))
	eq(win.focused, pane, "tab: the agent itself")
	w.env.files[live] = nil

	win.reply(pane, "ok")
	tick(3)
	eq(run.state, "success")
	launcher.route(L, win.cx, link(url))
	eq(win.toasts[#win.toasts].text, "这一步没有保存的 omp 会话", "nothing to resume yet")
	w.env.files[`{sdir}/2026-11-06T01-00-00-000Z_b.jsonl`] = "{}\n"
	w.env.files[`{sdir}/2026-11-06T00-00-00-000Z_a.jsonl`] = "{}\n"
	w.env.files[`{sdir}/.2026-11-06T01-00-00-000Z_b.jsonl.lock.os`] = ""
	win.focused = 1
	local before = #win.opened
	launcher.route(L, win.cx, link(url))
	local opened = win.opened[before + 1]
	eq(opened.command, `omp --session-dir {sdir} --resume {sdir}/2026-11-06T01-00-00-000Z_b.jsonl`, "newest session resumed")
	eq(opened.cwd, "/home/test", "the temp workspace is gone: home instead")
	local resumed = win.focused
	eq(win.panes[resumed].launch, opened, "the resumed session is focused")
	eq(win.panes[resumed].tab, win.panes[1].tab, "in the console's tab")
	eq(win.panes[resumed].split.target, 1, "split beside the console the link came from")
	eq(win.panes[resumed].split.dir, "right")
	eq(table.concat(steps_rows(run.id)[1].menu, "|"), "分屏打开|在新标签页打开", "an ended step resumes in a split or a tab")
	launcher.route(L, win.cx, link(home))
	local tabbed = win.opened[before + 2]
	eq(tabbed.command, opened.command, "tab: the same session resumed")
	for p, x in win.panes do
		if x.launch == tabbed then
			eq(x.split, nil, "in a tab of its own")
			eq(win.panes[p].tab ~= win.panes[1].tab, true)
		end
	end
	eq(#win.opened, before + 2)

	-- The log opens as a glimpse; a run without one says so.
	eq(launcher.route(L, win.cx, link(`roost://log/{run.id}`)), true)
	eq(win.files_opened[1].target, `{DATA}/runs/{run.id}/log.txt`)
	eq(win.files_opened[1].how, "glimpse")
	local toasts = #win.toasts
	launcher.route(L, win.cx, link("roost://log/abc123"))
	eq(#win.files_opened, 1, "no log, nothing opened")
	eq(win.toasts[toasts + 1].text, "这条运行还没有日志")

	eq(launcher.route(L, win.cx, link("https://example.com")), false, "other links pass through")

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
	local function list_cost(): any
		local runs = find(view(w).main, function(x)
			return x.k == "table" and x.p and x.p.key == "runs"
		end)
		return runs.p.rows[1].cells[5]
	end
	eq(list_cost(), "$0.42", "the run list shows the run's agent spend")
	s.tokens = 0
	eq(list_cost(), "", "blank without a tally")
end

do -- the facts list the models a run's agent steps use: seen in their sessions, else their setting
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL })
	w.core.dispatch(w.c, "plain")
	local r = w.c.store.runs[1]
	r.state = "running"
	local s = r.steps[1]
	s.kind, s.state = "omp", "running"
	table.insert(r.steps, { name = "复核", kind = "omp", state = "pending", model = "@smol" })
	table.insert(r.steps, { name = "执行", kind = "omp", state = "pending", model = "@unknown" })
	w.c.omp_models = {
		roles = { { name = "default", model = "anthropic/opus" }, { name = "smol", model = "xai/fast" } },
		models = {},
		loading = true,
	}
	w.st.tab = "runs"
	w.st.run_id = r.id
	local function models(): { string }
		local facts = find(view(w).main, function(x)
			return x.k == "kv" and x.p and x.p.key == "facts"
		end)
		local out = {}
		local inside = false
		for _, item in facts.p.items do
			inside = item[1] == "模型" or (inside and item[1] == "")
			if inside then
				local text = ""
				for _, sp in item[2] do
					text ..= sp.t
				end
				table.insert(out, text)
			end
		end
		return out
	end
	local name = s.name
	eq(table.concat(models(), "\n"), table.concat({
		`anthropic/opus  {name}(默认角色)`,
		"xai/fast  复核(@smol,待运行)",
		"@unknown  执行(待运行)",
	}, "\n"), "before any session: what each setting runs, roles looked up here")

	s.models = {
		{ model = "xai/composer" },
		{ model = "anthropic/sonnet", agent = "Reviewer" },
		{ model = "xai/fast", role = "judge" },
	}
	eq(table.concat(models(), "\n"), table.concat({
		`xai/composer  {name}`,
		`anthropic/sonnet  {name}(子代理 Reviewer)`,
		`xai/fast  {name}(judge) · 复核(@smol,待运行)`,
		"@unknown  执行(待运行)",
	}, "\n"), "what the session shows wins; one row per model, naming every use")

	r.state = "cancelled"
	s.state = "success"
	eq(table.concat(models(), "\n"), table.concat({
		`xai/composer  {name}`,
		`anthropic/sonnet  {name}(子代理 Reviewer)`,
		`xai/fast  {name}(judge)`,
	}, "\n"), "an ended run lists only what ran")
	s.models = nil
	eq(#models(), 0, "nothing known, nothing listed")
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

-- Node id → node for a view region (ids join the keys from the region root: `main.body.x.y`).
local function ids_of(root: any): { [string]: any }
	local out: { [string]: any } = {}
	local function go(n: any, id: string)
		out[id] = n
		for i, ch in n.c or {} do
			local key = if ch.p and ch.p.key then ch.p.key else tostring(i - 1)
			go(ch, `{id}.{key}`)
		end
	end
	go(root, "main")
	return out
end

-- Every card of a view that names a head control (`end`) must name a real node, keyed `end`.
local function head_controls(main: any, what: string): number
	local ids = ids_of(main)
	local n = 0
	F.walk(main, function(x)
		if x.k == "card" and x.p and x.p["end"] then
			n += 1
			local target = ids[x.p["end"]]
			truthy(target, `{what}: the card {x.p.key} names {x.p["end"]}, which is not a node`)
			eq(target.p.key, "end", `{what}: {x.p.key}'s head control is keyed end`)
		end
	end)
	return n
end

do -- storage shows the areas as number tiles and clears exports with two clicks
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL })
	act(w, "export-all")
	eq(#w.c.store.runs, 0)
	as_settings(w, "storage")
	local labels = ""
	F.walk(view(w).main, function(x)
		if x.k == "kv" and x.p and x.p.items then
			for _, item in x.p.items do
				labels ..= tostring(item[1] or item.k) .. "|"
			end
		elseif x.k == "stats" and x.p and x.p.items then
			for _, item in x.p.items do
				labels ..= tostring(item.label) .. "|"
			end
		end
	end)
	for _, label in { "运行", "事件记录", "导出文件", "脚本与文件", "状态目录", "上次自动清理" } do
		truthy(string.find(labels, label, 1, true), `storage shows {label}: {labels}`)
	end
	-- The tiles are on the page, never inside a card.
	local in_card = false
	F.walk(view(w).main, function(x)
		if x.k == "card" then
			F.walk(x, function(y)
				if y.k == "stats" then
					in_card = true
				end
			end)
		end
	end)
	eq(in_card, false, "stats are not inside a card")
	truthy(head_controls(view(w).main, "storage") >= 1, "the refresh control is a head control")
	-- The cleanup group and the deletions are separate cards; the deletions stay two-click.
	local ids = ids_of(view(w).main)
	truthy(ids["main.body.storage.page.main.right.cleanup"], "cleanup card")
	local wipe = ids["main.body.storage.page.main.right.wipe"]
	truthy(wipe, "deletions card")
	local acts = {}
	F.walk(wipe, function(x)
		if x.k == "button" and x.p and x.p.actions then
			table.insert(acts, x.p.actions.click)
		end
	end)
	eq(table.concat(acts, ","), "confirm=clear-runs,confirm=clear-events,confirm=clear-exports")
	confirm_click(w, "clear-exports")
	w.env.advance(200)
	eq(#w.core.exports(w.c), 0, "exports cleared")
end

do -- the general page: both config files side by side with their status and Edit at the head's end
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL })
	as_settings(w, "config")
	local main = view(w).main
	truthy(head_controls(main, "config") >= 4, "files, environments and theme cards have head controls")
	local ids = ids_of(main)
	local pair = ids["main.body.config.page.files"]
	eq(#pair.c, 2, "two config cards in one row")
	eq(pair.p.wrap, true, "the row wraps when narrow")
	for _, key in { "config", "workflows" } do
		local card = ids[`main.body.config.page.files.{key}`]
		eq(card.p.basis, 0.49, "wide pane: half each") -- the world's pane is wide
		local acts = ""
		F.walk(card, function(x)
			if x.k == "button" and x.p and x.p.actions then
				acts ..= x.p.actions.click .. ";"
			end
		end)
		eq(acts, `open={key};`)
	end
	truthy(string.find(F.text(main), "已加载 2 个工作流", 1, true), "the workflows status stays: " .. F.text(main))
	w.st.cols = 80
	eq(ids_of(view(w).main)["main.body.config.page.files.config"].p.basis, 1, "narrow pane: one column")
end

do -- the GitHub page: identity apart from actions, forgetting credentials apart from both
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = ROOST })
	w.c.relay.state.configured = true
	w.c.relay.state.agent = { github = { app = { name = "Roost", slug = "roost", owner = "zero", owner_type = "User", installations = 1, missing = { "issues:write" } } } }
	as_settings(w, "github")
	local main = view(w).main
	truthy(head_controls(main, "github") >= 1, "the installed badge is a head control")
	local ids = ids_of(main)
	local base = "main.body.github.page.main.right"
	local function actions(id: string): string
		local out = ""
		F.walk(ids[id], function(x)
			if x.k == "button" and x.p and x.p.actions then
				out ..= x.p.actions.click .. ";"
			end
		end)
		return out
	end
	eq(actions(base .. ".manage"), "app-install;app-manage;app-permissions;app-logo;")
	eq(actions(base .. ".danger"), "confirm=forget-app;")
	truthy(ids["main.body.github.page.missing"], "ungranted permissions get their own card")
	truthy(string.find(F.text(main), "issues:write", 1, true), "and name the permission")
	-- Before an App exists the org input keeps the id the key handler routes typing by.
	w.c.relay.state.agent = { github = {} }
	local input = ids_of(view(w).main)["main.body.github.page.app.org.input"]
	truthy(input and input.k == "input", "the org input sits at github.page.app.org.input")
	w.ui.event(w.st, { ev = "focus", id = "main.body.github.page.app.org.input" })
	truthy(w.st.app_focus, "focusing it arms typing")
end

do -- overview lists evolver revisions and a self-upgrade; only a watching one rolls back
	local book = [[{"revs":[{"n":1,"at":1793870000,"run":"bbb","reviewer":"evolver","workflows":["plain"],"libs":[],"watch":["plain"],"state":"rolled_back","baseline":{},"seen":{}},{"n":2,"at":1793880000,"run":"aaa","reviewer":"evolver","workflows":["triage"],"libs":["kit"],"watch":["triage"],"state":"watching","baseline":{},"seen":{},"note":"tighten the prompt"}],"next":3,"last":{},"day":{}}]]
	local up = [[{"run":"abc","old":"1111111111aaaa","new":"2222222222bbbb","state":"applied","message":"upgraded roost","at":1793881000}]]
	local w = world({
		[DATA .. "/workflows.toml"] = WORKFLOWS,
		[DATA .. "/roost.toml"] = LOCAL,
		[DATA .. "/revisions.json"] = book,
		[DATA .. "/upgrades/ab.json"] = up,
	})
	w.st.tab = "overview"
	local got: { number } = {}
	w.core.rollback_revision = function(_c: any, n: number): string?
		table.insert(got, n)
		return "refused"
	end
	local page = view(w)
	local text = F.text(page.main)
	truthy(string.find(text, "自迭代", 1, true), "card title")
	truthy(string.find(text, "#2", 1, true) and string.find(text, "观察中", 1, true), "watching revision")
	truthy(string.find(text, "@kit", 1, true), "changed library")
	truthy(string.find(text, "已回滚", 1, true), "rolled back revision")
	truthy(string.find(text, "已升级", 1, true) and string.find(text, "upgraded roost", 1, true), "upgrade row")
	eq(string.find(text, "还没有迭代修订", 1, true), nil)
	eq(string.find(text, "还没有自升级记录", 1, true), nil)
	local actions: { string } = {}
	F.walk(page.main, function(x)
		local click = x.p and x.p.actions and x.p.actions.click
		if type(click) == "string" and string.find(click, "rollback-rev:", 1, true) then
			table.insert(actions, click)
		end
	end)
	eq(#actions, 1, "only the watching revision offers rollback")
	eq(actions[1], "confirm=rollback-rev:2")
	w.ui.event(w.st, { ev = "action", act = "confirm", value = "rollback-rev:2" })
	eq(#got, 0, "the first click only arms it")
	w.env.advance(1000)
	w.ui.event(w.st, { ev = "action", act = "confirm", value = "rollback-rev:2" })
	eq(#got, 1, "the second click rolls back")
	eq(got[1], 2)
	truthy(string.find(w.cx.toasts[#w.cx.toasts].text, "refused", 1, true), "rollback error is toasted")
end

do -- home lists what needs a person; each item leads to its run or its settings page
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL })
	local function items(): { [string]: any }
		local out = {}
		local list = find(view(w).main, function(x)
			return x.k == "list" and x.p and x.p.key == "attention"
		end)
		for _, it in (list and list.c) or {} do
			out[it.p.key] = it
		end
		return out
	end
	eq(next(items()), nil, "nothing to do yet")
	w.core.dispatch(w.c, "plain")
	local r = require("../lib/store").list(w.c.store, 1, "plain")[1]
	eq(items()[`run_{r.id}`], nil, "a running workflow is not a failure")
	r.state, r.finished_at, r.reason = "failed", w.now, "exit 1"
	local it = items()[`run_{r.id}`]
	truthy(it and string.find(it.p.detail, "exit 1", 1, true), "the failed last run, with why")
	w.ui.event(w.st, { ev = "select", id = "main.body.overview.attention_view.attention", item = `run_{r.id}` })
	eq(w.st.tab, "runs", "the item opens the run")
	eq(w.st.run_id, r.id)
	w.st.tab = "overview"
	w.c.workflow_issues = { { path = "workflow[1]", message = "bad", line = 1 } }
	truthy(items().set_config, "config errors lead to the settings")
	w.ui.event(w.st, { ev = "select", id = "main.body.overview.attention_view.attention", item = "set_config" })
	eq(w.cx.opened[#w.cx.opened], "roost://settings/config")
end

do -- runs show their id; the detail and the row menu copy it
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL })
	w.core.dispatch(w.c, "plain")
	local r = require("../lib/store").list(w.c.store, 1, "plain")[1]
	truthy(r, "a run")
	w.st.tab = "runs"
	w.ui.event(w.st, { ev = "select", id = "main.body.runs.left.runs", item = r.id })
	local page = view(w)
	local tbl = find(page.main, function(x)
		return x.k == "table" and x.p and x.p.key == "runs"
	end)
	eq(tbl.p.rows[1].cells[2], r.id, "the id column holds the full id")
	local facts = find(page.main, function(x)
		return x.k == "kv" and x.p and x.p.key == "facts"
	end)
	local first = facts.p.items[1]
	eq(F.text({ k = "text", p = { spans = first[2] or first.v } }), r.id, "the detail leads with the id")
	w.ui.event(w.st, { ev = "action", id = "main.body.runs.left.runs", act = "copy-id", item = r.id })
	eq(w.cx.copied[#w.cx.copied], r.id, "row menu copies the id")
end

do -- workflow groups: create, move, fold, reorder keys, follow renames, survive reloads
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL })
	w.st.tab = "workflows"
	local function card(id: string): any
		return find(view(w).main, function(x)
			return x.k == "card" and x.p and x.p.role == "roost.workflow" and x.p.key == id
		end)
	end
	-- A new group from a card's menu takes that workflow along.
	act(w, "grp-new-for:plain")
	truthy(w.st.grp and view(w).layer, "the name dialog opens")
	w.st.grp.name = { text = "Ops", cursor = 3 }
	eq(press(w, "enter"), true)
	eq(w.st.grp, nil, "closed once created")
	local gid = w.c.groups.list[1].id
	eq(w.c.groups.of.plain, gid, "plain moved into the new group")
	-- The head controls are named by id: a card in a group is one level deeper.
	eq(card("plain").p["end"], `main.body.workflows.g_{gid}.cards.plain.end`)
	eq(card("triage").p["end"], "main.body.workflows.ungrouped.cards.triage.end")
	-- A second group with the same name is refused in the dialog.
	act(w, "grp-new")
	w.st.grp.name = { text = "Ops", cursor = 3 }
	act(w, "grp-ok")
	truthy(w.st.grp and w.st.grp.error, "duplicate name refused")
	eq(#w.c.groups.list, 1)
	eq(press(w, "escape"), true)
	-- j/k walk the page's order: the group first, then the ungrouped.
	eq(press(w, "j"), true)
	eq(w.st.wf_id, "plain")
	eq(press(w, "j"), true)
	eq(w.st.wf_id, "triage")
	-- [ moves the picked workflow into the previous group; ] past the last group ungroups it.
	eq(press(w, "["), true)
	eq(w.c.groups.of.triage, gid)
	eq(press(w, "["), false, "already in the first group")
	eq(press(w, "]"), true)
	eq(w.c.groups.of.triage, nil)
	-- The card menu moves too.
	act(w, `mv:triage:{gid}`)
	eq(w.c.groups.of.triage, gid)
	act(w, "mv:triage:")
	eq(w.c.groups.of.triage, nil)
	-- A folded group hides its cards, and j/k skip them.
	act(w, "grp-toggle", gid)
	eq(card("plain"), nil, "folded")
	w.st.wf_id = "triage"
	eq(press(w, "k"), false, "nothing shown above")
	act(w, "grp-toggle", gid)
	truthy(card("plain"), "unfolded")
	-- Saved, and read back by a new runtime.
	local saved = w.env.files[DATA .. "/groups.json"]
	truthy(saved and string.find(saved, '"Ops"', 1, true), "groups.json written")
	-- A renamed workflow keeps its group; a deleted one leaves it.
	local raw = w.core.workflow_raw(w.c, "plain")
	raw.id = "plain2"
	eq(w.core.save_workflow(w.c, "plain", raw), nil)
	eq(w.c.groups.of.plain, nil)
	eq(w.c.groups.of.plain2, gid, "the group follows the new id")
	eq(w.core.delete_workflow(w.c, "plain2"), nil)
	eq(w.c.groups.of.plain2, nil, "forgotten with the workflow")
	-- Deleting a group takes two clicks and ungroups its workflows.
	act(w, `mv:triage:{gid}`)
	confirm_click(w, `grp-del:{gid}`)
	eq(#w.c.groups.list, 0)
	eq(w.c.groups.of.triage, nil)
	eq(card("triage").p["end"], "main.body.workflows.cards.triage.end", "no groups: one grid again")

	local again = world({
		[DATA .. "/workflows.toml"] = WORKFLOWS,
		[DATA .. "/roost.toml"] = LOCAL,
		[DATA .. "/groups.json"] = saved,
	})
	eq(again.c.groups.list[1].name, "Ops", "loaded at start")
	eq(again.c.groups.of.plain, again.c.groups.list[1].id)
end

do -- exports carry groups: one workflow takes its group, all take every group in page order
	local GROUPS = '{"groups":[{"id":"g1","name":"Ops"},{"id":"g2","name":"Empty"}],"of":{"plain":"g1"}}'
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL, [DATA .. "/groups.json"] = GROUPS })
	local bundle = require("../lib/bundle")
	local function read(path: string): any
		local b, err = bundle.decode(w.env.files[path])
		truthy(b, `export decodes: {tostring(err)}`)
		return b
	end
	act(w, "export", "triage")
	eq(#read(w.cx.copied[1]).groups, 0, "an ungrouped workflow carries no group")
	act(w, "export", "plain")
	local one = read(w.cx.copied[2])
	eq(#one.groups, 1, "only its own group")
	eq(one.groups[1].name, "Ops")
	eq(table.concat(one.groups[1].workflows, ","), "plain")
	act(w, "export-all")
	local all = read(w.cx.copied[3])
	-- workflows.toml has triage first; the page shows group Ops (plain) before the ungrouped.
	eq(all.workflows[1].id, "plain", "page order")
	eq(all.workflows[2].id, "triage")
	eq(#all.groups, 2, "empty groups too")
	eq(all.groups[2].name, "Empty")
	eq(#all.groups[2].workflows, 0)
	local path = w.cx.copied[3]

	-- Into an install without them: groups made by name, workflows placed.
	local OTHER = '[[workflow]]\nid = "other"\nworkspace = "temp"\n[[workflow.step]]\nrun = "true"\n'
	local t = world({ [DATA .. "/workflows.toml"] = OTHER, [DATA .. "/roost.toml"] = LOCAL, [path] = w.env.files[path] })
	t.st.tab = "workflows"
	act(t, "imp-open")
	t.st.imp.path = { text = path, cursor = #path }
	act(t, "imp-preview")
	truthy(string.find(F.text(view(t).layer), "Ops", 1, true), "the preview lists the groups")
	act(t, "imp-run")
	eq(t.st.imp, nil)
	eq(t.c.groups.list[1].name, "Ops")
	eq(t.c.groups.list[2].name, "Empty")
	eq(t.c.groups.of.plain, t.c.groups.list[1].id)
	eq(t.c.groups.of.triage, nil)
	truthy(string.find(t.cx.toasts[#t.cx.toasts].text, "新建分组", 1, true), "summary names the new groups")

	-- Over workflows already grouped here: this machine's grouping stays; same-named groups merge.
	local u = world({
		[DATA .. "/workflows.toml"] = WORKFLOWS,
		[DATA .. "/roost.toml"] = LOCAL,
		[DATA .. "/groups.json"] = '{"groups":[{"id":"g1","name":"Local"},{"id":"g2","name":"Ops"}],"of":{"plain":"g1"}}',
		[path] = w.env.files[path],
	})
	truthy(u.core.import_workflows(u.c, path, true))
	eq(u.c.groups.of.plain, "g1", "kept in its local group")
	eq(#u.c.groups.list, 3, "Ops matched by name, Empty added")
	eq(u.c.groups.list[3].name, "Empty")

	-- A workflow in two groups, or a group naming a workflow not in the file, is refused.
	local base = '[roost]\nformat = 1\n[[workflow]]\nid = "a"\n[[workflow.step]]\nrun = "x"\n'
	truthy(select(2, bundle.decode(base .. '[[group]]\nname = "x"\nworkflows = ["a"]\n[[group]]\nname = "y"\nworkflows = ["a"]\n')), "twice")
	truthy(select(2, bundle.decode(base .. '[[group]]\nname = "x"\nworkflows = ["b"]\n')), "unknown")
	truthy(select(2, bundle.decode(base .. '[[group]]\nname = "x"\n[[group]]\nname = "x"\n')), "duplicate name")
	truthy(bundle.decode(base), "no groups is fine (older exports)")
end

do -- an unreadable groups.json is reported and never overwritten
	local w = world({
		[DATA .. "/workflows.toml"] = WORKFLOWS,
		[DATA .. "/roost.toml"] = LOCAL,
		[DATA .. "/groups.json"] = "{broken",
	})
	truthy(w.c.groups_err, "the error is kept")
	local id, err = w.core.group_create(w.c, "Ops")
	eq(id, nil)
	truthy(err, "creating is refused")
	eq(w.env.files[DATA .. "/groups.json"], "{broken", "the file is untouched")
end

do -- home: a finished run shows its answer and changes; 追问 continues it; the inbox acts
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL })
	view(w)
	-- A built-in task run, as core's submit_task makes one.
	local tasks = require("../lib/tasks")
	local repo = w.c.workflows and w.c.workflows.repos["acme/web"]
	local task: any = { kind = "task", prompt = "1\nx", workspace = if repo and repo.path then "worktree" else "temp" }
	local created = require("../lib/runner").submit(w.c.runner, tasks.workflow(tasks.new_id(), task, "acme/web"), {
		trigger = { kind = "task", detail = "首页" },
		repo = "acme/web",
		inputs = {},
		task = task,
	})
	truthy(created, "a task run")
	local run: any = created
	w.st.tab, w.st.run_id = "runs", run.id
	eq(run.task.kind, "task")
	eq(run.repo, "acme/web")

	-- Pretend it finished with an answer, changes and a conversation to continue.
	local d = `{DATA}/runs/{run.id}`
	for _, s in run.steps do
		s.state = "success"
	end
	run.steps[2].agent = true
	run.state, run.finished_at = "success", w.now
	run.changes = { files = 2, add = 3, del = 1 }
	w.env.files[d .. "/s2.answer.md"] = "## 完成\n改了 a.lua"
	w.env.files[d .. "/s2.session/2026-11-08T00-00-00-000Z_abc.jsonl"] = "{}\n"
	w.env.files[d .. "/changes.numstat"] = "3\t1\ta.lua\n-\t-\tlogo.png\n"
	w.env.files[d .. "/changes.total"] = "2 3 1\n"
	w.env.files[d .. "/changes.patch"] = "diff --git a/a.lua b/a.lua\n"
	w.env.files[d .. "/base.txt"] = "0123456789abcdef0123456789abcdef01234567\n"
	local page = view(w)
	local text = F.text(page.main)
	truthy(string.find(text, "完成", 1, true), "the answer shows")
	truthy(string.find(text, "改动 +3 −1 · 2 个文件", 1, true), "the changes' head")
	local files = find(page.main, function(x)
		return x.k == "table" and x.p and x.p.key == "table" and x.p.rows and x.p.rows[1] and x.p.rows[1].cells[1] == "a.lua"
	end)
	truthy(files and files.p.rows[2].cells[1] == "logo.png", "the changed files")
	local follow = find(page.main, function(x)
		return x.k == "button" and x.p and x.p.key == "followup"
	end)
	truthy(follow, "a finished run with a conversation offers 追问")
	w.ui.event(w.st, { ev = "action", act = "diff", value = run.id })
	truthy(string.find(F.text(view(w).layer), "diff --git", 1, true), "the diff overlay")
	eq(press(w, "escape"), true)
	eq(w.st.diff, nil, "Esc closes it")

	w.ui.event(w.st, { ev = "action", act = "followup-open", value = run.id })
	truthy(w.st.dlg and w.st.dlg.kind == "followup", "the follow-up dialog")
	press(w, "y", "y")
	press(w, "enter")
	eq(w.st.dlg.fields[1].text, "y\n", "Enter is a new line in the follow-up")
	press(w, "enter", nil, { meta = true })
	eq(w.st.dlg, nil, "⌘↵ sends it")
	local f = w.c.store.by_id[w.st.run_id]
	eq(f.parent, run.id, "the follow-up continues the run")
	eq(f.steps[1].kind, "resume")

	w.ui.event(w.st, { ev = "action", act = "pr-open", value = run.id })
	truthy(w.st.dlg and w.st.dlg.kind == "pr", "the PR dialog")
	eq(w.st.dlg.fields[3].text, "", "no branch set for the repo: its default")
	w.ui.event(w.st, { ev = "action", act = "dlg-cancel" })
	eq(w.st.dlg, nil)

	-- The inbox: a reported item with its actions; dismissing hides it.
	w.core.inbox_report(w.c, { id = "ab", workflow = "plain", steps = {} } :: any, '{"items":[{"id":"pr.9","title":"PR #9 等待批准","kind":"approve","url":"https://github.com/a/b/pull/9"}]}')
	w.st.tab = "overview"
	local home = view(w)
	truthy(string.find(F.text(home.main), "PR #9 等待批准", 1, true), "the item shows")
	local dismiss = find(home.main, function(x)
		return x.k == "button" and x.p and x.p.key == "dismiss"
	end)
	truthy(dismiss, "an item can be dismissed")
	local what, value = string.match(dismiss.p.actions.click, "^([^=]+)=(.*)$")
	w.ui.event(w.st, { ev = "action", act = what, value = value })
	eq(string.find(F.text(view(w).main), "PR #9", 1, true), nil, "dismissed")
end

do -- 用描述生成: omp drafts a workflow; complaints are fed back once; the draft opens in the editor
	local w = world({ [DATA .. "/workflows.toml"] = WORKFLOWS, [DATA .. "/roost.toml"] = LOCAL })
	local calls: { { string } } = {}
	local answers = {
		"好的:\n```toml\n[[workflow]]\nid = \"daily\"\nname = \"日报\"\n[[workflow.trigger]]\ngithub = \"pr_opened\"\n[[workflow.step]]\nname = \"写\"\nomp = \"总结\"\n```\n",
		"```toml\n[[workflow]]\nid = \"daily\"\nname = \"日报\"\n[[workflow.trigger]]\nschedule = \"daily\"\ntime = \"09:00\"\n[[workflow.step]]\nname = \"写\"\nomp = \"总结昨天合并的 PR\"\n```",
	}
	local base = w.env.process
	w.env.process = function(argv: { string }, opts: any): any
		if argv[6] == "-p" then
			table.insert(calls, argv)
			return { status = 0, stdout = answers[#calls] or "", stderr = "", timed_out = false }
		end
		return base(argv, opts)
	end
	w.st.tab = "workflows"
	w.ui.event(w.st, { ev = "action", act = "gen-open" })
	truthy(w.st.dlg and w.st.dlg.kind == "generate", "the dialog opens")
	for _, ch in { "日", "报" } do
		press(w, ch, ch)
	end
	press(w, "enter", nil, { meta = true })
	w.env.drain()
	eq(#calls, 2, "the first draft's problems went back to omp once")
	truthy(string.find(calls[2][9], "至少添加一个筛选器", 1, true), "with what was wrong")
	truthy(string.find(calls[1][9], "需求:日报", 1, true), "the description is in the prompt")
	eq(w.st.dlg, nil, "the dialog closed")
	truthy(w.st.editor, "the editor opened")
	eq(w.st.editor.raw.name, "日报")
	eq(w.st.editor.raw.id, nil, "a new workflow: the id is the editor's to make")
end

print("ok")
