--!strict
-- The automation editor: every schedule and GitHub kind renders, and save/delete/discard
-- round-trip through workflows.toml.

local F = require("./fake_tern")
local harness = require("./harness")
local model = require("../lib/model")

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
local NAME_ID = "layer.editor.body.head.name.input"
local PROMPT_ID = "layer.editor.body.prompt.stack.input"
local REPO_CHIP = "layer.editor.body.triggers.t1.card.repos.add"

local KEEP = [==[
[repos."acme/web"]
path = "~/code/web"

[[workflow]]
id = "keep"
name = "保留"
env = { TOKEN = "sek" }
[[workflow.input]]
name = "focus"
description = "关注点"
default = "x"
[[workflow.trigger]]
schedule = "daily"
time = "09:00"
[[workflow.step]]
name = "think"
omp = "hello"
]==]

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
			return false
		elseif argv[1] == "/bin/mkdir" then
			env.dirs[argv[2]] = true
			return { status = 0, stdout = "", stderr = "", timed_out = false }
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
	w.st = w.ui.new(w.c, w.cx, {}, nil)
	w.st.unsubscribe = core.subscribe(w.c, function()
		w.ui.refresh(w.st)
		w.cx:render()
	end)
	w.st.tab = "workflows"
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
local function step(w: World, seconds: number)
	for _ = 1, seconds do
		w.now += 1
		w.env.advance(1000)
	end
end

local function press(w: World, name: string, text: string?, mods: { [string]: boolean }?)
	local m: { [string]: boolean } = mods or {}
	w.ui.key(w.st, { name = name, text = text, ctrl = m.ctrl == true, alt = m.alt == true, shift = m.shift == true, meta = m.meta == true })
end

local function click(w: World, act: string)
	local name, value = string.match(act, "^([^=]+)=(.*)$")
	if name then
		w.ui.event(w.st, { ev = "action", act = name, value = value })
	else
		w.ui.event(w.st, { ev = "action", act = act })
	end
end

local function focus(w: World, id: string)
	w.ui.event(w.st, { ev = "focus", id = id })
end

local function type_text(w: World, s: string)
	for _, cp in utf8.codes(s) do
		local ch = utf8.char(cp)
		press(w, ch, ch)
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

local function has(text: string, s: string): boolean
	return string.find(text, s, 1, true) ~= nil
end

local function trigger_nodes(layer: any): { any }
	local out = {}
	F.walk(layer, function(x)
		if x.k == "col" and x.p and type(x.p.key) == "string" and string.match(x.p.key, "^t%d+$") then
			table.insert(out, x)
		end
	end)
	return out
end

local function select_key(node: any, key: string): any
	return find(node, function(x)
		return x.k == "select" and x.p and x.p.key == key
	end)
end

local function file_text(w: World): string?
	return w.env.files[DATA .. "/workflows.toml"]
end

local function parsed(w: World): any
	local text = file_text(w)
	truthy(type(text) == "string", "workflows.toml was written")
	local wfs, issues = model.parse_workflows(text :: string)
	eq(#issues, 0, `saved file has issues: {if issues[1] then issues[1].message else ""}`)
	truthy(wfs, "parse_workflows returned a catalogue")
	return wfs
end

do -- the add menu lists every kind, and each kind renders its own controls
	local w = world({})
	click(w, "editor-new")
	local opened = view(w)
	truthy(opened.layer, "editor overlay")
	local menu = find(opened.layer, function(x)
		return x.k == "menu" and x.p and x.p.key == "add"
	end)
	truthy(menu, "add-trigger menu")
	local ids: { [string]: boolean } = {}
	for _, item in menu.p.items do
		if type(item.id) == "string" then
			ids[item.id] = true
			truthy(type(item.detail) == "string" and item.detail ~= "", `{item.id} has a detail line`)
		end
	end
	for _, sch in model.SCHEDULES do
		truthy(ids[`sched:{sch.id}`], `menu lists {sch.label}`)
		click(w, `sched:{sch.id}`)
	end
	for _, kind in model.GITHUB_KINDS do
		truthy(ids[`gh:{kind.id}`], `menu lists {kind.label}`)
		click(w, `gh:{kind.id}`)
	end
	local layer = view(w).layer
	local nodes = trigger_nodes(layer)
	eq(#nodes, #model.SCHEDULES + #model.GITHUB_KINDS, "one card per added trigger")
	local by_sched: { [string]: any } = {}
	for _, node in nodes do
		local freq = select_key(node, "freq")
		if freq then
			by_sched[freq.p.value] = node
		end
	end
	for _, sch in model.SCHEDULES do
		local node = by_sched[sch.id]
		truthy(node, `{sch.label} sentence`)
		if sch.id == "once" or sch.id == "yearly" then
			truthy(find(node, function(x)
				return x.k == "date"
			end), `{sch.label} date`)
		end
		if sch.id == "hourly" then
			local span = select_key(node, "span")
			truthy(span and span.p.value == "range", "hourly defaults to a time window")
			truthy(select_key(node, "sh") and select_key(node, "eh"), "hourly start and end hours")
			truthy(find(node, function(x)
				return x.k == "button" and x.p and x.p.text == "六"
			end), "hourly day strip")
		elseif sch.id ~= "cron" then
			truthy(select_key(node, "hour") and select_key(node, "minute"), `{sch.label} time`)
		end
		if sch.id == "weekly" then
			local fri = find(node, function(x)
				return x.k == "button" and x.p and x.p.text == "五"
			end)
			local mon = find(node, function(x)
				return x.k == "button" and x.p and x.p.text == "一"
			end)
			truthy(fri and mon, "weekly day strip")
			eq(mon.p.on, true, "Monday starts selected")
			eq(fri.p.on, false, "Friday starts clear")
		end
		if sch.id == "monthly" then
			local day = select_key(node, "day")
			truthy(day and day.p.value == "1", "monthly day select")
		end
		if sch.id == "cron" then
			truthy(find(node, function(x)
				return x.k == "input" and x.p and x.p.placeholder == "0 9 * * 1-5"
			end), "cron input")
		end
	end
	for _, kind in model.GITHUB_KINDS do
		local node = nil
		for _, cand in nodes do
			if has(F.text(cand), kind.label) then
				node = cand
				break
			end
		end
		truthy(node, `{kind.label} card`)
		local text = F.text(node)
		truthy(has(text, "至少添加一个筛选器"), `{kind.label} warns until a filter is set`)
		local meta = model.kind(kind.id) :: model.KindMeta
		truthy(meta, kind.id)
		local wants_repo = false
		for _, key in meta.filters do
			local f = model.FILTERS[key]
			truthy(f, key)
			truthy(has(text, f.label), `{kind.label} shows {f.label}`)
			if f.kind == "choice" and f.options then
				for _, opt in f.options do
					truthy(has(text, opt.label), `{kind.label} offers {opt.label}`)
				end
			end
			if f.suggest == "people" or f.suggest == "labels" or f.suggest == "branches" or f.suggest == "workflows" then
				wants_repo = true
			end
		end
		if kind.id == "event" then
			truthy(has(text, "事件"), "custom kind picks its event")
		end
		if wants_repo then
			truthy(has(text, "选择一个仓库以查看建议"), `{kind.label} asks for a repo before suggestions`)
		end
	end
end

do -- new weekly trigger: toggle a day, name it, save a file the parser accepts
	local w = world({})
	click(w, "editor-new")
	press(w, "backspace", nil, { meta = true })
	type_text(w, "weekly")
	click(w, "sched:weekly")
	click(w, "day:1:fri")
	focus(w, PROMPT_ID)
	type_text(w, "hello")
	step(w, 1)
	local before = view(w)
	local save = find(before.layer, function(x)
		return x.k == "button" and x.p and x.p.text == "保存"
	end)
	truthy(save and save.p.disabled == false, "save enabled once the form is valid")
	press(w, "enter", nil, { meta = true })
	eq(w.st.editor, nil, "editor closes after save")
	eq(w.cx.toasts[#w.cx.toasts].text, "已保存", "saved toast")
	local wfs = parsed(w)
	local wf = wfs.by_id.weekly
	truthy(wf, "slug weekly")
	eq(wf.name, "weekly")
	eq(wf.triggers[1].schedule, "weekly")
	truthy(table.find(wf.triggers[1].days, "fri") ~= nil, "Friday selected")
	truthy(table.find(wf.triggers[1].days, "mon") ~= nil, "Monday kept")
	eq(wf.steps[1].prompt.parts[1].lit, "hello")
end

do -- editing keeps env and inputs that the form does not show
	local w = world({ [DATA .. "/workflows.toml"] = KEEP })
	click(w, "edit=keep")
	truthy(w.st.editor, "edit opened")
	view(w)
	press(w, "enter", nil, { meta = true })
	eq(w.st.editor, nil, "edit saved")
	local wfs = parsed(w)
	local wf = wfs.by_id.keep
	truthy(wf, "keep survived")
	eq(wf.env.TOKEN, "sek")
	eq(wf.inputs[1].name, "focus")
	eq(wf.inputs[1].default, "x")
	truthy(has(file_text(w) :: string, '[repos."acme/web"]'), "checkout table kept")
end

do -- a GitHub trigger without a filter cannot be saved; a typed repo chip clears the warning
	local w = world({})
	click(w, "editor-new")
	click(w, "gh:pr_opened")
	local blocked = view(w)
	truthy(has(F.text(blocked.layer), "至少添加一个筛选器"), "warning before any filter")
	local save = find(blocked.layer, function(x)
		return x.k == "button" and x.p and x.p.text == "保存"
	end)
	truthy(save and type(save.p.disabled) == "string", "save disabled with a reason")
	focus(w, REPO_CHIP)
	type_text(w, "acme/web")
	press(w, "enter")
	local cleared = view(w)
	truthy(has(F.text(cleared.layer), "acme/web ×"), "typed repo becomes a chip")
	eq(string.find(F.text(cleared.layer), "至少添加一个筛选器", 1, true), nil, "warning clears")
	focus(w, NAME_ID)
	press(w, "backspace", nil, { meta = true })
	type_text(w, "review")
	focus(w, PROMPT_ID)
	type_text(w, "look")
	press(w, "enter", nil, { meta = true })
	eq(w.st.editor, nil, "filtered trigger saves")
	local wf = parsed(w).by_id.review
	truthy(wf, "review saved")
	eq(wf.triggers[1].on, "pr_opened")
	eq(wf.triggers[1].repos[1], "acme/web")
end

do -- native edits (⌘A + typing, a click placing the caret) reach the raw table and save
	local w = world({})
	click(w, "editor-new")
	click(w, "gh:pr_opened")
	view(w)
	focus(w, REPO_CHIP)
	type_text(w, "acme/web")
	press(w, "enter")
	-- Default texts are BMP-only (CJK included), so codepoints = UTF-16 units.
	local len = utf8.len(w.st.editor.buf[NAME_ID].text) or 0
	w.ui.event(w.st, { ev = "edit", id = NAME_ID, from = 0, to = len, text = "review", cursor = 6, len = len + 1 })
	truthy(w.st.editor.raw.name ~= "review", "stale edit dropped")
	w.ui.event(w.st, { ev = "edit", id = NAME_ID, from = 0, to = len, text = "review", cursor = 6, len = len })
	eq(w.st.editor.raw.name, "review", "replaced selection reaches raw.name")
	local plen = utf8.len(w.st.editor.buf[PROMPT_ID].text) or 0
	w.ui.event(w.st, { ev = "edit", id = PROMPT_ID, from = 0, to = plen, text = "a\nb", cursor = 1, len = plen })
	eq(w.st.editor.buf[PROMPT_ID].text, "a\nb", "multi-line prompt keeps the newline")
	eq(w.st.editor.buf[PROMPT_ID].cursor, 1)
	press(w, "enter", nil, { meta = true })
	eq(w.st.editor, nil, "saves")
	local wf = parsed(w).by_id.review
	truthy(wf, "review saved")
	eq(wf.steps[1].prompt.parts[1].lit, "a\nb")
end

do -- Escape on a dirty form asks before discarding
	local w = world({})
	local before = w.env.files[DATA .. "/workflows.toml"]
	click(w, "editor-new")
	type_text(w, "x")
	press(w, "escape")
	local asking = view(w)
	truthy(has(F.text(asking.layer), "放弃未保存的更改?"), "discard confirm")
	click(w, "discard-stay")
	local stayed = view(w)
	eq(string.find(F.text(stayed.layer), "放弃未保存的更改?", 1, true), nil, "stay returns to the form")
	truthy(w.st.editor, "editor still open")
	press(w, "escape")
	click(w, "discard-go")
	eq(w.st.editor, nil, "discard closes")
	eq(w.env.files[DATA .. "/workflows.toml"], before, "discard writes nothing")
end

do -- frequency switches drop keys the new kind refuses; once keeps its clock in `at`;
	-- toggles show their defaults; the comment prefix saves as a string
	local w = world({})
	click(w, "editor-new")
	click(w, "sched:weekly")
	local change = function(id: string, value: any)
		w.ui.event(w.st, { ev = "change", id = id, value = value })
	end
	change("layer.editor.body.triggers.t1.sentence.freq", "daily")
	local tr = w.st.editor.raw.trigger[1]
	eq(tr.days, nil, "daily has no days")
	eq(tr.time, "09:00", "time carried over")
	change("layer.editor.body.triggers.t1.sentence.freq", "once")
	tr = w.st.editor.raw.trigger[1]
	eq(tr.time, nil, "once has no time key")
	change("layer.editor.body.triggers.t1.sentence.hour", "07")
	tr = w.st.editor.raw.trigger[1]
	eq(string.sub(tr.at, -5), "07:00", "hour lands in at")
	eq(tr.time, nil)

	click(w, "gh:pr_pushed")
	local layer = view(w).layer
	local skip = find(layer, function(x)
		return x.k == "switch" and x.p and x.p.label == "跳过草稿 PR"
	end)
	eq(skip and skip.p.on, true, "unset toggle shows its default (on)")

	click(w, "gh:comment")
	view(w)
	local prefix = "layer.editor.body.triggers.t3.card.comment.text.input"
	focus(w, prefix)
	type_text(w, "/roost")
	press(w, "enter")
	eq(w.st.editor.raw.trigger[3].comment, "/roost", "comment prefix is a string, not a chip list")
end

do -- switching an extra step's kind never turns it into the 指令 step or loses its text
	local wf = table.concat({
		"[[workflow]]",
		'id = "mix"',
		"[[workflow.step]]",
		'name = "fetch"',
		'run = "git fetch"',
		"[[workflow.step]]",
		'name = "review"',
		'omp = "review it"',
		'args = ["--thinking", "high"]',
		"[[workflow.step]]",
		'name = "think"',
		'omp = "more"',
		'args = ["--thinking", "low"]',
	}, "\n")
	local w = world({ [DATA .. "/workflows.toml"] = wf })
	click(w, "edit=mix")
	view(w)
	w.ui.event(w.st, { ev = "change", id = "layer.editor.body.steps.s1.bar.kind", value = "omp" })
	w.ui.event(w.st, { ev = "change", id = "layer.editor.body.steps.s3.bar.kind", value = "run" })
	press(w, "enter", nil, { meta = true })
	eq(w.st.editor, nil, "saved")
	local steps = parsed(w).by_id.mix.steps
	eq(steps[1].prompt.parts[1].lit, "git fetch", "the switched step keeps its own text")
	eq(steps[2].prompt.parts[1].lit, "review it", "the 指令 step is unchanged")
	eq(steps[2].args[2], "high", "and keeps its args")
	eq(steps[3].script, "more", "a step switched to 命令 drops omp-only args")
end

do -- deleting a step while a prompt insertion is pending removes the clicked step
	local wf = '[[workflow]]\nid = "two"\n[[workflow.step]]\nrun = "echo a"\n[[workflow.step]]\nrun = "echo b"\n'
	local w = world({ [DATA .. "/workflows.toml"] = wf })
	click(w, "edit=two")
	view(w)
	focus(w, PROMPT_ID)
	type_text(w, "x")
	click(w, "step-del:1")
	local steps = w.st.editor.raw.step
	eq(#steps, 2, "prompt step + the one left")
	eq(steps[1].omp, "x")
	eq(steps[2].run, "echo b", "echo a was the one clicked")
end

do -- the org field takes keys only while it is drawn
	local w = world({})
	w.c.relay.state.configured = true
	w.c.relay.state.agent = { github = { app = { slug = "r", owner = "zero", owner_type = "User" } } }
	w.st = w.ui.new(w.c, w.cx, { "github" }, nil, "settings")
	w.st.app_org = { text = "", cursor = 0 }
	w.st.app_focus = true
	press(w, "2", "2")
	eq(w.st.app_org.text, "", "App already exists: no hidden field swallows keys")
	eq(w.st.tab, "relay", "the digit switched pages instead")
end

do -- delete asks, then removes the workflow
	local w = world({ [DATA .. "/workflows.toml"] = KEEP })
	click(w, "edit=keep")
	click(w, "delete")
	local asking = view(w)
	truthy(find(asking.layer, function(x)
		return x.k == "button" and x.p and x.p.text == "确认删除"
	end), "second click confirms")
	truthy(w.env.tern.fs.exists(DATA .. "/workflows.toml"), "first click does not delete")
	click(w, "delete")
	eq(w.st.editor, nil, "delete closes")
	local text = file_text(w)
	truthy(type(text) == "string", "file still readable")
	eq(string.find(text :: string, 'id = "keep"', 1, true), nil, "workflow removed")
	local wfs, issues = model.parse_workflows(text :: string)
	eq(#issues, 0, "file still parses")
	truthy(wfs and wfs.by_id.keep == nil, "keep is gone")
end

do -- when and daily_budget round-trip; a non-number budget is a validator issue
	local wf = table.concat({
		"[[workflow]]",
		'id = "keep"',
		'name = "保留"',
		"[[workflow.input]]",
		'name = "dry_run"',
		"[[workflow.step]]",
		'name = "think"',
		'omp = "hello"',
		"[[workflow.step]]",
		'name = "ship"',
		'run = "echo ship"',
	}, "\n")
	local w = world({ [DATA .. "/workflows.toml"] = wf })
	click(w, "edit=keep")
	local layer = view(w)
	local when_fields = 0
	F.walk(layer.layer, function(x)
		if x.k == "field" and x.p and x.p.label == "条件(when)" then
			when_fields += 1
		end
	end)
	eq(when_fields, 2, "the prompt step and the extra step each have a when field")
	local PROMPT_WHEN = "layer.editor.body.prompt.when.input"
	local STEP_WHEN = "layer.editor.body.steps.s2.when.input"
	local BUDGET = "layer.editor.body.advanced.budget.input"
	focus(w, PROMPT_WHEN)
	type_text(w, "out.verify")
	focus(w, STEP_WHEN)
	type_text(w, "!input.dry_run")
	click(w, "advanced")
	layer = view(w)
	truthy(find(layer.layer, function(x)
		return x.k == "field" and x.p and x.p.label == "每日预算(美元)"
	end), "advanced section has the daily budget field")
	focus(w, BUDGET)
	type_text(w, "2.5")
	press(w, "enter")
	local raw = w.st.editor.raw
	eq(raw.step[1].when, "out.verify")
	eq(raw.step[2].when, "!input.dry_run")
	eq(raw.daily_budget, 2.5)
	local function roundtrip(): any
		local text = model.encode_workflow(w.st.editor.raw)
		local wfs, issues = model.parse_workflows(text)
		eq(#issues, 0, `round-trip issues: {if issues[1] then issues[1].message else ""}`)
		truthy(wfs, "parse_workflows returned a catalogue")
		return (wfs :: any).by_id.keep
	end
	local kept = roundtrip()
	eq(kept.daily_budget, 2.5)
	local when1 = kept.steps[1].when
	local when2 = kept.steps[2].when
	truthy(when1 and when2, "both conditions parsed")
	eq(when1.source, "out")
	eq(when1.key, "verify")
	eq(when1.negate, false)
	eq(when2.source, "input")
	eq(when2.key, "dry_run")
	eq(when2.negate, true)

	focus(w, PROMPT_WHEN)
	press(w, "backspace", nil, { meta = true })
	press(w, "enter")
	eq(w.st.editor.raw.step[1].when, nil, "empty when clears the condition")
	eq(roundtrip().steps[1].when, nil)

	focus(w, BUDGET)
	press(w, "backspace", nil, { meta = true })
	type_text(w, "lots")
	press(w, "enter")
	eq(w.st.editor.raw.daily_budget, "lots", "a non-number is kept for the validator")
	local found = false
	for _, issue in w.st.editor.issues do
		if string.find(issue.path, "daily_budget", 1, true) then
			found = true
			truthy(string.find(issue.message, "金额", 1, true) ~= nil, issue.message)
		end
	end
	truthy(found, "invalid budget surfaces a validator issue")
	local text = model.encode_workflow(w.st.editor.raw)
	local _, issues = model.parse_workflows(text)
	local hit = false
	for _, issue in issues do
		if string.find(issue.path, "daily_budget", 1, true) then
			hit = true
		end
	end
	truthy(hit, "parse_workflows rejects the non-number budget")
end


do -- workflow files: add, type two lines, save reaches disk under workflows/<id>/files
	local w = world({})
	click(w, "editor-new")
	press(w, "backspace", nil, { meta = true })
	type_text(w, "filesave")
	focus(w, PROMPT_ID)
	type_text(w, "noop")
	local ADD = "layer.editor.body.files.add.input"
	focus(w, ADD)
	press(w, "backspace", nil, { meta = true })
	type_text(w, "main.py")
	click(w, "file-add")
	eq(w.st.editor.files["main.py"], "", "file added to editor state")
	local EDIT = "layer.editor.body.files.edit.input"
	focus(w, EDIT)
	type_text(w, "print(1)")
	press(w, "enter")
	type_text(w, "print(2)")
	step(w, 1)
	eq(w.st.editor.files["main.py"], "print(1)\nprint(2)", "two lines stay in editor state")
	press(w, "enter", nil, { meta = true })
	eq(w.st.editor, nil, "saved with files")
	local path = DATA .. "/workflows/filesave/files/main.py"
	eq(w.env.files[path], "print(1)\nprint(2)", "file content reaches disk via save_workflow")
	local wf = parsed(w).by_id.filesave
	truthy(wf, "filesave workflow written")
end

do -- a file step is selectable and saves as file = "…" with args
	local w = world({})
	click(w, "editor-new")
	press(w, "backspace", nil, { meta = true })
	type_text(w, "filestep")
	focus(w, PROMPT_ID)
	type_text(w, "prep")
	focus(w, "layer.editor.body.files.add.input")
	press(w, "backspace", nil, { meta = true })
	type_text(w, "run.py")
	click(w, "file-add")
	focus(w, "layer.editor.body.files.edit.input")
	type_text(w, "print('go')")
	click(w, "step-add")
	-- new step is s2 (s1 is the prompt)
	w.ui.event(w.st, { ev = "change", id = "layer.editor.body.steps.s2.bar.kind", value = "file" })
	eq(w.st.editor.raw.step[2].file, "", "file kind clears omp/run")
	eq(w.st.editor.raw.step[2].omp, nil)
	eq(w.st.editor.raw.step[2].run, nil)
	view(w)
	w.ui.event(w.st, { ev = "change", id = "layer.editor.body.steps.s2.file.sel", value = "run.py" })
	eq(w.st.editor.raw.step[2].file, "run.py")
	view(w)
	local ARGS = "layer.editor.body.steps.s2.args.input"
	focus(w, ARGS)
	type_text(w, "--flag value")
	press(w, "enter")
	local args = w.st.editor.raw.step[2].args
	truthy(args and args[1] == "--flag" and args[2] == "value", `args split on whitespace: {tostring(args and args[1])} {tostring(args and args[2])}`)
	press(w, "enter", nil, { meta = true })
	eq(w.st.editor, nil, "file step saved")
	local text = file_text(w) :: string
	truthy(has(text, 'file = "run.py"'), "toml has file =")
	truthy(has(text, 'args = ["--flag", "value"]') or has(text, "args = ["), "toml has args")
	local steps = parsed(w).by_id.filestep.steps
	local file_step = nil
	for _, s in steps do
		if s.kind == "file" then
			file_step = s
		end
	end
	truthy(file_step, "parsed file step")
	eq(file_step.file.path, "run.py")
	eq(file_step.file.lib, nil)
	eq(file_step.args[1], "--flag")
	eq(file_step.args[2], "value")
end

do -- pasting a multi-line string into an omp/run step keeps the newlines
	local wf = table.concat({
		"[[workflow]]",
		'id = "ml"',
		"[[workflow.step]]",
		'name = "think"',
		'omp = "one"',
		"[[workflow.step]]",
		'name = "more"',
		'omp = "two"',
		"[[workflow.step]]",
		'name = "shell"',
		'run = "echo a"',
	}, "\n")
	local w = world({ [DATA .. "/workflows.toml"] = wf })
	click(w, "edit=ml")
	view(w)
	-- prompt is s1; extra omp is s2; run is s3
	local TEXT = "layer.editor.body.steps.s2.text.input"
	focus(w, TEXT)
	press(w, "backspace", nil, { meta = true })
	press(w, "paste", "line1\nline2")
	eq(w.st.editor.buf[TEXT].text, "line1\nline2", "omp step paste keeps newlines")
	eq(w.st.editor.buf[TEXT].lines, true, "omp step text is multi-line")
	local RUN = "layer.editor.body.steps.s3.text.input"
	view(w)
	focus(w, RUN)
	press(w, "backspace", nil, { meta = true })
	press(w, "paste", "echo 1\necho 2")
	eq(w.st.editor.buf[RUN].text, "echo 1\necho 2", "run step paste keeps newlines")
	press(w, "enter", nil, { meta = true })
	eq(w.st.editor, nil, "multi-line steps saved")
	local steps = parsed(w).by_id.ml.steps
	eq(steps[2].prompt.parts[1].lit, "line1\nline2", "omp newlines round-trip")
	eq(steps[3].script, "echo 1\necho 2", "run newlines round-trip")
end

do -- deleting the open file must not write its text onto the file that is selected next
	local wf = table.concat({
		"[[workflow]]",
		'id = "two"',
		"[[workflow.step]]",
		'omp = "go"',
	}, "\n")
	local w = world({
		[DATA .. "/workflows.toml"] = wf,
		[DATA .. "/workflows/two/files/a.py"] = "aaa",
		[DATA .. "/workflows/two/files/b.py"] = "bbb",
	})
	click(w, "edit=two")
	view(w)
	eq(w.st.editor.file_sel, "a.py", "the first file is open")
	click(w, "file-del:a.py")
	click(w, "file-del:a.py")
	view(w)
	eq(w.st.editor.file_sel, "b.py")
	press(w, "enter", nil, { meta = true })
	eq(w.st.editor, nil, "saved")
	eq(w.env.files[DATA .. "/workflows/two/files/b.py"], "bbb", "the survivor kept its own text")
	eq(w.env.files[DATA .. "/workflows/two/files/a.py"], nil, "the deleted file is gone")
end

do -- an argument with a space survives opening and saving a file step untouched
	local wf = table.concat({
		"[[workflow]]",
		'id = "sp"',
		"[[workflow.step]]",
		'omp = "go"',
		"[[workflow.step]]",
		'file = "run.py"',
		'args = ["--path", "/tmp/my file"]',
	}, "\n")
	local w = world({ [DATA .. "/workflows.toml"] = wf, [DATA .. "/workflows/sp/files/run.py"] = "print(1)" })
	click(w, "edit=sp")
	view(w)
	press(w, "enter", nil, { meta = true })
	eq(w.st.editor, nil, "saved")
	local file_step = parsed(w).by_id.sp.steps[2]
	eq(#file_step.args, 2, "still two arguments")
	eq(file_step.args[2], "/tmp/my file")
end

do -- tab, upgrade, roost and evolve survive a save without omp/run keys
	local wf = table.concat({
		"[[workflow]]",
		'id = "keep"',
		'name = "保留"',
		"[[workflow.step]]",
		'omp = "stay"',
		"[[workflow]]",
		'id = "iter"',
		'name = "迭代"',
		'evolve = ["*"]',
		"[[workflow.trigger]]",
		'roost = "run_failed"',
		'workflows = ["keep"]',
		"streak = 2",
		"[[workflow.step]]",
		'name = "open"',
		'tab = "open"',
		'key = "main"',
		'title = "日志"',
		'command = "echo hi"',
		"keep = true",
		"focus = true",
		"[[workflow.step]]",
		'name = "shut"',
		'tab = "close"',
		'key = "side"',
		"[[workflow.step]]",
		"upgrade = true",
	}, "\n")
	local w = world({ [DATA .. "/workflows.toml"] = wf })
	click(w, "edit=iter")
	local layer = view(w)
	truthy(find(layer.layer, function(x)
		return x.k == "text" and x.p and type(x.p.spans) == "table" and x.p.spans[1] and string.find(x.p.spans[1].t or "", "scripts/check.sh", 1, true)
	end), "upgrade step shows the muted note")
	local menu = find(layer.layer, function(x)
		return x.k == "menu" and x.p and x.p.key == "add"
	end)
	local listed = false
	for _, item in menu.p.items do
		if item.id == "roost:run_failed" then
			listed = true
		end
	end
	truthy(listed, "add menu lists roost:run_failed")
	press(w, "enter", nil, { meta = true })
	eq(w.st.editor, nil, "saved")
	local text = file_text(w) :: string
	local block = string.match(text, '%[%[workflow%]%][^\n]*\nid = "iter".*') or text
	eq(string.find(block, "omp =", 1, true), nil, "save did not inject omp")
	eq(string.find(block, "run =", 1, true), nil, "save did not inject run")
	local saved = parsed(w).by_id.iter
	eq(saved.evolve[1], "*")
	eq(saved.steps[1].kind, "tab")
	eq(saved.steps[1].tab.action, "open")
	eq(saved.steps[1].tab.key, "main")
	eq(saved.steps[1].tab.title, "日志")
	eq(saved.steps[1].tab.command, "echo hi")
	eq(saved.steps[1].tab.keep, true)
	eq(saved.steps[1].tab.focus, true)
	eq(saved.steps[2].kind, "tab")
	eq(saved.steps[2].tab.action, "close")
	eq(saved.steps[2].tab.key, "side")
	eq(saved.steps[3].kind, "upgrade")
	local tr = saved.triggers[1]
	eq(tr.kind, "roost")
	eq(tr.on, "run_failed")
	eq(tr.workflows[1], "keep")
	eq(tr.streak, 2)
end

do -- omp → tab → run clears the other kind's keys
	local wf = table.concat({
		"[[workflow]]",
		'id = "mix"',
		"[[workflow.step]]",
		'omp = "prompt"',
		"[[workflow.step]]",
		'name = "extra"',
		'omp = "do it"',
		'model = "auto"',
	}, "\n")
	local w = world({ [DATA .. "/workflows.toml"] = wf })
	click(w, "edit=mix")
	view(w)
	w.ui.event(w.st, { ev = "change", id = "layer.editor.body.steps.s2.bar.kind", value = "tab" })
	local extra = w.st.editor.raw.step[2]
	eq(extra.tab, "open")
	eq(extra.key, "main")
	eq(extra.omp, nil, "tab step has no omp")
	eq(extra.run, nil)
	eq(extra.model, nil)
	eq(extra.upgrade, nil)
	w.ui.event(w.st, { ev = "change", id = "layer.editor.body.steps.s2.bar.kind", value = "run" })
	extra = w.st.editor.raw.step[2]
	eq(extra.run, "")
	eq(extra.omp, nil)
	eq(extra.tab, nil, "leaving tab clears tab")
	eq(extra.key, nil)
	eq(extra.title, nil)
	eq(extra.command, nil)
	eq(extra.keep, nil)
	eq(extra.focus, nil)
	eq(extra.upgrade, nil)
end

do -- the add-trigger menu item adds a roost trigger
	local w = world({})
	click(w, "editor-new")
	view(w)
	click(w, "roost:run_failed")
	local tr = w.st.editor.raw.trigger
	eq(#tr, 1)
	eq(tr[1].roost, "run_failed")
	eq(tr[1].github, nil)
	eq(tr[1].schedule, nil)
end

do -- an API trigger: a generated token shows once, only its SHA-256 goes into the workflow
	local w = world({})
	local TOK, HASH = string.rep("1f", 32), string.rep("e3", 32)
	local base = w.env.process
	w.env.process = function(argv: { string }, opts: any): any
		if string.find(argv[3] or "", "openssl rand", 1, true) then
			return { status = 0, stdout = `{TOK}\n{HASH}\n`, stderr = "", timed_out = false }
		end
		return base(argv, opts)
	end
	click(w, "editor-new")
	view(w)
	click(w, "api:new")
	local tr = w.st.editor.raw.trigger
	eq(#tr, 1)
	eq(tr[1].api, "", "no token yet")
	click(w, "api-gen:1")
	w.env.drain()
	eq(tr[1].api, HASH, "the hash is kept")
	local shown = view(w)
	local text = F.text(shown.layer)
	truthy(string.find(text, TOK, 1, true), "the token shows once")
	truthy(string.find(text, "/hooks/dispatch/", 1, true), "with how to call it")
	click(w, "api-copy:1")
	eq(w.cx.copied[#w.cx.copied], TOK)
end

do -- a spot-check trigger edits its sample percent (100 is the default and is left out)
	local w = world({})
	click(w, "editor-new")
	view(w)
	click(w, "roost:run_succeeded")
	local layer = view(w)
	truthy(find(layer.layer, function(x)
		return x.k == "select" and x.p and x.p.value == "100"
	end), "sample select shows every success by default")
	local tr = w.st.editor.raw.trigger
	w.ui.event(w.st, { ev = "change", id = "layer.editor.body.triggers.t1.card.sample.sel", value = "30" })
	eq(tr[1].sample, 30)
	eq(tr[1].streak, nil, "no streak on a spot check")
	w.ui.event(w.st, { ev = "change", id = "layer.editor.body.triggers.t1.card.sample.sel", value = "100" })
	eq(tr[1].sample, nil)
	w.ui.event(w.st, { ev = "change", id = "layer.editor.body.triggers.t1.card.cap.sel", value = "1" })
	eq(tr[1].daily, 1, "per-day cap set")
	w.ui.event(w.st, { ev = "change", id = "layer.editor.body.triggers.t1.card.cap.sel", value = "20" })
	eq(tr[1].daily, nil, "the default cap is left out")
end

print("ok")
